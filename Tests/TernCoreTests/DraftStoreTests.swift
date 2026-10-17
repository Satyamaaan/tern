import Foundation
import GRDB
import Testing
@testable import TernCore

private let home = Account(email: "me@example.com", sortOrder: 0)
private let work = Account(email: "me@work.dev", sortOrder: 1)
private let maya = Participant(name: "Maya Chen", email: "maya@lumen.io")
private let jonas = Participant(name: "Jonas", email: "jonas@lumen.io")
private let thread = ThreadKey(accountId: home.id, threadId: "t1")
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func makeStore() throws -> DraftStore {
    let database = try AppDatabase.inMemory()
    try database.writer.write { db in
        try home.insert(db)
        try work.insert(db)
        try MailStore.upsertMessages(db, [
            MailMessage(accountId: home.id, id: "m1", threadId: "t1", date: Date(timeIntervalSince1970: 100),
                        fromName: maya.name, fromEmail: maya.email, toList: [Participant(email: home.email), jonas],
                        ccList: [Participant(email: work.email)], subject: "Lisbon offsite", bodyText: "Can you make it?",
                        bodyHtml: "<div>Can you make it?</div>", bodyState: .full, labelIds: ["INBOX"], hasAttachments: true),
            MailMessage(accountId: home.id, id: "d1", threadId: "t1", date: Date(timeIntervalSince1970: 200),
                        fromEmail: home.email, toList: [maya], subject: "Re: Lisbon offsite", snippet: "Started this",
                        bodyText: "Started this", bodyHtml: "<div>Started this</div>", bodyState: .full, labelIds: ["DRAFT"]),
        ], attachments: [
            MailAttachment(accountId: home.id, messageId: "m1", partId: "1", attachmentId: "att-1",
                           filename: "Agenda.pdf", mimeType: "application/pdf", size: 1_000),
            MailAttachment(accountId: home.id, messageId: "m1", partId: "2", attachmentId: "att-2",
                           filename: "logo.png", mimeType: "image/png", size: 200, contentId: "logo", isInline: true),
        ])
    }
    let files = FileManager.default.temporaryDirectory.appendingPathComponent("tern-draft-tests-\(UUID().uuidString)")
    return DraftStore(database, filesDirectory: files)
}

private func ops(_ store: DraftStore) throws -> [PendingOp] {
    try store.database.reader.read { db in try PendingOp.order(Column("id")).fetchAll(db) }
}

private func payload(_ op: PendingOp) throws -> DraftOpPayload {
    try JSONDecoder().decode(DraftOpPayload.self, from: Data(op.payload.utf8))
}

private func typed(_ content: DraftContent, _ text: String) -> Draft {
    var content = content
    content.body = RichText(plainText: text)
    return content.assembledDraft(updatedAt: t0)
}

@Test func newDraftUsesDefaultAccountAndSignature() async throws {
    let store = try makeStore()
    try await store.setSignature("<b>Alex</b>", accountId: work.id)
    try await store.database.writer.write { db in try Setting(key: DraftStore.SettingKey.defaultAccount, value: work.id).upsert(db) }
    let content = try #require(try store.makeDraft(.new(accountId: nil, to: [maya, Participant(email: "MAYA@lumen.io")])))
    #expect(content.draft.accountId == work.id)
    #expect(content.draft.toList == [maya])
    #expect(content.signatureHtml == "<b>Alex</b>")
    #expect(content.draft.bodyHtml.hasSuffix(#"<br><div class="gmail_signature" data-smartmail="gmail_signature"><b>Alex</b></div>"#))
    #expect(content.isBlank == false)

    try await store.database.writer.write { db in try Setting(key: DraftStore.SettingKey.signatures, value: "off").upsert(db) }
    let unsigned = try #require(try store.makeDraft(.new(accountId: work.id)))
    #expect(unsigned.signatureHtml == nil)
    #expect(unsigned.isBlank)
    // Nothing is written until the first save.
    #expect(try await store.database.reader.read { db in try Draft.fetchCount(db) } == 0)
}

