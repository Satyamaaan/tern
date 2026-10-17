import Foundation
import GRDB
import Testing
@testable import TernCore

private let me = Account(email: "me@example.com")

private func inboxMessage(_ id: String, date: Double, unread: Bool = true) -> MailMessage {
    MailMessage(
        accountId: me.id, id: id, threadId: id, date: Date(timeIntervalSince1970: date),
        fromName: "Ann", fromEmail: "ann@example.com", subject: id, snippet: id,
        labelIds: unread ? ["INBOX", "UNREAD"] : ["INBOX"])
}

private func seededStore() throws -> MailStore {
    let store = MailStore(try AppDatabase.inMemory())
    try store.upsertAccount(me)
    try store.upsertMessages([
        inboxMessage("people", date: 100),
        inboxMessage("news", date: 200),
        inboxMessage("reply", date: 300, unread: false),
        inboxMessage("fresh", date: 400),
    ])
    try store.database.writer.write { db in
        try ThreadAI(accountId: me.id, threadId: "people", category: .people, messageCount: 1).insert(db)
        try ThreadAI(accountId: me.id, threadId: "news", category: .newsletter, messageCount: 1).insert(db)
        try ThreadAI(accountId: me.id, threadId: "reply", category: .notification, needsReply: true, messageCount: 1).insert(db)
    }
    return store
}

@Test func inboxFilterSplitsByCategoryAndFlag() throws {
    let store = try seededStore()
    let important = InboxFilter(categories: [.people], includeUncategorized: true, includeNeedsReply: true)
    let ids = try store.database.reader.read { db in
        try MailStore.fetchInboxRows(db, important, limit: 10).map(\.thread.id)
    }
    #expect(ids == ["fresh", "reply", "people"])

    var rest = important
    rest.needsReply = .exclude
    let restIds = try store.database.reader.read { db in try MailStore.fetchInboxRows(db, rest, limit: 10).map(\.thread.id) }
    #expect(restIds == ["fresh", "people"])

    let newsletters = InboxFilter(categories: [.newsletter])
    let newsIds = try store.database.reader.read { db in try MailStore.fetchInboxRows(db, newsletters, limit: 10).map(\.thread.id) }
    #expect(newsIds == ["news"])
}

@Test func scopeCountsMatchFilters() throws {
    let store = try seededStore()
    let counts = try store.scopeCounts(accountId: me.id)
    #expect(counts.inboxUnread == 3)
    #expect(counts.needsReply == 1)
    #expect(counts.allAccountsInboxUnread == 3)
    let important = InboxFilter(categories: [.people], includeUncategorized: true, includeNeedsReply: true)
    #expect(counts.unread(in: important) == 2)
    #expect(counts.needingAction(in: important) == 3)
    #expect(counts.unread(in: InboxFilter(categories: [.newsletter])) == 1)
}

@Test func needsReplyToggleCreatesAndRestores() throws {
    let store = try seededStore()
    let fresh = ThreadKey(accountId: me.id, threadId: "fresh")
    let people = ThreadKey(accountId: me.id, threadId: "people")
    let undo = try store.setNeedsReply(true, on: [fresh, people])
    #expect(undo.previous == [people: false])
    #expect(undo.created == [fresh])
    let manual = try store.database.reader.read { db in try ThreadAI.fetchOne(db, key: ["accountId": me.id, "threadId": "fresh"]) }
    #expect(manual?.source == "manual")
    #expect(try store.scopeCounts(accountId: nil).needsReply == 3)

    try store.restoreNeedsReply(undo)
    #expect(try store.scopeCounts(accountId: nil).needsReply == 1)
    let ai = try store.database.reader.read { db in try ThreadAI.fetchOne(db, key: ["accountId": me.id, "threadId": "fresh"]) }
    #expect(ai == nil)
}
