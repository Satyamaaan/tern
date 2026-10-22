import Foundation

// MARK: - Terms

/// A word or quoted phrase from the search box.
public struct SearchText: Hashable, Sendable {
    /// As typed, without the surrounding quotes. May contain punctuation (`ENG-412`, `ann@x.com`);
    /// it matches the adjacent index tokens it splits into.
    public var value: String
    public var isPhrase: Bool
    /// The last word being typed: matches any word that starts with it.
    public var isPrefix: Bool

    public init(_ value: String, isPhrase: Bool = false, isPrefix: Bool = false) {
        self.value = value
        self.isPhrase = isPhrase
        self.isPrefix = isPrefix
    }

    var tokens: [String] { SearchTokenizer.tokens(in: value) }
}

/// Operators whose value is text.
public enum SearchField: String, Hashable, Sendable, CaseIterable {
    case from, to, cc, bcc, subject, filename
}

public enum SearchFolder: String, Hashable, Sendable, CaseIterable {
    case inbox, sent, drafts, trash, spam, anywhere
}

/// A calendar day as typed in `before:` / `after:`.
public struct SearchDay: Hashable, Sendable {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int = 1, day: Int = 1) {
        self.year = year
        self.month = month
        self.day = day
    }

    public func startOfDay(in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }

    var gmail: String { String(format: "%04d/%02d/%02d", year, month, day) }
}

/// `older_than:` / `newer_than:` value, e.g. `3d`, `2w`, `6m`, `1y`.
public struct SearchDuration: Hashable, Sendable {
    public enum Unit: String, Hashable, Sendable { case day = "d", week = "w", month = "m", year = "y" }

    public var count: Int
    public var unit: Unit

    public init(_ count: Int, _ unit: Unit) {
        self.count = count
        self.unit = unit
    }

    public var seconds: TimeInterval {
        let day = 86_400.0
        switch unit {
        case .day: return Double(count) * day
        case .week: return Double(count) * 7 * day
        case .month: return Double(count) * 30 * day
        case .year: return Double(count) * 365 * day
        }
    }

    var gmail: String {
        switch unit {
        case .week: "\(count * 7)d"
        default: "\(count)\(unit.rawValue)"
        }
    }
}

/// Operators that are not plain text matches.
public enum SearchFilter: Hashable, Sendable {
    case hasAttachment
    case unread, read, starred, important, snoozed
    /// Tern: the classifier thinks the thread waits on your reply.
    case needsReply
    case waiting
    case due(String)
    case folder(SearchFolder)
    /// A label id or name, as typed.
    case label(String)
    case before(SearchDay)
    case after(SearchDay)
    case olderThan(SearchDuration)
    case newerThan(SearchDuration)
    /// Message size in bytes.
    case larger(Int)
    case smaller(Int)
    /// Tern: the split-inbox bucket.
    case category(MailCategory)
    /// Tern: a project name, as typed.
    case project(String)
    /// Tern: an account email or display name, as typed.
    case account(String)
}

/// The parsed query. Implicit AND between neighbours; `OR` binds tighter than the implicit AND, like Gmail
/// (`a b OR c` is `a AND (b OR c)`).
public indirect enum SearchExpr: Hashable, Sendable {
    case text(SearchText)
    case field(SearchField, SearchText)
    case filter(SearchFilter)
    case and([SearchExpr])
    case or([SearchExpr])
    case not(SearchExpr)
}

// MARK: - Query

/// What the user typed, parsed. Parsing never fails: partial input (`from:`, `"unclosed`, `((`) yields
/// whatever is understood so far, and unknown operators fall back to plain text.
public struct SearchQuery: Hashable, Sendable {
    public let raw: String
    /// Nil when nothing searchable was typed.
    public let root: SearchExpr?

    public init(_ text: String) {
        raw = text
        root = SearchParser.parse(text)
    }

    public var isEmpty: Bool { root == nil }

    /// True when the query asks for trash or spam (or `in:anywhere`), so they are not hidden.
    public var includesTrashOrSpam: Bool {
        guard let root else { return false }
        return root.contains { expr in
            switch expr {
            case .filter(.folder(let folder)): folder == .trash || folder == .spam || folder == .anywhere
            case .filter(.label(let name)): ["trash", "spam"].contains(name.lowercased())
            default: false
            }
        }
    }

    /// Positive words and phrases (not under a negation), for highlighting matches in the list. Includes the
    /// values of `from:`, `to:`, `cc:`, `bcc:` and `subject:`, so it also suits sender and subject text.
    public var highlighter: SearchHighlighter {
        highlighter(text: true, fields: [.from, .to, .cc, .bcc, .subject])
    }

