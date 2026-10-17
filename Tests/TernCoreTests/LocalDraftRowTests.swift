import Foundation
import GRDB
import Testing
@testable import TernCore

private let home = Account(email: "me@example.com", sortOrder: 0)
private let work = Account(email: "me@work.dev", sortOrder: 1)
private let maya = Participant(name: "Maya Chen", email: "maya@lumen.io")

/// A home account with thread t1: Maya's message and a draft reply written in Gmail (d1).
private func makeStore() throws -> MailStore {
    let database = try AppDatabase.inMemory()
    try database.writer.write { db in
        try home.insert(db)
        try work.insert(db)
        try MailStore.upsertMessages(db, [
            MailMessage(accountId: home.id, id: "m1", threadId: "t1", date: Date(timeIntervalSince1970: 100),
                        fromName: maya.name, fromEmail: maya.email, toList: [Participant(email: home.email)],
                        subject: "Lisbon offsite", bodyText: "Can you make it?", bodyState: .full, labelIds: ["INBOX"]),
            MailMessage(accountId: home.id, id: "d1", threadId: "t1", date: Date(timeIntervalSince1970: 200),
                        fromEmail: home.email, toList: [maya], subject: "Re: Lisbon offsite", snippet: "Started this",
                        bodyText: "Started this", bodyState: .full, labelIds: ["DRAFT"]),
        ], attachments: [])
    }
    return MailStore(database)
}

private func insert(_ store: MailStore, _ drafts: [Draft]) throws {
    try store.database.writer.write { db in for draft in drafts { try draft.insert(db) } }
}

private func local(_ draft: Draft) -> ThreadKey {
    ThreadKey(accountId: draft.accountId, threadId: MailThread.localDraftPrefix + draft.id)
}

@Test func draftsListsEveryUnsentDraftGmailHasNoCopyOf() throws {
    let store = try makeStore()
    let unsaved = Draft(accountId: home.id, toList: [maya], subject: "Dinner", bodyHtml: "<p>Friday at <b>eight</b>?</p>",
                        updatedAt: Date(timeIntervalSince1970: 500))
    let failed = Draft(accountId: home.id, gmailDraftId: "r9", gmailMessageId: "gone", toList: [maya], subject: "Budget",
                       bodyHtml: "<p>Numbers</p>", state: .failed, lastError: "Network", updatedAt: Date(timeIntervalSince1970: 400))
    let scheduled = Draft(accountId: work.id, subject: "Standup", scheduledAt: Date(timeIntervalSince1970: 9_000), state: .queued,
                          updatedAt: Date(timeIntervalSince1970: 300))
    let linked = Draft(accountId: home.id, gmailMessageId: "d1", threadId: "t1", kind: .reply, subject: "Re: Lisbon offsite",
                       updatedAt: Date(timeIntervalSince1970: 600))
    let sending = Draft(accountId: home.id, subject: "Out the door", state: .sending, updatedAt: Date(timeIntervalSince1970: 700))
    try insert(store, [unsaved, failed, scheduled, linked, sending])
    let thread = ThreadKey(accountId: home.id, threadId: "t1")

    #expect(try store.threadRows(in: Mailbox(.drafts)).map(\.id) == [local(unsaved), local(failed), local(scheduled), thread],
            "newest first; a draft Gmail has a copy of is listed by its thread, one being sent not at all")
    #expect(try store.threadRows(in: Mailbox(.drafts, accountId: home.id)).map(\.id) == [local(unsaved), local(failed), thread])
    #expect(try store.threadRows(in: Mailbox(.drafts), limit: 2).map(\.id) == [local(unsaved), local(failed)])
    #expect(try store.threadRows(in: Mailbox(.drafts), before: Date(timeIntervalSince1970: 450)).map(\.id) == [local(failed), local(scheduled), thread])
    #expect(try store.scopeCounts(accountId: nil).drafts == 4)
    #expect(try store.scopeCounts(accountId: home.id).drafts == 3)
    #expect(try store.threadRows(in: Mailbox(.inbox)).map(\.id) == [thread], "only Drafts lists them")

    let row = try #require(try store.threadRows(in: Mailbox(.drafts)).first)
    #expect(MailThread.localDraftId(in: row.id) == unsaved.id)
    #expect(MailThread.localDraftId(in: thread) == nil)
    #expect(row.thread.subject == "Dinner" && row.thread.snippet == "Friday at eight?")
    #expect(row.thread.hasDraft && row.thread.unreadCount == 0 && row.thread.participants.last == maya)
    #expect(row.thread.lastDate == unsaved.updatedAt)
}

@Test func findsTheGmailDraftToOpenInAThread() async throws {
    let store = try makeStore()
    let drafts = DraftStore(store.database, filesDirectory: FileManager.default.temporaryDirectory)
    let thread = ThreadKey(accountId: home.id, threadId: "t1")
    let d1 = MessageKey(accountId: home.id, messageId: "d1")
    #expect(try drafts.draftMessage(inThread: thread) == d1)
    #expect(try drafts.gmailReplyDraft(inThread: thread) == d1, "r continues a draft written in Gmail")
    #expect(try drafts.gmailReplyDraft(inThread: ThreadKey(accountId: work.id, threadId: "t1")) == nil)

    var reply = Draft(accountId: home.id, threadId: "t1", replyToMessageId: "m1", kind: .reply, toList: [maya], subject: "Re: Lisbon offsite")
    try insert(store, [reply])
    #expect(try drafts.gmailReplyDraft(inThread: thread) == nil, "the reply being written here comes first")

    reply.gmailMessageId = "d1"
    reply.state = .sent
    try await store.database.writer.write { db in try reply.update(db) }
    #expect(try drafts.gmailReplyDraft(inThread: thread) == nil, "a draft Tern wrote isn't one written in Gmail")
    #expect(try drafts.draftMessage(inThread: thread) == d1, "the Drafts mailbox opens it either way")
}
