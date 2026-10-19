import Foundation
import GRDB
import Testing
@testable import TernCore

// Gmail's inbox tabs: which tab a thread is in (its Gmail category, else Tern's), the tab lists and counts,
// Move to tab with its undo, and `tabs-1` filling in the tabs of mail stored before it.

private let me = Account(email: "me@example.com")

private func message(
    _ id: String, thread: String, at date: Double, labels: [String], fromMe: Bool = false
) -> MailMessage {
    MailMessage(
        accountId: me.id, id: id, threadId: thread, date: Date(timeIntervalSince1970: date),
        fromName: fromMe ? "Me" : "Ann", fromEmail: fromMe ? me.email : "ann@example.com", subject: thread, snippet: thread,
        labelIds: labels, isFromMe: fromMe)
}

private func store(_ messages: [MailMessage], ai: [String: MailCategory] = [:]) throws -> MailStore {
    let store = MailStore(try AppDatabase.inMemory())
    try store.upsertAccount(me)
    try store.upsertMessages(messages)
    try store.database.writer.write { db in
        for (thread, category) in ai {
            try ThreadAI(accountId: me.id, threadId: thread, category: category, messageCount: 1).insert(db)
        }
    }
    return store
}

private func thread(_ store: MailStore, _ id: String) throws -> MailThread? {
    try store.database.reader.read { db in try MailThread.fetchOne(db, key: ["accountId": me.id, "id": id]) }
}

private func key(_ id: String) -> ThreadKey { ThreadKey(accountId: me.id, threadId: id) }

// MARK: The rule

@Test func eachCategoryLabelNamesItsTab() {
    for tab in InboxTab.allCases {
        #expect(InboxTab.gmailTab([([SystemLabel.inbox, tab.labelId], false)]) == tab)
        #expect(InboxTab(labelId: tab.labelId) == tab)
    }
    #expect(InboxTab.gmailTab([([SystemLabel.inbox, SystemLabel.unread], false)]) == nil)
    #expect(InboxTab.gmailTab([]) == nil)
}

@Test func theNewestMessageFromSomeoneElseDecides() {
    // A newsletter someone answered personally: their reply is the newest inbound message.
    #expect(InboxTab.gmailTab([
        ([SystemLabel.categoryPromotions], false), ([SystemLabel.categoryPersonal], false), ([SystemLabel.sent], true),
    ]) == .primary)
    #expect(InboxTab.gmailTab([([SystemLabel.categoryPersonal], false), ([SystemLabel.categoryPromotions], false)]) == .promotions)
    // Your own newer message doesn't outvote theirs.
    #expect(InboxTab.gmailTab([([SystemLabel.categoryUpdates], false), ([SystemLabel.categoryPersonal], true)]) == .updates)
    // An inbound message without a category is passed over for an older one that has one.
    #expect(InboxTab.gmailTab([([SystemLabel.categorySocial], false), ([SystemLabel.inbox], false)]) == .social)
}

@Test func yourOwnMessagesCountWhenNothingInboundIsCategorised() {
    #expect(InboxTab.gmailTab([([SystemLabel.inbox], false), ([SystemLabel.categoryForums], true)]) == .forums)
}

@Test func aMessageWithSeveralCategoriesIsInTheFirstTab() {
    #expect(InboxTab.gmailTab([([SystemLabel.categoryUpdates, SystemLabel.categorySocial], false)]) == .social)
    #expect(InboxTab.gmailTab([([SystemLabel.categoryForums, SystemLabel.categoryPersonal], false)]) == .primary)
}

