import Foundation
import GRDB

// Reads and small writes the app shell needs beyond the core `Mailbox` lists: the inbox tabs, per-scope
// counts, the needs-reply toggle.

/// A slice of the inbox: one account or all, the whole inbox or one of Gmail's tabs.
public struct InboxFilter: Hashable, Sendable {
    /// Nil reads every account.
    public var accountId: String?
    /// Nil is the whole inbox (All).
    public var tab: InboxTab?

    public init(accountId: String? = nil, tab: InboxTab? = nil) {
        self.accountId = accountId
        self.tab = tab
    }
}

/// Counts for the sidebar and the title bar's tabs, for one scope (one account or all).
public struct ScopeCounts: Hashable, Sendable {
    public var inboxUnread = 0
    /// Inbox threads flagged as waiting on your reply, read or not.
    public var needsReply = 0
    public var waitingOn = 0
    public var snoozed = 0
    public var drafts = 0
    /// Unread inbox threads per project id, across accounts.
    public var projectUnread: [String: Int] = [:]
    /// Inbox threads per tab; a tab with none is missing.
    public var tabThreads: [InboxTab: Int] = [:]
    /// Unread inbox threads per tab.
    public var tabUnread: [InboxTab: Int] = [:]
    /// Unread inbox threads over every account, for the Dock badge.
    public var allAccountsInboxUnread = 0

    public init() {}
}

/// What undoing a needs-reply change restores: earlier flags, and manual entries to remove.
public struct NeedsReplyUndo: Hashable, Sendable {
    public var previous: [ThreadKey: Bool] = [:]
    public var created: [ThreadKey] = []

    public init() {}
}

extension MailStore {
    /// Inbox rows in one slice, newest first. A tab with a fallback (Primary, Promotions, Updates) walks the
    /// inbox by date and keeps its rows; Social and Forums read their own index.
    public static func fetchInboxRows(_ db: Database, _ filter: InboxFilter, limit: Int, before: Date? = nil) throws -> [ThreadRow] {
        var sql = """
            SELECT \(rowColumns) FROM thread_label tl
            JOIN thread t ON t.accountId = tl.accountId AND t.id = tl.threadId
            \(rowJoins)
            WHERE tl.labelId = 'INBOX'
            """
        var arguments: StatementArguments = []
        if let accountId = filter.accountId {
            sql += " AND tl.accountId = ?"
            _ = arguments.append(contentsOf: [accountId])
        }
        if let tab = filter.tab {
            let condition = tab.condition(gmailTab: "tl.gmailTab", category: "ai.category")
            sql += " AND \(condition.sql)"
            _ = arguments.append(contentsOf: condition.arguments)
        }
        if let before {
            sql += " AND tl.lastDate < ?"
            _ = arguments.append(contentsOf: [before.timeIntervalSince1970])
        }
        sql += " ORDER BY tl.lastDate DESC LIMIT ?"
        _ = arguments.append(contentsOf: [limit])
        return try ThreadRow.fetchAll(db, sql: sql, arguments: arguments)
    }

    public func scopeCounts(accountId: String?) throws -> ScopeCounts {
        try database.reader.read { db in try Self.fetchScopeCounts(db, accountId: accountId) }
    }

    /// One pass over the scope's inbox rows (its index) for the inbox, tab and needs-reply counts.
    public static func fetchScopeCounts(_ db: Database, accountId: String?) throws -> ScopeCounts {
        var counts = ScopeCounts()
        counts.waitingOn = try Self.fetchLedgerCount(db, accountId: accountId)
        let scoped = accountId == nil ? "" : " AND i.accountId = ?"
        let scopeArguments: StatementArguments = accountId.map { [$0] } ?? []

        for row in try Row.fetchAll(db, sql: """
            SELECT \(InboxTab.expression(gmailTab: "i.gmailTab", category: "ai.category")) AS tab,
              COALESCE(ai.needsReply, 0) AS flagged, count(*) AS threads, sum(u.threadId IS NOT NULL) AS unread
            FROM thread_label i
            LEFT JOIN thread_label u ON u.accountId = i.accountId AND u.threadId = i.threadId AND u.labelId = 'UNREAD'
            LEFT JOIN thread_ai ai ON ai.accountId = i.accountId AND ai.threadId = i.threadId
            WHERE i.labelId = 'INBOX'\(scoped)
            GROUP BY 1, 2
            """, arguments: scopeArguments) {
            let threads: Int = row["threads"]
            let unread: Int = row["unread"]
            if let tab = InboxTab(rawValue: row["tab"]) {
                counts.tabThreads[tab, default: 0] += threads
                if unread > 0 { counts.tabUnread[tab, default: 0] += unread }
            }
            counts.inboxUnread += unread
            if row["flagged"] as Bool { counts.needsReply += threads }
        }

        counts.allAccountsInboxUnread = accountId == nil ? counts.inboxUnread : try Int.fetchOne(db, sql: """
            SELECT count(*) FROM thread_label i
            JOIN thread_label u ON u.accountId = i.accountId AND u.threadId = i.threadId AND u.labelId = 'UNREAD'
            WHERE i.labelId = 'INBOX'
            """) ?? 0

        counts.snoozed = try Int.fetchOne(
            db, sql: "SELECT count(*) FROM snooze i WHERE 1\(scoped)", arguments: scopeArguments) ?? 0
        counts.drafts = try (Int.fetchOne(
            db, sql: "SELECT count(*) FROM thread_label i WHERE i.labelId = 'DRAFT'\(scoped)", arguments: scopeArguments) ?? 0)
            + localDraftCount(db, accountId: accountId)

        for row in try Row.fetchAll(db, sql: """
            SELECT p.projectId, count(*) AS n FROM thread_project p
            JOIN thread_label u ON u.accountId = p.accountId AND u.threadId = p.threadId AND u.labelId = 'UNREAD'
            JOIN thread_label i ON i.accountId = p.accountId AND i.threadId = p.threadId AND i.labelId = 'INBOX'
            GROUP BY p.projectId
            """) {
            counts.projectUnread[row["projectId"]] = row["n"]
        }
        return counts
    }

