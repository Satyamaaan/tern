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

    private func run(_ query: SearchQuery, _ options: SearchOptions, resolveHits: Bool) throws -> [SearchHit] {
        guard !query.isEmpty else { return [] }
        let limit = max(1, min(options.limit, 500))
        return try database.reader.read { db in
            guard let compiled = try SearchCompiler(db, options: options).compile(query), !compiled.isImpossible else {
                return []
            }
            let executor = SearchExecutor(db: db, compiled: compiled)
            let keys = switch options.sort {
            case .newest: try executor.threadKeys(plan: try executor.choosePlan(), limit: limit)
            case .relevance: try executor.rankedThreadKeys(limit: limit)
            }
            let rows = try MailStore.fetchThreadRows(db, keys: keys)
            return try executor.hits(for: rows, resolve: resolveHits)
        }
    }
}
