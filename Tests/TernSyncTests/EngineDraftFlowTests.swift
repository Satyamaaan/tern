import Foundation
import GRDB
import Testing
import TernCore
@testable import TernSync

// The composer's path end to end: DraftStore writes, the engine sends what it wrote through
// DraftEncoder (MIMEBuilder), FakeGmail reads the MIME back.

private let ann = "Ann Lee <ann@example.com>"

extension Harness {
    /// A two-message thread from Ann (the second replying to the first), synced.
    func seedConversation() async throws -> (first: GmailMessage, second: GmailMessage) {
        let first = await fake.deliver(FakeEmail(from: ann, subject: "Plans", text: "Lunch on Friday?",
                                                 date: testNow.addingTimeInterval(-7200)))
        let second = await fake.deliver(FakeEmail(from: ann, subject: "Re: Plans", text: "Or Saturday?",
                                                  date: testNow.addingTimeInterval(-3600), threadId: first.threadId,
                                                  inReplyTo: "<\(first.id)@fake.tern>"))
        try await syncFully()
        return (first, second)
    }

    /// A reply written in the composer: prefilled by DraftStore, with typed text.
    func composeReply(to thread: String, text: String = "Saturday works.") throws -> Draft {
        var content = try #require(try drafts.makeDraft(.reply(self.thread(thread), all: false), now: clock.now()))
        content.body = RichText(html: "<p>\(text)</p>")
        return content.assembledDraft(updatedAt: clock.now())
    }

    func draftRow(_ id: String) throws -> Draft? {
        try store.database.reader.read { db in try Draft.fetchOne(db, key: id) }
    }

    func folderExists(_ draftId: String) -> Bool {
        FileManager.default.fileExists(atPath: drafts.folder(for: draftId).path)
    }

    func setSetting(_ key: String, _ value: String) async throws {
        try await store.database.writer.write { db in try Setting(key: key, value: value).upsert(db) }
    }
}

/// The decoded data of the first part of the stored Gmail message named `filename`.
private func fakeAttachment(_ fake: FakeGmail, messageId: String, filename: String) async throws -> Data? {
    guard let payload = await fake.message(messageId)?.payload else { return nil }
    func find(_ part: GmailMessagePart) -> GmailMessagePart? {
        if part.filename == filename { return part }
        return (part.parts ?? []).lazy.compactMap(find).first
    }
    guard let attachmentId = find(payload)?.body?.attachmentId else { return nil }
    return try await fake.attachment(messageId: messageId, attachmentId: attachmentId)
}

@Test func aReplySentFromTheComposerLandsInItsThread() async throws {
    let h = try Harness(realEncoder: true)
    let (first, second) = try await h.seedConversation()
    try await h.setSetting(DraftStore.SettingKey.senderName(testEmail), "Sam Rivera")
    let draft = try h.composeReply(to: first.threadId)
    try await h.drafts.save(draft, now: h.clock.now())

    let receipt = try await h.drafts.send(draft, undoSeconds: 5, now: h.clock.now())
    #expect(receipt.notBefore == h.clock.now().addingTimeInterval(5))
    try await h.sync.drainOps()
    #expect(await h.fake.callCount(.sendDraft) == 0, "inside the undo window")
    #expect(await h.fake.callCount(.createDraft) == 0, "the pending save was dropped by Send")

    h.clock.advance(6)
    try await h.sync.drainOps()
    #expect(await h.fake.callCount(.sendDraft) == 1)
    #expect(try h.draftRow(draft.id) == nil)
    #expect(try h.ops().isEmpty)
    #expect(!h.folderExists(draft.id))

    let detail = try #require(try h.store.threadDetail(h.thread(first.threadId)))
    #expect(detail.messages.count == 3)
    let sent = try #require(detail.messages.last)
    #expect(sent.threadId == first.threadId && sent.isFromMe && sent.labelIds == [SystemLabel.sent])
    #expect(sent.fromName == "Sam Rivera" && sent.fromEmail == testEmail)
    #expect(sent.toList.map(\.email) == ["ann@example.com"])
    #expect(sent.subject == "Re: Plans")
    #expect(sent.bodyText?.contains("Saturday works.") == true)
    #expect(sent.rfcMessageId == AccountSync.messageId(for: draft, account: try h.account()))
    #expect(sent.inReplyTo == "<\(second.id)@fake.tern>")
    #expect(sent.refs == "<\(first.id)@fake.tern> <\(second.id)@fake.tern>")

    try await h.sync.pollHistory()
    try await h.expectMirrorsGmail()
    #expect(try h.store.threadDetail(h.thread(first.threadId))?.messages.count == 3)
}

