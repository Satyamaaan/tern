import Foundation
import GRDB
import Testing
@testable import TernCore

private let me = Account(email: "me@example.com")
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let hold: TimeInterval = 15
private let google = Participant(name: "Google AI Studio", email: "news@google.com")

private func key(_ thread: String) -> ThreadKey { ThreadKey(accountId: me.id, threadId: thread) }

/// A newsletter in the inbox with a reply drafted on the phone ("Draft to Google"), and a new message
/// drafted on the web with a file ("Subscription…"). Gmail has both drafts; Tern has no rows for them.
private func makeStore() throws -> DraftStore {
    let database = try AppDatabase.inMemory()
    try database.writer.write { db in
        try me.insert(db)
        try MailStore.upsertMessages(db, [
            MailMessage(accountId: me.id, id: "m1", threadId: "news", date: Date(timeIntervalSince1970: 100),
                        fromName: google.name, fromEmail: google.email, toList: [Participant(email: me.email)],
                        subject: "What's new in AI Studio", bodyText: "Hello", bodyState: .full, labelIds: ["INBOX", "CATEGORY_UPDATES"]),
            MailMessage(accountId: me.id, id: "d1", threadId: "news", date: Date(timeIntervalSince1970: 200),
                        fromEmail: me.email, toList: [google], subject: "Re: What's new in AI Studio", snippet: "Thanks",
                        bodyText: "Thanks", bodyHtml: "<div>Thanks</div>", bodyState: .full, labelIds: ["DRAFT"],
                        isFromMe: true, rfcMessageId: "<d1@phone.example>"),
            MailMessage(accountId: me.id, id: "d2", threadId: "solo", date: Date(timeIntervalSince1970: 300),
                        fromEmail: me.email, toList: [Participant(email: "billing@example.com")], subject: "Subscription",
                        snippet: "Please cancel", bodyText: "Please cancel", bodyState: .full, labelIds: ["DRAFT"],
                        isFromMe: true, hasAttachments: true, rfcMessageId: "<d2@web.example>"),
        ], attachments: [
            MailAttachment(accountId: me.id, messageId: "d2", partId: "1", attachmentId: "att-1", filename: "plan.pdf",
                           mimeType: "application/pdf", size: 10),
        ])
    }
    let files = FileManager.default.temporaryDirectory.appendingPathComponent("tern-discard-tests-\(UUID().uuidString)")
    return DraftStore(database, filesDirectory: files)
}

private func mail(_ store: DraftStore) -> MailStore { MailStore(store.database) }

/// The Drafts mailbox, newest first.
private func draftRows(_ store: DraftStore) throws -> [String] {
    try mail(store).threadRows(in: Mailbox(.drafts), limit: 50).map(\.thread.id)
}

private func ops(_ store: DraftStore) throws -> [PendingOp] {
    try store.database.reader.read { db in try PendingOp.order(Column("id")).fetchAll(db) }
}

private func payload(_ op: PendingOp) throws -> DraftOpPayload {
    try JSONDecoder().decode(DraftOpPayload.self, from: Data(op.payload.utf8))
}

private func message(_ store: DraftStore, _ id: String) throws -> MailMessage? {
    try store.database.reader.read { db in try MailMessage.fetchOne(db, key: ["accountId": me.id, "id": id]) }
}

/// The phone's reply opened and edited here: a local row linked to d1, with a pasted file and a save waiting.
private func linkReply(_ store: DraftStore) async throws -> Draft {
    let file = try await store.addData(Data("png".utf8), filename: "paste.png", to: "reply-1")
    let draft = Draft(
        id: "reply-1", accountId: me.id, gmailDraftId: "r-1", gmailMessageId: "d1", threadId: "news", replyToMessageId: "m1",
        kind: .reply, toList: [google], subject: "Re: What's new in AI Studio", bodyHtml: "<div>Thanks, edited</div>",
        attachments: [file], updatedAt: t0, createdAt: t0)
    try await store.database.writer.write { db in
        try draft.insert(db)
        try DraftStore.queueSave(db, draft, now: t0)
    }
    return try #require(try store.draft(id: draft.id))
}

