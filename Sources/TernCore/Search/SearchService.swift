import Foundation
import GRDB

/// Local full-text search over every account, fast enough to run on each keystroke.
///
/// ```swift
/// let search = SearchService(database)
/// let rows = try search.search("from:maya invoice")              // [ThreadRow], newest first
/// let hits = try search.searchHits("from:maya invoice")          // + matched message, snippet, highlights
/// let hints = try search.suggestions(for: "from:ma")             // as the user types
/// ```
///
/// The language is Gmail's (`from:` `to:` `cc:` `bcc:` `subject:` `has:attachment` `filename:` `is:` `in:`
/// `label:` `before:` `after:` `older_than:` `newer_than:` `larger:` `smaller:` `"phrase"` `-not` `OR`
/// parentheses) plus `category:`, `project:`, `account:` and `is:needsreply`. See `SearchQuery`.
/// Trash and spam are left out unless the query says `in:trash`, `in:spam` or `in:anywhere`.
public struct SearchService: Sendable {
    public let database: AppDatabase

    public init(_ database: AppDatabase) {
        self.database = database
    }

    /// Thread rows matching `text`, newest first. The last word matches as a prefix so results update as you
    /// type. Empty input has no results.
    public func search(_ text: String, accountId: String? = nil, limit: Int = 100) throws -> [ThreadRow] {
        try search(SearchQuery(text), options: SearchOptions(accountId: accountId, limit: limit))
    }

    public func search(_ query: SearchQuery, options: SearchOptions = SearchOptions()) throws -> [ThreadRow] {
        try run(query, options, resolveHits: false).map(\.row)
    }

    /// Like `search`, with the message that matched, an excerpt and the matched words' ranges for each thread.
    public func searchHits(_ text: String, options: SearchOptions = SearchOptions()) throws -> [SearchHit] {
        try searchHits(SearchQuery(text), options: options)
    }

    public func searchHits(_ query: SearchQuery, options: SearchOptions = SearchOptions()) throws -> [SearchHit] {
        try run(query, options, resolveHits: true)
    }

    /// `searchHits` for search as you type: cancelling the calling task interrupts the query on its own
    /// connection (other reads and writes go on) and throws `CancellationError`.
    public func interruptibleSearchHits(_ text: String, options: SearchOptions = SearchOptions()) async throws -> [SearchHit] {
        let query = SearchQuery(text)
        guard !query.isEmpty else { return [] }
        do {
            return try await database.reader.read { db in try Self.run(db, query, options, resolveHits: true) }
        } catch let error as DatabaseError where error.isInterruptionError {
            throw CancellationError()
        }
    }

    /// Merges the full-text index into one segment. Searching works without it; run it now and then while idle
    /// (e.g. after a big backfill) to keep the index compact. Can take a few seconds on a large mailbox.
    public func optimizeIndex() throws {
        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO message_fts(message_fts) VALUES('optimize')")
        }
    }

    private func run(_ query: SearchQuery, _ options: SearchOptions, resolveHits: Bool) throws -> [SearchHit] {
        guard !query.isEmpty else { return [] }
        return try database.reader.read { db in try Self.run(db, query, options, resolveHits: resolveHits) }
    }

    private static func run(_ db: Database, _ query: SearchQuery, _ options: SearchOptions, resolveHits: Bool) throws -> [SearchHit] {
        let limit = max(1, min(options.limit, 500))
        guard let compiled = try SearchCompiler(db, options: options).compile(query), !compiled.isImpossible else {
            return []
        }
        let executor = SearchExecutor(db: db, compiled: compiled, limit: limit)
        let found = switch options.sort {
        case .newest: try executor.run(try executor.choosePlan(), resolveMatches: resolveHits)
        case .relevance: try executor.runRanked()
        }
        var rows = try MailStore.fetchThreadRows(db, keys: found.map(\.key))
        if query.includesDone {
            for i in rows.indices {
                let key = rows[i].id
                let completed = try Commitment.fetchAll(db, sql: "SELECT * FROM commitment WHERE accountId=? AND threadId=? AND state='done' AND updatedAt>=? ORDER BY updatedAt DESC LIMIT 20", arguments: [key.accountId, key.threadId, options.now.addingTimeInterval(-14 * 86_400).timeIntervalSince1970])
                guard let item = completed.first, let id = item.id else { continue }
                rows[i].ledger = CommitmentBrief(id: id, counterpartyEmail: item.counterpartyEmail, counterpartyName: item.counterpartyName,
                    sourceDate: item.resolvedAt ?? item.updatedAt, extraCount: completed.count - 1, surfaceAt: item.surfaceAt,
                    deliverable: item.deliverable, completion: item.completionText)
            }
        }
        return try executor.hits(rows: rows, found: found, resolve: resolveHits)
    }
}