@Test func threadsGmailHasntCategorisedFallBackToTernsCategory() {
    let expected: [MailCategory: InboxTab] = [
        .people: .primary, .calendar: .primary, .security: .primary, .other: .primary,
        .promotion: .promotions, .newsletter: .promotions, .notification: .updates, .receipt: .updates,
    ]
    for category in MailCategory.allCases { #expect(InboxTab(fallback: category) == expected[category], "\(category)") }
    #expect(InboxTab(fallback: nil) == .primary)
    #expect(InboxTab.social.fallbackCategories.isEmpty && InboxTab.forums.fallbackCategories.isEmpty)
}

// MARK: The store

@Test func refreshingAThreadKeepsItsTabOnTheThreadAndItsLabelRows() throws {
    let store = try store([
        message("a1", thread: "a", at: 100, labels: [SystemLabel.inbox, SystemLabel.categoryPromotions]),
        message("a2", thread: "a", at: 200, labels: [SystemLabel.sent], fromMe: true),
        message("a3", thread: "a", at: 300, labels: [SystemLabel.draft, SystemLabel.categorySocial], fromMe: true),
    ])
    #expect(try thread(store, "a")?.gmailTab == .promotions)
    let rows = try store.database.reader.read { db in
        try String?.fetchAll(db, sql: "SELECT gmailTab FROM thread_label WHERE accountId = ? AND threadId = 'a'", arguments: [me.id])
    }
    #expect(!rows.isEmpty && rows.allSatisfy { $0 == "promotions" })

    // A label change from Gmail (history) files it again.
    try store.setLabels(accountId: me.id, ["a1": [SystemLabel.inbox, SystemLabel.categoryUpdates]])
    #expect(try thread(store, "a")?.gmailTab == .updates)
    try store.setLabels(accountId: me.id, ["a1": [SystemLabel.inbox]])
    #expect(try thread(store, "a")?.gmailTab == nil)
}

/// Gmail's category wins over Tern's; without one, Tern's decides; unclassified mail is in Primary.
private func tabbedStore() throws -> MailStore {
    var messages: [MailMessage] = []
    func add(_ id: String, _ date: Double, _ labels: [String]) {
        messages.append(message(id, thread: id, at: date, labels: [SystemLabel.inbox] + labels))
    }
    add("gmailPromo", 100, [SystemLabel.categoryPromotions, SystemLabel.unread])
    add("gmailPersonal", 200, [SystemLabel.categoryPersonal])
    add("social", 300, [SystemLabel.categorySocial, SystemLabel.unread])
    add("forum", 400, [SystemLabel.categoryForums])
    add("plainNews", 500, [SystemLabel.unread])
    add("plainNote", 600, [])
    add("unclassified", 700, [SystemLabel.unread])
    messages.append(message("archived", thread: "archived", at: 800, labels: [SystemLabel.categorySocial]))
    return try store(messages, ai: [
        "gmailPromo": .people, "gmailPersonal": .newsletter, "forum": .newsletter, "plainNews": .newsletter, "plainNote": .receipt,
    ])
}

@Test func eachTabListsItsThreadsNewestFirst() throws {
    let store = try tabbedStore()
    func ids(_ tab: InboxTab?, account: String? = nil) throws -> [String] {
        try store.database.reader.read { db in
            try MailStore.fetchInboxRows(db, InboxFilter(accountId: account, tab: tab), limit: 50).map(\.thread.id)
        }
    }
    #expect(try ids(.primary) == ["unclassified", "gmailPersonal"])
    #expect(try ids(.promotions) == ["plainNews", "gmailPromo"])
    #expect(try ids(.social) == ["social"])
    #expect(try ids(.updates) == ["plainNote"])
    #expect(try ids(.forums) == ["forum"])
    #expect(try ids(nil).count == 7)
    #expect(try ids(.social, account: me.id) == ["social"])
    #expect(try ids(.social, account: "other@example.com").isEmpty)

    let rows = try store.database.reader.read { db in try MailStore.fetchInboxRows(db, InboxFilter(), limit: 50) }
    for row in rows {
        let listed = try ids(row.inboxTab)
        #expect(listed.contains(row.thread.id), "\(row.thread.id) is in \(row.inboxTab)")
    }
}

@Test func countsGiveEachTabItsThreadsAndUnread() throws {
    let counts = try tabbedStore().scopeCounts(accountId: nil)
    #expect(counts.tabThreads == [.primary: 2, .promotions: 2, .social: 1, .updates: 1, .forums: 1])
    #expect(counts.tabUnread == [.primary: 1, .promotions: 2, .social: 1])
    #expect(counts.inboxUnread == 4)
}

// MARK: Move to tab

@Test func moveToTabSwapsTheCategoryLabelsAndUndoPutsThemBack() throws {
    let store = try store([
        message("p1", thread: "p", at: 100, labels: [SystemLabel.inbox, SystemLabel.categoryPromotions, SystemLabel.unread]),
        message("p2", thread: "p", at: 200, labels: [SystemLabel.sent], fromMe: true),
        message("p3", thread: "p", at: 300, labels: [SystemLabel.draft], fromMe: true),
    ])
    let token = try store.perform(.moveToTab(.primary), on: [key("p")])
    #expect(try thread(store, "p")?.gmailTab == .primary)

    let ops = try store.database.reader.read { db in try PendingOp.fetchAll(db) }
    try #require(ops.count == 1)
    let payload = try JSONDecoder().decode(LabelOpPayload.self, from: Data(ops[0].payload.utf8))
    #expect(payload.action == "moveToTab" && payload.threadIds == ["p"])
    // Here only the label the message had comes off; Gmail is asked to take off every other category. Drafts are
    // left alone, like every label action.
    let others = [SystemLabel.categoryPromotions, SystemLabel.categorySocial, SystemLabel.categoryUpdates, SystemLabel.categoryForums]
    #expect(Set(payload.changes) == [
        LabelChange(messageId: "p1", add: [SystemLabel.categoryPersonal], remove: [SystemLabel.categoryPromotions],
                    intentAdd: [SystemLabel.categoryPersonal], intentRemove: others),
        LabelChange(messageId: "p2", add: [SystemLabel.categoryPersonal], remove: [],
                    intentAdd: [SystemLabel.categoryPersonal], intentRemove: others),
    ])
    let primary = try store.database.reader.read { db in
        try MailStore.fetchInboxRows(db, InboxFilter(tab: .primary), limit: 10).map(\.thread.id)
    }
    #expect(primary == ["p"])

    // Not sent yet: undo drops the op and restores the labels exactly.
    try store.undo(token)
    #expect(try store.database.reader.read { db in try PendingOp.fetchCount(db) } == 0)
    #expect(try thread(store, "p")?.gmailTab == .promotions)
    let labels = try store.database.reader.read { db in try MailStore.messageLabels(db, accountId: me.id, messageIds: ["p1", "p2"]) }
    #expect(Set(labels["p1"] ?? []) == [SystemLabel.inbox, SystemLabel.categoryPromotions, SystemLabel.unread])
    #expect(labels["p2"] == [SystemLabel.sent])
}

