import Foundation
import GRDB
import Testing
import TernCore
@testable import TernSync

@Test func attachmentsDownloadOnceIntoTheCache() async throws {
    let h = try Harness()
    let pdf = Data("%PDF-1.7 fake".utf8)
    let logo = Data([0x89, 0x50, 0x4E, 0x47])
    let delivered = await h.fake.deliver(FakeEmail(
        subject: "Report", text: "Attached", html: "<p><img src=\"cid:logo@acme\"> Attached</p>",
        attachments: [FakeAttachment(filename: "report.pdf", mimeType: "application/pdf", data: pdf),
                      FakeAttachment(filename: "logo.png", mimeType: "image/png", data: logo, contentId: "logo@acme")]))
    try await h.syncFully()

    let detail = try #require(try h.store.threadDetail(h.thread(delivered.threadId)))
    #expect(detail.thread.hasAttachments)
    let attachments = try #require(detail.attachments[delivered.id])
    let report = try #require(attachments.first { $0.filename == "report.pdf" })
    let inline = try #require(attachments.first { $0.contentId == "logo@acme" })
    #expect(inline.isInline && !report.isInline)

    let url = try await h.sync.downloadAttachment(report)
    #expect(try Data(contentsOf: url) == pdf)
    #expect(url.path.hasSuffix("/\(testEmail)/\(delivered.id)/report.pdf"))
    #expect(url.path.hasPrefix(h.configuration.attachmentCacheDirectory.path))
    let stored = try #require(try h.store.threadDetail(h.thread(delivered.threadId))?.attachments[delivered.id]?.first { $0.partId == report.partId })
    #expect(stored.localPath == url.path)

    #expect(try Data(contentsOf: try await h.sync.downloadAttachment(inline)) == logo)
    #expect(await h.fake.callCount(.attachment) == 2)
    _ = try await h.sync.downloadAttachment(report)
    #expect(await h.fake.callCount(.attachment) == 2, "a cached file isn't downloaded again")

    // Refetching the message keeps the cached path.
    try await h.store.database.writer.write { db in
        try db.execute(sql: "UPDATE message SET bodyState = 0 WHERE id = ?", arguments: [delivered.id])
    }
    try await h.sync.prefetchBodies()
    let refetched = try h.store.threadDetail(h.thread(delivered.threadId))?.attachments[delivered.id]?.first { $0.partId == report.partId }
    #expect(refetched?.localPath == url.path)
    try? FileManager.default.removeItem(at: h.configuration.attachmentCacheDirectory)
}

@Test func inlinePayloadDataIsSavedWithoutAnAttachmentCall() async throws {
    let h = try Harness()
    let text = Data("name,amount\nAnn,5\n".utf8)
    let payload = GmailMessagePart(
        partId: "", mimeType: "multipart/mixed", filename: "",
        headers: [GmailHeader(name: "From", value: "ann@example.com"), GmailHeader(name: "Subject", value: "CSV")],
        parts: [
            GmailMessagePart(partId: "0", mimeType: "text/plain", filename: "", headers: [],
                             body: GmailPartBody(size: 2, data: MailParsing.base64URLEncode(Data("Hi".utf8)))),
            GmailMessagePart(partId: "1", mimeType: "text/csv", filename: "data.csv",
                             headers: [GmailHeader(name: "Content-Disposition", value: "attachment; filename=data.csv")],
                             body: GmailPartBody(size: text.count, data: MailParsing.base64URLEncode(text))),
        ])
    let message = await h.fake.insert(GmailMessage(id: "c1", threadId: "c1", labelIds: [SystemLabel.inbox],
                                                   internalDate: "1700000000000", payload: payload))
    try await h.syncFully()
    let attachment = try #require(try h.store.threadDetail(h.thread(message.threadId))?.attachments["c1"]?.first)
    #expect(attachment.attachmentId == nil)
    let url = try await h.sync.downloadAttachment(attachment)
    #expect(try Data(contentsOf: url) == text)
    #expect(await h.fake.callCount(.attachment) == 0)
    try? FileManager.default.removeItem(at: h.configuration.attachmentCacheDirectory)
}

@Test func serverSearchStoresOlderMatches() async throws {
    let h = try Harness()
    let old = await h.fake.deliver(FakeEmail(subject: "Lisbon itinerary", text: "Flights and hotels",
                                             date: Date(timeIntervalSince1970: 1_500_000_000), labels: []))
    await seed(h.fake, count: 60)
    try await h.sync.initialSync()
    #expect(try h.message(old.id) == nil)

    let keys = try await h.sync.serverSearch(query: "lisbon", limit: 20)
    #expect(keys == [h.thread(old.threadId)])
    #expect(try h.message(old.id)?.bodyText == "Flights and hotels")
    #expect(try await h.sync.serverSearch(query: "nothing-matches-this", limit: 20).isEmpty)
}

