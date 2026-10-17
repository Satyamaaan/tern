import Foundation
import GRDB

/// Counts of an account's queued operations, for the sync status and to wake the op queue.
public struct PendingOpCounts: Hashable, Sendable {
    /// Pending or inflight.
    public var queued: Int
    public var failed: Int
    /// Highest op id; grows on every insert, so a new op is noticed even when the count is unchanged.
    public var maxId: Int64

    public init(queued: Int, failed: Int, maxId: Int64) {
        self.queued = queued
        self.failed = failed
        self.maxId = maxId
    }
}

// Reads and writes the sync engine runs inside its own transactions. Message writes still go
// through `upsertMessages` / `setLabels` / `deleteMessages`, so threads and the search index stay derived.
extension MailStore {
    // MARK: Message ids

    /// Which of `ids` are stored for the account.
    public static func storedMessageIds(_ db: Database, accountId: String, among ids: [String]) throws -> Set<String> {
        try idSubset(db, accountId: accountId, among: ids, extraCondition: "")
    }

    /// Which of `ids` are stored with their full body.
    public static func fullMessageIds(_ db: Database, accountId: String, among ids: [String]) throws -> Set<String> {
        try idSubset(db, accountId: accountId, among: ids, extraCondition: "AND bodyState = 1")
    }

    public static func allMessageIds(_ db: Database, accountId: String) throws -> Set<String> {
        Set(try String.fetchAll(db, sql: "SELECT id FROM message WHERE accountId = ?", arguments: [accountId]))
    }

