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
    let seeded = await seed(h.fake, count: 100)
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
    #expect(fetches.filter { $0.format == .metadata }.flatMap(\.ids).count == 59, "every stored message refreshes its labels")
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

@Test func historyRetentionExpiresOldStartPoints() async throws {
    let fake = FakeGmail(email: testEmail, historyRetention: 3, sleep: { _ in })
    let first = await fake.deliver(FakeEmail())
    let start = try #require(first.historyId)
    for _ in 0..<5 { await fake.deliver(FakeEmail()) }
    await #expect(throws: GmailAPIError.historyExpired) { try await fake.history(startHistoryId: start, pageToken: nil) }
    let recent = try await fake.history(startHistoryId: String(await fake.currentHistoryId - 3), pageToken: nil)
    #expect(recent.history?.count == 3)
}
