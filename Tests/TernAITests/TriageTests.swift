import Foundation
import GRDB
import Testing
@testable import TernAI
import TernCore

private func queue(_ database: AppDatabase, _ provider: FakeProvider, batchSize: Int = 15, concurrency: Int = 3) -> TriageQueue {
    TriageQueue(database: database, providers: AIProviders([provider]), batchSize: batchSize, concurrency: concurrency, now: { testNow })
}

private func key(_ thread: String) -> ThreadKey {
    ThreadKey(accountId: me.id, threadId: thread)
}

@Test func triageBatchesThreadsAndWritesVerdicts() async throws {
    let mails = (0..<40).map { TestMail(id: "m\($0)", thread: "t\($0)", daysAgo: Double($0) * 0.5) }
    let database = try makeDatabase(mails)
    let provider = FakeProvider { request, _ in triageAnswer(request) }
    let triage = queue(database, provider)

    var sent: [Int] = []
    while true {
        let result = try await triage.processBatch()
        if result.sent == 0 { break }
        sent.append(result.sent)
        #expect(result.classified == result.sent)
    }
    #expect(sent == [15, 15, 10])
    #expect(provider.requests.map { refsIn($0.input).count } == [15, 15, 10])
    #expect(provider.requests.allSatisfy { $0.schema != nil && $0.model == nil })

    let rows = try aiRows(database)
    #expect(rows.count == 40)
    #expect(rows.values.allSatisfy { $0.source == "codex" && $0.category == .people && $0.needsReply && $0.priority == 2 })
    #expect(rows["t0"]?.summary?.hasPrefix("Summary") == true)
    #expect(await triage.currentStatus.classified == 40)
}

@Test func triagePayloadIsCompactAndInstructionsHoldNoMail() async throws {
    let long = String(repeating: "Budget numbers for the launch plan. ", count: 60)
    let database = try makeDatabase([
        TestMail(id: "m1", thread: "t1", subject: "Launch plan", body: "FIRST MESSAGE should not be sent", daysAgo: 3),
        TestMail(id: "m2", thread: "t1", from: me.email, to: "ethan.brooks@gmail.com", subject: "Re: Launch plan", body: "Sounds good.", daysAgo: 2),
        TestMail(id: "m3", thread: "t1", subject: "Re: Launch plan",
                 body: "Can you confirm? \(long)\n\nOn Tue, Alex wrote:\n> QUOTED reply text", daysAgo: 1),
    ])
    let provider = FakeProvider { request, _ in triageAnswer(request) }
    try await queue(database, provider).processBatch()

    let request = try #require(provider.requests.first)
    #expect(request.input.contains("Subject: Launch plan"))
    #expect(request.input.contains("Messages in thread: 3"))
    #expect(request.input.contains("<message from=\"the owner\""))
    #expect(!request.input.contains("FIRST MESSAGE"))
    #expect(!request.input.contains("QUOTED"))
    #expect(request.input.contains("Owner addresses: \(me.email)"))
    let latest = try #require(request.input.components(separatedBy: "<message").last?.components(separatedBy: "\n")[1])
    #expect(latest.count <= 600 && latest.hasPrefix("Can you confirm?"))
    #expect(!request.instructions.contains("Launch plan") && !request.instructions.contains("Budget"))
    #expect(request.instructions.contains("untrusted"))
}