@Test func undoingAMoveGmailMayHaveSeenQueuesTheReverse() throws {
    let store = try store([message("s1", thread: "s", at: 100, labels: [SystemLabel.inbox, SystemLabel.categorySocial])])
    let token = try store.perform(.moveToTab(.forums), on: [key("s")])
    try store.database.writer.write { db in try db.execute(sql: "UPDATE pending_op SET dispatched = 1") }
    try store.undo(token)
    let ops = try store.database.reader.read { db in try PendingOp.order(Column("id")).fetchAll(db) }
    try #require(ops.count == 2)
    let reverse = try JSONDecoder().decode(LabelOpPayload.self, from: Data(ops[1].payload.utf8))
    #expect(reverse.action == "undo-moveToTab")
    #expect(reverse.changes == [LabelChange(messageId: "s1", add: [SystemLabel.categorySocial], remove: [SystemLabel.categoryForums])])
    #expect(try thread(store, "s")?.gmailTab == .social)
}

// A move Gmail hasn't confirmed yet, while Gmail files the message under another category (history brings it in
// before the op is sent): the move holds here and in what is sent, and undo puts back what Gmail has.

private func labels(_ store: MailStore, _ id: String) throws -> Set<String> {
    Set(try store.database.reader.read { db in try MailStore.messageLabels(db, accountId: me.id, messageIds: [id]) }[id] ?? [])
}

private func onlyOp(_ store: MailStore) throws -> LabelOpPayload {
    let ops = try store.database.reader.read { db in try PendingOp.fetchAll(db) }
    try #require(ops.count == 1)
    return try JSONDecoder().decode(LabelOpPayload.self, from: Data(ops[0].payload.utf8))
}

private func fromGmail(_ store: MailStore, _ labels: [String: [String]]) throws {
    try store.database.writer.write { db in try MailStore.applyServerLabels(db, accountId: me.id, labels) }
}

