import Foundation
import GRDB

/// Local full-text search over every account. Placeholder: plain terms only, newest first.
/// The search lane replaces the internals (operators, ranking, highlights) behind this API.
public struct SearchService: Sendable {
    public let database: AppDatabase

    public init(_ database: AppDatabase) {
        self.database = database
    }

    /// Thread rows matching `text`, newest first. The last word matches as a prefix so results
    /// update as you type.
    public func search(_ text: String, accountId: String? = nil, limit: Int = 100) throws -> [ThreadRow] {
        let words = text.split(whereSeparator: \.isWhitespace).map { String($0).replacingOccurrences(of: "\"", with: "") }
        guard !words.isEmpty else { return [] }
        let match = words.enumerated().map { index, word in
            index == words.count - 1 ? "\"\(word)\"*" : "\"\(word)\""
        }.joined(separator: " ")

        return try database.reader.read { db in
            var sql = """
                SELECT m.accountId, m.threadId, max(m.date) AS d FROM message_fts f
                JOIN message m ON m.seq = f.rowid
                WHERE message_fts MATCH ?
                """
            var arguments: StatementArguments = [match]
            if let accountId { sql += " AND m.accountId = ?"; _ = arguments.append(contentsOf: [accountId]) }
            sql += " GROUP BY m.accountId, m.threadId ORDER BY d DESC LIMIT ?"
            _ = arguments.append(contentsOf: [limit])
            let keys = try Row.fetchAll(db, sql: sql, arguments: arguments).map {
                ThreadKey(accountId: $0["accountId"], threadId: $0["threadId"])
            }
            return try MailStore.fetchThreadRows(db, keys: keys)
        }
    }
}