    public static func messageCount(_ db: Database, accountId: String) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT count(*) FROM message WHERE accountId = ?", arguments: [accountId]) ?? 0
    }

    /// Message ids still missing a body, newest first.
    public static func messageIdsNeedingBody(_ db: Database, accountId: String, limit: Int) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT id FROM message WHERE accountId = ? AND bodyState = 0 ORDER BY date DESC LIMIT ?
            """, arguments: [accountId, limit])
    }

    private static func idSubset(_ db: Database, accountId: String, among ids: [String], extraCondition: String) throws -> Set<String> {
        var found = Set<String>()
        for chunk in chunked(ids, 500) {
            let sql = "SELECT id FROM message WHERE accountId = ? AND id IN (\(databaseQuestionMarks(count: chunk.count))) \(extraCondition)"
            found.formUnion(try String.fetchAll(db, sql: sql, arguments: StatementArguments([accountId] + chunk)))
        }
        return found
    }

    // MARK: Labels

    /// Replaces an account's label list inside the caller's transaction.
    public static func replaceLabels(_ db: Database, accountId: String, with labels: [MailLabel]) throws {
        try db.execute(sql: "DELETE FROM label WHERE accountId = ?", arguments: [accountId])
        for label in labels { try label.insert(db) }
    }

    // MARK: Reconciliation

    /// Label changes of ops Gmail hasn't confirmed yet (pending or inflight), oldest first, by message id.
    public static func unconfirmedLabelChanges(_ db: Database, accountId: String, messageIds: Set<String>? = nil) throws -> [String: [LabelChange]] {
        let ops = try PendingOp
            .filter(Column("accountId") == accountId && Column("kind") == PendingOp.Kind.modifyLabels.rawValue
                && Column("state") != PendingOp.State.failed.rawValue)
            .order(Column("id"))
            .fetchAll(db)
        var result: [String: [LabelChange]] = [:]
        for op in ops {
            guard let payload = try? JSONDecoder().decode(LabelOpPayload.self, from: Data(op.payload.utf8)) else { continue }
            for change in payload.changes where messageIds?.contains(change.messageId) ?? true {
                result[change.messageId, default: []].append(change)
            }
        }
        return result
    }

    /// Writes messages fetched from Gmail, then replays unconfirmed local changes on top so a user
    /// action never visibly reverts while its op is still queued. Downloaded attachment paths are kept.
    /// Rules run for the touched threads (`applyRules`).
    public static func upsertServerMessages(_ db: Database, _ messages: [MailMessage], attachments: [MailAttachment] = []) throws {
        guard !messages.isEmpty || !attachments.isEmpty else { return }
        var attachments = attachments
        if !attachments.isEmpty {
            var paths: [String: String] = [:]
            for (accountId, items) in Dictionary(grouping: attachments, by: \.accountId) {
                for chunk in chunked(Array(Set(items.map(\.messageId))), 500) {
                    let rows = try Row.fetchAll(db, sql: """
                        SELECT messageId, partId, localPath FROM attachment
                        WHERE accountId = ? AND localPath IS NOT NULL AND messageId IN (\(databaseQuestionMarks(count: chunk.count)))
                        """, arguments: StatementArguments([accountId] + chunk))
                    for row in rows {
                        let messageId: String = row["messageId"], partId: String = row["partId"]
                        paths["\(accountId)/\(messageId)/\(partId)"] = row["localPath"]
                    }
                }
            }
            for index in attachments.indices where attachments[index].localPath == nil {
                attachments[index].localPath = paths[attachments[index].id]
            }
        }
        let touched = try upsertMessages(db, messages, attachments: attachments)
        for (accountId, items) in Dictionary(grouping: messages, by: \.accountId) {
            try reapplyUnconfirmedChanges(db, accountId: accountId, messageIds: Set(items.map(\.id)))
        }
        try applyRules(db, keys: touched)
    }

    /// Sets Gmail's current labels on stored messages, then replays unconfirmed local changes.
    /// Messages that aren't stored are ignored; unchanged ones are not rewritten. Rules run for the
    /// threads that changed (`applyRules`).
    public static func applyServerLabels(_ db: Database, accountId: String, _ labelsByMessage: [String: [String]]) throws {
        guard !labelsByMessage.isEmpty else { return }
        let ids = Array(labelsByMessage.keys)
        let changes = try unconfirmedLabelChanges(db, accountId: accountId, messageIds: Set(ids))
        var current: [String: [String]] = [:]
        for chunk in chunked(ids, 500) { current.merge(try messageLabels(db, accountId: accountId, messageIds: chunk)) { $1 } }
        var updates: [String: [String]] = [:]
        for (id, server) in labelsByMessage {
            guard let stored = current[id] else { continue }
            let labels = applying(changes[id] ?? [], to: server)
            if labels != Set(stored) { updates[id] = Array(labels) }
        }
        try applyRules(db, keys: try setLabels(db, accountId: accountId, updates))
    }

    /// Deletes messages Gmail no longer has, then runs rules for the threads left (`applyRules`).
    public static func deleteServerMessages(_ db: Database, accountId: String, ids: [String]) throws {
        try applyRules(db, keys: try deleteMessages(db, accountId: accountId, ids: ids))
    }

    /// Re-applies unconfirmed label changes on top of what's stored for `messageIds`.
    public static func reapplyUnconfirmedChanges(_ db: Database, accountId: String, messageIds: Set<String>) throws {
        let changes = try unconfirmedLabelChanges(db, accountId: accountId, messageIds: messageIds)
        guard !changes.isEmpty else { return }
        let current = try messageLabels(db, accountId: accountId, messageIds: Array(changes.keys))
        var updates: [String: [String]] = [:]
        for (id, stored) in current {
            let labels = applying(changes[id] ?? [], to: stored)
            if labels != Set(stored) { updates[id] = Array(labels) }
        }
        try setLabels(db, accountId: accountId, updates)
    }

    private static func applying(_ changes: [LabelChange], to labels: [String]) -> Set<String> {
        var result = Set(labels)
        for change in changes {
            result.subtract(change.remove)
            result.formUnion(change.add)
        }
        return result
    }

    // MARK: Rules

    /// Rule triage (`RuleClassifier`) and project rules (`ProjectRules`) for threads sync just
    /// changed, in the caller's transaction, so a thread never shows unsorted. Threads that no
    /// longer exist lose their triage, project and snooze rows; a reply ends a snooze (`endSnoozesAnswered`).
    public static func applyRules(_ db: Database, keys: Set<ThreadKey>, now: Date = Date()) throws {
        guard !keys.isEmpty else { return }
        let exists = try db.cachedStatement(sql: "SELECT EXISTS(SELECT 1 FROM thread WHERE accountId = ? AND id = ?)")
        var present: [ThreadKey] = []
        for key in keys {
            if try Bool.fetchOne(exists, arguments: [key.accountId, key.threadId]) == true {
                present.append(key)
            } else {
                for table in ["thread_ai", "thread_project", "snooze"] {
                    try db.execute(sql: "DELETE FROM \(table) WHERE accountId = ? AND threadId = ?", arguments: [key.accountId, key.threadId])
                }
            }
        }
        try endSnoozesAnswered(db, keys: present)
        try RuleClassifier.classify(db, keys: present, now: now)
        try ProjectRules.apply(db, keys: present)
    }

    // MARK: Pending ops

    /// Ops waiting to be sent, in the order they must reach Gmail.
    public static func queuedOps(_ db: Database, accountId: String) throws -> [PendingOp] {
        try PendingOp
            .filter(Column("accountId") == accountId && Column("state") == PendingOp.State.pending.rawValue)
            .order(Column("id"))
            .fetchAll(db)
    }

    public static func pendingOpCounts(_ db: Database) throws -> [String: PendingOpCounts] {
        var counts: [String: PendingOpCounts] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT accountId, sum(state != 'failed') AS queued, sum(state = 'failed') AS failed, max(id) AS maxId
            FROM pending_op GROUP BY accountId
            """) {
            counts[row["accountId"]] = PendingOpCounts(queued: row["queued"] ?? 0, failed: row["failed"] ?? 0, maxId: row["maxId"] ?? 0)
        }
        return counts
    }

    /// After a crash or quit, ops left inflight go back to pending. Label changes are idempotent, and
    /// a send records its progress in the payload so resending it can't deliver it twice.
    public static func recoverInterruptedOps(_ db: Database, accountId: String) throws {
        try db.execute(sql: """
            UPDATE pending_op SET state = 'pending' WHERE accountId = ? AND state = 'inflight'
            """, arguments: [accountId])
    }

    /// Draft ops (save, send, delete) that reference `draftId`.
    public static func draftOps(_ db: Database, draftId: String) throws -> [PendingOp] {
        try PendingOp.fetchAll(db, sql: """
            SELECT * FROM pending_op WHERE kind IN ('sendDraft', 'saveDraft', 'deleteDraft')
              AND json_extract(payload, '$.draftId') = ? ORDER BY id
            """, arguments: [draftId])
    }

    // MARK: Attachments

    public static func setAttachmentPath(_ db: Database, _ attachment: MailAttachment, path: String) throws {
        try db.execute(sql: """
            UPDATE attachment SET localPath = ? WHERE accountId = ? AND messageId = ? AND partId = ?
            """, arguments: [path, attachment.accountId, attachment.messageId, attachment.partId])
    }

    private static func chunked<T>(_ items: [T], _ size: Int) -> [[T]] {
        stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }
}
