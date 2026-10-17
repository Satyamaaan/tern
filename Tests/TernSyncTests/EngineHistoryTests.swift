import Foundation
import GRDB
import Testing
import TernCore
@testable import TernSync

@Test func historyAppliesAddsDeletesAndLabelChanges() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 40)
    try await h.syncFully()

    let fresh = await h.fake.deliver(FakeEmail(subject: "Fresh", text: "New body"))
    await h.fake.remoteArchive(threadId: seeded[0].threadId)
    await h.fake.remoteModify([seeded[4].id], remove: [SystemLabel.unread])
    await h.fake.remoteModify([seeded[1].id], add: [SystemLabel.starred])
    await h.fake.remoteDelete([seeded[2].id])
    await h.fake.resetCallLog()

    try await h.sync.pollHistory()

    try await h.expectMirrorsGmail()
    #expect(try h.message(fresh.id)?.bodyText == "New body")
    #expect(try h.message(seeded[2].id) == nil)
    #expect(!(try h.inboxThreadIds().contains(seeded[0].threadId)))
    #expect(try h.message(seeded[4].id)?.isUnread == false)
    #expect(try h.message(seeded[1].id)?.isStarred == true)
    #expect(try h.account().historyId == String(await h.fake.currentHistoryId))
    #expect(await h.fake.fetchCalls.flatMap(\.ids) == [fresh.id], "only the new message is fetched")
}

@Test func historyPagesSaveProgressAndNetOutChanges() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 12)
    try await h.syncFully()
    await h.fake.setHistoryPageSize(2)

    // Added then deleted before we look: never fetched.
    let shortLived = await h.fake.deliver(FakeEmail(subject: "Oops"))
    await h.fake.remoteDelete([shortLived.id])
    for message in seeded.prefix(5) { await h.fake.remoteModify([message.id], add: [SystemLabel.important]) }
    await h.fake.remoteModify([seeded[0].id], remove: [SystemLabel.important])
    await h.fake.resetCallLog()

    try await h.sync.pollHistory()

    try await h.expectMirrorsGmail()
    #expect(await h.fake.callCount(.history) == 4)
    #expect(await h.fake.fetchCalls.isEmpty, "a message added and deleted between polls is never fetched")
    #expect(try h.message(shortLived.id) == nil)
    #expect(try h.account().historyId == String(await h.fake.currentHistoryId))
}

@Test func emptyPollsDontRewriteTheAccount() async throws {
    let h = try Harness()
    await seed(h.fake, count: 5)
    try await h.syncFully()
    try await h.sync.pollHistory()
    let first = try h.account().lastSyncAt
    h.clock.advance(5)
    try await h.sync.pollHistory()
    #expect(try h.account().lastSyncAt == first)
    #expect(await h.sync.status.lastSyncAt == h.clock.now())
    h.clock.advance(60)
    try await h.sync.pollHistory()
    #expect(try h.account().lastSyncAt == h.clock.now())
}

@Test func labelChangeOnAnUnfetchedMessageInTheInboxFetchesIt() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 100, spacing: 12 * 3600)
    try await h.sync.initialSync()
    let old = seeded[1]
    #expect(try h.message(old.id) == nil, "older archived mail isn't stored before the backfill")

    await h.fake.remoteModify([old.id], add: [SystemLabel.inbox])
    await h.fake.remoteModify([seeded[2].id], add: [SystemLabel.starred])
    try await h.sync.pollHistory()

    #expect(try h.message(old.id)?.bodyState == .full)
    #expect(try h.inboxThreadIds().contains(old.threadId))
    #expect(try h.message(seeded[2].id) == nil, "label changes outside the inbox wait for the backfill")
}

