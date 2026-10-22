import Foundation
import GRDB

/// What a list shows. `accountId == nil` means every account (the unified view).
public struct Mailbox: Hashable, Codable, Sendable {
    public enum Kind: Hashable, Codable, Sendable {
        case inbox, starred, important, snoozed, sent, drafts, allMail, spam, trash
        /// Archived conversations: someone else wrote in them, or they hold a note you sent this account, and
        /// they aren't in the inbox, snoozed, spam or trash.
        case archive
        /// A Gmail label id; needs an account.
        case label(String)
        /// A project across all accounts; `accountId` is ignored.
        case project(String)
        /// Inbox threads in one split-inbox bucket.
        case category(MailCategory)
        /// Inbox threads the classifier flagged as waiting on your reply.
        case needsReply
        case waitingOn, iOwe
    }

    public var kind: Kind
    public var accountId: String?

    public init(_ kind: Kind, accountId: String? = nil) {
        self.kind = kind
        self.accountId = accountId
    }

    public static let unifiedInbox = Mailbox(.inbox)

    /// The Gmail label a label-backed mailbox reads from.
    var systemLabelId: String? {
        switch kind {
        case .inbox, .category, .needsReply: SystemLabel.inbox
        case .starred: SystemLabel.starred
        case .important: SystemLabel.important
        case .sent: SystemLabel.sent
        case .drafts: SystemLabel.draft
        case .spam: SystemLabel.spam
        case .trash: SystemLabel.trash
        case .label(let id): id
        case .snoozed, .allMail, .archive, .project, .waitingOn, .iOwe: nil
        }
    }
}

/// A thread plus everything a list row shows.
public struct ThreadRow: Hashable, Sendable, Identifiable, FetchableRecord {
    public var thread: MailThread
    public var category: MailCategory?
    public var needsReply: Bool
    public var priority: Int
    public var summary: String?
    public var snoozedUntil: Date?
    public var projectIds: [String]
    public var ledger: CommitmentBrief?

    public var id: ThreadKey { thread.key }

    public init(row: Row) throws {
        thread = try MailThread(row: row)
        if row.hasColumn("ledgerId"), let id: Int64 = row["ledgerId"] {
            ledger = CommitmentBrief(id: id, counterpartyEmail: row["ledgerEmail"], counterpartyName: row["ledgerName"],
                sourceDate: Date(timeIntervalSince1970: row["ledgerDate"]), extraCount: row["ledgerExtra"], surfaceAt: Date(timeIntervalSince1970: row["ledgerSurface"]),
                deliverable: row.hasColumn("ledgerDeliverable") ? row["ledgerDeliverable"] : nil,
                dueAt: (row.hasColumn("ledgerDue") ? row["ledgerDue"] as Double? : nil).map(Date.init(timeIntervalSince1970:)),
                hasHint: row.hasColumn("ledgerHint") ? row["ledgerHint"] : false,
                isMaybe: row.hasColumn("ledgerMaybe") ? row["ledgerMaybe"] : false)
        } else { ledger = nil }
        category = row["aiCategory"]
        needsReply = row["aiNeedsReply"] ?? false
        priority = row["aiPriority"] ?? 1
        summary = row["aiSummary"]
        snoozedUntil = (row["snoozedUntil"] as Double?).map { Date(timeIntervalSince1970: $0) }
        let ids: String? = row["projectIds"]
        projectIds = ids.map { $0.split(separator: ",").map(String.init) } ?? []
    }
}

/// A conversation with its messages, for the reader.
public struct ThreadDetail: Hashable, Sendable {
    public var thread: MailThread
    /// Oldest first.
    public var messages: [MailMessage]
    /// Keyed by message id.
    public var attachments: [String: [MailAttachment]]
    public var ai: ThreadAI?
    public var projects: [Project]
    public var snoozedUntil: Date?
    /// Open and recently completed local commitments, observed with the thread.
    public var commitments: [Commitment] = []
}

public struct SidebarCounts: Hashable, Sendable {
    /// Unread inbox threads per account id.
    public var inboxUnread: [String: Int] = [:]
    public var draftCount: [String: Int] = [:]
    /// Unread threads per project id.
    public var projectUnread: [String: Int] = [:]
    /// Unread inbox threads per category, across accounts.
    public var categoryUnread: [MailCategory: Int] = [:]
    public var needsReply: Int = 0
    public var snoozed: Int = 0

    public init() {}

    public var totalInboxUnread: Int { inboxUnread.values.reduce(0, +) }
}

/// Reads and writes the local mail database. Value type over a shared `AppDatabase`;
/// safe to copy and use from any thread.
public struct MailStore: Sendable {
    public let database: AppDatabase

