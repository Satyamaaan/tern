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

extension Harness {
    var drafts: DraftStore { DraftStore(store.database, filesDirectory: configuration.draftFilesDirectory) }

    /// Send with an undo window ending at `notBefore` (now when nil), on the test clock.
    func queueSend(_ draft: Draft, notBefore: Date?) async throws {
        let now = clock.now()
        if let scheduled = draft.scheduledAt {
            try await drafts.scheduleSend(draft, at: scheduled, now: now)
        } else {
            try await drafts.send(draft, undoSeconds: Int(((notBefore ?? now).timeIntervalSince(now)).rounded()), now: now)
        }
    }

    /// Saves the draft and makes its Gmail save due at once.
    func queueSave(_ draft: Draft) async throws {
        try await drafts.save(draft, now: clock.now().addingTimeInterval(-DraftStore.saveInterval))
    }
}

@Test func sendWaitsForTheUndoWindowAndCanBeUndone() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 4)
    try await h.syncFully()
    let original = seeded[0]
    let draft = reply(to: original)

    try await h.queueSend(draft, notBefore: h.clock.now().addingTimeInterval(10))
    try await h.sync.drainOps()
    #expect(await h.fake.callCount(.sendDraft) == 0)
    #expect(await h.sync.nextOpAt == h.clock.now().addingTimeInterval(10))

    // Undo within the window.
    #expect(try await h.drafts.cancelSend(draft.id))
    #expect(try draftRow(h, draft.id)?.state == .editing)
    #expect(try h.ops().map(\.kind) == [.saveDraft], "back to editing, the Gmail copy is saved later")

    // Send again and let the window pass.
    try await h.queueSend(draft, notBefore: h.clock.now().addingTimeInterval(10))
    h.clock.advance(5)
    try await h.sync.drainOps()
    #expect(await h.fake.callCount(.sendDraft) == 0)
    h.clock.advance(6)
    try await h.sync.drainOps()
    #expect(await h.fake.callCount(.sendDraft) == 1)
    #expect(!(try await h.drafts.cancelSend(draft.id)), "too late to undo")

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

    try await h.queueSend(draft, notBefore: nil)
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

    try await h.queueSave(draft)
    try await h.sync.drainOps()
    let saved = try #require(try draftRow(h, draft.id))
    let gmailDraftId = try #require(saved.gmailDraftId)
    #expect(saved.gmailMessageId != nil)
    #expect(await h.fake.draftIds == [gmailDraftId])

    draft = saved
    draft.bodyHtml = "<p>Second</p>"
    try await h.queueSave(draft)
    try await h.sync.drainOps()
    #expect(await h.fake.callCount(.updateDraft) == 1)
    #expect(try draftRow(h, draft.id)?.gmailDraftId == gmailDraftId)

    try await h.sync.pollHistory()
    #expect(try h.store.threadDetail(h.thread(seeded[0].threadId))?.thread.hasDraft == true)

    try await h.queueSend(try #require(try draftRow(h, draft.id)), notBefore: nil)
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
    try await h.queueSave(draft)
    try await h.sync.drainOps()
    try await h.sync.pollHistory()

    try await h.drafts.discard(draft.id)
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
    try await h.queueSend(draft, notBefore: nil)

    try await h.sync.drainOps()
    #expect(try h.ops().first?.state == .pending, "a lost response is retried")
    #expect(!(try await h.drafts.cancelSend(draft.id)), "it may already have gone out")
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
    try await h.queueSend(early, notBefore: nil)
    try await h.store.database.writer.write { db in try db.execute(sql: "UPDATE pending_op SET state = 'inflight'") }
    var relaunched = h.relaunched()
    try await relaunched.prepare()
    try await relaunched.drainOps()
    #expect(await h.fake.callCount(.sendDraft) == 1)
    #expect(try draftRow(h, early.id) == nil)

    // Quit right after drafts.send went through: the relaunch sees the draft is gone and doesn't resend.
    let late = reply(to: seeded[1], body: "<p>Late</p>")
    try await h.queueSend(late, notBefore: nil)
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
    try await h.queueSend(draft, notBefore: nil)

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

@Test func aFailedSendIsClearedWhenItsDraftIsDiscardedEditedOrSentAgain() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 3)
    try await h.syncFully()
    func failSend(_ draft: Draft) async throws {
        await h.fake.failNext(100, with: .server(status: 400, message: "Invalid To header"), on: .sendDraft)
        try await h.queueSend(draft, notBefore: nil)
        for _ in 0..<10 {
            try await h.sync.drainOps()
            h.clock.advance(1000)
        }
        await h.fake.clearFailures()
        #expect(try h.ops().map(\.state).contains(.failed))
    }
    func failed() throws -> Int {
        try h.store.database.reader.read { db in try MailStore.pendingOpCounts(db)[testEmail]?.failed ?? 0 }
    }

    let discarded = reply(to: seeded[0])
    try await failSend(discarded)
    #expect(try await h.drafts.discard(discarded.id))
    #expect(try failed() == 0, "discarded")

    let edited = reply(to: seeded[1])
    try await failSend(edited)
    var row = try #require(try draftRow(h, edited.id))
    row.bodyHtml = "<p>Fixed it</p>"
    try await h.drafts.save(row, now: h.clock.now())
    #expect(try failed() == 0, "taken back to edit")

    let resent = reply(to: seeded[2])
    try await failSend(resent)
    try await h.drafts.send(try #require(try draftRow(h, resent.id)), undoSeconds: 0, now: h.clock.now())
    #expect(try failed() == 0, "sent again")
    try await h.sync.drainOps()
    #expect(try draftRow(h, resent.id) == nil)
}