@Test func largeBodiesSentByAttachmentIdAreFetched() async throws {
    let h = try Harness()
    let html = "<html><body><p>" + String(repeating: "Big newsletter. ", count: 200) + "</p></body></html>"
    let payload = GmailMessagePart(
        partId: "", mimeType: "multipart/alternative", filename: "",
        headers: [GmailHeader(name: "From", value: "news@example.com"), GmailHeader(name: "Subject", value: "Weekly")],
        parts: [
            GmailMessagePart(partId: "0", mimeType: "text/plain", filename: "",
                             headers: [GmailHeader(name: "Content-Type", value: "text/plain; charset=utf-8")],
                             body: GmailPartBody(attachmentId: "body-plain", size: 3200)),
            GmailMessagePart(partId: "1", mimeType: "text/html", filename: "",
                             headers: [GmailHeader(name: "Content-Type", value: "text/html; charset=utf-8")],
                             body: GmailPartBody(attachmentId: "body-html", size: html.utf8.count)),
        ])
    await h.fake.insert(GmailMessage(id: "n1", threadId: "n1", labelIds: [SystemLabel.inbox], internalDate: "1700000000000",
                                     payload: payload),
                        attachments: ["body-plain": Data("Big newsletter.".utf8), "body-html": Data(html.utf8)])
    await h.fake.insert(GmailMessage(id: "n2", threadId: "n2", labelIds: [SystemLabel.inbox], internalDate: "1700000000001",
                                     payload: payload))
    try await h.syncFully()

    let message = try #require(try h.message("n1"))
    #expect(message.bodyState == .full)
    #expect(message.bodyHtml == html)
    #expect(message.bodyText == "Big newsletter.")
    #expect(try h.message("n1").map { !$0.hasAttachments } == true)
    #expect(try h.message("n2")?.bodyState == .metadata, "a body that can't be fetched is left for the prefetch")
}

@Test func openingAThreadFetchesItsBodiesOnDemand() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 90, spacing: 12 * 3600)
    try await h.syncFully()
    let old = seeded[1]
    #expect(try h.message(old.id)?.bodyState == .metadata)

    await h.fake.resetCallLog()
    try await h.sync.fetchBodies(h.thread(old.threadId))
    #expect(try h.message(old.id)?.bodyText == "Body of message 1")
    #expect(await h.fake.fetchCalls == [FakeGmail.FetchCall(ids: [old.id], format: .full)])

    // Opening it again costs nothing.
    try await h.sync.fetchBodies(h.thread(old.threadId))
    #expect(await h.fake.unitsSpent == 60)
}

@Test func openingAThreadDuringTheBackfillFindsItsMissingMessages() async throws {
    let h = try Harness()
    let root = await h.fake.deliver(FakeEmail(subject: "Old plan", date: testNow.addingTimeInterval(-90 * 86_400), labels: []))
    let reply = await h.fake.deliver(FakeEmail(subject: "Re: Old plan", date: testNow.addingTimeInterval(-60),
                                               threadId: root.threadId))
    try await h.sync.initialSync()
    #expect(try h.message(root.id) == nil, "the old message isn't backfilled yet")
    #expect(try h.message(reply.id)?.bodyState == .full)

    try await h.sync.fetchBodies(h.thread(root.threadId))
    let detail = try #require(try h.store.threadDetail(h.thread(root.threadId)))
    #expect(detail.messages.map(\.id) == [root.id, reply.id])
    #expect(detail.messages.allSatisfy { $0.bodyState == .full })
    #expect(await h.fake.threadCalls.last == FakeGmail.FetchCall(ids: [root.threadId], format: .metadata))
}

@Test func threadsNextToTheSelectionArePrefetched() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 90, spacing: 12 * 3600)
    try await h.syncFully()
    let neighbours = [seeded[1], seeded[2]].map { h.thread($0.threadId) }

    await h.sync.prefetchAdjacent(neighbours + [ThreadKey(accountId: "other@example.com", threadId: "x")])
    while try await h.sync.syncOnce() {}
    #expect(try h.message(seeded[1].id)?.bodyState == .full)
    #expect(try h.message(seeded[2].id)?.bodyState == .full)
}
