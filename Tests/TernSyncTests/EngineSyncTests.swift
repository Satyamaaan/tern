import Foundation
import GRDB
import Testing
import TernCore
@testable import TernSync

@Test func inboxFirstThenRecentMailInFullThenOlderMailAsMetadata() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 120, spacing: 12 * 3600)
    let inboxIds = Set(seeded.filter { $0.labelIds!.contains(SystemLabel.inbox) }.map(\.id))
    let recentIds = Set(seeded.filter { !isOld($0) }.map(\.id))
    let olderIds = Set(seeded.map(\.id)).subtracting(inboxIds).subtracting(recentIds)
    #expect(!olderIds.isEmpty && recentIds.count < 120)

    try await h.sync.initialSync()

    let fetches = await h.fake.fetchCalls
    #expect(fetches.allSatisfy { $0.format == .full })
    #expect(Set(fetches.flatMap(\.ids).prefix(inboxIds.count)) == inboxIds, "the inbox comes first")
    #expect(Set(fetches.flatMap(\.ids)) == inboxIds.union(recentIds))
    var account = try h.account()
    #expect(account.historyId == "1120")
    #expect(account.syncState == .backfilling)
    #expect(account.backfillPageToken == "")
    #expect(try h.inboxThreadIds() == inboxIds)
    #expect(try h.messages().values.allSatisfy { $0.bodyState == .full })
    #expect(try h.store.labels(accountId: testEmail).count == 14)
    var status = await h.sync.status
    #expect(status.phase == "Up to date")
    #expect(status.background == "Older mail syncing in the background")

    await h.fake.resetCallLog()
    while try await h.sync.backfillStep() {}

    account = try h.account()
    #expect(account.syncState == .live && account.backfillDone && account.backfillPageToken == nil)
    let backfill = await h.fake.fetchCalls
    #expect(backfill.allSatisfy { $0.format == .metadata }, "older mail is metadata only")
    #expect(Set(backfill.flatMap(\.ids)) == olderIds)
    #expect(try h.messages().filter { olderIds.contains($0.key) }.values.allSatisfy { $0.bodyState == .metadata && $0.bodyText == nil })
    try await h.expectMirrorsGmail()
    status = await h.sync.status
    #expect(status.state == .live && status.background == nil)
    #expect(status.backfillFetched == 120 && status.backfillTotal == 120)
}

@Test func threadsWithSeveralMessagesComeFromOneThreadsGet() async throws {
    let h = try Harness()
    let first = await h.fake.deliver(FakeEmail(subject: "Plan", date: testNow.addingTimeInterval(-500)))
    var thread = [first.id]
    for offset in [-400.0, -300, -200] {
        thread.append(await h.fake.deliver(FakeEmail(subject: "Re: Plan", date: testNow.addingTimeInterval(offset),
                                                     threadId: first.threadId)).id)
    }
    let single = await h.fake.deliver(FakeEmail(subject: "Solo", date: testNow.addingTimeInterval(-100)))

    try await h.sync.initialSync()

    #expect(await h.fake.threadCalls == [FakeGmail.FetchCall(ids: [first.threadId], format: .full)])
    #expect(await h.fake.fetchCalls.flatMap(\.ids) == [single.id])
    let detail = try #require(try h.store.threadDetail(h.thread(first.threadId)))
    #expect(detail.messages.map(\.id) == thread)
    #expect(detail.messages.allSatisfy { $0.bodyState == .full })
    #expect(await h.fake.unitsSpent < 4 * 60 + 60, "one 120-unit threads.get instead of four 60-unit gets")
}

@Test func clientsWithoutThreadsGetFallBackToMessages() async throws {
    let fake = FakeGmail(email: testEmail, sleep: { _ in })
    let first = await fake.deliver(FakeEmail(subject: "Plan", date: testNow.addingTimeInterval(-500)))
    for offset in [-400.0, -300] {
        await fake.deliver(FakeEmail(subject: "Re: Plan", date: testNow.addingTimeInterval(offset), threadId: first.threadId))
    }
    let h = try Harness(fake: fake)
    await fake.failNext(with: .server(status: 501, message: GmailThread.unsupported), on: .threads)
    let started = h.clock.now()
    try await h.sync.initialSync()
    #expect(try h.messages().count == 3)
    #expect(try h.messages().values.allSatisfy { $0.bodyState == .full })
    #expect(await fake.callCount(.threads) == 1, "not retried")
    #expect(h.clock.now() == started, "no backoff waits")
    #expect(await h.sync.budget.totalUnits == 3 * 60 + 5 + 5 + 1 + 1, "the refused threads.get isn't charged")
}

