import Foundation
import GRDB
import Testing
@testable import TernCore

@Test(arguments: ["needle", "needle OR second", "école", "from:sender"])
func excerptsMatchTheOriginalSQLIncludingUnicode(query: String) throws {
    let store = MailStore(try AppDatabase.inMemory())
    let account = Account(email: "me@example.com")
    try store.upsertAccount(account)
    let bodies: [String?] = [
        nil, "", "Nothing matches here.", "👩🏽‍💻 Needle\t東京\nsecond e\u{301} école",
        "ÉCOLE école İSTANBUL needle second",
        String(repeating: "préface 👩🏽‍💻 e\u{301} 東京 ", count: 12) + "SECOND needle école "
            + String(repeating: "suffix 🦊 café\n", count: 25),
    ]
    try store.upsertMessages(bodies.enumerated().map { i, body in
        MailMessage(accountId: account.id, id: "m\(i)", threadId: "t\(i)", date: Date(timeIntervalSince1970: Double(i)),
                    fromEmail: "sender@example.com", subject: "needle second école", snippet: "Fallback 🦊 needle",
                    bodyText: body, bodyState: .full, labelIds: ["INBOX"])
    })
    let options = SearchOptions()
    let hits = try SearchService(store.database).searchHits(query, options: options)
    #expect(hits.count == bodies.count)
    try store.database.reader.read { db in
        let compiled = try #require(try SearchCompiler(db, options: options).compile(SearchQuery(query)))
        let terms = compiled.bodyTerms
        let positions = terms.map { _ in "coalesce(nullif(instr(lower(bodyText), ?), 0), 2000000000)" }
        let position = positions.isEmpty ? "2000000000" : positions.count == 1 ? positions[0]
            : "min(" + positions.joined(separator: ", ") + ")"
        // The pre-optimization query is the compatibility reference for SQLite's Unicode character offsets
        // and ASCII-only lower(), including the no-body-match fallback.
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, snippet, pos, CASE WHEN pos < 2000000000
              THEN substr(bodyText, max(1, pos - 60), 200) END AS excerpt
            FROM (SELECT id, snippet, bodyText, \(position) AS pos FROM message)
            """, arguments: StatementArguments(terms))
        for row in rows {
            let id: String = row["id"]
            let hit = try #require(hits.first { $0.matchedMessageId == id })
            let raw: String? = row["excerpt"]
            let pos: Int = row["pos"]
            let expected = raw.map { SearchExecutor.tidy($0, cutAtStart: pos - 60 > 1, cutAtEnd: $0.utf8.count >= 200) }
                ?? (row["snippet"] as String)
            #expect(hit.snippet == expected)
            #expect(hit.highlights == compiled.bodyHighlighter.ranges(in: expected))
            #expect(hit.snippetHighlightRanges.map { NSRange($0, in: hit.snippet) } == hit.highlights)
        }
    }
    if query == "needle" {
        let hit = try #require(hits.first { $0.matchedMessageId == "m3" })
        #expect(hit.snippet == "👩🏽‍💻 Needle 東京 second e\u{301} école")
        #expect(hit.highlights == [NSRange(location: 8, length: 6)])
    }
}
