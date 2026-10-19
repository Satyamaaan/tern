import Foundation
import GRDB
import Testing
@testable import TernCore

private let me = Account(email: "me@example.com")
private let work = Account(email: "me@work.dev")

private func message(
    _ id: String, thread: String, date: Double, account: Account = me, fromMe: Bool = false, labels: [String]
) -> MailMessage {
    MailMessage(
        accountId: account.id, id: id, threadId: thread, date: Date(timeIntervalSince1970: date),
        fromName: fromMe ? "Me" : "Ann", fromEmail: fromMe ? account.email : "ann@example.com",
        toList: [Participant(email: fromMe ? "ann@example.com" : account.email)],
        subject: "Thread \(thread)", snippet: "Hi", bodyText: "Hi", bodyState: .full, labelIds: labels,
        isFromMe: fromMe)
}

private func makeStore() throws -> MailStore {
    let store = MailStore(try AppDatabase.inMemory())
    try store.upsertAccount(me)
    try store.upsertAccount(work)
    return store
}

private func key(_ thread: String, _ account: Account = me) -> ThreadKey { ThreadKey(accountId: account.id, threadId: thread) }

private func archive(_ store: MailStore, accountId: String? = nil, limit: Int = 50, before: Date? = nil) throws -> [String] {
    try store.threadRows(in: Mailbox(.archive, accountId: accountId), limit: limit, before: before).map(\.thread.id)
}

@Test func archiveListsArchivedMailSomeoneElseSent() throws {
    let store = try makeStore()
    try store.upsertMessages([
        message("a1", thread: "archived", date: 100, labels: ["CATEGORY_UPDATES"]),
        message("r1", thread: "replied", date: 200, labels: ["IMPORTANT"]),
        message("r2", thread: "replied", date: 300, fromMe: true, labels: ["SENT"]),
        message("l1", thread: "labelled", date: 400, labels: ["Label_1"]),
        message("i1", thread: "inbox", date: 500, labels: ["INBOX", "UNREAD"]),
        message("p1", thread: "spam", date: 600, labels: ["SPAM"]),
        message("x1", thread: "trash", date: 700, labels: ["TRASH"]),
        message("s1", thread: "sentOnly", date: 800, fromMe: true, labels: ["SENT"]),
        message("d1", thread: "draftOnly", date: 900, fromMe: true, labels: ["DRAFT"]),
        message("z1", thread: "snoozed", date: 1_000, labels: []),
        // One message of a thread in the inbox keeps the whole conversation there.
        message("h1", thread: "halfInbox", date: 1_100, labels: []),
        message("h2", thread: "halfInbox", date: 1_200, labels: ["INBOX"]),
        // An answer still being written doesn't take a thread out.
        message("w1", thread: "withDraft", date: 1_300, labels: []),
        message("w2", thread: "withDraft", date: 1_400, fromMe: true, labels: ["DRAFT"]),
    ])
    try store.database.writer.write { db in
        try Snooze(accountId: me.id, threadId: "snoozed", until: Date(timeIntervalSince1970: 9_999_999_999)).insert(db)
    }

    #expect(try archive(store) == ["withDraft", "labelled", "replied", "archived"], "newest first")
}

@Test func archiveListsNotesYouSentYourself() throws {
    let store = try makeStore()
    func sent(_ id: String, to: [Participant], date: Double, labels: [String] = ["SENT"]) -> MailMessage {
        MailMessage(accountId: me.id, id: id, threadId: id, date: Date(timeIntervalSince1970: date), fromName: "Me",
                    fromEmail: me.email, toList: to, subject: id, bodyText: "Milk", bodyState: .full, labelIds: labels, isFromMe: true)
    }
    try store.upsertMessages([
        sent("note", to: [Participant(name: "Me", email: me.email)], date: 100),
        sent("toWork", to: [Participant(email: "Me@Work.dev")], date: 200),
        sent("toAnn", to: [Participant(email: "ann@example.com")], date: 300),
        // An address that only contains yours isn't yours.
        sent("lookalike", to: [Participant(email: "notme@example.com")], date: 400),
        sent("noteInInbox", to: [Participant(email: me.email)], date: 500, labels: ["SENT", "INBOX"]),
        sent("draftNote", to: [Participant(email: me.email)], date: 600, labels: ["DRAFT"]),
    ])
    #expect(try archive(store) == ["toWork", "note"])
    #expect(try archive(store, accountId: me.id, before: Date(timeIntervalSince1970: 200)) == ["note"])
}

