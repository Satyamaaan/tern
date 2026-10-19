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
    #expect(try h.drafts.restore(discarded, now: h.clock.now()) == RestoredDrafts(exact: 1))
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

@Test func aGmailDraftSearchDoesntKnowYetIsFoundByGoingThroughTheDrafts() async throws {
    let h = try Harness()
    await seed(h.fake, count: 2)
    try await h.syncFully()
    // Gmail's index lags: searching by its Message-ID finds nothing.
    await h.fake.stallSearchIndex()
    let other = try await gmailDraft(h, subject: "Other", messageId: "other-2@example.com")
    let draft = try await gmailDraft(h, subject: "Note", messageId: "note-2@example.com")
    try await h.sync.pollHistory()
    #expect(try h.message(draft.messageId)?.rfcMessageId != nil)

    _ = try h.drafts.discardDrafts(inThreads: [draft.thread], holdFor: 0, now: h.clock.now())
    try await h.sync.drainOps()
    #expect(await h.fake.draftIds == [other.draftId], "only that draft goes")
    #expect(try h.ops().isEmpty)
    try await h.sync.pollHistory()
    try await h.expectMirrorsGmail()
}

@Test func aGmailDraftThatCantBeFoundIsntForgottenItComesBack() async throws {
    let h = try Harness()
    await seed(h.fake, count: 2)
    let draft = try await gmailDraft(h, subject: "Subscription", messageId: "phone-4@example.com")
    try await h.syncFully()

    _ = try h.drafts.discardDrafts(inThreads: [draft.thread], holdFor: 0, now: h.clock.now())
    // An account where drafts.list isn't available: the draft can't be looked up, but its message is still a draft.
    await h.fake.failNext(100, with: .server(status: 501, message: GmailDraftPage.unsupported), on: .drafts)
    try await h.sync.drainOps()
    #expect(try h.ops().first?.state == .pending && h.ops().first?.attempts == 1, "it tries again")
    for _ in 0..<(h.configuration.maxOpAttempts + 2) {
        h.clock.advance(3_600)
        try await h.sync.drainOps()
    }
    let ops = try h.ops()
    #expect(ops.map(\.kind) == [.deleteDraft] && ops.first?.state == .failed)
    #expect(await h.fake.draftIds == [draft.draftId])
    #expect(await h.fake.callCounts[.deleteDraft] == nil)
    #expect(try h.message(draft.messageId)?.isDraft == true, "Gmail kept it, so it shows again")
}

@Test func aDraftChangedOnAnotherDeviceDuringTheUndoWindowStays() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 2)
    try await h.syncFully()
    var draft = try #require(try h.drafts.makeDraft(.reply(h.thread(seeded[0].threadId), all: false))).draft
    draft.bodyHtml = "<p>On it</p>"
    try await h.queueSave(draft)
    try await h.sync.drainOps()
    try await h.sync.pollHistory()
    let gmailDraftId = try #require(await h.fake.draftIds.first)

    _ = try h.drafts.discardDrafts(inThreads: [h.thread(seeded[0].threadId)], holdFor: 15, now: h.clock.now())
    // Meanwhile the draft is opened and changed on the phone: a new message.
    let lines = ["From: \(testEmail)", "To: ann@example.com", "Subject: Re: changed", "Content-Type: text/plain; charset=UTF-8"]
    let edited = try await h.fake.updateDraft(id: gmailDraftId, raw: Data((lines.joined(separator: "\r\n") + "\r\n\r\nOn it, sending Friday").utf8),
                                               threadId: nil)
    try await h.sync.pollHistory()
    let newMessage = try #require(edited.message?.id)
    #expect(try h.message(newMessage)?.isDraft == true, "the changed draft comes in")

    h.clock.advance(16)
    try await h.sync.drainOps()
    #expect(await h.fake.draftIds == [gmailDraftId], "only the version discarded here would have gone")
    #expect(await h.fake.callCounts[.deleteDraft] == nil)
    #expect(try h.ops().isEmpty)
    try await h.sync.pollHistory()
    try await h.expectMirrorsGmail()
}

private final class Box<Value>: @unchecked Sendable {
    var value: Value?
}

/// A local draft saved to Gmail, then changed here: discarded while that change is on its way to Gmail.
private func discardDuringSave(_ h: Harness) async throws -> (DiscardedDrafts, draftId: String, gmailDraftId: String) {
    let seeded = await seed(h.fake, count: 2)
    try await h.syncFully()
    let thread = h.thread(seeded[0].threadId)
    var draft = try #require(try h.drafts.makeDraft(.reply(thread, all: false))).draft
    draft.bodyHtml = "<p>On it</p>"
    try await h.queueSave(draft)
    try await h.sync.drainOps()
    try await h.sync.pollHistory()
    let gmailDraftId = try #require(await h.fake.draftIds.first)

    draft.bodyHtml = "<p>On it, sending Friday</p>"
    try await h.queueSave(draft)
    let discarded = Box<DiscardedDrafts>()
    let drafts = h.drafts, now = h.clock.now()
    await h.fake.onNext(.updateDraft) { discarded.value = try? drafts.discardDrafts(inThreads: [thread], holdFor: 15, now: now) }
    try await h.sync.drainOps()
    let result = try #require(discarded.value)
    #expect(result.count == 1)
    return (result, draft.id, gmailDraftId)
}

@Test func aSaveOnItsWayWhenTheDraftIsDiscardedIsDeletedOnceTheWindowPasses() async throws {
    let h = try Harness()
    let (_, draftId, gmailDraftId) = try await discardDuringSave(h)
    let held = try h.ops()
    #expect(held.map(\.kind) == [.deleteDraft], "no second deletion, and nothing deleted before the window passes")
    let payload = try JSONDecoder().decode(DraftOpPayload.self, from: Data(held[0].payload.utf8))
    let saved = try #require(await h.fake.draftMessageId(gmailDraftId))
    #expect(payload.draftId == draftId && payload.gmailDraftId == gmailDraftId && payload.gmailMessageId == saved)
    try await h.sync.pollHistory()
    #expect(try h.message(saved) == nil, "the copy just saved stays out of the lists")

    h.clock.advance(16)
    try await h.sync.drainOps()
    #expect(await h.fake.draftIds.isEmpty)
    #expect(try h.ops().isEmpty)
    try await h.sync.pollHistory()
    try await h.expectMirrorsGmail()
}

@Test func undoAfterASaveThatWasOnItsWayBringsTheDraftBackWithItsChange() async throws {
    let h = try Harness()
    let (discarded, draftId, gmailDraftId) = try await discardDuringSave(h)
    try await h.sync.pollHistory()
    #expect(try h.drafts.restore(discarded, now: h.clock.now()) == RestoredDrafts(exact: 1))
    let back = try #require(try h.drafts.draft(id: draftId))
    #expect(back.gmailDraftId == gmailDraftId && back.bodyHtml == "<p>On it, sending Friday</p>")
    #expect(try h.ops().map(\.kind) == [.saveDraft])

    h.clock.advance(60)
    try await h.sync.drainOps()
    try await h.sync.pollHistory()
    #expect(await h.fake.draftIds == [gmailDraftId])
    #expect(await h.fake.callCounts[.deleteDraft] == nil)
    let message = try #require(try h.drafts.draft(id: draftId)?.gmailMessageId)
    #expect(try h.message(message)?.isDraft == true, "its message is back in the lists")
    try await h.expectMirrorsGmail()
}
