import GRDB

/// `archive-1`: each account's threads by date, so one account's Archive and All mail read their pages from
/// an index instead of sorting every thread the account has.
enum ArchiveSchema {
    static func migrate(_ db: Database) throws {
        try db.execute(sql: "CREATE INDEX thread_by_account_date ON thread(accountId, lastDate DESC)")
    }
}
