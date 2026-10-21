import Foundation
import GRDB

extension DraftStore {
    /// Autocomplete for a recipient field. Matches the start of the address, of its domain or any
    /// dot-separated part, and the start of any word of the name. Ranked by
    /// `(sentCount × 3 + receivedCount)`, decaying with time since last contact (90-day half-weight).
    /// Your own accounts and no-reply addresses are left out. An empty prefix gives recent recipients.
    public func suggestRecipients(
        prefix: String, limit: Int = 8, excluding: Set<String> = [], now: Date = Date()
    ) throws -> [Participant] {
        let query = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        return try database.reader.read { db in
            let own = Set(try String.fetchAll(db, sql: "SELECT id FROM account"))
            let skip = own.union(excluding.map { $0.lowercased() })
            guard !query.isEmpty else { return try Self.recentRecipients(db, limit: limit, excluding: skip) }

            let like = Self.escapeLike(query)
            let contacts = try Contact.fetchAll(db, sql: """
                SELECT * FROM contact
                WHERE id LIKE :starts ESCAPE '\\' OR id LIKE :domain ESCAPE '\\' OR id LIKE :part ESCAPE '\\'
                   OR name LIKE :starts ESCAPE '\\' OR name LIKE :word ESCAPE '\\'
                ORDER BY (sentCount * 3 + receivedCount) / (1.0 + max(0, :now - coalesce(lastContacted, 0)) / 7776000.0) DESC,
                         lastContacted DESC
                LIMIT :limit
                """, arguments: [
                    "starts": "\(like)%", "domain": "%@\(like)%", "part": "%.\(like)%", "word": "% \(like)%",
                    "now": now.timeIntervalSince1970, "limit": limit + skip.count + 8,
                ])
            let wantsNoReply = query.hasPrefix("no") || query.hasPrefix("do")
            return Array(contacts
                .filter { !skip.contains($0.id) && (wantsNoReply || !Self.isNoReply($0.id)) }
                .map { Participant(name: $0.name, email: $0.id) }
                .prefix(limit))
        }
    }

    /// Whether a suggestion still fits `prefix` by the rules of `suggestRecipients`, so a field can narrow what it
    /// shows while the suggestions for new text are read. Text compares as SQLite's LIKE compares it: only A–Z
    /// ignore case, and characters match exactly, so "É" doesn't find "émile" here or in the query.
    public static func suggestion(_ person: Participant, fits prefix: String) -> Bool {
        let query = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return false }
        let wantsNoReply = query.hasPrefix("no") || query.hasPrefix("do")
        guard wantsNoReply || !isNoReply(person.email) else { return false }
        let email = likeFolded(person.email), name = likeFolded(person.name)
        func starts(_ text: String) -> Bool { text.range(of: query, options: [.literal, .anchored]) != nil }
        func has(_ text: String, after mark: String) -> Bool { text.range(of: mark + query, options: .literal) != nil }
        return starts(email) || has(email, after: "@") || has(email, after: ".") || starts(name) || has(name, after: " ")
    }

    /// `text` with A–Z lowercased and everything else as it is, the case folding of SQLite's LIKE.
    static func likeFolded(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            ("A"..."Z").contains(scalar) ? Unicode.Scalar(scalar.value + 32) ?? scalar : scalar
        }))
    }

    /// People you wrote to most recently, newest first.
    public func recentRecipients(limit: Int = 8) throws -> [Participant] {
        try database.reader.read { db in
            let own = Set(try String.fetchAll(db, sql: "SELECT id FROM account"))
            return try Self.recentRecipients(db, limit: limit, excluding: own)
        }
    }

    static func recentRecipients(_ db: Database, limit: Int, excluding: Set<String>) throws -> [Participant] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT toList, ccList FROM message WHERE isFromMe = 1 AND isDraft = 0 ORDER BY date DESC LIMIT 80
            """)
        let decoder = JSONDecoder()
        var people: [Participant] = []
        for row in rows {
            for column in ["toList", "ccList"] {
                let json: String = row[column]
                people += (try? decoder.decode([Participant].self, from: Data(json.utf8))) ?? []
            }
        }
        return Array(RecipientParser.deduplicated(people, excluding: excluding).filter { !isNoReply($0.email) }.prefix(limit))
    }

    /// Counts a send right away so autocomplete learns before the next full contact rebuild.
    static func noteContacted(_ db: Database, _ people: [Participant], at date: Date) throws {
        let statement = try db.cachedStatement(sql: """
            INSERT INTO contact (id, name, sentCount, receivedCount, lastContacted) VALUES (?, ?, 1, 0, ?)
            ON CONFLICT(id) DO UPDATE SET
              sentCount = sentCount + 1,
              lastContacted = max(coalesce(lastContacted, 0), excluded.lastContacted),
              name = CASE WHEN name = '' THEN excluded.name ELSE name END
            """)
        for person in RecipientParser.deduplicated(people) where RecipientParser.isValidEmail(person.email) {
            try statement.execute(arguments: [person.email.lowercased(), person.name, date.timeIntervalSince1970])
        }
    }

    static func isNoReply(_ email: String) -> Bool {
        let local = email.lowercased().split(separator: "@").first.map(String.init) ?? ""
        return ["noreply", "no-reply", "no_reply", "donotreply", "do-not-reply", "mailer-daemon", "bounce"].contains { local.contains($0) }
    }

    static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