@Test func triagePicksOnlyThreadsThatNeedIt() async throws {
    let database = try makeDatabase([
        TestMail(id: "a", thread: "missing"),
        TestMail(id: "b", thread: "rules-people"),
        TestMail(id: "c", thread: "rules-notification"),
        TestMail(id: "d", thread: "ai-current"),
        TestMail(id: "e1", thread: "ai-stale", daysAgo: 2), TestMail(id: "e2", thread: "ai-stale"),
        TestMail(id: "f", thread: "old", daysAgo: 45),
        TestMail(id: "g", thread: "sent-only", from: me.email, to: "x@y.com"),
        TestMail(id: "h", thread: "trashed", labels: [SystemLabel.trash]),
    ])
    try await database.writer.write { db in
        for (thread, category, source, count) in [
            ("rules-people", MailCategory.people, "rules", 1), ("rules-notification", .notification, "rules", 1),
            ("ai-current", .people, "claude", 1), ("ai-stale", .people, "claude", 1),
        ] {
            try ThreadAI(accountId: me.id, threadId: thread, category: category, source: source, messageCount: count).upsert(db)
        }
    }
    let provider = FakeProvider { request, _ in triageAnswer(request) }
    let result = try await queue(database, provider).processBatch()
    #expect(result.sent == 3)
    let threads = try await database.reader.read { db in
        try TriageQueue.candidates(db, since: testNow.addingTimeInterval(-30 * 86_400), limit: 50).map(\.key.threadId)
    }
    #expect(threads.isEmpty)
    let rows = try aiRows(database)
    #expect(rows["missing"]?.source == "codex" && rows["rules-people"]?.source == "codex" && rows["ai-stale"]?.source == "codex")
    #expect(rows["ai-stale"]?.messageCount == 2)
    #expect(rows["rules-notification"]?.source == "rules" && rows["ai-current"]?.source == "claude")
    #expect(rows["old"] == nil && rows["sent-only"] == nil && rows["trashed"] == nil)
}

@Test func triageDoesNothingWhileDisabled() async throws {
    let database = try makeDatabase([TestMail(id: "a", thread: "t")], settings: AISettings(enabled: false, provider: "codex"))
    let provider = FakeProvider { request, _ in triageAnswer(request) }
    let triage = queue(database, provider)
    await #expect(throws: AIError.disabled) { try await triage.processBatch() }
    await triage.runPass()
    #expect(await triage.currentStatus.state == .off)
    #expect(provider.requests.isEmpty)
}

@Test func triageRetriesOnceOnMalformedOutput() async throws {
    let database = try makeDatabase([TestMail(id: "a", thread: "t1")])
    let provider = FakeProvider { request, attempt in attempt == 1 ? "Sorry, here it is: {items: [" : triageAnswer(request) }
    let result = try await queue(database, provider).processBatch()
    #expect(result.classified == 1)
    #expect(provider.requests.count == 2)

    let stubborn = FakeProvider { _, _ in "no json at all" }
    let database2 = try makeDatabase([TestMail(id: "a", thread: "t1")])
    let triage = queue(database2, stubborn)
    await #expect(throws: AIError.invalidOutput("The triage answer couldn't be read.")) { try await triage.processBatch() }
    #expect(stubborn.requests.count == 2)
    // The thread isn't resent until it changes.
    #expect(try await triage.processBatch().sent == 0)
    #expect(try aiRows(database2).isEmpty)
}

@Test func triageNeverMarksOwnLastMessageAsNeedingReply() async throws {
    let database = try makeDatabase([
        TestMail(id: "a1", thread: "t1", daysAgo: 2),
        TestMail(id: "a2", thread: "t1", from: me.email, to: "ethan.brooks@gmail.com", body: "On it."),
    ])
    let provider = FakeProvider { request, _ in triageAnswer(request, needsReply: true) }
    try await queue(database, provider).processBatch()
    #expect(try aiRows(database)["t1"]?.needsReply == false)
}