    /// Which of Gmail's tabs the scope's inbox has mail in, bounded for the main thread: an index seek per tab for
    /// threads Gmail has categorised, and the newest `uncategorisedSample` of those it hasn't (their tab comes from
    /// Tern's category). A fallback tab whose threads are all older than that sample is missing until the full
    /// counts (`fetchScopeCounts`) come in.
    public static func fetchTabsWithMail(_ db: Database, accountId: String?, uncategorisedSample: Int = 500) throws -> Set<InboxTab> {
        let scoped = accountId == nil ? "" : " AND accountId = ?"
        let scopeArguments: StatementArguments = accountId.map { [$0] } ?? []
        var tabs = Set<InboxTab>()
        let categorised = try db.cachedStatement(sql: """
            SELECT EXISTS(SELECT 1 FROM thread_label WHERE labelId = 'INBOX'\(scoped) AND gmailTab = ?)
            """)
        for tab in InboxTab.allCases where try Bool.fetchOne(categorised, arguments: scopeArguments + [tab]) == true {
            tabs.insert(tab)
        }
        // NULL must seek the tab index too; the label/date index can scan the entire inbox.
        let fallbackIndex = accountId == nil ? "thread_label_inbox_tab" : "thread_label_inbox_tab_account"
        for category in try String?.fetchAll(db, sql: """
            SELECT DISTINCT ai.category FROM (
              SELECT accountId, threadId FROM thread_label INDEXED BY \(fallbackIndex)
              WHERE labelId = 'INBOX'\(scoped) AND gmailTab IS NULL ORDER BY lastDate DESC LIMIT ?
            ) t
            LEFT JOIN thread_ai ai ON ai.accountId = t.accountId AND ai.threadId = t.threadId
            """, arguments: scopeArguments + [uncategorisedSample]) {
            tabs.insert(InboxTab(fallback: category.flatMap(MailCategory.init(rawValue:))))
        }
        return tabs
    }

    /// Flags or clears "needs reply" by hand. Threads the classifier hasn't seen get a manual entry.
    /// Returns what undo needs to put things back.
    @discardableResult
    public func setNeedsReply(_ needsReply: Bool, on threads: [ThreadKey]) throws -> NeedsReplyUndo {
        try database.writer.write { db in try Self.setNeedsReply(db, needsReply, on: threads) }
    }

    @discardableResult
    public static func setNeedsReply(_ db: Database, _ needsReply: Bool, on threads: [ThreadKey]) throws -> NeedsReplyUndo {
        var undo = NeedsReplyUndo()
        for key in threads {
            if var ai = try ThreadAI.fetchOne(db, key: ["accountId": key.accountId, "threadId": key.threadId]) {
                undo.previous[key] = ai.needsReply
                guard ai.needsReply != needsReply else { continue }
                ai.needsReply = needsReply
                try ai.update(db)
            } else {
                guard needsReply,
                      let thread = try MailThread.fetchOne(db, key: ["accountId": key.accountId, "id": key.threadId])
                else { continue }
                try ThreadAI(
                    accountId: key.accountId, threadId: key.threadId, category: .people, needsReply: true,
                    source: "manual", messageCount: thread.messageCount
                ).insert(db)
                undo.created.append(key)
            }
        }
        return undo
    }

    /// Puts back what `setNeedsReply` changed, removing the manual entries it created.
    public func restoreNeedsReply(_ undo: NeedsReplyUndo) throws {
        try database.writer.write { db in
            for (flag, keys) in Dictionary(grouping: undo.previous.keys, by: { undo.previous[$0]! }) {
                try Self.setNeedsReply(db, flag, on: keys)
            }
            for key in undo.created {
                _ = try ThreadAI.deleteOne(db, key: ["accountId": key.accountId, "threadId": key.threadId])
            }
        }
    }

    // MARK: Projects

    public func projectRules(_ projectId: String) throws -> [ProjectRule] {
        try database.reader.read { db in
            try ProjectRule.filter(Column("projectId") == projectId).order(Column("id")).fetchAll(db)
        }
    }

    /// Creates or updates a project and replaces its rules.
    public func saveProject(_ project: Project, rules: [ProjectRule]) throws {
        try database.writer.write { db in
            try project.upsert(db)
            try db.execute(sql: "DELETE FROM project_rule WHERE projectId = ?", arguments: [project.id])
            for var rule in rules {
                rule.id = nil
                rule.projectId = project.id
                try rule.insert(db)
            }
        }
    }

    /// Deletes a project; its threads stay where they are.
    public func deleteProject(_ projectId: String) throws {
        try database.writer.write { db in _ = try Project.deleteOne(db, key: projectId) }
    }

    /// Rebuilds the full-text index from the message table.
    public func rebuildSearchIndex() throws {
        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO message_fts(message_fts) VALUES ('rebuild')")
        }
    }
}