    public init(_ database: AppDatabase) {
        self.database = database
    }

    // MARK: Accounts, labels, projects

    public func accounts() throws -> [Account] {
        try database.reader.read { db in try Account.order(Column("sortOrder"), Column("createdAt")).fetchAll(db) }
    }

    public func labels(accountId: String) throws -> [MailLabel] {
        try database.reader.read { db in
            try MailLabel.filter(Column("accountId") == accountId).order(Column("name")).fetchAll(db)
        }
    }

    public func projects() throws -> [Project] {
        try database.reader.read { db in try Project.order(Column("sortOrder"), Column("name")).fetchAll(db) }
    }

    // MARK: Lists

    public func threadRows(in mailbox: Mailbox, limit: Int = 200, before: Date? = nil) throws -> [ThreadRow] {
        try database.reader.read { db in try Self.fetchThreadRows(db, in: mailbox, limit: limit, before: before) }
    }

    /// Emits the list whenever any table it reads changes. Duplicate results are dropped.
    public func observeThreadRows(in mailbox: Mailbox, limit: Int = 200) -> ValueObservation<ValueReducers.RemoveDuplicates<ValueReducers.Fetch<[ThreadRow]>>> {
        ValueObservation
            .tracking { db in try Self.fetchThreadRows(db, in: mailbox, limit: limit, before: nil) }
            .removeDuplicates()
    }

    static let rowColumns = """
        t.*, ai.category AS aiCategory, ai.needsReply AS aiNeedsReply, ai.priority AS aiPriority,
        COALESCE(sm.line, ai.summary) AS aiSummary, s.until AS snoozedUntil,
        (SELECT group_concat(tp.projectId, ',') FROM thread_project tp
          WHERE tp.accountId = t.accountId AND tp.threadId = t.id) AS projectIds
        """

    static let rowJoins = """
        LEFT JOIN thread_ai ai ON ai.accountId = t.accountId AND ai.threadId = t.id
        LEFT JOIN thread_summary sm ON sm.accountId=t.accountId AND sm.threadId=t.id AND sm.messageCount=t.messageCount AND sm.lastDate=t.lastDate
        LEFT JOIN snooze s ON s.accountId = t.accountId AND s.threadId = t.id
        """

    static let notTrashOrSpam = """
        NOT EXISTS (SELECT 1 FROM thread_label x WHERE x.accountId = t.accountId AND x.threadId = t.id
          AND x.labelId IN ('TRASH', 'SPAM'))
        """

    /// Archived: not in the inbox, and not in spam or trash.
    static let notInInboxTrashOrSpam = """
        NOT EXISTS (SELECT 1 FROM thread_label x WHERE x.accountId = t.accountId AND x.threadId = t.id
          AND x.labelId IN ('INBOX', 'TRASH', 'SPAM'))
        """

    /// The thread has a message you sent to the thread's own account (`searchRecipients` lists names and
    /// addresses separated by spaces). Mail to another of your accounts arrived there, not here. Send-as
    /// aliases aren't stored, so a note sent to an alias isn't recognised.
    static let holdsNoteToSelf = """
        EXISTS (SELECT 1 FROM message m JOIN account a ON a.id = m.accountId
          WHERE m.accountId = t.accountId AND m.threadId = t.id AND m.isDraft = 0 AND m.isFromMe = 1
          AND instr(' ' || lower(m.searchRecipients) || ' ', ' ' || lower(a.email) || ' ') > 0)
        """