@Test func aFailedGmailSaveIsSupersededByALaterOne() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 2)
    try await h.syncFully()
    var draft = reply(to: seeded[0])
    await h.fake.failNext(100, with: .server(status: 400, message: "Bad draft"), on: .createDraft)
    try await h.queueSave(draft)
    for _ in 0..<10 {
        try await h.sync.drainOps()
        h.clock.advance(1000)
    }
    await h.fake.clearFailures()
    #expect(try h.ops().map(\.state) == [.failed])

    draft.bodyHtml = "<p>Again</p>"
    try await h.queueSave(draft)
    try await h.sync.drainOps()
    #expect(try h.ops().isEmpty, "the save that went through replaces the failed one")
    #expect(await h.fake.draftIds.count == 1)
}

@Test func aDraftIsListedInDraftsOnceWhileGmailReplacesItsCopy() async throws {
    let h = try Harness()
    try await h.syncFully()
    var draft = Draft(accountId: testEmail, toList: [Participant(email: "ann@example.com")], subject: "Plans", bodyHtml: "<p>First</p>")
    func listed() throws -> [ThreadKey] { try h.store.threadRows(in: Mailbox(.drafts)).map(\.id) }
    let local = h.thread(MailThread.localDraftPrefix + draft.id)

    try await h.queueSave(draft)
    #expect(try listed() == [local], "listed before Gmail has a copy")
    try await h.sync.drainOps()
    try await h.sync.pollHistory()
    let first = try #require(try draftRow(h, draft.id)?.gmailMessageId)
    let threadId = try #require(try await h.store.database.reader.read { db in
        try String.fetchOne(db, sql: "SELECT threadId FROM message WHERE id = ?", arguments: [first])
    })
    #expect(try listed() == [h.thread(threadId)], "by its thread once Gmail's copy is stored")

    draft = try #require(try draftRow(h, draft.id))
    draft.bodyHtml = "<p>Second</p>"
    try await h.queueSave(draft)
    try await h.sync.drainOps()
    #expect(try draftRow(h, draft.id)?.gmailMessageId != first)
    #expect(try listed() == [local], "Gmail swapped its copy for a new message: still listed once")
    try await h.sync.pollHistory()
    let stored = try #require(try draftRow(h, draft.id)?.gmailMessageId)
    let newThread = try #require(try await h.store.database.reader.read { db in
        try String.fetchOne(db, sql: "SELECT threadId FROM message WHERE id = ? AND isDraft = 1", arguments: [stored])
    })
    #expect(try listed() == [h.thread(newThread)], "by its thread again once history stores the new copy")
    #expect(try h.store.scopeCounts(accountId: nil).drafts == 1)
}

@Test func aLocalDraftsRowFetchesNothingFromGmail() async throws {
    let h = try Harness()
    await seed(h.fake, count: 3)
    try await h.syncFully()
    let draft = Draft(accountId: testEmail, subject: "Never saved")
    try await h.queueSave(draft)
    let row = h.thread(MailThread.localDraftPrefix + draft.id)
    await h.fake.resetCallLog()

    try await h.sync.fetchBodies(row)
    await h.sync.prefetchAdjacent([row])
    #expect(await h.fake.unitsSpent == 0)
}