@Test func triageSuggestsProjectsOnlyWhenAllowed() async throws {
    let mails = [TestMail(id: "a", thread: "t1"), TestMail(id: "b", thread: "t2")]
    let lumen = Project(id: "p-lumen", name: "Lumen redesign")
    let home = Project(id: "p-home", name: "Home")
    for autoProjects in [false, true] {
        let database = try makeDatabase(mails, settings: AISettings(enabled: true, provider: "codex", autoProjects: autoProjects))
        try await database.writer.write { db in
            try lumen.insert(db)
            try home.insert(db)
            try ThreadProject(accountId: me.id, threadId: "t2", projectId: "p-home", source: .manual).insert(db)
            try ThreadProject(accountId: me.id, threadId: "t1", projectId: "p-home", source: .ai).insert(db)
        }
        let provider = FakeProvider { request, _ in triageAnswer(request, project: "Lumen redesign") }
        try await queue(database, provider).processBatch()
        let links = try await database.reader.read { db in
            Set(try ThreadProject.fetchAll(db).map { "\($0.threadId):\($0.projectId):\($0.source.rawValue)" })
        }
        if autoProjects {
            #expect(provider.requests[0].input.contains("- id p-lumen: Lumen redesign"))
            #expect(links == ["t1:p-lumen:ai", "t2:p-home:manual", "t2:p-lumen:ai"])
        } else {
            #expect(!provider.requests[0].input.contains("p-lumen"))
            #expect(links == ["t1:p-home:ai", "t2:p-home:manual"])
        }
    }
}

@Test func triageNeverRefilesAThreadTakenOutByHand() async throws {
    let mails = [TestMail(id: "a", thread: "t1"), TestMail(id: "b", thread: "t2")]
    let lumen = Project(id: "p-lumen", name: "Lumen redesign")
    let database = try makeDatabase(mails, settings: AISettings(enabled: true, provider: "codex", autoProjects: true))
    try await database.writer.write { db in
        try lumen.insert(db)
        try ProjectExclusion(accountId: me.id, threadId: "t1", projectId: "p-lumen").insert(db)
    }
    let provider = FakeProvider { request, _ in triageAnswer(request, project: "Lumen redesign") }
    try await queue(database, provider).processBatch()
    let links = try await database.reader.read { db in Set(try ThreadProject.fetchAll(db).map(\.threadId)) }
    #expect(links == ["t2"])
}

@Test func triagePausesOnRateLimitAndSignOut() async throws {
    let database = try makeDatabase([TestMail(id: "a", thread: "t1")])
    let limited = FakeProvider { _, _ in throw AIError.rateLimited("usage limit reached") }
    let triage = queue(database, limited)
    await triage.runPass()
    guard case .waiting(let until, _) = await triage.currentStatus.state else {
        Issue.record("expected waiting, got \(await triage.currentStatus.state)")
        return
    }
    #expect(until == testNow.addingTimeInterval(300))
    // While waiting, another pass sends nothing.
    await triage.runPass()
    #expect(limited.requests.count == 1)

    let signedOut = FakeProvider(availability: .signedOut) { _, _ in "" }
    let other = queue(try makeDatabase([TestMail(id: "a", thread: "t1")]), signedOut)
    await other.runPass()
    #expect(await other.currentStatus.state == .unavailable("codex isn't signed in."))
    #expect(signedOut.requests.isEmpty)
}

@Test func triageQueueRunsOnNewMail() async throws {
    let database = try makeDatabase([TestMail(id: "a", thread: "t1")])
    let provider = FakeProvider { request, _ in triageAnswer(request) }
    let triage = TriageQueue(database: database, providers: AIProviders([provider]), debounce: .milliseconds(20), now: { testNow })
    await triage.start()
    try await waitUntil { (try? aiRows(database).count) == 1 }

    try MailStore(database).upsertMessages([MailMessage(
        accountId: me.id, id: "b", threadId: "t2", date: testNow, fromName: "Ethan", fromEmail: "ethan.brooks@gmail.com",
        toList: [Participant(email: me.email)], subject: "New", snippet: "Free tomorrow?", bodyText: "Free tomorrow?",
        bodyState: .full, labelIds: [SystemLabel.inbox])])
    try await waitUntil { (try? aiRows(database).count) == 2 }
    // The pass writes its rows before it reports idle; wait for the report rather than racing it.
    for _ in 0..<200 where await triage.currentStatus.state != .idle { try await Task.sleep(for: .milliseconds(10)) }
    await triage.stop()
    #expect(provider.requests.count == 2)
    #expect(await triage.currentStatus.state == .idle)
}