@Test func undoInsideTheWindowCancelsTheSend() async throws {
    let h = try Harness(realEncoder: true)
    let (first, _) = try await h.seedConversation()
    let draft = try h.composeReply(to: first.threadId)
    try await h.drafts.send(draft, undoSeconds: 5, now: h.clock.now())
    h.clock.advance(3)
    try await h.sync.drainOps()
    #expect(try await h.drafts.cancelSend(draft.id, now: h.clock.now()))

    h.clock.advance(60)
    try await h.sync.drainOps()
    #expect(await h.fake.callCount(.sendDraft) == 0)
    #expect(await h.fake.sentRaw.isEmpty)
    #expect(try h.draftRow(draft.id)?.state == .editing)
    // Back to editing: the Gmail copy is saved instead, and Gmail's thread doesn't change.
    #expect(await h.fake.draftIds.count == 1)
    #expect(await h.fake.ids(inThread: first.threadId).count == 3, "two received and the draft")
}

@Test func sendLaterFiresAtItsTime() async throws {
    let h = try Harness(realEncoder: true)
    let (first, _) = try await h.seedConversation()
    let draft = try h.composeReply(to: first.threadId)
    let at = h.clock.now().addingTimeInterval(3600)
    try await h.drafts.scheduleSend(draft, at: at, now: h.clock.now())

    try await h.sync.drainOps()
    #expect(await h.sync.nextOpAt == at)
    h.clock.advance(1800)
    try await h.sync.drainOps()
    #expect(await h.fake.callCount(.sendDraft) == 0)
    #expect(try h.draftRow(draft.id)?.state == .queued)

    h.clock.advance(1801)
    try await h.sync.drainOps()
    #expect(await h.fake.callCount(.sendDraft) == 1)
    #expect(try h.draftRow(draft.id) == nil)
    #expect(try h.store.threadDetail(h.thread(first.threadId))?.messages.last?.isFromMe == true)
}

@Test func discardDeletesTheGmailDraft() async throws {
    let h = try Harness(realEncoder: true)
    let (first, _) = try await h.seedConversation()
    let draft = try h.composeReply(to: first.threadId)
    try await h.queueSave(draft)
    try await h.sync.drainOps()
    try await h.sync.pollHistory()
    let gmailDraftId = try #require(try h.draftRow(draft.id)?.gmailDraftId)
    #expect(try h.store.threadDetail(h.thread(first.threadId))?.thread.hasDraft == true)

    #expect(try await h.drafts.discard(draft.id))
    #expect(try h.draftRow(draft.id) == nil, "the row goes at once")
    #expect(try h.store.threadDetail(h.thread(first.threadId))?.thread.hasDraft == false)
    let op = try #require(try h.ops().first)
    #expect(op.kind == .deleteDraft && op.payload.contains(gmailDraftId))

    try await h.sync.drainOps()
    #expect(await h.fake.draftIds.isEmpty)
    #expect(try h.ops().isEmpty)
    try await h.sync.pollHistory()
    try await h.expectMirrorsGmail()
}