@Test func replyAllPrefillsRecipientsSubjectAndQuote() async throws {
    let store = try makeStore()
    try await store.setSignature("Alex", accountId: home.id)
    let content = try #require(try store.makeDraft(.reply(thread, all: true), timeZone: TimeZone(identifier: "UTC")!))
    let draft = content.draft
    #expect(draft.kind == .replyAll)
    #expect(draft.accountId == home.id)
    #expect(draft.threadId == "t1")
    #expect(draft.replyToMessageId == "m1")
    #expect(draft.toList == [maya, jonas])
    #expect(draft.ccList.isEmpty)
    #expect(draft.subject == "Re: Lisbon offsite")
    #expect(content.quoteHtml?.contains("Maya Chen &lt;<a href=\"mailto:maya@lumen.io\">maya@lumen.io</a>&gt; wrote:") == true)
    // Signature sits above the quote.
    let html = draft.bodyHtml
    let signature = try #require(html.range(of: "gmail_signature"))
    let quote = try #require(html.range(of: "gmail_quote"))
    #expect(signature.lowerBound < quote.lowerBound)
    #expect(content.isBlank)
}

@Test func replyReusesTheEditingDraftOfTheSameKind() async throws {
    let store = try makeStore()
    let first = try #require(try store.makeDraft(.reply(thread, all: false)))
    try await store.save(typed(first, "On it"), now: t0)
    let again = try #require(try store.makeDraft(.reply(thread, all: false)))
    #expect(again.draft.id == first.draft.id)
    #expect(again.body.plainText == "On it")
    #expect(again.quoteHtml == first.quoteHtml)
    #expect(try store.makeDraft(.reply(thread, all: true))?.draft.id != first.draft.id)
    #expect(try store.editingDraft(inThread: thread)?.id == first.draft.id)
}

@Test func forwardCarriesAttachmentsToFetchLater() throws {
    let store = try makeStore()
    try store.database.writer.write { db in
        try db.execute(sql: "UPDATE message SET bodyHtml = '<div>Can you make it?</div><img src=\"cid:logo\">' WHERE id = 'm1'")
    }
    let content = try #require(try store.makeDraft(.forward(thread)))
    #expect(content.draft.kind == .forward)
    #expect(content.draft.subject == "Fwd: Lisbon offsite")
    #expect(content.draft.toList.isEmpty)
    #expect(content.quoteHtml?.contains("Forwarded message") == true)
    #expect(content.draft.attachments == [
        DraftAttachment(path: "", filename: "Agenda.pdf", mimeType: "application/pdf", size: 1_000,
                        remote: RemoteAttachmentRef(accountId: home.id, messageId: "m1", partId: "1", attachmentId: "att-1")),
        DraftAttachment(path: "", filename: "logo.png", mimeType: "image/png", size: 200,
                        remote: RemoteAttachmentRef(accountId: home.id, messageId: "m1", partId: "2", attachmentId: "att-2"),
                        contentId: "logo"),
    ])
    #expect(content.draft.attachments.allSatisfy { $0.needsFetch })
    #expect(content.isBlank)
}

@Test func oldDraftAttachmentJSONStillDecodes() throws {
    let json = #"[{"path":"/tmp/a.pdf","filename":"a.pdf","mimeType":"application/pdf","size":3}]"#
    let decoded = try JSONDecoder().decode([DraftAttachment].self, from: Data(json.utf8))
    #expect(decoded == [DraftAttachment(path: "/tmp/a.pdf", filename: "a.pdf", mimeType: "application/pdf", size: 3)])
    #expect(try JSONDecoder().decode(DraftOpPayload.self, from: Data(#"{"draftId":"x"}"#.utf8)) == DraftOpPayload(draftId: "x"))
}

@Test func autosaveQueuesAtMostOneGmailSavePerDraft() async throws {
    let store = try makeStore()
    let content = try #require(try store.makeDraft(.new(accountId: home.id, to: [maya])))
    try await store.save(typed(content, "Hi"), now: t0)
    try await store.save(typed(content, "Hi there"), now: t0.addingTimeInterval(2))
    var queued = try ops(store)
    #expect(queued.count == 1)
    #expect(queued[0].kind == .saveDraft)
    #expect(queued[0].notBefore == t0.addingTimeInterval(DraftStore.saveInterval))
    #expect(try payload(queued[0]).draftId == content.draft.id)
    #expect(try store.draft(id: content.draft.id)?.bodyHtml.hasPrefix("<div>Hi there</div>") == true)

    // While the engine is uploading, the next edit queues one more.
    try await store.database.writer.write { db in try db.execute(sql: "UPDATE pending_op SET state = 'inflight'") }
    try await store.save(typed(content, "Hi there!"), now: t0.addingTimeInterval(12))
    try await store.save(typed(content, "Hi there!!"), now: t0.addingTimeInterval(13))
    queued = try ops(store)
    #expect(queued.map(\.state) == [.inflight, .pending])
    #expect(queued[1].notBefore == t0.addingTimeInterval(12 + DraftStore.saveInterval))
}

