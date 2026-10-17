import Foundation
import GRDB
import Testing
import TernCore
@testable import TernSync

// An interactive fetch (opening a thread, server search) can overlap a history poll. Whatever it
// fetched must never overwrite what history wrote meanwhile.

private let largeText = String(repeating: "Long body. ", count: 60)

/// A message whose text body Gmail serves by attachment id, as it does for large bodies, so fetching
/// it in full takes a second request.
@discardableResult
private func deliverLargeBody(_ fake: FakeGmail, id: String, threadId: String, minutesAgo: Double,
                              labels: [String] = [SystemLabel.inbox, SystemLabel.unread]) async -> GmailMessage {
    let headers = [
        GmailHeader(name: "From", value: "Ann Lee <ann@example.com>"),
        GmailHeader(name: "To", value: testEmail),
        GmailHeader(name: "Subject", value: "Minutes"),
        GmailHeader(name: "Message-ID", value: "<\(id)@fake.tern>"),
        GmailHeader(name: "Content-Type", value: "text/plain; charset=UTF-8"),
    ]
    let date = testNow.addingTimeInterval(-minutesAgo * 60)
    let message = GmailMessage(
        id: id, threadId: threadId, labelIds: labels, snippet: "Long body.",
        internalDate: String(Int64(date.timeIntervalSince1970 * 1000)),
        payload: GmailMessagePart(partId: "", mimeType: "text/plain", filename: "", headers: headers,
                                  body: GmailPartBody(attachmentId: "body-\(id)", size: largeText.utf8.count)))
    return await fake.insert(message, attachments: ["body-\(id)": Data(largeText.utf8)])
}

extension Harness {
    /// Forgets the stored bodies, as for older mail that synced as headers.
    func dropBodies(_ ids: [String]) async throws {
        try await store.database.writer.write { db in
            for id in ids {
                try db.execute(sql: "UPDATE message SET bodyState = 0, bodyText = NULL, bodyHtml = NULL WHERE id = ?", arguments: [id])
            }
        }
    }

    /// While the next body part downloads, `change` happens in Gmail and a history poll applies it.
    func whileTheBodyDownloads(_ change: @escaping @Sendable (FakeGmail) async -> Void) async {
        let sync = self.sync, fake = self.fake
        await fake.onNext(.attachment) {
            await change(fake)
            try? await sync.pollHistory()
        }
    }
}

@Test func openingAThreadDoesNotUndoAnArchiveHistoryAppliedMeanwhile() async throws {
    let h = try Harness()
    await seed(h.fake, count: 3)
    await deliverLargeBody(h.fake, id: "b1", threadId: "b1", minutesAgo: 30)
    try await h.syncFully()
    try await h.dropBodies(["b1"])

    await h.whileTheBodyDownloads { await $0.remoteArchive(threadId: "b1") }
    try await h.sync.fetchBodies(h.thread("b1"))

    let stored = try #require(try h.message("b1"))
    #expect(stored.bodyState == .full && stored.bodyText?.contains("Long body.") == true, "the body is stored")
    #expect(!stored.labelIds.contains(SystemLabel.inbox), "with the labels history wrote")
    #expect(!(try h.inboxThreadIds().contains("b1")))
    try await h.sync.pollHistory()
    try await h.expectMirrorsGmail()
}

@Test func openingALongThreadDoesNotUndoAnArchiveHistoryAppliedMeanwhile() async throws {
    let h = try Harness()
    await seed(h.fake, count: 3)
    await deliverLargeBody(h.fake, id: "t1a", threadId: "t1", minutesAgo: 50)
    await deliverLargeBody(h.fake, id: "t1b", threadId: "t1", minutesAgo: 40)
    await deliverLargeBody(h.fake, id: "t1c", threadId: "t1", minutesAgo: 30)
    try await h.syncFully()
    try await h.dropBodies(["t1a", "t1b", "t1c"])
    await h.fake.resetCallLog()

    await h.whileTheBodyDownloads { await $0.remoteArchive(threadId: "t1") }
    try await h.sync.fetchBodies(h.thread("t1"))

    #expect(await h.fake.callCount(.threads) == 1, "fetched as one thread")
    for id in ["t1a", "t1b", "t1c"] {
        let stored = try #require(try h.message(id))
        #expect(stored.bodyState == .full, "body of \(id)")
        #expect(!stored.labelIds.contains(SystemLabel.inbox), "labels of \(id)")
    }
    #expect(!(try h.inboxThreadIds().contains("t1")))
    try await h.sync.pollHistory()
    try await h.expectMirrorsGmail()
}

@Test func aSearchResultDeletedWhileItDownloadsIsNotStored() async throws {
    let h = try Harness()
    await seed(h.fake, count: 3)
    try await h.syncFully()
    await deliverLargeBody(h.fake, id: "old1", threadId: "old1", minutesAgo: 60 * 24 * 400, labels: [SystemLabel.categoryUpdates])
    // History picks up the earlier messages but this one only arrives through search.
    try await h.sync.pollHistory()
    try await h.store.deleteMessages(accountId: testEmail, ids: ["old1"])

    await h.whileTheBodyDownloads { await $0.remoteDelete(["old1"]) }
    let found = try await h.sync.serverSearch(query: "minutes", limit: 10)

    #expect(try h.message("old1") == nil, "a message Gmail deleted meanwhile isn't brought back")
    #expect(!found.contains(h.thread("old1")))
    try await h.sync.pollHistory()
    try await h.expectMirrorsGmail()
}
