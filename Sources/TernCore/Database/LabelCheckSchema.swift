import GRDB

/// Messages whose labels a resync could only approximate (stored Trash and Spam beyond what it reads
/// at once), waiting for the sync engine to read Gmail's. Registered as `fixsync-2` in `Schema.register`.
enum LabelCheckSchema {
    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE label_check (
              accountId TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
              messageId TEXT NOT NULL,
              PRIMARY KEY (accountId, messageId)
            );
            """)
    }
}
