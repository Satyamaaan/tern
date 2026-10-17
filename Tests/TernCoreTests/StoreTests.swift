import Foundation
import GRDB
import Testing
@testable import TernCore

private let account = Account(email: "me@example.com")

private func message(_ id: String, thread: String, date: Double, from: String = "ann@example.com",
                     labels: [String], subject: String = "Hello", body: String = "Body") -> MailMessage {
    MailMessage(
        accountId: account.id, id: id, threadId: thread, date: Date(timeIntervalSince1970: date),
        fromName: from == account.email ? "Me" : "Ann", fromEmail: from,
        toList: [Participant(email: from == account.email ? "ann@example.com" : account.email)],
        subject: subject, snippet: body, bodyText: body, bodyState: .full, labelIds: labels,
        isFromMe: from == account.email)
}

private func makeStore() throws -> MailStore {
    let store = MailStore(try AppDatabase.inMemory())
    try store.upsertAccount(account)
    return store
}

@Test func threadsAreDerivedFromMessages() throws {
    let store = try makeStore()
    try store.upsertMessages([
        message("m1", thread: "t1", date: 100, labels: ["INBOX", "UNREAD"]),
        message("m2", thread: "t1", date: 200, from: account.email, labels: ["SENT"], subject: "Re: Hello"),
    ])
    let rows = try store.threadRows(in: .unifiedInbox)
    #expect(rows.count == 1)
    let thread = try #require(rows.first).thread
    #expect(thread.subject == "Hello")
    #expect(thread.messageCount == 2)
    #expect(thread.unreadCount == 1)
    #expect(thread.lastDate == Date(timeIntervalSince1970: 200))
    #expect(thread.lastInboundDate == Date(timeIntervalSince1970: 100))
    #expect(thread.participants.map(\.email) == ["ann@example.com", account.email])
    #expect(try store.threadRows(in: Mailbox(.sent)).count == 1)
}

@Test func metadataUpsertKeepsStoredBody() throws {
    let store = try makeStore()
    try store.upsertMessages([message("m1", thread: "t1", date: 100, labels: ["INBOX"], body: "Full body")])
    var metadata = message("m1", thread: "t1", date: 100, labels: ["INBOX"], body: "")
    metadata.bodyText = nil
    metadata.bodyState = .metadata
    try store.upsertMessages([metadata])
    let detail = try #require(try store.threadDetail(ThreadKey(accountId: account.id, threadId: "t1")))
    #expect(detail.messages.first?.bodyText == "Full body")
}

@Test func archiveAppliesLocallyQueuesAndUndoes() throws {
    let store = try makeStore()
    try store.upsertMessages([
        message("m1", thread: "t1", date: 100, labels: ["INBOX", "UNREAD"]),
        message("m2", thread: "t1", date: 200, labels: ["INBOX"]),
    ])
    let key = ThreadKey(accountId: account.id, threadId: "t1")
    let token = try store.perform(.archive, on: [key])
    #expect(try store.threadRows(in: .unifiedInbox).isEmpty)
    let ops = try store.database.reader.read { db in try PendingOp.fetchAll(db) }
    #expect(ops.count == 1)
    let payload = try JSONDecoder().decode(LabelOpPayload.self, from: Data(ops[0].payload.utf8))
    #expect(Set(payload.changes.map(\.messageId)) == ["m1", "m2"])
    #expect(payload.changes.allSatisfy { $0.remove == ["INBOX"] && $0.add.isEmpty })

    try store.undo(token)
    #expect(try store.threadRows(in: .unifiedInbox).count == 1)
    #expect(try store.database.reader.read { db in try PendingOp.fetchCount(db) } == 0)
}

@Test func undoAfterSyncQueuesInverse() throws {
    let store = try makeStore()
    try store.upsertMessages([message("m1", thread: "t1", date: 100, labels: ["INBOX", "UNREAD"])])
    let key = ThreadKey(accountId: account.id, threadId: "t1")
    let token = try store.perform(.markRead, on: [key])
    try store.database.writer.write { db in try db.execute(sql: "UPDATE pending_op SET state = 'inflight'") }
    try store.undo(token)
    let ops = try store.database.reader.read { db in try PendingOp.order(Column("id")).fetchAll(db) }
    #expect(ops.count == 2)
    let inverse = try JSONDecoder().decode(LabelOpPayload.self, from: Data(ops[1].payload.utf8))
    #expect(inverse.changes == [LabelChange(messageId: "m1", add: ["UNREAD"], remove: [])])
}

@Test func snoozeLeavesInboxAndWakesUnread() throws {
    let store = try makeStore()
    try store.upsertMessages([message("m1", thread: "t1", date: 100, labels: ["INBOX"])])
    let key = ThreadKey(accountId: account.id, threadId: "t1")
    try store.perform(.snooze(until: Date(timeIntervalSince1970: 1_000)), on: [key])
    #expect(try store.threadRows(in: .unifiedInbox).isEmpty)
    #expect(try store.threadRows(in: Mailbox(.snoozed)).count == 1)
    let woken = try store.wakeSnoozed(now: Date(timeIntervalSince1970: 2_000))
    #expect(woken == [key])
    let row = try #require(try store.threadRows(in: .unifiedInbox).first)
    #expect(row.thread.unreadCount == 1)
    #expect(row.snoozedUntil == nil)
}

@Test func searchFindsPrefixAndSkipsDeleted() throws {
    let store = try makeStore()
    try store.upsertMessages([
        message("m1", thread: "t1", date: 100, labels: ["INBOX"], subject: "Lisbon flights", body: "Gate B12"),
        message("m2", thread: "t2", date: 200, labels: ["INBOX"], subject: "Lunch", body: "Tacos"),
    ])
    let search = SearchService(store.database)
    #expect(try search.search("lisb").map(\.thread.id) == ["t1"])
    #expect(try search.search("tacos").map(\.thread.id) == ["t2"])
    try store.deleteMessages(accountId: account.id, ids: ["m1"])
    #expect(try search.search("lisb").isEmpty)
    #expect(try store.threadRows(in: .unifiedInbox).map(\.thread.id) == ["t2"])
}

@Test func fakeMailboxPopulatesQuickly() throws {
    let database = try AppDatabase.inMemory()
    let summary = try FakeMailbox.populate(database, options: .init(messages: 3_000))
    #expect(summary.messages >= 3_000)
    let store = MailStore(database)
    #expect(try !store.threadRows(in: .unifiedInbox).isEmpty)
    #expect(try store.sidebarCounts().totalInboxUnread > 0)
    #expect(try !SearchService(database).search("roadmap").isEmpty)
}