@Test func changesDuringBackfillArriveThroughHistory() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 80, spacing: 12 * 3600)
    try await h.sync.initialSync()
    #expect(try h.account().historyId == "1080")

    let fresh = await h.fake.deliver(FakeEmail(subject: "During backfill", text: "Hot off the press", date: testNow))
    await h.fake.remoteArchive(threadId: seeded[0].threadId)
    await h.fake.remoteModify([seeded[1].id], add: [SystemLabel.starred])
    try await h.sync.backfillStep()
    try await h.sync.pollHistory()
    while try await h.sync.backfillStep() {}

    try await h.expectMirrorsGmail()
    #expect(try h.message(fresh.id)?.bodyText == "Hot off the press")
    #expect(!(try h.inboxThreadIds().contains(seeded[0].threadId)))
}

@Test func backfillResumesAfterInterruption() async throws {
    let h = try Harness()
    await seed(h.fake, count: 150, spacing: 12 * 3600)
    try await h.sync.initialSync()

    // A page with older mail fails partway through.
    await h.fake.failNext(with: .server(status: 400, message: "boom"), on: .messages, after: 1)
    await #expect(throws: GmailAPIError.self) { while try await h.sync.backfillStep() {} }
    let savedToken = try #require(try h.account().backfillPageToken)
    #expect(!savedToken.isEmpty, "pages before it were saved")
    let storedBefore = Set(try h.messages().keys)

    // The app relaunches and carries on from the saved page.
    await h.fake.resetCallLog()
    let relaunched = h.relaunched()
    while try await relaunched.syncOnce() {}
    while try !h.account().backfillDone { try await relaunched.backfillStep() }

    try await h.expectMirrorsGmail()
    let lists = await h.fake.listCalls
    #expect(lists.first?.pageToken == savedToken)
    #expect(!lists.contains { $0.pageToken == nil && $0.labelIds.isEmpty && $0.query == nil }, "the backfill doesn't start over")
    #expect(Set(await h.fake.fetchCalls.flatMap(\.ids)).isDisjoint(with: storedBefore), "nothing stored is fetched again")
}

@Test func interruptedInitialSyncKeepsItsHistoryId() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 40)
    await h.fake.failNext(with: .server(status: 400, message: "boom"), on: .messages, after: 1)
    await #expect(throws: GmailAPIError.self) { try await h.sync.initialSync() }
    #expect(try h.account().historyId == "1040")
    #expect(try h.account().syncState == .new)

    await h.fake.remoteModify([seeded[0].id], add: [SystemLabel.starred])
    let relaunched = h.relaunched()
    while try await relaunched.syncOnce() {}
    #expect(try h.account().syncState == .live)
    try await h.expectMirrorsGmail()
    #expect(try h.message(seeded[0].id)?.isStarred == true)
}

@Test func serverErrorsAreRetriedAndRateLimitsPauseTheAccount() async throws {
    let h = try Harness()
    await seed(h.fake, count: 30)
    await h.fake.failNext(2, with: .server(status: 503, message: "busy"), on: .messageIds)
    await h.fake.failNext(1, with: .rateLimited(retryAfter: 90), on: .messages)

    await #expect(throws: GmailAPIError.rateLimited(retryAfter: 90)) { try await h.sync.initialSync() }
    #expect(try h.account().syncState == .new, "a rate limit isn't a failure")
    // The whole account waits: even a poll is refused until the pause ends.
    await #expect(throws: GmailAPIError.self) { try await h.sync.pollHistory() }
    await h.sync.publishQuota()
    #expect(await h.sync.status.rateLimitedUntil != nil)

    h.clock.advance(91)
    try await h.syncFully()
    try await h.expectMirrorsGmail()
}