@Test func archiveFollowsTheScopeAndPages() throws {
    let store = try makeStore()
    try store.upsertMessages([
        message("m1", thread: "mine1", date: 100, labels: []),
        message("m2", thread: "mine2", date: 300, labels: []),
        message("w1", thread: "work1", date: 200, account: work, labels: []),
        message("w2", thread: "work2", date: 400, account: work, labels: ["INBOX"]),
    ])
    #expect(try archive(store) == ["mine2", "work1", "mine1"])
    #expect(try archive(store, accountId: me.id) == ["mine2", "mine1"])
    #expect(try archive(store, accountId: work.id) == ["work1"])
    #expect(try archive(store, limit: 1) == ["mine2"])
    #expect(try archive(store, before: Date(timeIntervalSince1970: 300)) == ["work1", "mine1"])
    #expect(try archive(store, accountId: me.id, before: Date(timeIntervalSince1970: 300)) == ["mine1"])
}

@Test func archiveReadsItsPagesFromIndexes() throws {
    let store = try makeStore()
    for accountId in [nil, me.id] {
        for before in [nil, Date()] {
            var sql: String?
            try store.database.writer.write { db in
                db.trace(options: .statement) { event in
                    if case .statement(let statement) = event, statement.sql.contains("lastInboundDate IS NOT NULL") { sql = statement.sql }
                }
                _ = try MailStore.fetchThreadRows(db, in: Mailbox(.archive, accountId: accountId), limit: 50, before: before)
                db.trace(options: .statement, nil)
            }
            let query = try #require(sql)
            let placeholders = query.filter { $0 == "?" }.count
            let plan = try store.database.reader.read { db in
                try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(query)",
                                 arguments: StatementArguments(Array(repeating: "x", count: placeholders))).map { $0["detail"] as String }
            }
            let index = accountId == nil ? "USING INDEX thread_by_date" : "USING INDEX thread_by_account_date (accountId=?"
            #expect(plan.first?.contains(index) == true, "\(plan)")
            #expect(!plan.contains { $0.contains("TEMP B-TREE") }, "\(plan)")
        }
    }
}

@Test func moveToInboxQueuesTheLabelAndUndoes() throws {
    let store = try makeStore()
    try store.upsertMessages([
        message("m1", thread: "t1", date: 100, labels: ["CATEGORY_UPDATES"]),
        message("m2", thread: "t1", date: 200, fromMe: true, labels: ["SENT"]),
        message("m3", thread: "t1", date: 300, fromMe: true, labels: ["DRAFT"]),
    ])
    let thread = key("t1")
    #expect(try archive(store) == ["t1"])

    let token = try store.perform(.moveToInbox, on: [thread])
    #expect(try store.threadRows(in: .unifiedInbox).map(\.id) == [thread])
    #expect(try archive(store).isEmpty)
    let ops = try store.database.reader.read { db in try PendingOp.fetchAll(db) }
    #expect(ops.count == 1 && ops[0].accountId == me.id && ops[0].kind == .modifyLabels)
    let payload = try JSONDecoder().decode(LabelOpPayload.self, from: Data(ops[0].payload.utf8))
    #expect(payload.action == "moveToInbox" && payload.threadIds == ["t1"])
    #expect(payload.changes == [
        LabelChange(messageId: "m1", add: ["INBOX"], remove: []),
        LabelChange(messageId: "m2", add: ["INBOX"], remove: []),
    ], "drafts keep their labels; nothing to take out of spam or trash")

    // Undo before sync sent it: the op is dropped and the thread is archived again.
    try store.undo(token)
    #expect(try archive(store) == ["t1"])
    #expect(try store.threadRows(in: .unifiedInbox).isEmpty)
    #expect(try store.database.reader.read { db in try PendingOp.fetchCount(db) } == 0)

    // Undo after Gmail may have seen it: the reverse goes out after it.
    let sent = try store.perform(.moveToInbox, on: [thread])
    try store.database.writer.write { db in try db.execute(sql: "UPDATE pending_op SET dispatched = 1") }
    try store.undo(sent)
    #expect(try archive(store) == ["t1"])
    let queued = try store.database.reader.read { db in try PendingOp.order(Column("id")).fetchAll(db) }
    #expect(queued.count == 2)
    let inverse = try JSONDecoder().decode(LabelOpPayload.self, from: Data(queued[1].payload.utf8))
    #expect(inverse.action == "undo-moveToInbox")
    #expect(inverse.changes == [
        LabelChange(messageId: "m1", add: [], remove: ["INBOX"]),
        LabelChange(messageId: "m2", add: [], remove: ["INBOX"]),
    ])
}
