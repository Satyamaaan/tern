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

@Test func inboxFilterReadsATabByItsFallback() throws {
    let store = try seededStore()
    func ids(_ tab: InboxTab?) throws -> [String] {
        try store.database.reader.read { db in try MailStore.fetchInboxRows(db, InboxFilter(tab: tab), limit: 10).map(\.thread.id) }
    }
    // No Gmail category on any of them: people and unclassified mail are in Primary, a newsletter in
    // Promotions, a notification (needs reply or not) in Updates.
    #expect(try ids(nil) == ["fresh", "reply", "news", "people"])
    #expect(try ids(.primary) == ["fresh", "people"])
    #expect(try ids(.promotions) == ["news"])
    #expect(try ids(.updates) == ["reply"])
    #expect(try ids(.social).isEmpty)
}

@Test func scopeCountsCountTabs() throws {
    let store = try seededStore()
    let counts = try store.scopeCounts(accountId: me.id)
    #expect(counts.inboxUnread == 3)
    #expect(counts.needsReply == 1)
    #expect(counts.allAccountsInboxUnread == 3)
    #expect(counts.tabThreads == [.primary: 2, .promotions: 1, .updates: 1])
    #expect(counts.tabUnread == [.primary: 2, .promotions: 1])
    #expect(try store.scopeCounts(accountId: "other@example.com").tabThreads.isEmpty)
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