@Test func aForwardArrivesWithItsAttachmentAndInlineImage() async throws {
    let h = try Harness(realEncoder: true)
    let pdf = Data((0..<3000).map { UInt8($0 % 251) })
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + (0..<200).map { UInt8($0) })
    let original = await h.fake.deliver(FakeEmail(
        from: ann, subject: "Q3 report", text: nil, html: #"<p>Numbers attached.</p><img src="cid:chart-1">"#,
        date: testNow.addingTimeInterval(-600),
        attachments: [FakeAttachment(filename: "report.pdf", mimeType: "application/pdf", data: pdf),
                      FakeAttachment(filename: "chart.png", mimeType: "image/png", data: png, contentId: "chart-1")]))
    try await h.syncFully()

    var content = try #require(try h.drafts.makeDraft(.forward(h.thread(original.threadId)), now: h.clock.now()))
    #expect(content.draft.attachments.count == 2)
    #expect(content.draft.attachments.allSatisfy { $0.needsFetch })
    content.draft.toList = [Participant(name: "Bo", email: "bo@example.com")]
    content.body = RichText(html: "<p>FYI</p>")
    let draft = content.assembledDraft(updatedAt: h.clock.now())
    try await h.drafts.send(draft, undoSeconds: 0, now: h.clock.now())
    try await h.sync.drainOps()

    #expect(await h.fake.callCount(.sendDraft) == 1)
    #expect(await h.fake.callCount(.attachment) == 2, "both files downloaded once")
    let sentId = try #require(try h.messages().values.first { $0.isFromMe }?.id)
    #expect(try await fakeAttachment(h.fake, messageId: sentId, filename: "report.pdf") == pdf)
    #expect(try await fakeAttachment(h.fake, messageId: sentId, filename: "chart.png") == png)
    let raw = String(decoding: try #require(await h.fake.draftRaw.last), as: UTF8.self)
    #expect(raw.contains("Content-ID: <chart-1>"), "the inline image keeps the id the quoted body uses")
    #expect(raw.contains("multipart/related"))

    let stored = try h.store.threadDetail(h.thread(original.threadId))
    #expect(stored?.messages.last?.subject == "Fwd: Q3 report")
    #expect(stored?.attachments[sentId]?.map(\.filename).sorted() == ["chart.png", "report.pdf"])
    #expect(!h.folderExists(draft.id), "the draft's folder, downloads included, is removed after sending")
}

@MainActor
@Test func aForwardMovedToAnotherAccountFetchesTheFileFromTheFirst() async throws {
    let store = try MailStore(AppDatabase.inMemory())
    let configuration = SyncConfiguration.test()
    let clock = EngineTestClock()
    let work = FakeGmail(email: "me@work.example", sleep: { _ in })
    let personal = FakeGmail(email: testEmail, sleep: { _ in })
    let pdf = Data("contract".utf8)
    let original = await work.deliver(FakeEmail(from: ann, subject: "Contract", date: testNow.addingTimeInterval(-60),
                                                attachments: [FakeAttachment(filename: "contract.pdf", mimeType: "application/pdf", data: pdf)]))
    let coordinator = SyncCoordinator(
        store: store, accounts: [Account(email: "me@work.example"), Account(email: testEmail)],
        apiProvider: { $0 == testEmail ? personal : work }, encodeDraft: DraftEncoder.make(store: store),
        configuration: configuration, clock: clock)
    let workSync = try #require(coordinator.sync(for: "me@work.example"))
    let personalSync = try #require(coordinator.sync(for: testEmail))
    try await workSync.initialSync()
    try await personalSync.initialSync()

    let drafts = DraftStore(store.database, filesDirectory: configuration.draftFilesDirectory)
    var content = try #require(try drafts.makeDraft(.forward(ThreadKey(accountId: "me@work.example", threadId: original.threadId))))
    content.draft.accountId = testEmail
    content.draft.toList = [Participant(email: "lawyer@example.com")]
    try await drafts.send(content.assembledDraft(), undoSeconds: 0, now: clock.now())
    try await personalSync.drainOps()

    #expect(await work.callCount(.attachment) == 1, "downloaded through the account that has it")
    #expect(await personal.callCount(.sendDraft) == 1)
    let sent = try #require(await personal.allMessageIds.first)
    #expect(try await fakeAttachment(personal, messageId: sent, filename: "contract.pdf") == pdf)
    let threadId = try #require(await personal.message(sent)?.threadId)
    #expect(await personal.ids(inThread: threadId) == [sent], "a new conversation in the other account")
    await coordinator.shutdown()
}

