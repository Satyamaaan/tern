import Foundation
import GRDB
import Testing
import TernCore
@testable import TernSync

/// A draft written in Gmail (on the phone or the web): Tern only knows its DRAFT message.
private func gmailDraft(_ h: Harness, subject: String, messageId: String) async throws -> (draftId: String, messageId: String, thread: ThreadKey) {
    let lines = ["From: \(testEmail)", "To: ann@example.com", "Subject: \(subject)", "Message-ID: <\(messageId)>",
                 "Content-Type: text/plain; charset=UTF-8"]
    let draft = try await h.fake.createDraft(raw: Data((lines.joined(separator: "\r\n") + "\r\n\r\nThanks, will do").utf8), threadId: nil)
    let message = try #require(draft.message)
    return (draft.id, message.id, h.thread(message.threadId))
}

private func draftRows(_ h: Harness) throws -> Int {
    try h.store.database.reader.read { db in try Draft.fetchCount(db) }
}

@Test func aGmailDraftIsDeletedFromGmailOnceTheUndoWindowPasses() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 3)
    let draft = try await gmailDraft(h, subject: "Subscription", messageId: "phone-1@example.com")
    try await h.syncFully()
    #expect(try h.message(draft.messageId)?.isDraft == true && draftRows(h) == 0, "only its message is stored")

    let discarded = try h.drafts.discardDrafts(inThreads: [draft.thread], holdFor: 15, now: h.clock.now())
    #expect(try discarded.count == 1 && h.message(draft.messageId) == nil)
    #expect(try h.message(seeded[0].id) != nil, "other mail stays")

    try await h.sync.drainOps()
    try await h.sync.pollHistory()
    #expect(await h.fake.draftIds == [draft.draftId], "Gmail keeps it through the undo window")
    #expect(try h.message(draft.messageId) == nil, "and sync doesn't bring it back meanwhile")

    h.clock.advance(16)
    try await h.sync.drainOps()
    #expect(await h.fake.draftIds.isEmpty)
    #expect(try h.ops().isEmpty)
    try await h.sync.pollHistory()
    try await h.expectMirrorsGmail()
}

@Test func aGmailDraftWithoutAMessageIdIsFoundAmongTheDrafts() async throws {
    let h = try Harness()
    await seed(h.fake, count: 2)
    let other = try await gmailDraft(h, subject: "Other", messageId: "other@example.com")
    let draft = try await gmailDraft(h, subject: "Note", messageId: "note@example.com")
    try await h.syncFully()
    // Stored without its Message-ID, so it can only be found by going through the drafts.
    try await h.store.database.writer.write { db in
        try db.execute(sql: "UPDATE message SET rfcMessageId = NULL WHERE id = ?", arguments: [draft.messageId])
    }

    _ = try h.drafts.discardDrafts([.message(MessageKey(accountId: testEmail, messageId: draft.messageId))], holdFor: 0, now: h.clock.now())
    try await h.sync.drainOps()
    #expect(await h.fake.draftIds == [other.draftId], "only that draft goes")
    try await h.sync.pollHistory()
    try await h.expectMirrorsGmail()
}

@Test func undoInTheWindowKeepsTheGmailDraftAndItsMessage() async throws {
    let h = try Harness()
    await seed(h.fake, count: 2)
    let draft = try await gmailDraft(h, subject: "Subscription", messageId: "phone-2@example.com")
    try await h.syncFully()

    let discarded = try h.drafts.discardDrafts(inThreads: [draft.thread], holdFor: 15, now: h.clock.now())
    #expect(discarded.count == 1)
    h.clock.advance(4)
    #expect(try h.drafts.restore(discarded, now: h.clock.now()))
    h.clock.advance(60)
    try await h.sync.drainOps()
    #expect(await h.fake.draftIds == [draft.draftId])
    #expect(await h.fake.callCounts[.deleteDraft] == nil)
    #expect(try h.message(draft.messageId)?.isDraft == true)
    try await h.sync.pollHistory()
    try await h.expectMirrorsGmail()
}

@Test func aLocalDraftDiscardedFromTheListDeletesItsGmailCopyAndFiles() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 2)
    try await h.syncFully()
    let content = try #require(try h.drafts.makeDraft(.reply(h.thread(seeded[0].threadId), all: false)))
    var draft = content.draft
    draft.bodyHtml = "<p>On it</p>"
    draft.attachments = [try await h.drafts.addData(Data("pdf".utf8), filename: "notes.pdf", to: draft.id)]
    try await h.queueSave(draft)
    try await h.sync.drainOps()
    try await h.sync.pollHistory()
    #expect(await h.fake.draftIds.count == 1)

    _ = try h.drafts.discardDrafts(inThreads: [h.thread(seeded[0].threadId)], holdFor: 15, now: h.clock.now())
    #expect(FileManager.default.fileExists(atPath: draft.attachments[0].path))
    h.clock.advance(16)
    try await h.sync.drainOps()
    #expect(await h.fake.draftIds.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: draft.attachments[0].path), "its files go with the Gmail copy")
    try await h.sync.pollHistory()
    try await h.expectMirrorsGmail()
}

@Test func aDeletionGmailKeepsRefusingBringsTheDraftBack() async throws {
    let h = try Harness()
    await seed(h.fake, count: 2)
    let draft = try await gmailDraft(h, subject: "Subscription", messageId: "phone-3@example.com")
    try await h.syncFully()

    _ = try h.drafts.discardDrafts(inThreads: [draft.thread], holdFor: 0, now: h.clock.now())
    await h.fake.failNext(100, with: .server(status: 400, message: "Invalid draft"), on: .deleteDraft)
    for _ in 0..<(h.configuration.maxOpAttempts + 2) {
        try await h.sync.drainOps()
        h.clock.advance(3_600)
    }
    let ops = try h.ops()
    #expect(ops.map(\.kind) == [.deleteDraft] && ops.first?.state == .failed, "counted with the other changes that didn't reach Gmail")
    #expect(await h.fake.draftIds == [draft.draftId])
    #expect(try h.message(draft.messageId)?.isDraft == true, "Gmail kept it, so it shows again")
}