@Test func blankDraftsStayLocal() async throws {
    let store = try makeStore()
    let content = try #require(try store.makeDraft(.new(accountId: home.id)))
    try await store.save(content.assembledDraft(), now: t0)
    #expect(try store.draft(id: content.draft.id) != nil)
    #expect(try ops(store).isEmpty)
}

@Test func savingKeepsSyncOwnedColumns() async throws {
    let store = try makeStore()
    let content = try #require(try store.makeDraft(.new(accountId: home.id, to: [maya])))
    try await store.save(typed(content, "v1"), now: t0)
    try await store.database.writer.write { db in
        try db.execute(sql: "UPDATE draft SET gmailDraftId = 'r-1', gmailMessageId = 'g-1' WHERE id = ?", arguments: [content.draft.id])
    }
    try await store.save(typed(content, "v2"), now: t0.addingTimeInterval(1))
    let stored = try #require(try store.draft(id: content.draft.id))
    #expect(stored.gmailDraftId == "r-1")
    #expect(stored.gmailMessageId == "g-1")
    #expect(stored.updatedAt == t0.addingTimeInterval(1))
}

@Test func changingAccountMovesTheGmailDraft() async throws {
    let store = try makeStore()
    let content = try #require(try store.makeDraft(.new(accountId: home.id, to: [maya])))
    try await store.save(typed(content, "v1"), now: t0)
    try await store.database.writer.write { db in
        try db.execute(sql: "UPDATE draft SET gmailDraftId = 'r-1' WHERE id = ?", arguments: [content.draft.id])
    }
    var moved = typed(content, "v2")
    moved.accountId = work.id
    try await store.save(moved, now: t0.addingTimeInterval(1))
    let queued = try ops(store)
    #expect(queued.map(\.kind) == [.deleteDraft, .saveDraft])
    #expect(queued.map(\.accountId) == [home.id, work.id])
    #expect(try payload(queued[0]) == DraftOpPayload(draftId: content.draft.id, gmailDraftId: "r-1"))
    #expect(try store.draft(id: content.draft.id)?.gmailDraftId == nil)
}

@Test func sendQueuesWithUndoWindowAndCanBeCancelled() async throws {
    let store = try makeStore()
    let content = try #require(try store.makeDraft(.reply(thread, all: false)))
    try await store.save(typed(content, "Yes!"), now: t0)
    let receipt = try await store.send(typed(content, "Yes, I'm in."), now: t0.addingTimeInterval(1))
    #expect(receipt.notBefore == t0.addingTimeInterval(1 + 5))
    var queued = try ops(store)
    #expect(queued.map(\.kind) == [.sendDraft])
    #expect(queued[0].id == receipt.opId)
    #expect(queued[0].notBefore == receipt.notBefore)
    var stored = try #require(try store.draft(id: content.draft.id))
    #expect(stored.state == .queued)
    #expect(stored.bodyHtml.hasPrefix("<div>Yes, I&#39;m in.</div>") || stored.bodyHtml.hasPrefix("<div>Yes, I'm in.</div>"))
    // A stale autosave can't pull it back.
    #expect(try await store.save(typed(content, "late"), now: t0.addingTimeInterval(2)) == false)
    await #expect(throws: DraftError.notEditable) { try await store.send(typed(content, "again")) }
    let contact = try await store.database.reader.read { db in try Contact.fetchOne(db, key: maya.email) }
    #expect(contact?.sentCount == 1)

    #expect(try await store.cancelSend(content.draft.id, now: t0.addingTimeInterval(3)))
    stored = try #require(try store.draft(id: content.draft.id))
    #expect(stored.state == .editing)
    queued = try ops(store)
    #expect(queued.map(\.kind) == [.saveDraft])
    #expect(try await store.cancelSend(content.draft.id) == false)
}