@Test func aCategoryGmailAddsBeforeTheMoveIsSentDoesNotUndoIt() throws {
    let store = try store([message("m1", thread: "m", at: 100, labels: [SystemLabel.inbox, SystemLabel.categoryPromotions])])
    let token = try store.perform(.moveToTab(.forums), on: [key("m")])

    // Gmail adds Primary's category on top of Promotions.
    try fromGmail(store, ["m1": [SystemLabel.inbox, SystemLabel.categoryPromotions, SystemLabel.categoryPersonal]])
    #expect(try labels(store, "m1") == [SystemLabel.inbox, SystemLabel.categoryForums])
    #expect(try thread(store, "m")?.gmailTab == .forums)
    let change = try #require(try onlyOp(store).changes.first)
    #expect(Set(change.requestRemove).isSuperset(of: [SystemLabel.categoryPromotions, SystemLabel.categoryPersonal]))
    // What the move now changes on Gmail's labels, for undo.
    #expect(Set(change.remove) == [SystemLabel.categoryPromotions, SystemLabel.categoryPersonal] && change.add == [SystemLabel.categoryForums])

    // The same labels again, and the echo of the move once Gmail has made it, leave that record alone.
    try fromGmail(store, ["m1": [SystemLabel.inbox, SystemLabel.categoryPromotions, SystemLabel.categoryPersonal]])
    try fromGmail(store, ["m1": [SystemLabel.inbox, SystemLabel.categoryForums]])
    #expect(try onlyOp(store).changes.first == change)

    // Not sent: undo drops the op and leaves the labels Gmail has.
    try store.undo(token)
    #expect(try store.database.reader.read { db in try PendingOp.fetchCount(db) } == 0)
    #expect(try labels(store, "m1") == [SystemLabel.inbox, SystemLabel.categoryPromotions, SystemLabel.categoryPersonal])
}

@Test func undoAfterGmailRefiledTheMessageMeanwhilePutsBackGmailsCategory() throws {
    let store = try store([message("m1", thread: "m", at: 100, labels: [SystemLabel.inbox, SystemLabel.categoryPromotions])])
    let token = try store.perform(.moveToTab(.forums), on: [key("m")])
    // Gmail moves it from Promotions to Primary, and the op has been sent since.
    try fromGmail(store, ["m1": [SystemLabel.inbox, SystemLabel.categoryPersonal]])
    #expect(try thread(store, "m")?.gmailTab == .forums)
    try store.database.writer.write { db in try db.execute(sql: "UPDATE pending_op SET dispatched = 1") }

    try store.undo(token)
    let ops = try store.database.reader.read { db in try PendingOp.order(Column("id")).fetchAll(db) }
    try #require(ops.count == 2)
    let reverse = try JSONDecoder().decode(LabelOpPayload.self, from: Data(ops[1].payload.utf8))
    #expect(reverse.changes == [LabelChange(messageId: "m1", add: [SystemLabel.categoryPersonal], remove: [SystemLabel.categoryForums])])
    #expect(try labels(store, "m1") == [SystemLabel.inbox, SystemLabel.categoryPersonal])
}

@Test func theThreadsOtherMessagesKeepTheMoveToo() throws {
    // m2, the newest, is in Forums already; m1 isn't. Gmail then files m2 under Primary too.
    let store = try store([
        message("m1", thread: "m", at: 100, labels: [SystemLabel.inbox, SystemLabel.categoryPromotions]),
        message("m2", thread: "m", at: 200, labels: [SystemLabel.inbox, SystemLabel.categoryForums]),
    ])
    _ = try store.perform(.moveToTab(.forums), on: [key("m")])
    let payload = try onlyOp(store)
    #expect(payload.changes.map(\.messageId).sorted() == ["m1", "m2"])
    #expect(payload.changes.first { $0.messageId == "m2" }.map { $0.add.isEmpty && $0.remove.isEmpty } == true,
            "m2 changes nothing here, but Gmail is asked to take off the other categories")

    try fromGmail(store, ["m2": [SystemLabel.inbox, SystemLabel.categoryForums, SystemLabel.categoryPersonal]])
    #expect(try labels(store, "m2") == [SystemLabel.inbox, SystemLabel.categoryForums])
    #expect(try thread(store, "m")?.gmailTab == .forums)
}

@Test func moveToTabRunsProjectRulesOnCategories() throws {
    let store = try store([message("m1", thread: "m", at: 100, labels: [SystemLabel.inbox, SystemLabel.categoryPromotions])])
    try store.database.writer.write { db in
        try MailLabel(accountId: me.id, id: SystemLabel.categoryPromotions, name: SystemLabel.categoryPromotions).insert(db)
    }
    try store.saveProject(Project(id: "deals", name: "Deals"),
                          rules: [ProjectRule(projectId: "deals", field: .label, value: SystemLabel.categoryPromotions)])
    _ = try store.database.writer.write { db in try ProjectRules.recomputeAll(db, projectId: "deals") }
    func inProject() throws -> Bool {
        try store.database.reader.read { db in
            try ThreadProject.filter(Column("projectId") == "deals" && Column("threadId") == "m").fetchCount(db) > 0
        }
    }
    #expect(try inProject())
    let token = try store.perform(.moveToTab(.primary), on: [key("m")])
    #expect(try !inProject(), "out of the project as soon as it leaves Promotions")
    try store.undo(token)
    #expect(try inProject(), "and back in on undo")
}

