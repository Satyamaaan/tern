import Foundation
import GRDB
import TernCore

// Exact labels for messages a full resync could only approximate. After history expires, the resync
// reads stored Trash and Spam directly only up to `resyncHiddenRefreshLimit` messages; beyond that it
// moves them to Trash or Spam locally and queues them in `label_check`, and these background steps
// read Gmail's labels for them, a few at a time, within the quota left over.
extension AccountSync {
    /// Queues messages for `labelCheckStep`, inside the caller's transaction.
    static func queueLabelChecks(_ db: Database, accountId: String, ids: [String]) throws {
        let insert = try db.cachedStatement(sql: "INSERT OR IGNORE INTO label_check (accountId, messageId) VALUES (?, ?)")
        for id in ids { try insert.execute(arguments: [accountId, id]) }
    }

    /// Whether `label_check` has anything for this account; clears `labelChecksPending` when not.
    func hasLabelChecks() async throws -> Bool {
        let accountId = self.accountId
        let any = try await read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM label_check WHERE accountId = ?)", arguments: [accountId]) ?? false
        }
        if !any { labelChecksPending = false }
        return any
    }

    /// Reads Gmail's labels (minimal format) for the next queued messages and stores them, replaying
    /// unconfirmed local changes; those Gmail no longer has are deleted. They leave the queue in the
    /// same write, so a quit resumes where it stopped. Returns true while more remain.
    @discardableResult
    public func labelCheckStep() async throws -> Bool {
        let accountId = self.accountId
        let limit = batchSize(cost: configuration.quota.getMessage)
        let ids = try await read { db in
            try String.fetchAll(db, sql: "SELECT messageId FROM label_check WHERE accountId = ? ORDER BY rowid LIMIT ?",
                                arguments: [accountId, limit])
        }
        guard !ids.isEmpty else {
            labelChecksPending = false
            return false
        }
        let fetched = try await withRetry { [api] in try await api.messages(ids: ids, format: .minimal) }
        let returned = Set(fetched.map(\.id))
        let labels = Dictionary(fetched.map { ($0.id, $0.labelIds ?? []) }, uniquingKeysWith: { $1 })
        let gone = ids.filter { !returned.contains($0) }
        try await writeServer { db in
            try MailStore.applyServerLabels(db, accountId: accountId, labels)
            try MailStore.deleteServerMessages(db, accountId: accountId, ids: gone)
            try db.execute(sql: """
                DELETE FROM label_check WHERE accountId = ? AND messageId IN (\(databaseQuestionMarks(count: ids.count)))
                """, arguments: StatementArguments([accountId] + ids))
        }
        return true
    }
}
