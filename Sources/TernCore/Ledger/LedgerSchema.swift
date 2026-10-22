import GRDB

/// The ledger keeps local commitments independently of Gmail labels.
enum LedgerSchema {
    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE commitment (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              accountId TEXT NOT NULL, threadId TEXT NOT NULL,
              direction TEXT NOT NULL, kind TEXT NOT NULL DEFAULT 'deliverable',
              counterpartyEmail TEXT NOT NULL DEFAULT '', counterpartyName TEXT NOT NULL DEFAULT '',
              deliverable TEXT NOT NULL, dueAt DOUBLE, dueText TEXT,
              sourceMessageId TEXT NOT NULL, sourceQuote TEXT NOT NULL DEFAULT '', sourceDate DOUBLE NOT NULL,
              origin TEXT NOT NULL, confidence INTEGER NOT NULL DEFAULT 2,
              state TEXT NOT NULL DEFAULT 'open', stateSource TEXT NOT NULL DEFAULT 'rule',
              resolvedMessageId TEXT, resolvedAt DOUBLE, resolutionNote TEXT,
              hintMessageId TEXT, hintAt DOUBLE, checkedCount INTEGER NOT NULL DEFAULT 0,
              surfaceAt DOUBLE NOT NULL, surfaced INTEGER NOT NULL DEFAULT 0, fingerprint TEXT NOT NULL,
              createdAt DOUBLE NOT NULL, updatedAt DOUBLE NOT NULL,
              FOREIGN KEY (accountId, threadId) REFERENCES thread(accountId, id) ON DELETE CASCADE
            );
            CREATE UNIQUE INDEX commitment_fingerprint ON commitment(accountId, threadId, fingerprint);
            CREATE INDEX commitment_by_thread ON commitment(accountId, threadId);
            CREATE INDEX commitment_list ON commitment(direction, dueAt, sourceDate) WHERE state='open' AND surfaced=1;
            CREATE INDEX commitment_unsurfaced ON commitment(surfaceAt) WHERE state='open' AND surfaced=0;
            CREATE TABLE ledger_scan (
              accountId TEXT NOT NULL, threadId TEXT NOT NULL, messageCount INTEGER NOT NULL,
              scannedAt DOUBLE NOT NULL, origin TEXT NOT NULL, promptVersion INTEGER NOT NULL,
              PRIMARY KEY (accountId, threadId),
              FOREIGN KEY (accountId, threadId) REFERENCES thread(accountId, id) ON DELETE CASCADE
            );
            """)
    }
}