@Test func expiredHistoryResyncsAndKeepsBodies() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 60)
    try await h.syncFully()

    await h.fake.remoteDelete([seeded[3].id])
    await h.fake.remoteArchive(threadId: seeded[0].threadId)
    await h.fake.remoteModify([seeded[7].id], add: [SystemLabel.trash], remove: [SystemLabel.categoryUpdates])
    let fresh = await h.fake.deliver(FakeEmail(subject: "After the gap", text: "Missed by history"))
    await h.fake.expireHistory()
    await h.fake.resetCallLog()
    await h.sync.syncNow()

    try await h.sync.syncOnce()

    try await h.expectMirrorsGmail()
    let fetches = await h.fake.fetchCalls
    #expect(Set(fetches.filter { $0.format == .full }.flatMap(\.ids)) == [fresh.id])
    #expect(fetches.filter { $0.format == .metadata }.isEmpty, "labels come from per-label lists, not a get per message")
    #expect(fetches.filter { $0.format == .minimal }.flatMap(\.ids) == [seeded[7].id], "only Trash and Spam are read directly")
    #expect(await h.fake.unitsSpent < 400, "a resync of 60 messages costs a few hundred units, not 60 × 20")
    #expect(try h.message(seeded[5].id)?.bodyText == "Body of message 5", "stored bodies are kept")
    #expect(try h.message(fresh.id)?.bodyText == "Missed by history")
    #expect(try h.message(seeded[7].id)?.labelIds.contains(SystemLabel.trash) == true)
    #expect(try h.account().historyId == String(await h.fake.currentHistoryId))
    #expect(try h.account().syncState == .live)

    // Live updates continue from the new historyId.
    let next = await h.fake.deliver(FakeEmail(subject: "Back to normal"))
    try await h.sync.pollHistory()
    #expect(try h.message(next.id) != nil)
}

