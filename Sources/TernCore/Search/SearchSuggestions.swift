import Foundation
import GRDB

/// One line in the dropdown under the search box.
public struct SearchSuggestion: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        /// A person, for `from:` / `to:` / `cc:` / `bcc:`.
        case contact
        case label
        case project
        case category
        case account
        /// An operator to start typing (`from:`, `is:unread`…).
        case `operator`
        case recent
    }

    public var kind: Kind
    /// What the row shows.
    public var title: String
    /// Secondary text: an address, a count, a hint.
    public var detail: String?
    /// The whole search text after choosing this row, ready to put in the search box.
    public var completion: String
    /// Whether choosing it should search at once (a recent search) or let the user keep typing.
    public var runsImmediately: Bool

    public var id: String { "\(kind.rawValue):\(completion)" }
}

extension SearchService {
    static let recentSearchesKey = "search.recent"
    static let recentSearchLimit = 20

    /// Suggestions for the text typed so far, most useful first. Looks at the last word only: after `from:ma`
    /// the people whose name or address starts with "ma", after `label:` the labels, and so on. With nothing
    /// typed, the recent searches; with a plain word, recent searches that start with it, then operators.
    public func suggestions(for partial: String, limit: Int = 8) throws -> [SearchSuggestion] {
        let limit = max(1, limit)
        let (head, word) = Self.splitLastWord(partial)

        guard !word.text.isEmpty || word.op != nil else {
            // Nothing typed (or only spaces): recent searches.
            return Array(try recentSearches().prefix(limit).map(Self.recentSuggestion))
        }

        if let op = word.op {
            return try database.reader.read { db in
                try Self.suggestions(db, op: op, value: word.text, head: head, quoted: word.quoted, limit: limit)
            }
        }

        // A plain word: finished searches that begin with it, then operators it could become.
        var result: [SearchSuggestion] = []
        let typed = partial.trimmingCharacters(in: .whitespaces).lowercased()
        for recent in try recentSearches() where recent.lowercased().hasPrefix(typed) && recent.lowercased() != typed {
            result.append(Self.recentSuggestion(recent))
        }
        let lower = word.text.lowercased()
        for entry in Self.operatorCatalog where entry.name.hasPrefix(lower) && lower.count >= 1 {
            result.append(SearchSuggestion(
                kind: .operator, title: entry.name, detail: entry.hint,
                completion: head + entry.name, runsImmediately: false))
        }
        return Array(result.prefix(limit))
    }

    // MARK: Recent searches