@Test func triageRunsSeveralCallsAtOnceUpToTheCap() async throws {
    let database = try makeDatabase((0..<60).map { TestMail(id: "m\($0)", thread: "t\($0)", daysAgo: Double($0) * 0.2) })
    let running = Counter()
    let provider = FakeProvider { request, _ in
        await running.enter()
        try await Task.sleep(for: .milliseconds(100))
        await running.leave()
        return triageAnswer(request)
    }
    await queue(database, provider, batchSize: 5, concurrency: 3).runPass()
    #expect(await running.peak == 3)
    #expect(provider.requests.count == 12, "every thread went out once")
    #expect(provider.requests.allSatisfy { $0.isBackground })
    #expect(try aiRows(database).count == 60)
}

@Test func triageBacksOffOnceWhenConcurrentCallsHitTheUsageLimit() async throws {
    let database = try makeDatabase((0..<40).map { TestMail(id: "m\($0)", thread: "t\($0)", daysAgo: Double($0) * 0.2) })
    let state = TestState()
    state.isOn = true
    let running = Counter()
    let provider = FakeProvider { request, _ in
        await running.enter()
        try await Task.sleep(for: .milliseconds(20))
        await running.leave()
        if state.isOn { throw AIError.rateLimited("usage limit reached") }
        return triageAnswer(request)
    }
    let triage = TriageQueue(database: database, providers: AIProviders([provider]), batchSize: 5, concurrency: 3, now: { state.now })

    // Three calls at once all hit the limit: one pause of five minutes, nothing written.
    await triage.runPass()
    #expect(provider.requests.count == 3)
    #expect(await triage.currentStatus.state == .waiting(until: testNow.addingTimeInterval(300), reason: "usage limit reached"))
    #expect(try aiRows(database).isEmpty)
    await triage.runPass()
    #expect(provider.requests.count == 3, "nothing is sent while waiting")

    // Still limited: the next pass tries one call, and the pause doubles once (not once per call).
    state.now = testNow.addingTimeInterval(301)
    await triage.runPass()
    #expect(provider.requests.count == 4)
    #expect(await triage.currentStatus.state == .waiting(until: state.now.addingTimeInterval(600), reason: "usage limit reached"))

    // The limit lifts: the pass starts with a single call, ramps up, and no thread was dropped.
    state.isOn = false
    state.now = state.now.addingTimeInterval(601)
    let before = await running.atStart.count
    await triage.runPass()
    #expect(await running.atStart[before] == 1)
    #expect(try aiRows(database).count == 40)
    #expect(provider.requests.count == 4 + 8)
    #expect(await triage.currentStatus.state == .idle)
}

@Test func triageResendsAFailedCallInHalves() async throws {
    let database = try makeDatabase((0..<3).map { TestMail(id: "m\($0)", thread: "t\($0)") })
    let provider = FakeProvider { request, attempt in
        if attempt == 1 { throw AIError.timedOut }
        return triageAnswer(request)
    }
    let triage = queue(database, provider)
    await #expect(throws: AIError.timedOut) { try await triage.processBatch() }
    #expect(try await triage.processBatch() == .init(sent: 2, classified: 2))
    #expect(try await triage.processBatch() == .init(sent: 1, classified: 1))
    #expect(try await triage.processBatch().sent == 0)
}