@Test func theQuotaIsNeverExceededAndLiveSyncKeepsRunning() async throws {
    var configuration = SyncConfiguration.test()
    configuration.quota.unitsPerMinute = 1_200
    configuration.bulkReserve = 120
    configuration.backgroundReserve = 300
    configuration.bulkStepUnits = 300
    let h = try Harness(configuration: configuration)
    var quota = GmailQuota()
    quota.unitsPerMinute = 1_200
    await h.fake.enforceQuota(quota, clock: h.clock)
    let seeded = await seed(h.fake, count: 200, inboxEvery: 5, spacing: 6 * 3600)
    let started = h.clock.now()

    try await h.sync.prepare()
    try await h.runLoop { try h.account().syncState == .live }

    #expect(await h.fake.quotaViolations == 0)
    let units = await h.fake.unitsSpent
    let minutes = h.clock.now().timeIntervalSince(started) / 60
    #expect(Double(units) / minutes <= 1_200, "spent \(units) units in \(minutes) minutes")
    #expect(await h.fake.callCount(.history) > 5, "history polls kept running through the backfill")
    #expect(try h.messages().count == seeded.count)
}

@Test func userActionsJumpAheadOfTheBackfill() async throws {
    var configuration = SyncConfiguration.test()
    configuration.quota.unitsPerMinute = 1_000
    configuration.bulkReserve = 100
    configuration.backgroundReserve = 300
    let h = try Harness(configuration: configuration)
    let seeded = await seed(h.fake, count: 300, spacing: 12 * 3600)
    try await h.sync.initialSync()
    h.clock.advance(120)

    // Background steps run until they've used what they may this minute.
    while try await h.sync.syncOnce() {}
    let used = await h.sync.budget.unitsLastMinute
    #expect(used > 490 && used <= 700, "background work stops at 700 of 1,000 units (used \(used))")
    #expect(try !h.account().backfillDone)

    try h.store.perform(.archive, on: [h.thread(seeded[296].threadId)])
    await h.sync.kick()
    try await h.sync.syncOnce()
    #expect(try h.ops().isEmpty, "the action went out without waiting for the minute to pass")
    #expect(await h.fake.labels(of: seeded[296].id)?.contains(SystemLabel.inbox) == false)
}

@Test func statusReportsPhasesAndBackgroundWork() async throws {
    let phases = PhaseLog()
    let store = MailStore(try AppDatabase.inMemory())
    let fake = FakeGmail(email: testEmail, sleep: { _ in })
    await seed(fake, count: 80, spacing: 12 * 3600)
    let sync = AccountSync(account: Account(email: testEmail), store: store, api: fake, encodeDraft: testEncoder,
                           configuration: .test(), clock: EngineTestClock(), statusSink: { phases.append($0) })
    try await sync.initialSync()
    while try await sync.backfillStep() {}
    let seen = phases.snapshots
    #expect(seen.contains { $0.phase == "Fetching inbox" && $0.state == .new })
    #expect(seen.contains { $0.phase == "Fetching the last 30 days" })
    #expect(seen.contains { $0.state == .backfilling && $0.background == "Older mail syncing in the background" && $0.backfillTotal == 80 })
    #expect(seen.last?.phase == "Up to date")
    #expect(seen.last?.state == .live)
    #expect(seen.last?.background == nil)
}

final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SyncStatusSnapshot] = []
    func append(_ snapshot: SyncStatusSnapshot) { lock.withLock { items.append(snapshot) } }
    var snapshots: [SyncStatusSnapshot] { lock.withLock { items } }
}

