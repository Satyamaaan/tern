import GRDB

extension MailStore {
    // Correlated indexed label probes also hide user-reopened items without changing their state.
    private static let ledgerVisible = """
        NOT EXISTS (SELECT 1 FROM thread_label x INDEXED BY thread_label_by_thread WHERE x.accountId=commitment.accountId AND x.threadId=commitment.threadId
          AND (x.labelId IN ('TRASH','SPAM','TERN_PENDING_MUTED') OR x.labelId=(SELECT value FROM setting WHERE key='mute.label.' || commitment.accountId)))
        """

    static func fetchLedgerRows(_ db: Database, in mailbox: Mailbox, limit: Int) throws -> [ThreadRow] {
        let settings = try LedgerSettings.load(db)
        guard settings.enabled else { return [] }
        let confidence = settings.showMaybe ? "" : " AND confidence=2"
        let scope = mailbox.accountId == nil ? "" : " AND accountId=?"
        var arguments: StatementArguments = [mailbox.kind == .waitingOn ? "waitingOn" : "iOwe"]
        if let account = mailbox.accountId { arguments += [account] }
        arguments += [limit]
        var rows = try ThreadRow.fetchAll(db, sql: """
            WITH ranked AS (
              SELECT *, row_number() OVER (PARTITION BY accountId,threadId ORDER BY hintAt IS NOT NULL,dueAt IS NULL,dueAt,sourceDate,id) AS rank,
                count(*) OVER (PARTITION BY accountId,threadId)-1 AS extra
              FROM commitment WHERE \(ledgerVisible) AND state='open' AND surfaced=1 AND direction=?\(confidence)\(scope)
            )
            SELECT \(rowColumns), c.id AS ledgerId,c.counterpartyEmail AS ledgerEmail,c.counterpartyName AS ledgerName,
              c.sourceDate AS ledgerDate,c.extra AS ledgerExtra,c.surfaceAt AS ledgerSurface,CASE WHEN c.kind='deliverable' THEN c.deliverable END AS ledgerDeliverable,c.dueAt AS ledgerDue,c.hintAt IS NOT NULL AS ledgerHint,c.confidence=1 AS ledgerMaybe
            FROM ranked c JOIN thread t ON t.accountId=c.accountId AND t.id=c.threadId \(rowJoins)
            WHERE c.rank=1 ORDER BY c.hintAt IS NOT NULL,c.dueAt IS NULL,c.dueAt,c.sourceDate,c.id LIMIT ?
            """, arguments: arguments)
        for index in rows.indices { rows[index].ledger?.direction = mailbox.kind == .iOwe ? .iOwe : .waitingOn }
        return rows
    }

    static func fetchLedgerCount(_ db: Database, accountId: String?, direction: LedgerDirection = .waitingOn) throws -> Int {
        let settings = try LedgerSettings.load(db)
        guard settings.enabled else { return 0 }
        let scope = accountId == nil ? "" : " AND accountId=?"
        let confidence = settings.showMaybe ? "" : " AND confidence=2"
        return try Int.fetchOne(db, sql: """
            SELECT count(*) FROM (SELECT accountId,threadId FROM commitment
              WHERE \(ledgerVisible) AND state='open' AND surfaced=1 AND direction=?\(scope)\(confidence) GROUP BY accountId,threadId)
            """, arguments: StatementArguments([direction.rawValue] + (accountId.map { [$0] } ?? []))) ?? 0
    }
}