@Test func triageSetsAsideTheThreadThatMakesCallsTimeOutUntilItChanges() async throws {
    let mails = (0..<12).map { TestMail(id: "m\($0)", thread: "t\($0)", subject: $0 == 5 ? "Poison" : "Thread \($0)", daysAgo: 1 + Double($0) * 0.1) }
    let database = try makeDatabase(mails)
    let state = TestState()
    state.isOn = true
    let provider = FakeProvider { request, _ in
        if state.isOn && subjectsIn(request.input).contains("Poison") { throw AIError.timedOut }
        return triageAnswer(request)
    }
    let triage = TriageQueue(database: database, providers: AIProviders([provider]), batchSize: 8, concurrency: 1, now: { state.now })
    // Each time-out pauses the queue two minutes.
    for _ in 0..<12 {
        await triage.runPass()
        state.now = state.now.addingTimeInterval(121)
    }
    // The batch with the bad thread is halved until the thread is alone, which fails twice: then it waits.
    let poisoned = provider.requests.map { subjectsIn($0.input) }.filter { $0.contains("Poison") }
    #expect(poisoned.map(\.count) == [8, 4, 2, 1, 1])
    #expect(provider.requests.count == 9, "8 + its halves, then the four after them")
    var rows = try aiRows(database)
    #expect(rows.count == 11 && rows["t5"] == nil)
    await triage.runPass()
    #expect(provider.requests.count == 9, "set aside, not sent again")

    // New mail in the thread: it goes out again, like any thread.
    state.isOn = false
    try MailStore(database).upsertMessages([MailMessage(
        accountId: me.id, id: "m5b", threadId: "t5", date: testNow, fromName: "Ethan", fromEmail: "ethan.brooks@gmail.com",
        toList: [Participant(email: me.email)], subject: "Re: Poison", snippet: "Any news?", bodyText: "Any news?",
        bodyState: .full, labelIds: [SystemLabel.inbox])])
    await triage.runPass()
    rows = try aiRows(database)
    #expect(rows["t5"]?.source == "codex" && rows["t5"]?.messageCount == 2)
}

@Test func triageStopsSendingCallsThatAlwaysFail() async throws {
    let database = try makeDatabase((0..<4).map { TestMail(id: "m\($0)", thread: "t\($0)") })
    let state = TestState()
    let provider = FakeProvider { _, _ in throw AIError.failed("Codex: ERROR: boom") }
    let triage = TriageQueue(database: database, providers: AIProviders([provider]), batchSize: 4, concurrency: 1, now: { state.now })
    for _ in 0..<30 {
        await triage.runPass()
        state.now = state.now.addingTimeInterval(121)
    }
    // 4, then 2 + 2, then each thread alone twice: eleven calls, then nothing more until mail changes.
    #expect(provider.requests.map { refsIn($0.input).count } == [4, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1])
    #expect(try aiRows(database).isEmpty)
    #expect(await triage.currentStatus.state == .idle)
}

@Test func triageFindsEligibleMailBehindMoreThanTwoThousandSetAside() async throws {
    let database = try makeDatabase((0..<2_050).map { TestMail(id: "m\($0)", thread: "t\($0)", daysAgo: 1 + Double($0) * 0.01) })
    let state = TestState()
    state.isOn = true
    // While the switch is on the model answers for the first thread of a call only: 2,008 of the newest
    // threads are remembered as sent, unchanged, ahead of 40 older threads that still need sorting.
    let provider = FakeProvider { request, _ in
        guard state.isOn else { return triageAnswer(request) }
        return #"{"items":[{"threadKey":"1","category":"people","needsReply":false,"priority":1,"summary":"One"}]}"#
    }
    let triage = queue(database, provider, batchSize: 1_005)
    #expect(try await triage.processBatch() == .init(sent: 1_005, classified: 1))
    #expect(try await triage.processBatch() == .init(sent: 1_005, classified: 1))
    #expect(await triage.remembered.sent == 2_010)

    state.isOn = false
    #expect(try await triage.processBatch() == .init(sent: 40, classified: 40))
    #expect(subjectsIn(provider.requests[2].input).count == 40)
    #expect(try await triage.processBatch().sent == 0)
    #expect(try aiRows(database).count == 42)
}