    /// Newest first, at most 20, without duplicates.
    public func recentSearches() throws -> [String] {
        guard let json = try MailStore(database).setting(Self.recentSearchesKey),
              let items = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) else { return [] }
        return items
    }

    /// Remembers a search the user ran (pressed return on, or opened a result of). Empty text is ignored; a
    /// repeat moves to the top.
    public func recordRecentSearch(_ text: String) throws {
        let trimmed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !SearchQuery(trimmed).isEmpty else { return }
        try database.writer.write { db in
            let key = Self.recentSearchesKey
            var items = (try Setting.fetchOne(db, key: key)).flatMap {
                try? JSONDecoder().decode([String].self, from: Data($0.value.utf8))
            } ?? []
            items.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
            items.insert(trimmed, at: 0)
            items = Array(items.prefix(Self.recentSearchLimit))
            try Setting(key: key, value: String(decoding: try JSONEncoder().encode(items), as: UTF8.self)).save(db)
        }
    }

    public func clearRecentSearches() throws {
        try MailStore(database).setSetting(Self.recentSearchesKey, nil)
    }

    /// Forgets one remembered search.
    public func removeRecentSearch(_ text: String) throws {
        try database.writer.write { db in
            let key = Self.recentSearchesKey
            guard let stored = try Setting.fetchOne(db, key: key),
                  var items = try? JSONDecoder().decode([String].self, from: Data(stored.value.utf8)) else { return }
            items.removeAll { $0.caseInsensitiveCompare(text) == .orderedSame }
            try Setting(key: key, value: String(decoding: try JSONEncoder().encode(items), as: UTF8.self)).save(db)
        }
    }

    private static func recentSuggestion(_ text: String) -> SearchSuggestion {
        SearchSuggestion(kind: .recent, title: text, detail: nil, completion: text, runsImmediately: true)
    }

    // MARK: Operators

    static let operatorCatalog: [(name: String, hint: String)] = [
        ("from:", "Sender"), ("to:", "Recipient"), ("subject:", "Words in the subject"),
        ("has:attachment", "With attachments"), ("is:unread", "Unread"), ("is:starred", "Starred"),
        ("is:important", "Important"), ("is:snoozed", "Snoozed"), ("is:needsreply", "Waiting on your reply"), ("is:owe", "I owe"), ("is:waiting", "Waiting on someone else"), ("due:", "Commitment due date"),
        ("in:inbox", "In the inbox"), ("in:sent", "Sent"), ("in:drafts", "Drafts"), ("in:trash", "Trash"),
        ("in:spam", "Spam"), ("in:anywhere", "Including trash and spam"), ("label:", "A label"),
        ("category:", "Split-inbox category"), ("project:", "A project"), ("account:", "One account"),
        ("filename:", "Attachment name"), ("before:", "Before a date"), ("after:", "After a date"),
        ("older_than:", "Older than 7d, 2w, 3m, 1y"), ("newer_than:", "Newer than 7d, 2w, 3m, 1y"),
        ("larger:", "Larger than 10K, 2M"), ("smaller:", "Smaller than 10K, 2M"), ("cc:", "Copied"), ("bcc:", "Blind copied"),
    ]

    // MARK: Splitting what is typed

    struct LastWord {
        /// The operator the word starts with (`from`), if it has one.
        var op: String?
        /// What follows the operator, or the whole word; quotes removed.
        var text: String
        var quoted: Bool
    }

    /// Everything before the word being typed (with its trailing space), and the word.
    static func splitLastWord(_ partial: String) -> (head: String, word: LastWord) {
        // The word starts after the last space that is not inside an open quote.
        var inQuote = false
        var start = partial.startIndex
        var index = partial.startIndex
        while index < partial.endIndex {
            let character = partial[index]
            if character == "\"" { inQuote.toggle() }
            if (character.isWhitespace || character == "(" || character == "{") && !inQuote { start = partial.index(after: index) }
            index = partial.index(after: index)
        }
        var head = String(partial[..<start])
        var raw = String(partial[start...])
        while raw.hasPrefix("-") { head += "-"; raw.removeFirst() }
        guard !raw.isEmpty else { return (head, LastWord(op: nil, text: "", quoted: false)) }

        if let colon = raw.firstIndex(of: ":") {
            let name = raw[..<colon].lowercased()
            if SearchParser.operators.contains(name) {
                var value = String(raw[raw.index(after: colon)...])
                let quoted = value.hasPrefix("\"")
                if quoted { value.removeFirst() }
                return (head, LastWord(op: name, text: value.replacingOccurrences(of: "\"", with: ""), quoted: quoted))
            }
        }
        return (head, LastWord(op: nil, text: raw.replacingOccurrences(of: "\"", with: ""), quoted: false))
    }

    // MARK: Per operator

    private static func suggestions(_ db: Database, op: String, value: String, head: String, quoted: Bool, limit: Int) throws -> [SearchSuggestion] {
        let prefix = head + op + ":"
        let lower = value.lowercased()
        func make(_ kind: SearchSuggestion.Kind, _ title: String, detail: String?, token: String) -> SearchSuggestion {
            let needsQuotes = token.contains(where: \.isWhitespace) || token.contains("(") || token.contains(")")
            return SearchSuggestion(
                kind: kind, title: title, detail: detail,
                completion: prefix + (needsQuotes ? "\"\(token)\"" : token) + " ", runsImmediately: false)
        }

        switch op {
        case "from", "to", "cc", "bcc":
            return try contacts(db, matching: lower, sentTo: op != "from", limit: limit).map {
                make(.contact, $0.name.isEmpty ? $0.id : $0.name, detail: $0.name.isEmpty ? nil : $0.id, token: $0.id)
            }

        case "label":
            // Names, once each even when every account has the label; system labels are not worth typing.
            var seen = Set<String>()
            var result: [SearchSuggestion] = []
            let rows = try Row.fetchAll(db, sql: """
                SELECT name, type, count(*) AS accounts FROM label WHERE hidden = 0 GROUP BY lower(name), type ORDER BY type DESC, name
                """)
            for row in rows {
                let name: String = row["name"]
                let normalized = SearchSQL.normalizedName(name)
                guard value.isEmpty || normalized.hasPrefix(SearchSQL.normalizedName(value)) || name.lowercased().hasPrefix(lower),
                      seen.insert(normalized).inserted else { continue }
                let system = (row["type"] as String) == "system"
                if system && value.isEmpty { continue }
                result.append(make(.label, name, detail: system ? "System label" : nil, token: name))
                if result.count == limit { break }
            }
            return result

        case "project":
            return try Row.fetchAll(db, sql: "SELECT name FROM project ORDER BY sortOrder, name").compactMap { row -> SearchSuggestion? in
                let name: String = row["name"]
                guard value.isEmpty || SearchSQL.normalizedName(name).hasPrefix(SearchSQL.normalizedName(value))
                        || name.lowercased().hasPrefix(lower) else { return nil }
                return make(.project, name, detail: nil, token: name)
            }.prefix(limit).map { $0 }

        case "category":
            return MailCategory.allCases.filter { value.isEmpty || $0.rawValue.hasPrefix(lower) }.prefix(limit).map {
                make(.category, $0.rawValue.capitalized, detail: categoryHint($0), token: $0.rawValue)
            }

        case "account":
            return try Account.order(Column("sortOrder"), Column("createdAt")).fetchAll(db).compactMap { account -> SearchSuggestion? in
                guard value.isEmpty || account.email.lowercased().hasPrefix(lower) || account.displayName.lowercased().hasPrefix(lower)
                else { return nil }
                return make(.account, account.displayName.isEmpty ? account.email : account.displayName,
                            detail: account.displayName.isEmpty ? nil : account.email, token: account.email)
            }.prefix(limit).map { $0 }

        case "due":
            return ["overdue", "today", "week", "none"].filter { value.isEmpty || $0.hasPrefix(lower) }.prefix(limit).map { make(.operator, "due:\($0)", detail: "Commitment due date", token: $0) }
        case "is", "in", "has":
            let options: [(String, String)] = switch op {
            case "is": [("unread", "Unread"), ("read", "Read"), ("starred", "Starred"), ("important", "Important"),
                        ("snoozed", "Snoozed"), ("needsreply", "Waiting on your reply"), ("owe", "I owe"), ("waiting", "Waiting on someone else")]
            case "in": [("inbox", "Inbox"), ("sent", "Sent"), ("drafts", "Drafts"), ("trash", "Trash"), ("spam", "Spam"),
                        ("anywhere", "Everywhere, trash and spam too"), ("snoozed", "Snoozed")]
            default: [("attachment", "With attachments")]
            }
            return options.filter { value.isEmpty || $0.0.hasPrefix(lower) }.prefix(limit).map {
                make(.operator, "\(op):\($0.0)", detail: $0.1, token: $0.0)
            }

        default:
            return []
        }
    }

    private static func categoryHint(_ category: MailCategory) -> String {
        switch category {
        case .people: "Real people"
        case .notification: "GitHub, Linear, Vercel…"
        case .newsletter: "Newsletters"
        case .receipt: "Receipts and invoices"
        case .calendar: "Invitations"
        case .promotion: "Promotions"
        case .security: "Codes and security alerts"
        case .other: "Everything else"
        }
    }

    /// People whose name or address starts with `prefix` (any word of the name counts), best known first:
    /// for recipients the ones you write to, for senders the ones who write to you.
    private static func contacts(_ db: Database, matching prefix: String, sentTo: Bool, limit: Int) throws -> [Contact] {
        let order = sentTo ? "sentCount DESC, receivedCount DESC" : "receivedCount DESC, sentCount DESC"
        guard !prefix.isEmpty else {
            return try Contact.fetchAll(db, sql: "SELECT * FROM contact ORDER BY \(order), lastContacted DESC LIMIT ?", arguments: [limit])
        }
        let escaped = SearchSQL.containsPattern(prefix).dropFirst().dropLast()
        let starts = "\(escaped)%"
        let word = "% \(escaped)%"
        return try Contact.fetchAll(db, sql: """
            SELECT * FROM contact
            WHERE id LIKE ? ESCAPE '\\' OR name LIKE ? ESCAPE '\\' OR name LIKE ? ESCAPE '\\'
              OR substr(id, instr(id, '@') + 1) LIKE ? ESCAPE '\\'
            ORDER BY (id LIKE ? ESCAPE '\\' OR name LIKE ? ESCAPE '\\') DESC, \(order), lastContacted DESC
            LIMIT ?
            """, arguments: [starts, starts, word, starts, starts, starts, limit])
    }
}