@Test func aLostCreateResponseDoesNotLeaveADuplicateGmailDraft() async throws {
    let h = try Harness(realEncoder: true)
    let (first, _) = try await h.seedConversation()
    let draft = try h.composeReply(to: first.threadId)
    await h.fake.loseNextResponse(on: .createDraft)
    try await h.queueSave(draft)
    try await h.sync.drainOps()
    #expect(try h.draftRow(draft.id)?.gmailDraftId == nil)
    #expect(try h.ops().first?.lastError != nil, "retried later")

    h.clock.advance(60)
    try await h.sync.drainOps()
    #expect(await h.fake.callCount(.createDraft) == 1)
    #expect(await h.fake.callCount(.updateDraft) == 1, "the lost draft was found by its Message-ID and updated")
    #expect(await h.fake.draftIds.count == 1)
    let remaining = await h.fake.draftIds
    #expect(try h.draftRow(draft.id)?.gmailDraftId == remaining.first)

    try await h.drafts.send(try #require(try h.draftRow(draft.id)), undoSeconds: 0, now: h.clock.now())
    try await h.sync.drainOps()
    #expect(await h.fake.draftIds.isEmpty)
    #expect(await h.fake.callCount(.createDraft) == 1)
}

@Test func aDraftFromTheBrowserIsSentAsThatDraft() async throws {
    let h = try Harness(realEncoder: true)
    let (first, second) = try await h.seedConversation()
    let browser = Data("""
        From: \(testEmail)\r
        To: ann@example.com\r
        Subject: Re: Plans\r
        Message-ID: <browser-1@mail.gmail.com>\r
        In-Reply-To: <\(second.id)@fake.tern>\r
        Content-Type: text/plain; charset=UTF-8\r
        \r
        Started on the phone
        """.utf8)
    let gmailDraft = try await h.fake.createDraft(raw: browser, threadId: first.threadId)
    try await h.sync.pollHistory()
    let messageId = try #require(gmailDraft.message?.id)

    var content = try #require(try h.drafts.importDraftMessage(MessageKey(accountId: testEmail, messageId: messageId)))
    content.body = RichText(html: "<p>Finished on the Mac</p>")
    try await h.drafts.send(content.assembledDraft(), undoSeconds: 0, now: h.clock.now())
    try await h.sync.drainOps()

    #expect(await h.fake.callCount(.createDraft) == 1, "only the browser's")
    #expect(await h.fake.callCount(.updateDraft) == 1)
    #expect(await h.fake.draftIds.isEmpty, "that draft was sent")
    try await h.sync.pollHistory()
    try await h.expectMirrorsGmail()
    let messages = try #require(try h.store.threadDetail(h.thread(first.threadId))?.messages)
    #expect(messages.count == 3 && messages.last?.bodyText?.contains("Finished on the Mac") == true)
}

@Test func aDraftDiscardedWhileItsGmailCopyIsSavedLeavesNoCopy() async throws {
    let discardDuringCall = Locked<DraftStore?>(nil)
    let draftId = Locked("")
    let fake = FakeGmail(email: testEmail, sleep: { _ in
        guard let drafts = discardDuringCall.value else { return }
        discardDuringCall.set(nil)
        _ = try await drafts.discard(draftId.value)
    })
    let h = try Harness(fake: fake, realEncoder: true)
    let (first, _) = try await h.seedConversation()
    let draft = try h.composeReply(to: first.threadId)
    try await h.queueSave(draft)
    draftId.set(draft.id)
    // The user discards the draft while drafts.create is on its way.
    discardDuringCall.set(h.drafts)
    await fake.setLatency(0.01)
    try await h.sync.drainOps()

    #expect(try h.draftRow(draft.id) == nil)
    #expect(await fake.callCount(.createDraft) == 1)
    #expect(await fake.draftIds.isEmpty, "the copy made meanwhile was deleted")
    #expect(try h.ops().isEmpty)
}

@Test func changingTheAccountMovesTheGmailDraft() async throws {
    let store = try MailStore(AppDatabase.inMemory())
    let configuration = SyncConfiguration.test()
    let clock = EngineTestClock()
    let work = FakeGmail(email: "me@work.example", sleep: { _ in })
    let personal = FakeGmail(email: testEmail, sleep: { _ in })
    let workSync = AccountSync(account: Account(email: "me@work.example"), store: store, api: work,
                               encodeDraft: DraftEncoder.make(store: store), configuration: configuration, clock: clock)
    let personalSync = AccountSync(account: Account(email: testEmail), store: store, api: personal,
                                   encodeDraft: DraftEncoder.make(store: store), configuration: configuration, clock: clock)
    try await workSync.initialSync()
    try await personalSync.initialSync()
    let drafts = DraftStore(store.database, filesDirectory: configuration.draftFilesDirectory)

    var draft = Draft(accountId: "me@work.example", toList: [Participant(email: "bo@example.com")], subject: "Hello",
                      bodyHtml: "<p>Hi Bo</p>")
    try await drafts.save(draft, now: clock.now().addingTimeInterval(-60))
    try await workSync.drainOps()
    #expect(await work.draftIds.count == 1)

    draft.accountId = testEmail
    try await drafts.save(draft, now: clock.now().addingTimeInterval(-60))
    try await workSync.drainOps()
    try await personalSync.drainOps()
    #expect(await work.draftIds.isEmpty, "removed from the old account")
    #expect(await personal.draftIds.count == 1, "saved in the new one")
    let row = try #require(try drafts.draft(id: draft.id))
    let saved = await personal.draftIds
    #expect(row.accountId == testEmail && row.gmailDraftId == saved.first)
}

@Test func aStagedSendNeverGivesUpOnAServerOutage() async throws {
    let h = try Harness(realEncoder: true)
    let (first, _) = try await h.seedConversation()
    let draft = try h.composeReply(to: first.threadId)
    // drafts.send went through but its answer was lost, then Gmail answers 500 for a long while.
    await h.fake.loseNextResponse(on: .sendDraft)
    try await h.drafts.send(draft, undoSeconds: 0, now: h.clock.now())
    try await h.sync.drainOps()
    await h.fake.failNext(1000, with: .server(status: 500, message: "Backend Error"))
    for _ in 0..<20 {
        h.clock.advance(400)
        try await h.sync.drainOps()
    }
    #expect(try h.draftRow(draft.id)?.state == .queued, "never made editable while it may have gone out")
    #expect(try h.ops().first?.state == .pending)
    #expect(!(try await h.drafts.cancelSend(draft.id)))

    await h.fake.clearFailures()
    h.clock.advance(400)
    try await h.sync.drainOps()
    #expect(try h.draftRow(draft.id) == nil)
    #expect(await h.fake.ids(inThread: first.threadId).count == 3, "two received and exactly one sent")
}

@Test func sendingAgainAfterAStagedSendFailedDoesNotDuplicateIt() async throws {
    let h = try Harness(realEncoder: true)
    let (first, _) = try await h.seedConversation()
    let draft = try h.composeReply(to: first.threadId)
    await h.fake.loseNextResponse(on: .sendDraft)
    try await h.drafts.send(draft, undoSeconds: 0, now: h.clock.now())
    try await h.sync.drainOps()
    // As an older build would leave it: the op failed for good and the draft became editable again.
    try await h.store.database.writer.write { db in
        try db.execute(sql: "UPDATE pending_op SET state = 'failed'")
        try db.execute(sql: "UPDATE draft SET state = 'failed'")
    }
    let stored = try #require(try h.draftRow(draft.id))
    try await h.drafts.send(stored, undoSeconds: 0, now: h.clock.now())
    try await h.sync.drainOps()

    #expect(await h.fake.callCount(.createDraft) == 1)
    #expect(await h.fake.callCount(.sendDraft) == 1)
    #expect(await h.fake.ids(inThread: first.threadId).count == 3, "two received and exactly one sent")
    #expect(try h.draftRow(draft.id) == nil)
}

@Test func queuedSendsGoOutDuringALongHistoryCatchUp() async throws {
    var configuration = SyncConfiguration.test()
    configuration.historyFullFetchLimit = 2
    let h = try Harness(configuration: configuration, realEncoder: true)
    let (first, _) = try await h.seedConversation()
    for index in 0..<40 {
        await h.fake.deliver(FakeEmail(subject: "Overnight \(index)", date: testNow.addingTimeInterval(Double(index))))
    }
    let draft = try h.composeReply(to: first.threadId)
    try await h.drafts.send(draft, undoSeconds: 0, now: h.clock.now())
    await h.sync.kick()

    // The poll alone: the send can only have gone out from inside it.
    try await h.sync.pollHistory()
    #expect(await h.fake.callCount(.sendDraft) == 1)
    #expect(try h.draftRow(draft.id) == nil)
}