@Test func triageForgetsThreadsItNoLongerNeeds() async throws {
    let database = try makeDatabase((0..<6).map { TestMail(id: "m\($0)", thread: "t\($0)", daysAgo: 1 + Double($0)) })
    let state = TestState()
    let provider = FakeProvider { request, attempt in
        if attempt == 1 { throw AIError.timedOut }
        // Later calls answer for the first thread only; the rest are remembered as sent.
        return #"{"items":[{"threadKey":"1","category":"people","needsReply":false,"priority":1,"summary":"One"}]}"#
    }
    let triage = TriageQueue(database: database, providers: AIProviders([provider]), batchSize: 4, now: { state.now })
    await #expect(throws: AIError.timedOut) { try await triage.processBatch() }
    #expect(await triage.remembered == (sent: 0, failed: 4, retries: 2))
    // A retry that comes back settles its threads, failures and all.
    try await triage.processBatch()
    #expect(await triage.remembered == (sent: 2, failed: 2, retries: 1))
    try await triage.processBatch()
    #expect(await triage.remembered == (sent: 4, failed: 0, retries: 0))

    // Each pass first forgets classified threads (t0 and t2; t4 is classified in this pass)...
    await triage.runPass()
    #expect(try aiRows(database).keys.sorted() == ["t0", "t2", "t4"])
    #expect(await triage.remembered.sent == 4)
    await triage.runPass()
    #expect(await triage.remembered.sent == 3)
    // ...and threads that fell out of the window.
    state.now = testNow.addingTimeInterval(40 * 86_400)
    await triage.runPass()
    #expect(await triage.remembered == (sent: 0, failed: 0, retries: 0))
}

@Test func triageCancelsQueuedAndRunningCallsWhenAIIsTurnedOff() async throws {
    let database = try makeDatabase((0..<20).map { TestMail(id: "m\($0)", thread: "t\($0)", daysAgo: Double($0) * 0.2) })
    let gate = CLIGate(limit: 2, backgroundLimit: 2)
    let started = Recorder()
    let stopped = Recorder()
    let provider = FakeProvider { request, _ in
        try await gate.withSlot(background: request.isBackground) {
            await started.add("call")
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                await stopped.add("call")
                throw error
            }
            return triageAnswer(request)
        }
    }
    // An on-demand call holds one slot: one triage call runs, two wait behind it.
    let latch = Latch()
    let onDemand = Task { try await gate.withSlot { await latch.wait() } }
    for _ in 0..<200 where await gate.occupancy.running == 0 { try await Task.sleep(for: .milliseconds(5)) }
    let triage = TriageQueue(
        database: database, providers: AIProviders([provider]), batchSize: 5, concurrency: 3,
        debounce: .milliseconds(10), now: { testNow })
    await triage.start()
    for _ in 0..<400 where await gate.occupancy.waiting < 2 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await started.items.count == 1)

    try await database.writer.write { db in try AISettings(enabled: false, provider: "codex").write(db) }
    for _ in 0..<400 where await triage.currentStatus.state != .off { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await triage.currentStatus.state == .off)
    #expect(await stopped.items.count == 1, "the running call was stopped")
    await latch.release()
    try await onDemand.value
    try await Task.sleep(for: .milliseconds(100))
    #expect(await started.items.count == 1, "the waiting calls never started")
    #expect(try aiRows(database).isEmpty)
    let occupancy = await gate.occupancy
    #expect(occupancy.running == 0 && occupancy.waiting == 0)
    await triage.stop()
}

