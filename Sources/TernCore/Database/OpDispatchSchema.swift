import GRDB

/// Records on each queued op whether a request for it may have reached Gmail. Registered as `fixsync-1`
/// in `Schema.register`.
enum OpDispatchSchema {
    static func migrate(_ db: Database) throws {
        // Ops that were tried, failed or are in flight may have reached Gmail already.
        try db.execute(sql: """
            ALTER TABLE pending_op ADD COLUMN dispatched INTEGER NOT NULL DEFAULT 0;
            UPDATE pending_op SET dispatched = 1 WHERE attempts > 0 OR lastError IS NOT NULL OR state != 'pending';
            """)
    }
}