@Test func aDraftLeavesAtOnceWhileItsGmailCopyWaitsForTheUndoWindow() async throws {
    let store = try makeStore()
    let draft = try await linkReply(store)
    let saves = try ops(store)

    let discarded = try store.discardDrafts(inThreads: [key("news")], holdFor: hold, now: t0)
    #expect(discarded.count == 1 && discarded.refused.isEmpty)
    #expect(try store.draft(id: draft.id) == nil)
    let detail = try #require(try mail(store).threadDetail(key("news")))
    #expect(detail.messages.map(\.id) == ["m1"] && !detail.thread.hasDraft, "the conversation stays, without the draft")
    #expect(Set(try message(store, "m1")?.labelIds ?? []) == ["INBOX", "CATEGORY_UPDATES"])
    #expect(try draftRows(store) == ["solo"])
    let queued = try ops(store)
    #expect(queued.map(\.kind) == [.deleteDraft], "the waiting save went with the draft; nothing touches the newsletter")
    #expect(queued.first?.notBefore == t0.addingTimeInterval(hold))
    #expect(try payload(queued[0]) == DraftOpPayload(
        draftId: draft.id, gmailDraftId: "r-1", gmailMessageId: "d1", rfcMessageId: "<d1@phone.example>"))
    #expect(FileManager.default.fileExists(atPath: draft.attachments[0].path), "files stay until Gmail's copy is deleted")

    #expect(try store.restore(discarded, now: t0.addingTimeInterval(3)))
    #expect(try store.draft(id: draft.id) == draft)
    #expect(try mail(store).threadDetail(key("news"))?.messages.map(\.id) == ["m1", "d1"])
    #expect(try draftRows(store) == ["solo", "news"])
    let restored = try ops(store)
    #expect(restored.map(\.kind) == [.saveDraft], "the deletion is cancelled and the save comes back")
    #expect(restored.map(\.payload) == saves.map(\.payload) && restored.map(\.notBefore) == saves.map(\.notBefore))
}

@Test func aGmailDraftTernHasNoRowForCanBeDiscardedAndBroughtBack() throws {
    let store = try makeStore()
    try store.database.writer.write { db in
        try Project(id: "p1", name: "Admin", createdAt: t0).insert(db)
        try ThreadProject(accountId: me.id, threadId: "solo", projectId: "p1", source: .manual).insert(db)
        try ThreadAI(accountId: me.id, threadId: "solo", category: .other, messageCount: 1, classifiedAt: t0).insert(db)
    }

    let discarded = try store.discardDrafts(inThreads: [key("solo")], holdFor: hold, now: t0)
    #expect(discarded.count == 1)
    #expect(try draftRows(store) == ["news"])
    #expect(try mail(store).threadDetail(key("solo")) == nil, "a thread of nothing but the draft goes with it")
    let queued = try ops(store)
    #expect(queued.map(\.kind) == [.deleteDraft] && queued.first?.notBefore == t0.addingTimeInterval(hold))
    #expect(try payload(queued[0]) == DraftOpPayload(
        draftId: DraftStore.gmailDraftPrefix + "d2", gmailMessageId: "d2", rfcMessageId: "<d2@web.example>"))

    #expect(try store.restore(discarded))
    let detail = try #require(try mail(store).threadDetail(key("solo")))
    #expect(detail.messages.map(\.id) == ["d2"] && detail.attachments["d2"]?.map(\.filename) == ["plan.pdf"])
    #expect(detail.projects.map(\.id) == ["p1"] && detail.ai?.category == .other)
    #expect(try ops(store).isEmpty)
    #expect(try draftRows(store) == ["solo", "news"])
}

@Test func discardingSeveralRowsTakesEachOfTheirDraftsOnce() throws {
    let store = try makeStore()
    let local = Draft(id: "local-1", accountId: me.id, toList: [google], subject: "Note", bodyHtml: "<p>Hi</p>",
                      updatedAt: t0, createdAt: t0)
    try store.database.writer.write { db in try local.insert(db) }
    let localRow = ThreadKey(accountId: me.id, threadId: MailThread.localDraftPrefix + local.id)
    #expect(Set(try draftRows(store)) == [localRow.threadId, "news", "solo"])

    let discarded = try store.discardDrafts(inThreads: [localRow, key("news"), key("solo"), localRow], holdFor: hold, now: t0)
    #expect(discarded.count == 3)
    #expect(try draftRows(store).isEmpty)
    #expect(try ops(store).map(\.kind) == [.deleteDraft, .deleteDraft, .deleteDraft])
    #expect(try payload(ops(store)[0]) == DraftOpPayload(draftId: local.id), "a draft Gmail never had leaves only its files to clean up")
    #expect(try mail(store).threadRows(in: .unifiedInbox).map(\.thread.id) == ["news"])

    #expect(try store.restore(discarded))
    #expect(Set(try draftRows(store)) == [localRow.threadId, "news", "solo"])
    #expect(try store.draft(id: local.id) == local)
    #expect(try ops(store).isEmpty)
}