@Test func triageDropsAnswersFromTheProviderItSwitchedFrom() async throws {
    let database = try makeDatabase((0..<10).map { TestMail(id: "m\($0)", thread: "t\($0)", daysAgo: Double($0) * 0.2) })
    let latch = Latch()
    // The old provider ignores cancellation and answers after the switch anyway.
    let codex = FakeProvider(id: "codex") { request, _ in
        await latch.wait()
        return triageAnswer(request)
    }
    let claude = FakeProvider(id: "claude") { request, _ in triageAnswer(request, category: "notification", needsReply: false) }
    let triage = TriageQueue(
        database: database, providers: AIProviders([codex, claude]), batchSize: 5, concurrency: 2,
        debounce: .milliseconds(10), now: { testNow })
    await triage.start()
    for _ in 0..<400 where codex.requests.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
    let before = await triage.generation

    try await database.writer.write { db in try AISettings(enabled: true, provider: "claude").write(db) }
    for _ in 0..<400 where await triage.generation == before { try await Task.sleep(for: .milliseconds(5)) }
    await latch.release()
    for _ in 0..<400 where (try? aiRows(database).count) != 10 { try await Task.sleep(for: .milliseconds(5)) }
    await triage.stop()
    let rows = try aiRows(database)
    #expect(rows.count == 10)
    #expect(rows.values.allSatisfy { $0.source == "claude" && $0.category == .notification })
    #expect(codex.requests.count == 2)
}

@Test func triageSkipsTheDebounceForRowsOnScreen() async throws {
    let database = try makeDatabase((0..<3).map { TestMail(id: "m\($0)", thread: "t\($0)") })
    let provider = FakeProvider { request, _ in triageAnswer(request) }
    let triage = TriageQueue(database: database, providers: AIProviders([provider]), debounce: .seconds(60), now: { testNow })
    // The first pass waits out a long debounce...
    await triage.start()
    try await Task.sleep(for: .milliseconds(100))
    #expect(provider.requests.isEmpty)
    // ...until rows on screen need sorting.
    await triage.prioritize([key("t1")])
    for _ in 0..<200 where (try? aiRows(database).count) != 3 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(try aiRows(database).count == 3)
    #expect(subjectsIn(provider.requests[0].input).count == 1, "the row on screen went first, alone")
    await triage.stop()
}

@Test func triageSendsThreadsOnScreenFirst() async throws {
    let inbox = (0..<20).map { TestMail(id: "i\($0)", thread: "inbox\($0)", subject: "Inbox \($0)", daysAgo: 1 + Double($0) * 0.1) }
    let archived = (0..<6).map { TestMail(id: "a\($0)", thread: "old\($0)", subject: "Old \($0)", daysAgo: 10 + Double($0), labels: []) }
    let database = try makeDatabase(inbox + archived)
    let provider = FakeProvider { request, _ in triageAnswer(request) }
    let triage = queue(database, provider, batchSize: 10, concurrency: 1)

    // The rows on screen go first, in screen order and in a batch of their own; threads that don't
    // need AI (or don't exist) are skipped.
    await triage.prioritize([key("old4"), key("old1"), key("inbox3"), key("missing"), key("old4")])
    #expect(try await triage.processBatch().sent == 3)
    #expect(subjectsIn(provider.requests[0].input) == ["Old 4", "Old 1", "Inbox 3"])
    // Then the inbox, newest first, then older mail.
    try await triage.processBatch()
    #expect(subjectsIn(provider.requests[1].input) == ["Inbox 0", "Inbox 1", "Inbox 2"] + (4...10).map { "Inbox \($0)" })
    try await triage.processBatch()
    #expect(subjectsIn(provider.requests[2].input) == (11...19).map { "Inbox \($0)" } + ["Old 0"])
    try await triage.processBatch()
    #expect(subjectsIn(provider.requests[3].input) == ["Old 2", "Old 3", "Old 5"])
}

