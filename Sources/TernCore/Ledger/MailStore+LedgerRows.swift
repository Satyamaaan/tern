import GRDB

extension MailStore {
    static func fetchLedgerRows(_ db: Database, in mailbox: Mailbox, limit: Int) throws -> [ThreadRow] {
        let settings = try LedgerSettings.load(db)
        guard settings.enabled else { return [] }
        let confidence = settings.showMaybe ? "" : " AND confidence=2"
        let scope = mailbox.accountId == nil ? "" : " AND accountId=?"
        var arguments: StatementArguments = [mailbox.kind == .waitingOn ? "waitingOn" : "iOwe"]
        if let account = mailbox.accountId { arguments += [account] }
        arguments += [limit]
        return try ThreadRow.fetchAll(db, sql: """
            WITH ranked AS (
              SELECT *, row_number() OVER (PARTITION BY accountId,threadId ORDER BY dueAt IS NULL,dueAt,sourceDate,id) AS rank,
                count(*) OVER (PARTITION BY accountId,threadId)-1 AS extra
              FROM commitment WHERE state='open' AND surfaced=1 AND direction=?\(confidence)\(scope)
            )
            SELECT \(rowColumns), c.id AS ledgerId,c.counterpartyEmail AS ledgerEmail,c.counterpartyName AS ledgerName,
              c.sourceDate AS ledgerDate,c.extra AS ledgerExtra,c.surfaceAt AS ledgerSurface
            FROM ranked c JOIN thread t ON t.accountId=c.accountId AND t.id=c.threadId \(rowJoins)
            WHERE c.rank=1 ORDER BY c.dueAt IS NULL,c.dueAt,c.sourceDate,c.id LIMIT ?
            """, arguments: arguments)
    }

    static func fetchLedgerCount(_ db: Database, accountId: String?) throws -> Int {
        let settings = try LedgerSettings.load(db)
        guard settings.enabled else { return 0 }
        let scope = accountId == nil ? "" : " AND accountId=?"
        let confidence = settings.showMaybe ? "" : " AND confidence=2"
        return try Int.fetchOne(db, sql: """
            SELECT count(*) FROM (SELECT accountId,threadId FROM commitment
              WHERE state='open' AND surfaced=1 AND direction='waitingOn'\(scope)\(confidence) GROUP BY accountId,threadId)
            """, arguments: accountId.map { [$0] } ?? []) ?? 0
    }
}