    public static func fetchThreadRows(_ db: Database, in mailbox: Mailbox, limit: Int, before: Date?) throws -> [ThreadRow] {
        var arguments: StatementArguments = []
        var sql: String

        switch mailbox.kind {
        case .waitingOn, .iOwe:
            return try fetchLedgerRows(db, in: mailbox, limit: limit)
        case .project(let projectId):
            return try fetchProjectRows(db, projectId: projectId, limit: limit, before: before)

        case .snoozed:
            sql = """
                SELECT \(rowColumns) FROM snooze s0
                JOIN thread t ON t.accountId = s0.accountId AND t.id = s0.threadId
                \(rowJoins)
                WHERE 1
                """
            if let accountId = mailbox.accountId { sql += " AND t.accountId = ?"; _ = arguments.append(contentsOf: [accountId]) }
            sql += " ORDER BY s0.until ASC LIMIT ?"

        case .allMail:
            sql = "SELECT \(rowColumns) FROM thread t \(rowJoins) WHERE \(notTrashOrSpam)"
            if let accountId = mailbox.accountId { sql += " AND t.accountId = ?"; _ = arguments.append(contentsOf: [accountId]) }
            if let before { sql += " AND t.lastDate < ?"; _ = arguments.append(contentsOf: [before.timeIntervalSince1970]) }
            sql += " ORDER BY t.lastDate DESC LIMIT ?"

        case .archive:
            // lastInboundDate is set once a message someone else sent is in the thread, so sent-only
            // conversations and drafts stay out; a note to yourself (sent to this account's address) comes in
            // through message_by_thread. Snoozed ones show in Snoozed. Reads thread_by_date, or
            // thread_by_account_date for one account.
            sql = """
                SELECT \(rowColumns) FROM thread t \(rowJoins)
                WHERE (t.lastInboundDate IS NOT NULL OR \(holdsNoteToSelf)) AND s.threadId IS NULL AND \(notInInboxTrashOrSpam)
                """
            if let accountId = mailbox.accountId { sql += " AND t.accountId = ?"; _ = arguments.append(contentsOf: [accountId]) }
            if let before { sql += " AND t.lastDate < ?"; _ = arguments.append(contentsOf: [before.timeIntervalSince1970]) }
            sql += " ORDER BY t.lastDate DESC LIMIT ?"

        default:
            guard let labelId = mailbox.systemLabelId else { return [] }
            sql = """
                SELECT \(rowColumns) FROM thread_label tl
                JOIN thread t ON t.accountId = tl.accountId AND t.id = tl.threadId
                \(rowJoins)
                WHERE tl.labelId = ?
                """
            _ = arguments.append(contentsOf: [labelId])
            if let accountId = mailbox.accountId { sql += " AND tl.accountId = ?"; _ = arguments.append(contentsOf: [accountId]) }
            if case .category(let category) = mailbox.kind {
                sql += " AND ai.category = ?"
                _ = arguments.append(contentsOf: [category.rawValue])
            }
            if case .needsReply = mailbox.kind { sql += " AND ai.needsReply = 1" }
            if let before { sql += " AND tl.lastDate < ?"; _ = arguments.append(contentsOf: [before.timeIntervalSince1970]) }
            sql += " ORDER BY tl.lastDate DESC LIMIT ?"
        }

        _ = arguments.append(contentsOf: [limit])
        let rows = try ThreadRow.fetchAll(db, sql: sql, arguments: arguments)
        guard case .drafts = mailbox.kind else { return rows }
        return merging(try localDraftRows(db, accountId: mailbox.accountId, limit: limit, before: before), into: rows, limit: limit)
    }

    /// Rows for specific threads, in the order given. Used by search and the command palette.
    public static func fetchThreadRows(_ db: Database, keys: [ThreadKey]) throws -> [ThreadRow] {
        guard !keys.isEmpty else { return [] }
        var rows: [ThreadKey: ThreadRow] = [:]
        for chunk in stride(from: 0, to: keys.count, by: 400).map({ Array(keys[$0..<min($0 + 400, keys.count)]) }) {
            let placeholders = chunk.map { _ in "(?, ?)" }.joined(separator: ", ")
            var arguments: StatementArguments = []
            for key in chunk { _ = arguments.append(contentsOf: [key.accountId, key.threadId]) }
            let sql = """
                SELECT \(rowColumns) FROM thread t \(rowJoins)
                WHERE (t.accountId, t.id) IN (VALUES \(placeholders))
                """
            for row in try ThreadRow.fetchAll(db, sql: sql, arguments: arguments) { rows[row.id] = row }
        }
        return keys.compactMap { rows[$0] }
    }

    // MARK: Reader

    public func threadDetail(_ key: ThreadKey) throws -> ThreadDetail? {
        try database.reader.read { db in try Self.fetchThreadDetail(db, key) }
    }

