import Foundation
import GRDB
import Testing
import TernCore
@testable import TernSync

extension Harness {
    func syncFully() async throws {
        try await sync.initialSync()
        while try await sync.backfillStep() {}
    }
}

@Test func initialSyncFetchesInboxFirstThenBackfills() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 120)
    let inboxIds = Set(seeded.filter { $0.labelIds!.contains(SystemLabel.inbox) }.map(\.id))

    try await h.sync.initialSync()

    let fetches = await h.fake.fetchCalls
    #expect(Set(fetches.flatMap(\.ids).prefix(inboxIds.count)) == inboxIds)
    #expect(fetches.allSatisfy { $0.format == .full })
    var account = try h.account()
    #expect(account.historyId == "1120")
    #expect(account.syncState == .backfilling)
    #expect(account.backfillPageToken != nil)
    #expect(try h.inboxThreadIds() == inboxIds)
    let stored = try h.messages()
    let newest = seeded.suffix(30).map(\.id)
    #expect(newest.allSatisfy { stored[$0]?.bodyState == .full })
    #expect(stored.count == Set(newest).union(inboxIds).count)
    #expect(try h.store.labels(accountId: testEmail).count == 14)
    #expect(await h.sync.status.phase == "Fetching older mail")

    while try await h.sync.backfillStep() {}

    account = try h.account()
    #expect(account.syncState == .live)
    #expect(account.backfillDone)
    #expect(account.backfillPageToken == nil)
    try await h.expectMirrorsGmail()
    let all = await h.fake.fetchCalls.flatMap(\.ids)
    #expect(all.count == Set(all).count, "no message is fetched twice")
    let status = await h.sync.status
    #expect(status.state == .live && status.fetched == 120 && status.total == 120)
}

@Test func changesDuringBackfillArriveThroughHistory() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 80)
    try await h.sync.initialSync()
    #expect(try h.account().historyId == "1080")

    // While older mail is still coming in: new mail, and the user archives on their phone.
    let fresh = await h.fake.deliver(FakeEmail(subject: "During backfill", text: "Hot off the press"))
    await h.fake.remoteArchive(threadId: seeded[0].threadId)
    try await h.sync.backfillStep()
    try await h.sync.pollHistory()
    while try await h.sync.backfillStep() {}

    try await h.expectMirrorsGmail()
    #expect(try h.message(fresh.id)?.bodyText == "Hot off the press")
    #expect(!(try h.inboxThreadIds().contains(seeded[0].threadId)))
}

@Test func backfillResumesAfterInterruption() async throws {
    let h = try Harness()
    await seed(h.fake, count: 150)
    try await h.sync.initialSync()
    try await h.sync.backfillStep()
    let savedToken = try #require(try h.account().backfillPageToken)

    // The next page fails halfway through fetching its messages.
    await h.fake.failNext(with: .server(status: 400, message: "boom"), on: .messages, after: 1)
    await #expect(throws: GmailAPIError.self) { try await h.sync.backfillStep() }
    #expect(try h.account().backfillPageToken == savedToken)

    // The app relaunches and carries on from the saved page.
    await h.fake.resetCallLog()
    let relaunched = h.relaunched()
    while try await relaunched.syncOnce() {}

    #expect(try h.account().backfillDone)
    try await h.expectMirrorsGmail()
    let lists = await h.fake.listCalls
    #expect(lists.first?.pageToken == savedToken)
    #expect(!lists.contains { $0.pageToken == nil && $0.labelIds.isEmpty }, "the backfill doesn't start over")
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
    try await h.expectMirrorsGmail()
    #expect(try h.message(seeded[0].id)?.isStarred == true)
}

@Test func rateLimitsAndServerErrorsAreRetried() async throws {
    let h = try Harness()
    await seed(h.fake, count: 30)
    await h.fake.failNext(2, with: .rateLimited(retryAfter: 7), on: .messages)
    await h.fake.failNext(2, with: .server(status: 503, message: "busy"), on: .messageIds)
    let started = h.clock.now()
    try await h.syncFully()
    try await h.expectMirrorsGmail()
    #expect(h.clock.now().timeIntervalSince(started) >= 14, "the retries waited on the injected clock")
}

@Test func statusReportsPhases() async throws {
    let phases = PhaseLog()
    let store = MailStore(try AppDatabase.inMemory())
    let fake = FakeGmail(email: testEmail, sleep: { _ in })
    await seed(fake, count: 50)
    let sync = AccountSync(account: Account(email: testEmail), store: store, api: fake, encodeDraft: testEncoder,
                           configuration: .test(), clock: TestClock(), statusSink: { phases.append($0) })
    try await sync.initialSync()
    while try await sync.backfillStep() {}
    let seen = phases.snapshots.map(\.phase)
    #expect(seen.contains("Fetching inbox"))
    #expect(seen.contains("Fetching recent mail"))
    #expect(seen.last == "Up to date")
    #expect(phases.snapshots.last?.state == .live)
}

final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SyncStatusSnapshot] = []
    func append(_ snapshot: SyncStatusSnapshot) { lock.withLock { items.append(snapshot) } }
    var snapshots: [SyncStatusSnapshot] { lock.withLock { items } }
}

@Test func prefetchFillsBodiesOfMetadataBackfill() async throws {
    var configuration = SyncConfiguration.test()
    configuration.backfillFormat = .metadata
    let h = try Harness(configuration: configuration)
    let seeded = await seed(h.fake, count: 90)
    try await h.syncFully()
    let oldest = try #require(try h.message(seeded[1].id))
    #expect(oldest.bodyState == .metadata && oldest.bodyText == nil)

    while try await h.sync.prefetchBodies() > 0 {}
    let messages = try h.messages()
    #expect(messages.count == 90)
    #expect(messages.values.allSatisfy { $0.bodyState == .full })
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
