import Foundation
import GRDB
import Testing
import TernCore
@testable import TernSync

private func reply(to message: GmailMessage, body: String = "<p>Thanks!</p>") -> Draft {
    Draft(accountId: testEmail, threadId: message.threadId, replyToMessageId: message.id, kind: .reply,
          toList: [Participant(name: "Ann Lee", email: "ann@example.com")], subject: "Re: Hello", bodyHtml: body)
}

private func draftRow(_ h: Harness, _ id: String) throws -> Draft? {
    try h.store.database.reader.read { db in try Draft.fetchOne(db, key: id) }
}

@Test func sendWaitsForTheUndoWindowAndCanBeUndone() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 4)
    try await h.syncFully()
    let original = seeded[0]
    let draft = reply(to: original)

    try h.store.queueSend(draft, notBefore: h.clock.now().addingTimeInterval(10))
    try await h.sync.drainOps()
    #expect(await h.fake.callCount(.sendDraft) == 0)
    #expect(await h.sync.nextOpAt == h.clock.now().addingTimeInterval(10))

    // Undo within the window.
    #expect(try h.store.cancelPendingSend(draftId: draft.id))
    #expect(try draftRow(h, draft.id)?.state == .editing)
    #expect(try h.ops().isEmpty)

    // Send again and let the window pass.
    try h.store.queueSend(draft, notBefore: h.clock.now().addingTimeInterval(10))
    h.clock.advance(5)
    try await h.sync.drainOps()
    #expect(await h.fake.callCount(.sendDraft) == 0)
    h.clock.advance(6)
    try await h.sync.drainOps()
    #expect(await h.fake.callCount(.sendDraft) == 1)
    #expect(!(try h.store.cancelPendingSend(draftId: draft.id)), "too late to undo")

    #expect(try draftRow(h, draft.id) == nil)
    #expect(try h.ops().isEmpty)
    #expect(await h.fake.draftIds.isEmpty)
    let raw = String(decoding: try #require(await h.fake.draftRaw.last), as: UTF8.self)
    #expect(raw.contains("Subject: Re: Hello"))
    let account = try h.account()
    #expect(raw.hasPrefix("Message-ID: \(AccountSync.messageId(for: draft, account: account))\r\n"))
    #expect(AccountSync.messageId(for: draft, account: account) == "<tern.\(draft.id.lowercased())@example.com>")
    let detail = try #require(try h.store.threadDetail(h.thread(original.threadId)))
    #expect(detail.messages.count == 2)
    let sent = try #require(detail.messages.last)
    #expect(sent.isFromMe && sent.labelIds == [SystemLabel.sent])
    #expect(sent.bodyHtml == "<p>Thanks!</p>")

    // The history event for the send doesn't duplicate it.
    try await h.sync.pollHistory()
    try await h.expectMirrorsGmail()
}

@Test func sendLaterWaitsForScheduledTime() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 2)
    try await h.syncFully()
    var draft = reply(to: seeded[0])
    draft.scheduledAt = h.clock.now().addingTimeInterval(3600)

    try h.store.queueSend(draft, notBefore: nil)
    try await h.sync.drainOps()
    #expect(await h.fake.callCount(.sendDraft) == 0)
    #expect(await h.sync.nextOpAt == draft.scheduledAt)
    #expect(try draftRow(h, draft.id)?.state == .queued)

    h.clock.advance(3601)
    try await h.sync.drainOps()
    #expect(await h.fake.callCount(.sendDraft) == 1)
    #expect(try draftRow(h, draft.id) == nil)
}

@Test func savedDraftIsUpdatedThenReplacedBySending() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 2)
    try await h.syncFully()
    var draft = reply(to: seeded[0], body: "<p>First</p>")

    try h.store.queueSave(draft)
    try await h.sync.drainOps()
    let saved = try #require(try draftRow(h, draft.id))
    let gmailDraftId = try #require(saved.gmailDraftId)
    #expect(saved.gmailMessageId != nil)
    #expect(await h.fake.draftIds == [gmailDraftId])

    draft = saved
    draft.bodyHtml = "<p>Second</p>"
    try h.store.queueSave(draft)
    try await h.sync.drainOps()
    #expect(await h.fake.callCount(.updateDraft) == 1)
    #expect(try draftRow(h, draft.id)?.gmailDraftId == gmailDraftId)

    try await h.sync.pollHistory()
    #expect(try h.store.threadDetail(h.thread(seeded[0].threadId))?.thread.hasDraft == true)

    try h.store.queueSend(try #require(try draftRow(h, draft.id)), notBefore: nil)
    try await h.sync.drainOps()
    #expect(await h.fake.callCount(.createDraft) == 1, "the existing Gmail draft is updated and sent")
    #expect(await h.fake.draftIds.isEmpty, "sending consumes the Gmail draft")
    #expect(try draftRow(h, draft.id) == nil)
    try await h.sync.pollHistory()
    try await h.expectMirrorsGmail()
    let detail = try #require(try h.store.threadDetail(h.thread(seeded[0].threadId)))
    #expect(!detail.thread.hasDraft)
    #expect(detail.messages.last?.bodyHtml == "<p>Second</p>")
}

