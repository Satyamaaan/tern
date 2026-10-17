import Foundation
import GRDB

/// A thread that matched, with why: the message that matched and an excerpt with the matched words marked.
public struct SearchHit: Identifiable, Sendable {
    public var row: ThreadRow
    /// The newest message in the thread that satisfies the query. Nil for queries about the thread as a whole
    /// (`is:unread`, `in:inbox`, `label:`…).
    public var matchedMessageId: String?
    public var matchedAt: Date?
    /// A short plain-text excerpt (one line): around the first match in the message body when the body
    /// matched, otherwise the message's own snippet.
    public var snippet: String
    /// UTF-16 ranges of the matched words inside `snippet` (use with `NSAttributedString`).
    public var highlights: [NSRange]
    /// UTF-16 ranges of the matched words inside `row.thread.subject`.
    public var subjectHighlights: [NSRange]

    public var id: ThreadKey { row.id }

    /// `highlights` as ranges of `snippet` for `AttributedString` and `Text` styling.
    public var snippetHighlightRanges: [Range<String.Index>] {
        highlights.compactMap { Range($0, in: snippet) }
    }
}

extension SearchExecutor {
    private struct Candidate {
        var seq: Int64
        var id: String
        var date: Double
        var snippet: String
    }

    /// Builds hits for `rows` (already in result order).
    func hits(for rows: [ThreadRow], resolve: Bool) throws -> [SearchHit] {
        guard resolve, compiled.hasMessageConditions else {
            return rows.map {
                SearchHit(
                    row: $0, matchedMessageId: nil, matchedAt: nil, snippet: $0.thread.snippet, highlights: [],
                    subjectHighlights: compiled.highlighter.ranges(in: $0.thread.subject))
            }
        }

        // 1. Each thread's messages that satisfy the conditions that are not about words.
        let filter = SQLFragment.all(compiled.messageConds)
        let select = try db.cachedStatement(sql: """
            SELECT m.seq, m.id, m.date, m.snippet FROM message m
            WHERE m.accountId = ? AND m.threadId = ? AND \(filter.sql) ORDER BY m.date DESC
            """)
        var candidates: [ThreadKey: [Candidate]] = [:]
        for row in rows {
            let arguments = StatementArguments([row.thread.accountId.databaseValue, row.thread.id.databaseValue] + filter.arguments)
            candidates[row.id] = try Row.fetchAll(select, arguments: arguments).map {
                Candidate(seq: $0[0], id: $0[1], date: $0[2], snippet: $0[3])
            }
        }

        // 2. Of those, the ones the words match, with excerpts.
        var excerpts: [Int64: (body: String?, snippet: String?)] = [:]
        if let fts = compiled.fts {
            let list = candidates.values.flatMap { $0.map { String($0.seq) } }.joined(separator: ",")
            if !list.isEmpty {
                for row in try Row.fetchAll(db, sql: """
                    SELECT rowid, snippet(message_fts, 4, char(1), char(2), '…', 14),
                           snippet(message_fts, 3, char(1), char(2), '…', 14)
                    FROM message_fts WHERE message_fts MATCH ? AND rowid IN (\(list))
                    """, arguments: [fts]) {
                    excerpts[row[0]] = (row[1], row[2])
                }
            }
        }

        // 3. The newest matching message per thread.
        return rows.map { row in
            let all = candidates[row.id] ?? []
            let match = all.first { compiled.fts == nil || excerpts[$0.seq] != nil }
            var snippet = row.thread.snippet
            var highlights: [NSRange] = []
            if let match {
                let excerpt = excerpts[match.seq]
                if let marked = Self.parseMarked(excerpt?.body) ?? Self.parseMarked(excerpt?.snippet) {
                    (snippet, highlights) = marked
                } else {
                    snippet = match.snippet.isEmpty ? row.thread.snippet : match.snippet
                    highlights = compiled.highlighter.ranges(in: snippet)
                }
            }
            return SearchHit(
                row: row, matchedMessageId: match?.id, matchedAt: match.map { Date(timeIntervalSince1970: $0.date) },
                snippet: snippet, highlights: highlights,
                subjectHighlights: compiled.highlighter.ranges(in: row.thread.subject))
        }
    }

    /// Turns an FTS5 `snippet()` result (matches wrapped in U+0001…U+0002) into one line of text and the
    /// UTF-16 ranges of the marked words. Nil when nothing in it is marked.
    static func parseMarked(_ marked: String?) -> (String, [NSRange])? {
        guard let marked, marked.unicodeScalars.contains("\u{1}") else { return nil }
        var text = String.UnicodeScalarView()
        var ranges: [NSRange] = []
        var start: Int?
        var offset = 0
        var pendingSpace = false
        for scalar in marked.unicodeScalars {
            switch scalar {
            case "\u{1}":
                if pendingSpace && offset > 0 { text.append(" "); offset += 1 }
                pendingSpace = false
                start = offset
            case "\u{2}":
                if let begin = start, offset > begin { ranges.append(NSRange(location: begin, length: offset - begin)) }
                start = nil
            default:
                if scalar.properties.isWhitespace {
                    pendingSpace = true
                    continue
                }
                if pendingSpace && offset > 0 { text.append(" "); offset += 1 }
                pendingSpace = false
                text.append(scalar)
                offset += scalar.utf16.count
            }
        }
        guard !ranges.isEmpty else { return nil }
        return (String(text), ranges)
    }
}