@Test func aLargeTrashAndSpamGetExactLabelsAfterAResync() async throws {
    var configuration = SyncConfiguration.test()
    configuration.resyncHiddenRefreshLimit = 2
    let h = try Harness(configuration: configuration)
    let seeded = await seed(h.fake, count: 20, inboxEvery: 1)
    let project = try await h.fake.createLabel(name: "Clients")
    let junk = await h.fake.deliver(FakeEmail(subject: "Prize", date: testNow.addingTimeInterval(-30), labels: [SystemLabel.spam]))
    try await h.syncFully()
    #expect(try h.message(junk.id)?.labelIds == [SystemLabel.spam])

    // While Tern is away long enough for history to expire, mail is trashed and relabelled on the phone.
    let trashed = seeded.prefix(5).map(\.id)
    await h.fake.remoteModify([trashed[0]], add: [SystemLabel.starred])
    await h.fake.remoteModify([trashed[1]], add: [project.id])
    await h.fake.remoteModify([trashed[2]], remove: [SystemLabel.unread])
    await h.fake.remoteModify(trashed, add: [SystemLabel.trash], remove: [SystemLabel.inbox])
    await h.fake.remoteModify([junk.id], add: [SystemLabel.trash], remove: [SystemLabel.spam])
    await h.fake.expireHistory()
    await h.fake.resetCallLog()

    try await h.sync.fullResync()
    // At once: out of the inbox and in Trash, not in Spam as well.
    for id in trashed + [junk.id] {
        let labels = Set(try #require(try h.message(id)).labelIds)
        #expect(labels.contains(SystemLabel.trash) && !labels.contains(SystemLabel.inbox) && !labels.contains(SystemLabel.spam))
    }
    #expect(await h.fake.fetchCalls.filter { $0.format == .minimal }.isEmpty, "too many to read during the resync")
    let queued = try await h.store.database.reader.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM label_check") ?? 0 }
    #expect(queued == 6)

    // One background step, then a quit: the next run finishes the rest.
    try await h.sync.labelCheckStep()
    let relaunched = h.relaunched()
    try await relaunched.prepare()
    while try await relaunched.labelCheckStep() {}
    let left = try await h.store.database.reader.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM label_check") ?? 0 }
    #expect(left == 0)
    #expect(Set(await h.fake.fetchCalls.filter { $0.format == .minimal }.flatMap(\.ids)) == Set(trashed + [junk.id]))
    #expect(try h.message(trashed[0])?.isStarred == true)
    #expect(try h.message(trashed[1])?.labelIds.contains(project.id) == true)
    #expect(try h.message(trashed[2])?.isUnread == false)
    try await relaunched.pollHistory()
    try await h.expectMirrorsGmail()
}

@Test func labelChecksRunInTheBackgroundBeforeTheBackfill() async throws {
    var configuration = SyncConfiguration.test()
    configuration.resyncHiddenRefreshLimit = 0
    let h = try Harness(configuration: configuration)
    let seeded = await seed(h.fake, count: 8, inboxEvery: 1)
    try await h.syncFully()
    await h.fake.remoteModify([seeded[0].id], add: [SystemLabel.trash, SystemLabel.starred], remove: [SystemLabel.inbox])
    await h.fake.expireHistory()

    try await h.runLoop(until: {
        try await h.store.database.reader.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM label_check") ?? 0 } == 0
            && (try h.message(seeded[0].id)?.isStarred ?? false)
    })
    try await h.expectMirrorsGmail()
}

@Test func historyRetentionExpiresOldStartPoints() async throws {
    let fake = FakeGmail(email: testEmail, historyRetention: 3, sleep: { _ in })
    let first = await fake.deliver(FakeEmail())
    let start = try #require(first.historyId)
    for _ in 0..<5 { await fake.deliver(FakeEmail()) }
    await #expect(throws: GmailAPIError.historyExpired) { try await fake.history(startHistoryId: start, pageToken: nil) }
    let recent = try await fake.history(startHistoryId: String(await fake.currentHistoryId - 3), pageToken: nil)
    #expect(recent.history?.count == 3)
}

@Test func aLongGapFetchesOnlyTheNewestMailInFull() async throws {
    var configuration = SyncConfiguration.test()
    configuration.historyFullFetchLimit = 2
    let h = try Harness(configuration: configuration)
    await seed(h.fake, count: 4)
    try await h.syncFully()
    var fresh: [GmailMessage] = []
    for index in 0..<5 { fresh.append(await h.fake.deliver(FakeEmail(subject: "New \(index)", date: testNow.addingTimeInterval(Double(index))))) }

    try await h.sync.pollHistory()
    let states = try fresh.map { try h.message($0.id)?.bodyState }
    #expect(states == [.metadata, .metadata, .metadata, .full, .full])
    try await h.expectMirrorsGmail()
}

@Test func theFullFetchLimitCoversTheWholeGapAcrossPages() async throws {
    var configuration = SyncConfiguration.test()
    configuration.historyFullFetchLimit = 3
    let h = try Harness(configuration: configuration)
    await seed(h.fake, count: 4)
    try await h.syncFully()
    await h.fake.setHistoryPageSize(2)
    var fresh: [GmailMessage] = []
    for index in 0..<8 { fresh.append(await h.fake.deliver(FakeEmail(subject: "New \(index)", date: testNow.addingTimeInterval(Double(index))))) }

    try await h.sync.pollHistory()
    let states = try fresh.map { try h.message($0.id)?.bodyState }
    #expect(states == Array(repeating: .metadata, count: 5) + Array(repeating: .full, count: 3))
}

@Test func expiredHistoryLeavesOtherNewMailToTheBackfill() async throws {
    let h = try Harness()
    await seed(h.fake, count: 20)
    try await h.syncFully()
    let archived = await h.fake.deliver(FakeEmail(subject: "Receipt", date: testNow, labels: [SystemLabel.categoryUpdates]))
    let seeded = await h.fake.allMessageIds
    await h.fake.expireHistory()

    try h.store.perform(.markRead, on: [h.thread(seeded.last!)])
    await h.sync.kick()
    try await h.sync.fullResync()
    #expect(!(await h.fake.modifyCalls.isEmpty), "a queued action went out during the resync")
    #expect(try h.message(archived.id) == nil)
    #expect(try h.account().syncState == .backfilling)
    #expect(try h.account().backfillPageToken == "")

    while try await h.sync.backfillStep() {}
    #expect(try h.message(archived.id)?.bodyState == .metadata)
    try await h.sync.pollHistory()
    try await h.expectMirrorsGmail()
}

@Test func expiredHistoryDuringTheInitialSyncKeepsItGoing() async throws {
    let h = try Harness()
    await seed(h.fake, count: 40)
    await h.fake.failNext(with: .server(status: 400, message: "boom"), on: .messages, after: 1)
    await #expect(throws: GmailAPIError.self) { try await h.sync.initialSync() }
    await h.fake.expireHistory()

    try await h.sync.syncOnce()
    #expect(try h.account().syncState == .new)
    while try await h.sync.syncOnce() {}
    #expect(try h.account().syncState == .live)
    #expect(try h.messages().count == 40)
    #expect(try h.messages().values.allSatisfy { $0.bodyState == .full }, "recent mail still came in full")
}