@Test func deletingADraftRemovesItFromGmail() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 2)
    try await h.syncFully()
    let draft = reply(to: seeded[0])
    try h.store.queueSave(draft)
    try await h.sync.drainOps()
    try await h.sync.pollHistory()

    try h.store.queueDelete(draftId: draft.id)
    try await h.sync.drainOps()
    #expect(await h.fake.draftIds.isEmpty)
    #expect(try draftRow(h, draft.id) == nil)
    #expect(try h.ops().isEmpty)
    try await h.sync.pollHistory()
    try await h.expectMirrorsGmail()
}

@Test func aLostSendResponseDoesNotSendTwice() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 2)
    try await h.syncFully()
    await h.fake.loseNextResponse(on: .sendDraft)
    let draft = reply(to: seeded[0])
    try h.store.queueSend(draft, notBefore: nil)

    try await h.sync.drainOps()
    #expect(try h.ops().first?.state == .pending, "a lost response is retried")
    #expect(!(try h.store.cancelPendingSend(draftId: draft.id)), "it may already have gone out")
    h.clock.advance(60)
    try await h.sync.drainOps()

    #expect(await h.fake.callCount(.sendDraft) == 1, "the retry found it in Sent by its Message-ID")
    #expect(await h.fake.allMessageIds.count == 3, "two received messages and exactly one sent")
    let detail = try #require(try h.store.threadDetail(h.thread(seeded[0].threadId)))
    #expect(detail.messages.last?.labelIds == [SystemLabel.sent], "the sent message is stored at once")
    #expect(try draftRow(h, draft.id) == nil)
    #expect(try h.ops().isEmpty)
    try await h.sync.pollHistory()
    try await h.expectMirrorsGmail()
}

@Test func aSendInterruptedByQuitGoesOutExactlyOnce() async throws {
    // Quit before drafts.send: the relaunch sends it.
    let h = try Harness()
    let seeded = await seed(h.fake, count: 2)
    try await h.syncFully()
    let early = reply(to: seeded[0])
    try h.store.queueSend(early, notBefore: nil)
    try await h.store.database.writer.write { db in try db.execute(sql: "UPDATE pending_op SET state = 'inflight'") }
    var relaunched = h.relaunched()
    try await relaunched.prepare()
    try await relaunched.drainOps()
    #expect(await h.fake.callCount(.sendDraft) == 1)
    #expect(try draftRow(h, early.id) == nil)

    // Quit right after drafts.send went through: the relaunch sees the draft is gone and doesn't resend.
    let late = reply(to: seeded[1], body: "<p>Late</p>")
    try h.store.queueSend(late, notBefore: nil)
    await h.fake.loseNextResponse(on: .sendDraft)
    try await relaunched.drainOps()
    try await h.store.database.writer.write { db in try db.execute(sql: "UPDATE pending_op SET state = 'inflight'") }
    relaunched = h.relaunched()
    try await relaunched.prepare()
    h.clock.advance(60)
    try await relaunched.drainOps()
    #expect(await h.fake.callCount(.sendDraft) == 2)
    #expect(try draftRow(h, late.id) == nil)
    #expect(try h.ops().isEmpty)
    try await relaunched.pollHistory()
    try await h.expectMirrorsGmail()
    #expect(await h.fake.allMessageIds.count == 4, "two received, two sent")
}

@Test func aSendThatKeepsFailingMarksTheDraftFailed() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 2)
    try await h.syncFully()
    await h.fake.failNext(100, with: .server(status: 400, message: "Invalid To header"), on: .sendDraft)
    let draft = reply(to: seeded[0])
    try h.store.queueSend(draft, notBefore: nil)

    try await h.sync.drainOps()
    #expect(try draftRow(h, draft.id)?.state == .queued)
    #expect(try draftRow(h, draft.id)?.lastError?.contains("Invalid To header") == true)
    for _ in 0..<10 {
        h.clock.advance(1000)
        try await h.sync.drainOps()
    }
    #expect(await h.fake.callCount(.sendDraft) == 8)
    #expect(try draftRow(h, draft.id)?.state == .failed)
    #expect(try h.ops().first?.state == .failed)
}

@Test func aSendHiddenFromALaggingSearchIndexIsStillNotResent() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 2)
    try await h.syncFully()
    await h.fake.stallSearchIndex()
    await h.fake.loseNextResponse(on: .sendDraft)
    let draft = reply(to: seeded[0])
    try h.store.queueSend(draft, notBefore: nil)

    try await h.sync.drainOps()
    h.clock.advance(60)
    try await h.sync.drainOps()

    // Search missed it, so drafts.send was tried again; the draft was gone, so it was already sent.
    #expect(await h.fake.callCount(.sendDraft) == 2)
    #expect(await h.fake.allMessageIds.count == 3)
    #expect(try draftRow(h, draft.id) == nil)
    #expect(try h.ops().isEmpty)
}

@Test func theStableMessageIdReplacesTheEncodersOwn() {
    let raw = Data("From: a@x\r\nMessage-ID: <random@x>\r\nX-Folded: one\r\n two\r\nmessage-id:\r\n <again@x>\r\n\r\nBody\r\n".utf8)
    let result = String(decoding: MailParsing.settingHeader("Message-ID", to: "<stable@x>", in: raw), as: UTF8.self)
    #expect(result == "Message-ID: <stable@x>\r\nFrom: a@x\r\nX-Folded: one\r\n two\r\n\r\nBody\r\n")
    let bare = String(decoding: MailParsing.settingHeader("Message-ID", to: "<s@x>", in: Data("Subject: Hi\n\nText".utf8)), as: UTF8.self)
    #expect(bare == "Message-ID: <s@x>\r\nSubject: Hi\r\n\r\nText")
}