@Test func aDraftBeingSentIsNeverDiscarded() throws {
    let store = try makeStore()
    func add(_ id: String, state: Draft.State, send: PendingOp.State? = nil, staged: Bool = false) throws {
        try store.database.writer.write { db in
            try Draft(id: id, accountId: me.id, subject: id, bodyHtml: "<p>\(id)</p>", state: state, updatedAt: t0, createdAt: t0).insert(db)
            guard let send else { return }
            let payload = DraftOpPayload(draftId: id, sendingDraftId: staged ? "r-\(id)" : nil)
            try PendingOp(accountId: me.id, kind: .sendDraft, payload: try encodeJSON(payload), createdAt: t0,
                          notBefore: t0.addingTimeInterval(5), state: send, dispatched: staged).insert(db)
        }
    }
    try add("sending", state: .sending, send: .inflight)
    try add("claimed", state: .queued, send: .inflight)
    try add("staged", state: .queued, send: .pending, staged: true)
    try add("waiting", state: .queued, send: .pending)

    let refs = ["sending", "claimed", "staged", "waiting"].map(DraftRef.draft)
    let discarded = try store.discardDrafts(refs, holdFor: hold, now: t0)
    #expect(discarded.refused == Array(refs.prefix(3)))
    #expect(discarded.count == 1, "a send still in its undo window can be discarded")
    #expect(try store.draft(id: "sending") != nil && store.draft(id: "claimed") != nil && store.draft(id: "staged") != nil)
    #expect(try store.draft(id: "waiting") == nil)
    let sends = try ops(store).filter { $0.kind == .sendDraft }.compactMap { try? payload($0).draftId }
    #expect(sends == ["sending", "claimed", "staged"])

    #expect(try store.restore(discarded))
    #expect(try store.draft(id: "waiting")?.state == .queued)
    #expect(try ops(store).filter { $0.kind == .sendDraft }.compactMap { try? payload($0).draftId }.sorted() == ["claimed", "sending", "staged", "waiting"])
}

@Test func undoAfterTheDeletionStartedKeepsWhatItCan() async throws {
    let store = try makeStore()
    let draft = try await linkReply(store)
    try await store.database.writer.write { db in try db.execute(sql: "DELETE FROM pending_op") }
    let reply = try store.discardDrafts(inThreads: [key("news")], holdFor: hold, now: t0)
    let solo = try store.discardDrafts(inThreads: [key("solo")], holdFor: hold, now: t0)
    try await store.database.writer.write { db in try db.execute(sql: "UPDATE pending_op SET state = 'inflight', dispatched = 1") }

    // The local draft comes back without the Gmail copy that's going, and saves a new one.
    #expect(try store.restore(reply, now: t0.addingTimeInterval(20)))
    let back = try #require(try store.draft(id: draft.id))
    #expect(back.gmailDraftId == nil && back.gmailMessageId == nil && back.bodyHtml == draft.bodyHtml && back.attachments == draft.attachments)
    #expect(try message(store, "d1") == nil)
    #expect(try ops(store).map(\.kind) == [.deleteDraft, .deleteDraft, .saveDraft])

    // A Gmail draft Tern had no row for has nothing left to bring back.
    #expect(try !store.restore(solo))
    #expect(try message(store, "d2") == nil)
}

@Test func syncLeavesADiscardedDraftOutWhileItsDeletionWaits() throws {
    let store = try makeStore()
    let d2 = try #require(try message(store, "d2"))
    _ = try store.discardDrafts(inThreads: [key("solo")], holdFor: hold, now: t0)

    try store.database.writer.write { db in try MailStore.upsertServerMessages(db, [d2]) }
    #expect(try message(store, "d2") == nil)

    // Once the deletion has failed for good, Gmail still has the draft, so it shows again.
    try store.database.writer.write { db in try db.execute(sql: "UPDATE pending_op SET state = 'failed'") }
    try store.database.writer.write { db in try MailStore.upsertServerMessages(db, [d2]) }
    #expect(try message(store, "d2") != nil)
}