@Test func movingToTheTabItIsInQueuesNothing() throws {
    let store = try store([message("x1", thread: "x", at: 100, labels: [SystemLabel.inbox, SystemLabel.categoryUpdates])])
    _ = try store.perform(.moveToTab(.updates), on: [key("x")])
    #expect(try store.database.reader.read { db in try PendingOp.fetchCount(db) } == 0)
}

@Test func moveToTabSurvivesTheRoundTripThroughJSON() throws {
    let action = MailAction.moveToTab(.social)
    #expect(try JSONDecoder().decode(MailAction.self, from: JSONEncoder().encode(action)) == action)
    #expect(!action.removesFromInbox)
}

// MARK: Migration

@Test func tabs1FillsInTheTabsOfMailStoredBeforeIt() throws {
    var migrator = DatabaseMigrator()
    Schema.register(in: &migrator)
    let queue = try DatabaseQueue()
    try migrator.migrate(queue, upTo: "fixapp-1")
    try queue.write { db in
        try db.execute(sql: "INSERT INTO account (id, email, createdAt) VALUES (?, ?, 0)", arguments: [me.id, me.email])
        let rows: [(thread: String, id: String, date: Double, labels: String, fromMe: Bool, draft: Bool)] = [
            ("promo", "m1", 100, #"["CATEGORY_PROMOTIONS","INBOX"]"#, false, false),
            ("answered", "m2", 100, #"["CATEGORY_PROMOTIONS","INBOX"]"#, false, false),
            ("answered", "m3", 200, #"["CATEGORY_PERSONAL","INBOX"]"#, false, false),
            ("answered", "m4", 300, #"["CATEGORY_UPDATES","SENT"]"#, true, false),
            ("plain", "m5", 100, #"["INBOX"]"#, false, false),
            ("drafted", "m6", 100, #"["INBOX"]"#, false, false),
            ("drafted", "m7", 200, #"["CATEGORY_SOCIAL","DRAFT"]"#, true, true),
        ]
        for row in rows {
            try db.execute(sql: """
                INSERT INTO message (accountId, id, threadId, date, labelIds, isFromMe, isDraft) VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [me.id, row.id, row.thread, row.date, row.labels, row.fromMe, row.draft])
        }
        for thread in Set(rows.map(\.thread)) {
            try db.execute(sql: "INSERT INTO thread (accountId, id, lastDate) VALUES (?, ?, 300)", arguments: [me.id, thread])
            try db.execute(sql: "INSERT INTO thread_label (accountId, threadId, labelId, lastDate) VALUES (?, ?, 'INBOX', 300)",
                           arguments: [me.id, thread])
        }
    }
    try migrator.migrate(queue)
    let tabs = try queue.read { db in
        Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: """
            SELECT t.id, t.gmailTab AS thread, l.gmailTab AS label FROM thread t
            JOIN thread_label l ON l.accountId = t.accountId AND l.threadId = t.id
            """).map { row -> (String, [String?]) in (row["id"], [row["thread"], row["label"]]) })
    }
    #expect(tabs["promo"] == ["promotions", "promotions"])
    #expect(tabs["answered"] == ["primary", "primary"])
    #expect(tabs["plain"] == [nil, nil])
    #expect(tabs["drafted"] == [nil, nil])
    // A tab without a fallback reads its own index, newest first, without sorting.
    let detail = try queue.read { db in
        try Row.fetchAll(db, sql: """
            EXPLAIN QUERY PLAN SELECT threadId FROM thread_label WHERE labelId = 'INBOX' AND gmailTab = 'social'
            ORDER BY lastDate DESC LIMIT 10
            """).map { $0["detail"] as String }.joined(separator: " | ")
    }
    #expect(detail.contains("thread_label_inbox_tab") && !detail.contains("TEMP B-TREE"), "\(detail)")
}
