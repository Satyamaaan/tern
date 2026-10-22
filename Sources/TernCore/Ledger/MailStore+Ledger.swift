import Foundation
import GRDB

extension MailStore {
    /// Changes local ledger state without creating a pending Gmail operation.
    public func setCommitmentState(_ ids: [Int64], to state: CommitmentState) throws -> LedgerUndo {
        try database.writer.write { try Self.setCommitmentState($0, ids, to: state) }
    }

    /// Transaction variant for callers already on the database writer.
    public static func setCommitmentState(_ db: Database, _ ids: [Int64], to state: CommitmentState, now: Date = Date()) throws -> LedgerUndo {
        let previous = try Commitment.filter(ids.contains(Column("id"))).fetchAll(db)
        for var item in previous {
            item.state = state
            item.stateSource = "user"
            if state == .done { item.resolvedAt = now; item.resolutionNote = "Marked done by you" }
            item.updatedAt = now
            if state == .open {
                item.resolvedMessageId = nil; item.resolvedAt = nil; item.resolutionNote = nil
                item.hintMessageId = nil; item.hintAt = nil
                item.surfaced = true
            }
            try item.update(db)
        }
        return LedgerUndo(previous: previous)
    }

    /// Restores every previous field, including the automation lock.
    public func restoreCommitments(_ undo: LedgerUndo) throws {
        try database.writer.write { try Self.restoreCommitments($0, undo) }
    }

    /// Restores rows inside an existing writer transaction.
    public static func restoreCommitments(_ db: Database, _ undo: LedgerUndo) throws {
        _ = try Commitment.filter(undo.created.contains(Column("id"))).deleteAll(db)
        for item in undo.previous { try item.update(db) }
    }

    /// Commitments for actions on a selected or open thread, including completed items for reopening.
    public func commitments(on keys: [ThreadKey]) throws -> [Commitment] {
        try database.reader.read { db in
            try keys.flatMap { key in
                try Commitment.fetchAll(db, sql: "SELECT * FROM commitment WHERE accountId=? AND threadId=? ORDER BY sourceDate", arguments: [key.accountId, key.threadId])
            }
        }
    }

    /// Bounded probes for menu availability, without decoding every commitment on the main thread.
    public func hasCommitments(on keys: [ThreadKey], state: CommitmentState? = nil) throws -> Bool {
        guard !keys.isEmpty, keys.count <= 50 else { return false }
        return try database.reader.read { db in
            let pairs = keys.map { _ in "(?,?)" }.joined(separator: ",")
            var arguments = StatementArguments(keys.flatMap { [$0.accountId, $0.threadId] })
            if let state { arguments += [state.rawValue] }
            return try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM commitment WHERE (accountId,threadId) IN (\(pairs))" + (state == nil ? "" : " AND state=?") + " LIMIT 1)", arguments: arguments) ?? false
        }
    }

    /// Updates follow-up preferences and existing rule thresholds in the same transaction.
    public func setLedgerSettings(enabled: Bool, waitingDays: Int, now: Date = Date()) throws {
        guard [2, 3, 5, 7].contains(waitingDays) else { return }
        let previous = try database.reader.read { try LedgerSettings.load($0) }
        guard previous.enabled != enabled || previous.waitingDays != waitingDays else { return }
        try database.writer.write { db in
            try Setting(key: "ledger.enabled", value: enabled ? "true" : "false").upsert(db)
            try Setting(key: "ledger.waitingDays", value: String(waitingDays)).upsert(db)
            try db.execute(sql: "UPDATE commitment SET surfaceAt=sourceDate+?, surfaced=CASE WHEN stateSource='user' THEN surfaced ELSE (sourceDate+?<=?) END, updatedAt=CASE WHEN stateSource='user' THEN updatedAt ELSE ? END WHERE origin='rule' AND state='open'",
                           arguments: [Double(waitingDays) * 86_400, Double(waitingDays) * 86_400, now.timeIntervalSince1970, now.timeIntervalSince1970])
            try Ledger.sweep(db, now: now)
        }
        if enabled {
            let database = database
            Task.detached(priority: .utility) { try? Ledger.rebuildWaiting(in: database, now: now) }
        }
    }
}
