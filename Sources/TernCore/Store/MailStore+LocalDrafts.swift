import Foundation
import GRDB

// The Drafts mailbox lists Gmail's DRAFT messages by thread. Local drafts Gmail has no copy of (not
// saved there yet, a Gmail save that failed, a send that couldn't be confirmed) get a row of their own
// there, under a thread id that names the draft, so every unsent draft can be found and reopened.
extension MailThread {
    /// Thread ids of Drafts rows that stand for a local draft: this prefix and the draft id.
    public static let localDraftPrefix = "tern-draft:"

    /// The local draft a Drafts row stands for; nil for a Gmail thread.
    public static func localDraftId(in key: ThreadKey) -> String? {
        key.threadId.hasPrefix(localDraftPrefix) ? String(key.threadId.dropFirst(localDraftPrefix.count)) : nil
    }

    /// A list row for a local draft: its subject, the start of its text, "Draft to …".
    init(localDraft draft: Draft) {
        let text = DraftContent(stored: draft).body.plainText.replacingOccurrences(of: "\n", with: " ")
        self.init(
            accountId: draft.accountId, id: MailThread.localDraftPrefix + draft.id, subject: draft.subject,
            snippet: String(text.prefix(200)), lastDate: draft.updatedAt, lastInboundDate: nil, messageCount: 1,
            unreadCount: 0, isStarred: false, isImportant: false, hasAttachments: !draft.attachments.isEmpty,
            hasDraft: true, participants: [Participant(email: draft.accountId)] + draft.toList,
            labelIds: [SystemLabel.draft])
    }
}

extension ThreadRow {
    /// A Drafts row for a local draft Gmail has no copy of.
    public init(localDraft draft: Draft) {
        thread = MailThread(localDraft: draft)
        category = nil
        needsReply = false
        priority = 1
        summary = nil
        snoozedUntil = nil
        projectIds = []
    }
}

extension MailStore {
    /// Condition on `draft` rows: unsent local drafts with no DRAFT message stored for them.
    static let localOnlyDrafts = """
        state IN ('editing', 'failed', 'queued')
          AND NOT EXISTS (SELECT 1 FROM message m WHERE m.accountId = draft.accountId AND m.id = draft.gmailMessageId AND m.isDraft = 1)
        """

    /// Local drafts Gmail has no copy of, as Drafts rows, newest first.
    static func localDraftRows(_ db: Database, accountId: String?, limit: Int, before: Date?) throws -> [ThreadRow] {
        var sql = "SELECT * FROM draft WHERE \(localOnlyDrafts)"
        var arguments: StatementArguments = []
        if let accountId { sql += " AND accountId = ?"; _ = arguments.append(contentsOf: [accountId]) }
        if let before { sql += " AND updatedAt < ?"; _ = arguments.append(contentsOf: [before.timeIntervalSince1970]) }
        sql += " ORDER BY updatedAt DESC LIMIT ?"
        _ = arguments.append(contentsOf: [limit])
        return try Draft.fetchAll(db, sql: sql, arguments: arguments).map(ThreadRow.init(localDraft:))
    }

    /// `local` (newest first) slotted into `rows` by date, keeping the order of `rows`.
    static func merging(_ local: [ThreadRow], into rows: [ThreadRow], limit: Int) -> [ThreadRow] {
        guard !local.isEmpty else { return rows }
        var merged: [ThreadRow] = []
        var pending = local[...]
        for row in rows {
            while let next = pending.first, next.thread.lastDate > row.thread.lastDate {
                merged.append(next)
                pending = pending.dropFirst()
            }
            merged.append(row)
        }
        return Array((merged + pending).prefix(limit))
    }

    /// How many local drafts Gmail has no copy of, in one account or all.
    static func localDraftCount(_ db: Database, accountId: String?) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT count(*) FROM draft WHERE \(localOnlyDrafts)\(accountId == nil ? "" : " AND accountId = ?")",
                         arguments: accountId.map { [$0] } ?? []) ?? 0
    }
}