@Test func undoSecondsComeFromSettings() async throws {
    let store = try makeStore()
    try await store.database.writer.write { db in try Setting(key: DraftStore.SettingKey.undoSeconds, value: "10").upsert(db) }
    let content = try #require(try store.makeDraft(.new(accountId: home.id, to: [maya])))
    let receipt = try await store.send(typed(content, "Hi"), now: t0)
    #expect(receipt.notBefore == t0.addingTimeInterval(10))
    let quick = try #require(try store.makeDraft(.new(accountId: home.id, to: [jonas])))
    #expect(try await store.send(typed(quick, "Hi"), undoSeconds: 0, now: t0).notBefore == t0)
}

@Test func cancelFailsOnceTheEngineHasStarted() async throws {
    let store = try makeStore()
    let content = try #require(try store.makeDraft(.new(accountId: home.id, to: [maya])))
    try await store.send(typed(content, "Hi"), now: t0)
    try await store.database.writer.write { db in try db.execute(sql: "UPDATE pending_op SET state = 'inflight'") }
    #expect(try await store.cancelSend(content.draft.id) == false)
    #expect(try store.draft(id: content.draft.id)?.state == .queued)
    #expect(try await store.discard(content.draft.id) == false)
}

@Test func aSendTheEngineHasStagedCanNoLongerBeUndoneOrDiscarded() async throws {
    let store = try makeStore()
    let content = try #require(try store.makeDraft(.new(accountId: home.id, to: [maya])))
    try await store.send(typed(content, "Hi"), now: t0)
    // A retry after a lost drafts.send response: back to pending, but the Gmail draft is staged.
    let staged = String(decoding: try JSONEncoder().encode(DraftOpPayload(draftId: content.draft.id, sendingDraftId: "r-1")), as: UTF8.self)
    try await store.database.writer.write { db in try db.execute(sql: "UPDATE pending_op SET payload = ?", arguments: [staged]) }
    #expect(try await store.cancelSend(content.draft.id) == false)
    #expect(try await store.discard(content.draft.id) == false)
    #expect(try store.draft(id: content.draft.id)?.state == .queued)
}

@Test func aSignatureSetInTernStaysTernsOwn() async throws {
    let store = try makeStore()
    try await store.setSignature("<b>Mia</b>", accountId: home.id)
    let key = DraftStore.SettingKey.customSignature(home.id)
    #expect(try await store.database.reader.read { db in try Setting.fetchOne(db, key: key)?.value } == "1")
    try await store.useGmailSignature(accountId: home.id)
    #expect(try await store.database.reader.read { db in try Setting.fetchOne(db, key: key) } == nil)
    #expect(try store.signature(accountId: home.id) == "<b>Mia</b>", "kept until Gmail's replaces it")
}

@Test func scheduleSendWaitsForTheDate() async throws {
    let store = try makeStore()
    let content = try #require(try store.makeDraft(.new(accountId: home.id, to: [maya])))
    let later = t0.addingTimeInterval(86_400)
    let receipt = try await store.scheduleSend(typed(content, "Morning!"), at: later, now: t0)
    #expect(receipt.notBefore == later)
    let stored = try #require(try store.draft(id: content.draft.id))
    #expect(stored.state == .queued)
    #expect(stored.scheduledAt == later)
    #expect(try ops(store).first?.notBefore == later)
    #expect(try await store.cancelSend(content.draft.id))
    #expect(try store.draft(id: content.draft.id)?.scheduledAt == nil)
}

@Test func discardRemovesDraftOpsAndGmailCopy() async throws {
    let store = try makeStore()
    let local = try #require(try store.makeDraft(.new(accountId: home.id, to: [maya])))
    try await store.save(typed(local, "x"), now: t0)
    #expect(try await store.discard(local.draft.id))
    #expect(try store.draft(id: local.draft.id) == nil)
    #expect(try ops(store).isEmpty)

    let synced = try #require(try store.makeDraft(.reply(thread, all: false)))
    try await store.save(typed(synced, "y"), now: t0)
    try await store.database.writer.write { db in
        try db.execute(sql: "UPDATE draft SET gmailDraftId = 'r-9', gmailMessageId = 'd1' WHERE id = ?", arguments: [synced.draft.id])
    }
    let attachment = try await store.addData(Data("png".utf8), filename: "paste.png", to: synced.draft.id)
    #expect(FileManager.default.fileExists(atPath: attachment.path))
    #expect(attachment.mimeType == "image/png")
    #expect(try await store.discard(synced.draft.id))
    let queued = try ops(store)
    #expect(queued.map(\.kind) == [.deleteDraft])
    #expect(try payload(queued[0]) == DraftOpPayload(draftId: synced.draft.id, gmailDraftId: "r-9"))
    #expect(!FileManager.default.fileExists(atPath: attachment.path))
    // The local DRAFT message is gone too, so the thread no longer shows a draft.
    let detail = try MailStore(store.database).threadDetail(thread)
    #expect(detail?.messages.map(\.id) == ["m1"])
    #expect(detail?.thread.hasDraft == false)
}

