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
    #expect(await h.fake.callCount(.send) == 0)
    #expect(await h.sync.nextOpAt == h.clock.now().addingTimeInterval(10))

    // Undo within the window.
    #expect(try h.store.cancelPendingSend(draftId: draft.id))
    #expect(try draftRow(h, draft.id)?.state == .editing)
    #expect(try h.ops().isEmpty)

    // Send again and let the window pass.
    try h.store.queueSend(draft, notBefore: h.clock.now().addingTimeInterval(10))
    h.clock.advance(5)
    try await h.sync.drainOps()
    #expect(await h.fake.callCount(.send) == 0)
    h.clock.advance(6)
    try await h.sync.drainOps()
    #expect(await h.fake.callCount(.send) == 1)
    #expect(!(try h.store.cancelPendingSend(draftId: draft.id)), "too late to undo")

    #expect(try draftRow(h, draft.id) == nil)
    #expect(try h.ops().isEmpty)
    let raw = String(decoding: try #require(await h.fake.sentRaw.first), as: UTF8.self)
    #expect(raw.contains("Subject: Re: Hello"))
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
    #expect(await h.fake.callCount(.send) == 0)
    #expect(await h.sync.nextOpAt == draft.scheduledAt)
    #expect(try draftRow(h, draft.id)?.state == .queued)

    h.clock.advance(3601)
    try await h.sync.drainOps()
    #expect(await h.fake.callCount(.send) == 1)
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
    #expect(await h.fake.draftIds.isEmpty, "the Gmail draft is deleted after sending")
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

@Test func aSendInterruptedByQuitIsNotResent() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 2)
    try await h.syncFully()
    let draft = reply(to: seeded[0])
    try h.store.queueSend(draft, notBefore: nil)
    try await h.store.database.writer.write { db in try db.execute(sql: "UPDATE pending_op SET state = 'inflight'") }

    let relaunched = h.relaunched()
    try await relaunched.prepare()
    try await relaunched.drainOps()

    #expect(await h.fake.callCount(.send) == 0)
    let op = try #require(try h.ops().first)
    #expect(op.state == .failed)
    #expect(try draftRow(h, draft.id)?.state == .failed)
    #expect(try draftRow(h, draft.id)?.lastError == AccountSync.interruptedSendError)
}

@Test func aSendThatKeepsFailingMarksTheDraftFailed() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 2)
    try await h.syncFully()
    await h.fake.failNext(100, with: .server(status: 400, message: "Invalid To header"), on: .send)
    let draft = reply(to: seeded[0])
    try h.store.queueSend(draft, notBefore: nil)

    try await h.sync.drainOps()
    #expect(try draftRow(h, draft.id)?.state == .queued)
    #expect(try draftRow(h, draft.id)?.lastError?.contains("Invalid To header") == true)
    for _ in 0..<10 {
        h.clock.advance(1000)
        try await h.sync.drainOps()
    }
    #expect(await h.fake.callCount(.send) == 8)
    #expect(try draftRow(h, draft.id)?.state == .failed)
    #expect(try h.ops().first?.state == .failed)
}