    /// A highlighter for free-text terms (`text`) and the values of the given operators only.
    func highlighter(text includeText: Bool, fields: Set<SearchField>) -> SearchHighlighter {
        var terms: [SearchHighlighter.Term] = []
        func add(_ text: SearchText) {
            let tokens = text.tokens.map(SearchTokenizer.fold)
            if !tokens.isEmpty { terms.append(.init(tokens: tokens, isPrefix: text.isPrefix)) }
        }
        func visit(_ expr: SearchExpr) {
            switch expr {
            case .text(let text): if includeText { add(text) }
            case .field(let field, let text): if fields.contains(field) { add(text) }
            case .and(let children), .or(let children): children.forEach(visit)
            case .filter, .not: break
            }
        }
        if let root { visit(root) }
        return SearchHighlighter(terms: terms)
    }

    // MARK: Gmail

    /// The query in Gmail's `q` syntax, for searching older mail on the server. Tern-only operators
    /// (`category:`, `project:`, `account:`, `is:needsreply`, `is:snoozed`) are dropped; dropping inside an
    /// `OR` or a negation widens the clause away entirely, so the server result is always a superset.
    /// Nil when nothing is left. A `label:` value is passed through as typed (Gmail wants the label name).
    public var gmailQuery: String? {
        guard let root, let text = root.gmail(), !text.isEmpty else { return nil }
        return text
    }
}

extension SearchExpr {
    func contains(where predicate: (SearchExpr) -> Bool) -> Bool {
        if predicate(self) { return true }
        switch self {
        case .and(let children), .or(let children): return children.contains { $0.contains(where: predicate) }
        case .not(let child): return child.contains(where: predicate)
        default: return false
        }
    }

    /// The same expression with no word treated as still being typed.
    var exact: SearchExpr {
        switch self {
        case .text(var text):
            text.isPrefix = false
            return .text(text)
        case .field(let field, var text):
            text.isPrefix = false
            return .field(field, text)
        case .filter: return self
        case .and(let children): return .and(children.map(\.exact))
        case .or(let children): return .or(children.map(\.exact))
        case .not(let child): return .not(child.exact)
        }
    }

    /// Children of a top-level AND, or the expression itself.
    var conjuncts: [SearchExpr] {
        switch self {
        case .and(let children): children.flatMap(\.conjuncts)
        default: [self]
        }
    }

    // MARK: Gmail rendering

    fileprivate func gmail() -> String? {
        switch self {
        case .text(let text):
            return text.isPhrase ? Self.quoted(text.value) : Self.word(text.value)
        case .field(let field, let text):
            return "\(field.rawValue):\(Self.value(text))"
        case .filter(let filter):
            return filter.gmail()
        case .and(let children):
            let parts = children.compactMap { $0.gmail() }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        case .or(let children):
            let parts = children.compactMap { $0.gmail() }
            // A dropped branch would narrow the OR; leave the whole clause out instead.
            guard parts.count == children.count, !parts.isEmpty else { return nil }
            return parts.count == 1 ? parts[0] : "(" + parts.joined(separator: " OR ") + ")"
        case .not(let child):
            guard let part = child.gmail() else { return nil }
            let simple = !part.contains(" ") || (part.hasPrefix("\"") && part.hasSuffix("\"") && !part.dropFirst().dropLast().contains("\""))
            return simple ? "-" + part : "-(" + part + ")"
        }
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "") + "\""
    }

    private static func word(_ value: String) -> String {
        value.contains(where: \.isWhitespace) ? quoted(value) : value
    }

    private static func value(_ text: SearchText) -> String {
        text.isPhrase || text.value.contains(where: \.isWhitespace) ? quoted(text.value) : text.value
    }
}

extension SearchFilter {
    fileprivate func gmail() -> String? {
        switch self {
        case .hasAttachment: "has:attachment"
        case .unread: "is:unread"
        case .read: "is:read"
        case .starred: "is:starred"
        case .important: "is:important"
        case .snoozed, .needsReply, .waiting, .due, .category, .project, .account: nil
        case .folder(let folder): "in:\(folder.rawValue)"
        case .label(let name): "label:" + name.split(whereSeparator: \.isWhitespace).joined(separator: "-")
        case .before(let day): "before:\(day.gmail)"
        case .after(let day): "after:\(day.gmail)"
        case .olderThan(let duration): "older_than:\(duration.gmail)"
        case .newerThan(let duration): "newer_than:\(duration.gmail)"
        case .larger(let bytes): "larger:\(bytes)"
        case .smaller(let bytes): "smaller:\(bytes)"
        }
    }
}