@Test func addingFilesCopiesWithUniqueNames() async throws {
    let store = try makeStore()
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("tern-src-\(UUID().uuidString).pdf")
    try Data(repeating: 1, count: 2_048).write(to: source)
    let first = try await store.addFile(source, to: "d")
    let second = try await store.addFile(source, to: "d")
    #expect(first.size == 2_048)
    #expect(first.mimeType == "application/pdf")
    #expect(first.path != second.path)
    #expect(second.filename.hasSuffix(" 2.pdf"))
    try? FileManager.default.removeItem(at: source)
    try? FileManager.default.removeItem(at: store.filesDirectory)
}

@Test func importsGmailDraftMessages() async throws {
    let store = try makeStore()
    let imported = try #require(try store.importDraftMessage(MessageKey(accountId: home.id, messageId: "d1")))
    #expect(imported.draft.gmailMessageId == "d1")
    #expect(imported.body.plainText == "Started this")
    #expect(imported.draft.toList == [maya])
    #expect(imported.draft.subject == "Re: Lisbon offsite")
    try await store.save(typed(imported, "Edited"), now: t0)
    let again = try #require(try store.importDraftMessage(MessageKey(accountId: home.id, messageId: "d1")))
    #expect(again.draft.id == imported.draft.id)
    #expect(again.body.plainText == "Edited")
}

@Test func importingAGmailDraftKeepsItsFiles() async throws {
    let store = try makeStore()
    try await store.database.writer.write { db in
        try MailStore.upsertMessages(db, [
            MailMessage(accountId: home.id, id: "d2", threadId: "t2", date: Date(timeIntervalSince1970: 300),
                        fromEmail: home.email, toList: [maya], subject: "Deck", snippet: "See the deck",
                        bodyText: "See the deck", bodyHtml: #"<div>See the deck</div><img src="cid:fig">"#,
                        bodyState: .full, labelIds: ["DRAFT"], hasAttachments: true),
        ], attachments: [
            MailAttachment(accountId: home.id, messageId: "d2", partId: "1", attachmentId: "att-d",
                           filename: "Deck.pdf", mimeType: "application/pdf", size: 4_000, localPath: "/tmp/cached-deck.pdf"),
            MailAttachment(accountId: home.id, messageId: "d2", partId: "2", attachmentId: "att-f",
                           filename: "fig.png", mimeType: "image/png", size: 300, contentId: "fig", isInline: true),
        ])
    }
    let imported = try #require(try store.importDraftMessage(MessageKey(accountId: home.id, messageId: "d2")))
    #expect(imported.draft.attachments == [
        DraftAttachment(path: "/tmp/cached-deck.pdf", filename: "Deck.pdf", mimeType: "application/pdf", size: 4_000,
                        remote: RemoteAttachmentRef(accountId: home.id, messageId: "d2", partId: "1", attachmentId: "att-d")),
        DraftAttachment(path: "", filename: "fig.png", mimeType: "image/png", size: 300,
                        remote: RemoteAttachmentRef(accountId: home.id, messageId: "d2", partId: "2", attachmentId: "att-f"),
                        contentId: "fig"),
    ])
    try await store.save(typed(imported, "Updated"), now: t0)
    let saved = try #require(try store.draft(id: imported.draft.id))
    #expect(saved.attachments == imported.draft.attachments, "a save keeps them")
}

@Test func aGmailDraftStoredWithoutItsBodyIsNotImported() throws {
    let store = try makeStore()
    try store.database.writer.write { db in
        try MailStore.upsertMessages(db, [
            MailMessage(accountId: home.id, id: "d3", threadId: "t3", date: Date(timeIntervalSince1970: 400),
                        fromEmail: home.email, toList: [maya], subject: "Long draft", snippet: "The first line only",
                        labelIds: ["DRAFT"], hasAttachments: true),
        ])
    }
    #expect(throws: DraftError.bodyNotFetched(ThreadKey(accountId: home.id, threadId: "t3"))) {
        try store.importDraftMessage(MessageKey(accountId: home.id, messageId: "d3"))
    }
}