    public static func fetchThreadDetail(_ db: Database, _ key: ThreadKey) throws -> ThreadDetail? {
        guard let thread = try MailThread.fetchOne(db, key: ["accountId": key.accountId, "id": key.threadId]) else {
            return nil
        }
        let messages = try MailMessage
            .filter(Column("accountId") == key.accountId && Column("threadId") == key.threadId)
            .order(Column("date"))
            .fetchAll(db)
        let ids = messages.map(\.id)
        let attachments = try MailAttachment
            .filter(Column("accountId") == key.accountId && ids.contains(Column("messageId")))
            .order(Column("partId"))
            .fetchAll(db)
        let ai = try ThreadAI.fetchOne(db, key: ["accountId": key.accountId, "threadId": key.threadId])
        let projects = try Project.fetchAll(db, sql: """
            SELECT project.* FROM project JOIN thread_project tp ON tp.projectId = project.id
            WHERE tp.accountId = ? AND tp.threadId = ? ORDER BY project.sortOrder
            """, arguments: [key.accountId, key.threadId])
        let snooze = try Snooze.fetchOne(db, key: ["accountId": key.accountId, "threadId": key.threadId])
        let ledgerSettings = try LedgerSettings.load(db)
        var commitments = ledgerSettings.enabled ? try Commitment.fetchAll(db, sql: "SELECT * FROM commitment WHERE accountId=? AND threadId=? AND (confidence=2 OR ?) AND (state='open' OR (state='done' AND updatedAt>=?)) ORDER BY sourceDate,id LIMIT 100", arguments: [key.accountId, key.threadId, ledgerSettings.showMaybe, Date().addingTimeInterval(-14 * 86_400).timeIntervalSince1970]) : []
        for i in commitments.indices where commitments[i].sourceQuote.isEmpty {
            if let source = messages.first(where: { $0.id == commitments[i].sourceMessageId }) {
                commitments[i].sourceQuote = String(MailText.stripQuoted(source.bodyText ?? source.snippet).prefix(700))
            }
        }
        return ThreadDetail(
            thread: thread, messages: messages, attachments: Dictionary(grouping: attachments, by: \.messageId),
            ai: ai, projects: projects, snoozedUntil: snooze?.until,
            commitments: commitments)
    }

    public func observeThreadDetail(_ key: ThreadKey) -> ValueObservation<ValueReducers.RemoveDuplicates<ValueReducers.Fetch<ThreadDetail?>>> {
        ValueObservation.tracking { db in try Self.fetchThreadDetail(db, key) }.removeDuplicates()
    }

    // MARK: Counts

    public func sidebarCounts() throws -> SidebarCounts {
        try database.reader.read { db in try Self.fetchSidebarCounts(db) }
    }

    public func observeSidebarCounts() -> ValueObservation<ValueReducers.RemoveDuplicates<ValueReducers.Fetch<SidebarCounts>>> {
        ValueObservation.tracking { db in try Self.fetchSidebarCounts(db) }.removeDuplicates()
    }

    public static func fetchSidebarCounts(_ db: Database) throws -> SidebarCounts {
        var counts = SidebarCounts()
        for row in try Row.fetchAll(db, sql: """
            SELECT i.accountId, count(*) AS n FROM thread_label i
            JOIN thread_label u ON u.accountId = i.accountId AND u.threadId = i.threadId AND u.labelId = 'UNREAD'
            WHERE i.labelId = 'INBOX' GROUP BY i.accountId
            """) {
            counts.inboxUnread[row["accountId"]] = row["n"]
        }
        for row in try Row.fetchAll(db, sql: """
            SELECT accountId, count(*) AS n FROM thread_label WHERE labelId = 'DRAFT' GROUP BY accountId
            """) {
            counts.draftCount[row["accountId"]] = row["n"]
        }
        for row in try Row.fetchAll(db, sql: """
            SELECT p.projectId, count(*) AS n FROM thread_project p
            JOIN thread_label u ON u.accountId = p.accountId AND u.threadId = p.threadId AND u.labelId = 'UNREAD'
            JOIN thread_label i ON i.accountId = p.accountId AND i.threadId = p.threadId AND i.labelId = 'INBOX'
            GROUP BY p.projectId
            """) {
            counts.projectUnread[row["projectId"]] = row["n"]
        }
        for row in try Row.fetchAll(db, sql: """
            SELECT ai.category, count(*) AS n FROM thread_label i
            JOIN thread_label u ON u.accountId = i.accountId AND u.threadId = i.threadId AND u.labelId = 'UNREAD'
            JOIN thread_ai ai ON ai.accountId = i.accountId AND ai.threadId = i.threadId
            WHERE i.labelId = 'INBOX' GROUP BY ai.category
            """) {
            if let category = MailCategory(rawValue: row["category"]) { counts.categoryUnread[category] = row["n"] }
        }
        counts.needsReply = try Int.fetchOne(db, sql: """
            SELECT count(*) FROM thread_label i
            JOIN thread_ai ai ON ai.accountId = i.accountId AND ai.threadId = i.threadId
            WHERE i.labelId = 'INBOX' AND ai.needsReply = 1
            """) ?? 0
        counts.snoozed = try Snooze.fetchCount(db)
        return counts
    }

    // MARK: Settings

    public func setting(_ key: String) throws -> String? {
        try database.reader.read { db in try Setting.fetchOne(db, key: key)?.value }
    }

    public func setSetting(_ key: String, _ value: String?) throws {
        try database.writer.write { db in
            if let value { try Setting(key: key, value: value).upsert(db) } else { _ = try Setting.deleteOne(db, key: key) }
        }
    }
}
