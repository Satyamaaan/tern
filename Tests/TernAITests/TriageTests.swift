import Foundation
import GRDB
import Testing
@testable import TernAI
import TernCore

private func queue(_ database: AppDatabase, _ provider: FakeProvider, batchSize: Int = 15) -> TriageQueue {
    TriageQueue(database: database, providers: AIProviders([provider]), batchSize: batchSize, now: { testNow })
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
    await triage.stop()
    #expect(provider.requests.count == 2)
    #expect(await triage.currentStatus.state == .idle)
}

private func waitUntil(_ condition: @escaping () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting")
}
