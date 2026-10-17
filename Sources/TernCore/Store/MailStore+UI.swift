import Foundation
import GRDB

// Reads and small writes the app shell needs beyond the core `Mailbox` lists: split-inbox filters,
// per-scope counts, the needs-reply toggle.

/// A slice of the inbox, used for split tabs. Filters combine with AND.
public struct InboxFilter: Hashable, Sendable {
    public enum NeedsReply: Hashable, Sendable { case any, only, exclude }

    /// Nil reads every account.
    public var accountId: String?
    /// Nil keeps every category.
    public var categories: Set<MailCategory>?
    /// With `categories`, also keep threads the classifier hasn't seen yet.
    public var includeUncategorized: Bool
    /// With `categories`, also keep threads flagged as needing a reply, whatever their category.
    public var includeNeedsReply: Bool
    public var needsReply: NeedsReply

    public init(
        accountId: String? = nil, categories: Set<MailCategory>? = nil, includeUncategorized: Bool = false,
        includeNeedsReply: Bool = false, needsReply: NeedsReply = .any
    ) {
        self.accountId = accountId
        self.categories = categories
        self.includeUncategorized = includeUncategorized
        self.includeNeedsReply = includeNeedsReply
        self.needsReply = needsReply
    }

    /// Whether a row read elsewhere belongs to this slice.
    public func matches(category: MailCategory?, needsReply flagged: Bool) -> Bool {
        switch needsReply {
        case .only where !flagged, .exclude where flagged: return false
        default: break
        }
        guard let categories else { return true }
        if let category, categories.contains(category) { return true }
        return (category == nil && includeUncategorized) || (flagged && includeNeedsReply)
    }
}

/// Counts for the sidebar, split tabs and the Flock, for one scope (one account or all).
public struct ScopeCounts: Hashable, Sendable {
    public struct Bucket: Hashable, Sendable {
        public var category: MailCategory?
        public var needsReply: Bool

        public init(category: MailCategory?, needsReply: Bool) {
            self.category = category
            self.needsReply = needsReply
        }
    }

    public var inboxUnread = 0
    /// Inbox threads flagged as waiting on your reply, read or not.
    public var needsReply = 0
    public var snoozed = 0
    public var drafts = 0
    /// Unread inbox threads per project id, across accounts.
    public var projectUnread: [String: Int] = [:]
    /// Unread inbox threads per bucket.
    public var unreadByBucket: [Bucket: Int] = [:]
    /// Inbox threads that are unread or need a reply, per bucket.
    public var actionByBucket: [Bucket: Int] = [:]
    /// Unread inbox threads over every account, for the Dock badge.
    public var allAccountsInboxUnread = 0

    public init() {}

    public func unread(in filter: InboxFilter) -> Int { sum(unreadByBucket, filter) }
    public func needingAction(in filter: InboxFilter) -> Int { sum(actionByBucket, filter) }

    private func sum(_ buckets: [Bucket: Int], _ filter: InboxFilter) -> Int {
        buckets.reduce(0) { total, entry in
            filter.matches(category: entry.key.category, needsReply: entry.key.needsReply) ? total + entry.value : total
        }
    }
}

/// What undoing a needs-reply change restores: earlier flags, and manual entries to remove.
public struct NeedsReplyUndo: Hashable, Sendable {
    public var previous: [ThreadKey: Bool] = [:]
    public var created: [ThreadKey] = []

    public init() {}
}

extension MailStore {
    /// Inbox rows in one slice, newest first.
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
        if let categories = filter.categories {
            var any: [String] = []
            if !categories.isEmpty {
                any.append("ai.category IN (\(databaseQuestionMarks(count: categories.count)))")
                _ = arguments.append(contentsOf: StatementArguments(categories.map(\.rawValue).sorted()))
            }
            if filter.includeUncategorized { any.append("ai.category IS NULL") }
            if filter.includeNeedsReply { any.append("ai.needsReply = 1") }
            sql += any.isEmpty ? " AND 0" : " AND (\(any.joined(separator: " OR ")))"
        }
        switch filter.needsReply {
        case .any: break
        case .only: sql += " AND ai.needsReply = 1"
        case .exclude: sql += " AND COALESCE(ai.needsReply, 0) = 0"
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

    public static func fetchScopeCounts(_ db: Database, accountId: String?) throws -> ScopeCounts {
        var counts = ScopeCounts()
        let scoped = accountId == nil ? "" : " AND i.accountId = ?"
        let scopeArguments: StatementArguments = accountId.map { [$0] } ?? []

        for row in try Row.fetchAll(db, sql: """
            SELECT ai.category AS category, COALESCE(ai.needsReply, 0) AS flagged,
              sum(u.threadId IS NOT NULL) AS unread, count(*) AS action
            FROM thread_label i
            LEFT JOIN thread_label u ON u.accountId = i.accountId AND u.threadId = i.threadId AND u.labelId = 'UNREAD'
            LEFT JOIN thread_ai ai ON ai.accountId = i.accountId AND ai.threadId = i.threadId
            WHERE i.labelId = 'INBOX'\(scoped) AND (u.threadId IS NOT NULL OR ai.needsReply = 1)
            GROUP BY 1, 2
            """, arguments: scopeArguments) {
            let category: String? = row["category"]
            let bucket = ScopeCounts.Bucket(category: category.flatMap(MailCategory.init(rawValue:)), needsReply: row["flagged"])
            let unread: Int = row["unread"]
            let action: Int = row["action"]
            counts.unreadByBucket[bucket, default: 0] += unread
            counts.actionByBucket[bucket, default: 0] += action
            counts.inboxUnread += unread
            if bucket.needsReply { counts.needsReply += action }
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
