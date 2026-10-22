import Foundation
import GRDB

/// Gmail's inbox tabs, in the order the title bar shows them. A thread is in the tab its Gmail category
/// label names (`MailThread.gmailTab`, see `gmailTab(_:)` for threads whose messages disagree); a thread
/// Gmail hasn't categorised (some Workspace accounts, older mail, threads with only your own messages)
/// falls back to Tern's own category (`init(fallback:)`).
public enum InboxTab: String, CaseIterable, Identifiable, Codable, Sendable, DatabaseValueConvertible {
    case primary, promotions, social, updates, forums

    public var id: String { rawValue }

    /// The Gmail label behind the tab.
    public var labelId: String {
        switch self {
        case .primary: SystemLabel.categoryPersonal
        case .promotions: SystemLabel.categoryPromotions
        case .social: SystemLabel.categorySocial
        case .updates: SystemLabel.categoryUpdates
        case .forums: SystemLabel.categoryForums
        }
    }

    public init?(labelId: String) {
        guard let tab = Self.allCases.first(where: { $0.labelId == labelId }) else { return nil }
        self = tab
    }

    /// Where a thread without a Gmail category goes, by what Tern's classifier made of it. Mail it
    /// hasn't classified yet waits in Primary, so nothing new is hidden behind a tab.
    public init(fallback category: MailCategory?) {
        switch category {
        case .promotion?, .newsletter?: self = .promotions
        case .notification?, .receipt?: self = .updates
        case .people?, .calendar?, .security?, .other?, nil: self = .primary
        }
    }

    /// The Tern categories that fall back to this tab; Primary also takes threads not classified yet.
    public var fallbackCategories: [MailCategory] { MailCategory.allCases.filter { InboxTab(fallback: $0) == self } }

    /// The tab Gmail's labels put a conversation in, from its messages oldest first, drafts left out:
    /// the category of the newest message from someone else that has one (what Gmail filed the latest
    /// mail under), else of the newest of your own messages that has one; nil when none has. A message
    /// carrying several category labels counts as the first of them in tab order.
    public static func gmailTab(_ messages: [(labelIds: [String], isFromMe: Bool)]) -> InboxTab? {
        func tab(_ labelIds: [String]) -> InboxTab? { allCases.first { labelIds.contains($0.labelId) } }
        let newestFirst = messages.reversed()
        return newestFirst.lazy.filter { !$0.isFromMe }.compactMap { tab($0.labelIds) }.first
            ?? newestFirst.lazy.compactMap { tab($0.labelIds) }.first
    }

    /// SQL for an inbox row being in this tab, given its `thread_label.gmailTab` and `thread_ai.category`
    /// columns. Social and Forums have no fallback, so theirs reads the tab index alone.
    public func condition(gmailTab: String, category: String) -> (sql: String, arguments: StatementArguments) {
        let fallback = fallbackCategories.map(\.rawValue)
        var alternatives: [String] = []
        if !fallback.isEmpty { alternatives.append("\(category) IN (\(databaseQuestionMarks(count: fallback.count)))") }
        if self == .primary { alternatives.append("\(category) IS NULL") }
        guard !alternatives.isEmpty else { return ("\(gmailTab) = ?", [rawValue]) }
        let sql = "(\(gmailTab) = ? OR (\(gmailTab) IS NULL AND (\(alternatives.joined(separator: " OR ")))))"
        return (sql, StatementArguments([rawValue] + fallback))
    }

    /// SQL for the tab of an inbox row, as a tab raw value.
    static func expression(gmailTab: String, category: String) -> String {
        let cases = allCases.filter { $0 != .primary }.compactMap { tab -> String? in
            let fallback = tab.fallbackCategories.map { "'\($0.rawValue)'" }
            return fallback.isEmpty ? nil : "WHEN \(category) IN (\(fallback.joined(separator: ", "))) THEN '\(tab.rawValue)'"
        }
        return "COALESCE(\(gmailTab), CASE \(cases.joined(separator: " ")) ELSE '\(InboxTab.primary.rawValue)' END)"
    }
}

extension ThreadRow {
    /// The inbox tab the thread shows in: its Gmail category, else Tern's.
    public var inboxTab: InboxTab { thread.gmailTab ?? InboxTab(fallback: category) }
}

/// `tabs-1`: each thread's Gmail tab, on the thread and copied onto its `thread_label` rows (like
/// `lastDate`) so the inbox's rows for a tab read straight from an index. Existing threads get theirs
/// from the messages already stored; `MailStore.refreshThreads` keeps it from then on.
enum InboxTabSchema {
    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE thread ADD COLUMN gmailTab TEXT;
            ALTER TABLE thread_label ADD COLUMN gmailTab TEXT;
            CREATE INDEX thread_label_inbox_tab ON thread_label(gmailTab, lastDate DESC) WHERE labelId = 'INBOX';
            CREATE INDEX thread_label_inbox_tab_account ON thread_label(accountId, gmailTab, lastDate DESC) WHERE labelId = 'INBOX';
            """)

        var tabs: [ThreadKey: InboxTab] = [:]
        var current: ThreadKey?
        var messages: [(labelIds: [String], isFromMe: Bool)] = []
        func flush() {
            if let current, let tab = InboxTab.gmailTab(messages) { tabs[current] = tab }
            messages = []
        }
        let rows = try Row.fetchCursor(db, sql: """
            SELECT accountId, threadId, labelIds, isFromMe FROM message
            WHERE isDraft = 0 AND labelIds LIKE '%CATEGORY%' ORDER BY accountId, threadId, date
            """)
        while let row = try rows.next() {
            let key = ThreadKey(accountId: row["accountId"], threadId: row["threadId"])
            if key != current { flush(); current = key }
            let json: String = row["labelIds"]
            messages.append(((try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? [], row["isFromMe"]))
        }
        flush()

        let thread = try db.makeStatement(sql: "UPDATE thread SET gmailTab = ? WHERE accountId = ? AND id = ?")
        let labels = try db.makeStatement(sql: "UPDATE thread_label SET gmailTab = ? WHERE accountId = ? AND threadId = ?")
        for (key, tab) in tabs {
            try thread.execute(arguments: [tab, key.accountId, key.threadId])
            try labels.execute(arguments: [tab, key.accountId, key.threadId])
        }
    }
}