@Test func bodyTrickleFillsOlderMailSlowly() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 90, spacing: 12 * 3600)
    try await h.syncFully()
    #expect(try h.message(seeded[1].id)?.bodyState == .metadata)
    h.clock.advance(120)

    // The loop trickles one batch, then waits its turn.
    await h.fake.resetCallLog()
    try await h.sync.syncOnce()
    let first = await h.fake.fetchCalls.filter { $0.format == .full }.flatMap(\.ids).count
    #expect(first == 15)
    try await h.sync.syncOnce()
    #expect(await h.fake.fetchCalls.filter { $0.format == .full }.flatMap(\.ids).count == first, "paced")
    let due = try #require(await h.sync.nextBackgroundAt)
    #expect(due.timeIntervalSince(h.clock.now()) == 45, "15 bodies × 60 units at 1,200 units a minute")

    while try await h.sync.prefetchBodies() > 0 {}
    let messages = try h.messages()
    #expect(messages.count == 90 && messages.values.allSatisfy { $0.bodyState == .full })
    #expect(messages[seeded[1].id]?.bodyText == "Body of message 1")
}

@Test func backfillAlsoBringsInTrashAndSpam() async throws {
    let h = try Harness()
    let old = Date(timeIntervalSince1970: 1_600_000_000)
    let trashed = await h.fake.deliver(FakeEmail(subject: "Deleted", date: old, labels: [SystemLabel.trash]))
    let spam = await h.fake.deliver(FakeEmail(subject: "Win big", date: old, labels: [SystemLabel.spam]))
    await seed(h.fake, count: 70)
    try await h.sync.initialSync()
    #expect(try h.message(trashed.id) == nil)

    while try await h.sync.backfillStep() {}
    #expect(try h.message(trashed.id)?.labelIds == [SystemLabel.trash])
    #expect(try h.message(spam.id)?.labelIds == [SystemLabel.spam])
    try await h.expectMirrorsGmail()
}

@Test func quotaBudgetKeepsReservesForInteractiveWork() async throws {
    let clock = EngineTestClock()
    let budget = QuotaBudget(unitsPerMinute: 600, bulkReserve: 100, backgroundReserve: 200, clock: clock)
    try await budget.acquire(400, priority: .background)
    #expect(await budget.delay(for: 50, priority: .background) == 60)
    #expect(await budget.delay(for: 50, priority: .bulk) == 0)
    #expect(await budget.delay(for: 200, priority: .interactive) == 0)
    try await budget.acquire(200, priority: .interactive)
    #expect(await budget.delay(for: 1, priority: .interactive) == 60)

    clock.advance(30)
    let started = clock.now()
    try await budget.acquire(100, priority: .interactive)
    #expect(clock.now().timeIntervalSince(started) == 30, "waited for the window to free up")

    await budget.pause(seconds: 10)
    await #expect(throws: GmailAPIError.self) { try await budget.acquire(1, priority: .interactive) }
    clock.advance(11)
    try await budget.acquire(1, priority: .interactive)
}

@Test func noSingleRequestCostsMoreThanTheCap() async throws {
    var configuration = SyncConfiguration.test()
    configuration.fetchBatchSize = 100
    configuration.bulkStepUnits = 6_000
    let h = try Harness(configuration: configuration)
    await seed(h.fake, count: 60)
    try await h.sync.initialSync()
    #expect(try h.messages().count == 60)
    let calls = await h.fake.fetchCalls
    // The initial sync is bulk work: 4 full messages (240 units) a call.
    #expect(calls.allSatisfy { $0.ids.count * 60 <= configuration.backgroundMaxUnitsPerRequest })
    #expect(calls.contains { $0.ids.count == 4 })

    // Interactive calls may be bigger: a poll that brings 20 new messages fetches 16, then 4.
    await h.fake.resetCallLog()
    for index in 0..<20 { await h.fake.deliver(FakeEmail(subject: "New \(index)", date: testNow)) }
    try await h.sync.pollHistory()
    #expect(await h.fake.fetchCalls.map(\.ids.count) == [16, 4])
}

@Test func aStaleBackfillTokenRestartsTheBackfill() async throws {
    let h = try Harness()
    await seed(h.fake, count: 80, spacing: 12 * 3600)
    try await h.sync.initialSync()
    try await h.sync.backfillStep()
    try h.store.updateAccount(testEmail) { $0.backfillPageToken = "no-longer-valid" }
    try await h.sync.reloadAccount()

    while try await h.sync.backfillStep() {}
    #expect(try h.account().backfillDone)
    try await h.expectMirrorsGmail()
}
