import Foundation
import GRDB

/// A thread that matched, with why: the message that matched and an excerpt with the matched words marked.
public struct SearchHit: Identifiable, Sendable {
    public var row: ThreadRow
    /// The newest message in the thread that satisfies the query (the best-scoring one when sorted by
    /// relevance). Nil for queries about the thread as a whole (`is:unread`, `in:inbox`, `label:`…).
    public var matchedMessageId: String?
    public var matchedAt: Date?
    /// A short plain-text excerpt (one line): around the first occurrence of a search word in the message
    /// body when there is one, otherwise the message's own snippet.
    public var snippet: String

    let snippetHighlighter: SearchHighlighter
    let subjectHighlighter: SearchHighlighter

    init(row: ThreadRow, matchedMessageId: String? = nil, matchedAt: Date? = nil, snippet: String,
         snippetHighlighter: SearchHighlighter, subjectHighlighter: SearchHighlighter) {
        self.row = row
        self.matchedMessageId = matchedMessageId
        self.matchedAt = matchedAt
        self.snippet = snippet
        self.snippetHighlighter = snippetHighlighter
        self.subjectHighlighter = subjectHighlighter
    }

    public var id: ThreadKey { row.id }

    /// UTF-16 ranges of the matched words inside `snippet` (use with `NSAttributedString`). Found when asked
    /// (microseconds), so ask for the rows you show, not for all of them.
    public var highlights: [NSRange] { snippetHighlighter.ranges(in: snippet) }

    /// UTF-16 ranges of the matched words inside `row.thread.subject`. Found when asked, like `highlights`.
    public var subjectHighlights: [NSRange] { subjectHighlighter.ranges(in: row.thread.subject) }

    /// `highlights` as ranges of `snippet` for `AttributedString` and `Text` styling.
    public var snippetHighlightRanges: [Range<String.Index>] {
        highlights.compactMap { Range($0, in: snippet) }
    }
}

extension SearchExecutor {
    private static let noMatch = 2_000_000_000
    private static let excerptLead = 60
    private static let excerptLength = 200

    private struct Excerpt {
        var id: String
        var date: Double
        var snippet: String
        /// Around the first search word in the body; nil when there is none.
        var body: String?
    }

    /// Builds hits for `rows` (already in result order). With `resolve` off, hits carry only the thread.
    func hits(rows: [ThreadRow], found: [Found], resolve: Bool) throws -> [SearchHit] {
        let bySeq = Dictionary(found.map { ($0.key, $0.messageSeq) }, uniquingKeysWith: { first, _ in first })
        let resolve = resolve && compiled.hasMessageConditions
        let excerpts = resolve ? try loadExcerpts(Array(Set(found.compactMap(\.messageSeq)))) : [:]

        return rows.map { row in
            var hit = SearchHit(
                row: row, snippet: row.thread.snippet,
                snippetHighlighter: compiled.bodyHighlighter, subjectHighlighter: compiled.subjectHighlighter)
            guard resolve, let seq = bySeq[row.id] ?? nil, let excerpt = excerpts[seq] else { return hit }
            hit.matchedMessageId = excerpt.id
            hit.matchedAt = Date(timeIntervalSince1970: excerpt.date)
            hit.snippet = excerpt.body ?? (excerpt.snippet.isEmpty ? row.thread.snippet : excerpt.snippet)
            return hit
        }
    }

    /// Message id, date and snippet, plus a body excerpt around the first search word. The position comes from
    /// `instr()`, so the body text never leaves SQLite except for the excerpt itself.
    private func loadExcerpts(_ seqs: [Int64]) throws -> [Int64: Excerpt] {
        guard !seqs.isEmpty else { return [:] }
        let terms = compiled.bodyTerms
        let positions = terms.map { _ in "coalesce(nullif(instr(lower(bodyText), ?), 0), \(Self.noMatch))" }
        let position = switch positions.count {
        case 0: "\(Self.noMatch)"
        case 1: positions[0]
        default: "min(" + positions.joined(separator: ", ") + ")"
        }
        let list = seqs.map(String.init).joined(separator: ",")
        // Keep only positions in the temporary table: compute each once without copying full bodies.
        let rows = try Row.fetchAll(db, sql: """
            WITH positions AS MATERIALIZED (
              SELECT seq, \(position) AS pos FROM message WHERE seq IN (\(list))
            )
            SELECT m.seq, m.id, m.date, m.snippet, p.pos, CASE WHEN p.pos < \(Self.noMatch)
              THEN substr(m.bodyText, max(1, p.pos - \(Self.excerptLead)), \(Self.excerptLength)) END
            FROM positions p JOIN message m ON m.seq = p.seq
            """, arguments: StatementArguments(terms))

        var result: [Int64: Excerpt] = [:]
        for row in rows {
            let position: Int = row[4]
            let raw: String? = row[5]
            result[row[0]] = Excerpt(
                id: row[1], date: row[2], snippet: row[3],
                body: raw.map { Self.tidy($0, cutAtStart: position - Self.excerptLead > 1, cutAtEnd: $0.utf8.count >= Self.excerptLength) })
        }
        return result
    }

    /// One line, whitespace collapsed, no half words at the cut edges. Works on bytes: the characters it
    /// moves (ASCII whitespace) can never be part of a multi-byte character.
    static func tidy(_ raw: String, cutAtStart: Bool, cutAtEnd: Bool) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(raw.utf8.count)
        var pendingSpace = false
        for byte in raw.utf8 {
            if byte == 0x20 || (byte >= 0x09 && byte <= 0x0D) {
                pendingSpace = !bytes.isEmpty
            } else {
                if pendingSpace { bytes.append(0x20); pendingSpace = false }
                bytes.append(byte)
            }
        }
        var range = bytes.startIndex..<bytes.endIndex
        if cutAtStart, let space = bytes[range].firstIndex(of: 0x20) { range = (space + 1)..<range.upperBound }
        if cutAtEnd, let space = bytes[range].lastIndex(of: 0x20), space > range.lowerBound { range = range.lowerBound..<space }
        var result: [UInt8] = []
        if cutAtStart { result += [0xE2, 0x80, 0xA6] }
        result += bytes[range]
        if cutAtEnd { result += [0xE2, 0x80, 0xA6] }
        return String(decoding: result, as: UTF8.self)
    }
}
