import Foundation
import GRDB

extension MailStore {
    static func fetchProjectRows(_ db: Database, projectId: String, limit: Int, before: Date?) throws -> [ThreadRow] {
        guard limit != 0 else { return [] }
        // thread_by_date breaks equal dates by rowid, as in All Mail. Keep that order in every path.
        let dateFilter = before == nil ? "" : " AND t.lastDate < ?"
        var arguments: StatementArguments = [projectId]
        if let before { _ = arguments.append(contentsOf: [before.timeIntervalSince1970]) }
        _ = arguments.append(contentsOf: [limit])

        // Try only a bounded prefix of this page's date range. Membership count alone cannot tell
        // whether a large project is recent or scattered across years of unrelated mail.
        let sampleLimit = max(500, limit)
        let hasManyMembers = try limit > 0 && Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM thread_project WHERE projectId = ? LIMIT 1 OFFSET ?)
            """, arguments: [projectId, max(1_000, limit)]) == true
        if hasManyMembers {
            var probeArguments: StatementArguments = [projectId]
            if let before { _ = probeArguments.append(contentsOf: [before.timeIntervalSince1970]) }
            _ = probeArguments.append(contentsOf: [max(4_000, limit)])
            var rowIds: [Int64] = []
            let candidates = try Row.fetchCursor(db, sql: """
                SELECT t.rowid AS threadRowid,
                  CASE WHEN EXISTS (SELECT 1 FROM thread_project p
                    WHERE p.accountId = t.accountId AND p.threadId = t.id AND p.projectId = ?)
                  THEN \(notTrashOrSpam) ELSE 0 END AS eligible
                FROM thread t INDEXED BY thread_by_date
                WHERE 1 \(dateFilter) ORDER BY t.lastDate DESC, t.rowid ASC LIMIT ?
                """, arguments: probeArguments)
            var scanned = 0
            while let candidate = try candidates.next() {
                scanned += 1
                if candidate["eligible"] as Bool {
                    rowIds.append(candidate["threadRowid"])
                    if rowIds.count == limit { break }
                }
                // Continue a moderately sparse walk only if the first sample filled at least a
                // half of the page. Empty/old ranges fall back after that sample.
                if scanned == sampleLimit && rowIds.count < max(1, limit / 2) { break }
            }
            if rowIds.count == limit {
                return try ThreadRow.fetchAll(db, sql: """
                    SELECT \(rowColumns) FROM thread t \(rowJoins)
                    WHERE t.rowid IN (\(databaseQuestionMarks(count: rowIds.count)))
                    ORDER BY t.lastDate DESC, t.rowid ASC
                    """, arguments: StatementArguments(rowIds))
            }
        }

        if !hasManyMembers {
            return try ThreadRow.fetchAll(db, sql: """
                SELECT \(rowColumns) FROM thread_project p
                JOIN thread t ON t.accountId = p.accountId AND t.id = p.threadId
                \(rowJoins)
                WHERE p.projectId = ? AND \(notTrashOrSpam) \(dateFilter)
                ORDER BY t.lastDate DESC, t.rowid ASC LIMIT ?
                """, arguments: arguments)
        }

        // Sort only member keys. Hydrate the selected page after LIMIT, so old and sparse projects
        // don't join AI, snooze and project metadata for every member that the sort discards.
        return try ThreadRow.fetchAll(db, sql: """
            WITH page AS MATERIALIZED (
              SELECT t.rowid AS threadRowid, t.lastDate FROM thread_project p
              JOIN thread t ON t.accountId = p.accountId AND t.id = p.threadId
              WHERE p.projectId = ? AND \(notTrashOrSpam) \(dateFilter)
              ORDER BY t.lastDate DESC, t.rowid ASC LIMIT ?
            )
            SELECT \(rowColumns) FROM page
            JOIN thread t ON t.rowid = page.threadRowid
            \(rowJoins)
            ORDER BY t.lastDate DESC, t.rowid ASC
            """, arguments: arguments)
    }
}