@Test func triageSplitsThreadsOnScreenAcrossFreeCalls() async throws {
    let mails = (0..<30).map { TestMail(id: "m\($0)", thread: "t\($0)", subject: "Thread \($0)", daysAgo: 1 + Double($0) * 0.1) }
    let database = try makeDatabase(mails)
    let provider = FakeProvider { request, _ in
        try await Task.sleep(for: .milliseconds(50))
        return triageAnswer(request)
    }
    let triage = queue(database, provider, batchSize: 15, concurrency: 3)
    let screen = (10..<22).map { key("t\($0)") }
    await triage.prioritize(screen)
    await triage.runPass()
    // Twelve threads on screen over three free calls: no call smaller than five, nothing else mixed in.
    let first = provider.requests.prefix(3).map { subjectsIn($0.input) }
    #expect(first.map(\.count) == [5, 5, 2])
    #expect(Set(first.joined()) == Set((10..<22).map { "Thread \($0)" }))
    #expect(try aiRows(database).count == 30)
}

@Test func triageReportsProgressWhileItWorks() async throws {
    let database = try makeDatabase((0..<40).map { TestMail(id: "m\($0)", thread: "t\($0)", daysAgo: Double($0) * 0.2) })
    let box = QueueBox()
    let seen = ProgressLog()
    let provider = FakeProvider { request, _ in
        if let progress = await box.queue?.currentStatus.progress { await seen.add(progress) }
        try await Task.sleep(for: .milliseconds(20))
        return triageAnswer(request)
    }
    let triage = queue(database, provider, batchSize: 10, concurrency: 2)
    box.queue = triage
    await triage.runPass()
    let log = await seen.items
    #expect(log.count == 4)
    #expect(log.allSatisfy { $0.total == 40 })
    #expect(log.map(\.done) == log.map(\.done).sorted() && log.first?.done == 0 && (log.last?.done ?? 40) < 40)
    let status = await triage.currentStatus
    #expect(status.progress == nil && status.state == .idle && status.classified == 40)
}

private final class QueueBox: @unchecked Sendable {
    var queue: TriageQueue?
}

private actor ProgressLog {
    var items: [TriageQueue.Progress] = []
    func add(_ item: TriageQueue.Progress) { items.append(item) }
}

private func waitUntil(_ condition: @escaping () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting")
}

@Test func triagePromptSizeIsPinned() {
    let owner = me.email
    let ethan = Participant(name: "Ethan Brooks", email: "ethan@example.com")
    let team = (1...9).map { Participant(name: "Teammate \($0)", email: "team\($0)@example.com") }
    let threads = (1...15).map { index in
        PromptThread(
            key: ThreadKey(accountId: me.id, threadId: "t\(index)"), subject: "Launch plan \(index)", messageCount: 2,
            lastDate: testNow, labels: ["inbox", "unread"], messages: [
                .init(from: Participant(name: "Alex Morgan", email: owner), to: [ethan], cc: [], date: testNow.addingTimeInterval(-7_200),
                      text: String(repeating: "Sounds good, see my notes. ", count: 11), isFromMe: true),
                .init(from: ethan, to: team.prefix(3) + [Participant(name: "Alex Morgan", email: owner)] + team.dropFirst(3), cc: [],
                      date: testNow, text: String(repeating: "Can you confirm the budget by Thursday? ", count: 14), isFromMe: false),
            ])
    }
    let request = Prompts.triage(threads, refs: (1...15).map(String.init), owner: [owner], projects: nil, today: testNow)
    // What every triage call sends for 15 threads. A change here changes the cost of every call: update
    // these numbers on purpose, with a measurement.
    #expect(request.instructions.utf8.count == 1_536)
    #expect(request.input.utf8.count == 19_641)
    #expect(request.schema?.utf8.count == 494)
    // Long recipient lists are cut to four, the owner's address first.
    #expect(request.input.contains(
        #"to="Alex Morgan ‹alex@kiteworks.dev›, Teammate 1 ‹team1@example.com›, Teammate 2 ‹team2@example.com›, Teammate 3 ‹team3@example.com› +6 more""#))
    // The summary comes before needsReply, so the model writes down what is asked first.
    let schema = request.schema ?? ""
    #expect(schema.range(of: #""summary""#)!.lowerBound < schema.range(of: #""needsReply""#)!.lowerBound)
}