@Test func aSendHiddenFromALaggingSearchIndexIsStillNotResent() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 2)
    try await h.syncFully()
    await h.fake.stallSearchIndex()
    await h.fake.loseNextResponse(on: .sendDraft)
    let draft = reply(to: seeded[0])
    try await h.queueSend(draft, notBefore: nil)

    try await h.sync.drainOps()
    h.clock.advance(60)
    try await h.sync.drainOps()

    // Search missed it, so drafts.send was tried again; the draft was gone, which usually means it
    // went out, but that isn't taken on trust: the draft stays, locked, until Sent shows the message.
    #expect(await h.fake.callCount(.sendDraft) == 2)
    #expect(try draftRow(h, draft.id)?.state == .queued)
    #expect(!(try await h.drafts.cancelSend(draft.id)))
    #expect(!(try await h.drafts.discard(draft.id)))

    await h.fake.resumeSearchIndex()
    h.clock.advance(15)
    try await h.sync.drainOps()
    #expect(await h.fake.callCount(.sendDraft) == 2, "never sent again")
    #expect(await h.fake.allMessageIds.count == 3)
    #expect(try draftRow(h, draft.id) == nil)
    #expect(try h.ops().isEmpty)
    let detail = try #require(try h.store.threadDetail(h.thread(seeded[0].threadId)))
    #expect(detail.messages.last?.labelIds == [SystemLabel.sent])
}

@Test func aSendWhoseGmailDraftWasDeletedElsewhereIsKeptAndNotResent() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 2)
    try await h.syncFully()
    var draft = reply(to: seeded[0])
    let file = try await h.drafts.addData(Data("notes".utf8), filename: "notes.txt", to: draft.id)
    draft.attachments = [file]
    // Staged, then drafts.send fails before Gmail takes it; meanwhile the draft is deleted on the phone.
    await h.fake.failNext(1, with: .network("offline"), on: .sendDraft)
    try await h.queueSend(draft, notBefore: nil)
    try await h.sync.drainOps()
    let op = try #require(try h.ops().first)
    let staged = try #require(try JSONDecoder().decode(DraftOpPayload.self, from: Data(op.payload.utf8)).sendingDraftId)
    try await h.fake.deleteDraft(id: staged)

    for _ in 0..<6 {
        h.clock.advance(200)
        try await h.sync.drainOps()
    }
    #expect(await h.fake.callCount(.sendDraft) == 2, "drafts.send is not called again after it said the draft is gone")
    let sentChecks = await h.fake.listCalls.filter { $0.query?.hasPrefix("rfc822msgid:") == true }.count
    #expect(sentChecks == 1 + h.configuration.sendConfirmationDelays.count, "Sent was looked at again a few times")
    #expect(await h.fake.allMessageIds.count == 2, "nothing went out")
    let row = try #require(try draftRow(h, draft.id), "the draft is kept")
    #expect(row.state == .failed)
    #expect(row.lastError == DraftStore.unconfirmedSendError)
    #expect(row.attachments.map(\.path) == [file.path])
    #expect(FileManager.default.fileExists(atPath: file.path), "and so are its files")
    #expect(try h.ops().isEmpty, "the send op is dropped")

    // Sending it again is the user's call; it then goes out once.
    try await h.drafts.send(row, undoSeconds: 0, now: h.clock.now())
    try await h.sync.drainOps()
    #expect(await h.fake.callCount(.sendDraft) == 3)
    #expect(await h.fake.allMessageIds.count == 3)
    #expect(try draftRow(h, draft.id) == nil)
}

@Test func theStableMessageIdReplacesTheEncodersOwn() {
    let raw = Data("From: a@x\r\nMessage-ID: <random@x>\r\nX-Folded: one\r\n two\r\nmessage-id:\r\n <again@x>\r\n\r\nBody\r\n".utf8)
    let result = String(decoding: MailParsing.settingHeader("Message-ID", to: "<stable@x>", in: raw), as: UTF8.self)
    #expect(result == "Message-ID: <stable@x>\r\nFrom: a@x\r\nX-Folded: one\r\n two\r\n\r\nBody\r\n")
    let bare = String(decoding: MailParsing.settingHeader("Message-ID", to: "<s@x>", in: Data("Subject: Hi\n\nText".utf8)), as: UTF8.self)
    #expect(bare == "Message-ID: <s@x>\r\nSubject: Hi\r\n\r\nText")
}
