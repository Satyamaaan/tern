import Foundation

/// Turns the search box text into a `SearchExpr`. Total: any string parses, nothing throws.
enum SearchParser {
    static func parse(_ text: String) -> SearchExpr? {
        var parser = Parser(tokens: Lexer(text).tokens)
        let expr = parser.parseSequence(context: nil, closer: nil)
        return Self.combine(expr, as: .and)
    }

    enum Combiner { case and, or }

    static func combine(_ items: [SearchExpr], as combiner: Combiner) -> SearchExpr? {
        let flat: [SearchExpr] = items.flatMap { item -> [SearchExpr] in
            switch (combiner, item) {
            case (.and, .and(let children)): children
            case (.or, .or(let children)): children
            default: [item]
            }
        }
        switch flat.count {
        case 0: return nil
        case 1: return flat[0]
        default: return combiner == .and ? .and(flat) : .or(flat)
        }
    }

    // MARK: Lexer

    struct Atom {
        var op: String?
        var value: String
        var quoted: Bool
        /// Typed up to the end of the input with nothing closing it: the word is still being typed.
        var open: Bool
    }

    enum Token {
        case lparen, rparen, lbrace, rbrace, minus, or, and
        /// `subject:(` — an operator applied to everything inside the parentheses.
        case opGroup(String)
        case atom(Atom)
    }

    static let operators: Set<String> = [
        "from", "to", "cc", "bcc", "subject", "filename", "due", "has", "is", "in", "label", "before", "after",
        "older_than", "newer_than", "larger", "smaller", "category", "project", "account",
    ]

    struct Lexer {
        var tokens: [Token] = []

        init(_ text: String) {
            let chars = Array(text)
            let count = chars.count
            var i = 0
            let delimiters: Set<Character> = ["(", ")", "{", "}", "\""]

            func readQuoted(from start: Int) -> (value: String, next: Int, closed: Bool) {
                var j = start + 1
                var value = ""
                while j < count, chars[j] != "\"" { value.append(chars[j]); j += 1 }
                let closed = j < count
                return (value, closed ? j + 1 : j, closed)
            }

            while i < count {
                let c = chars[i]
                if c.isWhitespace { i += 1; continue }
                switch c {
                case "(": tokens.append(.lparen); i += 1
                case ")": tokens.append(.rparen); i += 1
                case "{": tokens.append(.lbrace); i += 1
                case "}": tokens.append(.rbrace); i += 1
                case "\"":
                    let quoted = readQuoted(from: i)
                    tokens.append(.atom(Atom(op: nil, value: quoted.value, quoted: true, open: !quoted.closed)))
                    i = quoted.next
                case "-":
                    if i + 1 < count, !chars[i + 1].isWhitespace { tokens.append(.minus) }
                    i += 1
                default:
                    var j = i
                    var word = ""
                    while j < count, !chars[j].isWhitespace, !delimiters.contains(chars[j]) { word.append(chars[j]); j += 1 }
                    if word == "OR" { tokens.append(.or); i = j; continue }
                    if word == "AND" { tokens.append(.and); i = j; continue }
                    if let colon = word.firstIndex(of: ":") {
                        let name = word[..<colon].lowercased()
                        if SearchParser.operators.contains(name) {
                            let rest = String(word[word.index(after: colon)...])
                            if rest.isEmpty, j < count, chars[j] == "\"" {
                                let quoted = readQuoted(from: j)
                                tokens.append(.atom(Atom(op: name, value: quoted.value, quoted: true, open: !quoted.closed)))
                                i = quoted.next
                            } else if rest.isEmpty, j < count, chars[j] == "(" {
                                tokens.append(.opGroup(name))
                                i = j + 1
                            } else {
                                tokens.append(.atom(Atom(op: name, value: rest, quoted: false, open: j == count)))
                                i = j
                            }
                            continue
                        }
                    }
                    tokens.append(.atom(Atom(op: nil, value: word, quoted: false, open: j == count)))
                    i = j
                }
            }
        }
    }

    // MARK: Parser

    struct Parser {
        static let maxDepth = 24

        let tokens: [Token]
        var position = 0
        var depth = 0

        init(tokens: [Token]) {
            self.tokens = tokens
        }

        enum Closer { case paren, brace }

        private func peek() -> Token? { position < tokens.count ? tokens[position] : nil }

        private func isCloser(_ token: Token?, _ closer: Closer?) -> Bool {
            guard let closer, let token else { return false }
            switch (closer, token) {
            case (.paren, .rparen), (.brace, .rbrace): return true
            default: return false
            }
        }

        /// Items in sequence (implicit AND). Stops before the closer, which the caller consumes.
        mutating func parseSequence(context: String?, closer: Closer?) -> [SearchExpr] {
            var items: [SearchExpr] = []
            while let token = peek() {
                if isCloser(token, closer) { break }
                switch token {
                case .and, .or, .rparen, .rbrace:
                    position += 1
                    continue
                default: break
                }
                var alternatives: [SearchExpr] = []
                if let first = parseUnary(context: context) { alternatives.append(first) }
                while case .or? = peek() {
                    position += 1
                    while case .and? = peek() { position += 1 }
                    if peek() == nil || isCloser(peek(), closer) { break }
                    if case .or? = peek() { continue }
                    if let next = parseUnary(context: context) { alternatives.append(next) }
                }
                if let group = SearchParser.combine(alternatives, as: .or) { items.append(group) }
            }
            return items
        }

        private mutating func parseUnary(context: String?) -> SearchExpr? {
            var negated = false
            while case .minus? = peek() { negated.toggle(); position += 1 }
            guard let token = peek() else { return nil }
            switch token {
            case .or, .and, .rparen, .rbrace, .minus: return nil
            default: position += 1
            }

            var expr: SearchExpr?
            switch token {
            case .lparen, .lbrace, .opGroup:
                // Groups nested absurdly deep are read flat instead of recursing without end.
                guard depth < Self.maxDepth else { return nil }
                depth += 1
                defer { depth -= 1 }
                switch token {
                case .lparen:
                    let inner = parseSequence(context: context, closer: .paren)
                    if case .rparen? = peek() { position += 1 }
                    expr = SearchParser.combine(inner, as: .and)
                case .lbrace:
                    let inner = parseSequence(context: context, closer: .brace)
                    if case .rbrace? = peek() { position += 1 }
                    expr = SearchParser.combine(inner, as: .or)
                case .opGroup(let name):
                    let inner = parseSequence(context: name, closer: .paren)
                    if case .rparen? = peek() { position += 1 }
                    expr = SearchParser.combine(inner, as: .and)
                default:
                    break
                }
            case .atom(let atom):
                expr = SearchParser.leaf(atom, context: context)
            case .minus, .or, .and, .rparen, .rbrace:
                expr = nil
            }
            guard let expr else { return nil }
            return negated ? .not(expr.exact) : expr
        }
    }

    // MARK: Leaves

    static func leaf(_ atom: Atom, context: String?) -> SearchExpr? {
        let op = atom.op ?? context
        let value = atom.value
        guard let op else { return textLeaf(value, atom: atom) }

        // `from:` with nothing after it yet: nothing to filter on.
        if value.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        let lower = value.lowercased()
        let fallback = { textLeaf(atom.op == nil ? value : "\(op):\(value)", atom: atom) }

        switch op {
        case "from", "to", "cc", "bcc", "subject", "filename":
            let field = SearchField(rawValue: op)!
            guard !SearchTokenizer.tokens(in: value).isEmpty else { return nil }
            return .field(field, SearchText(value, isPhrase: atom.quoted, isPrefix: atom.open && field != .filename))
        case "has":
            if ["attachment", "attachments"].contains(lower) { return .filter(.hasAttachment) }
            return partial(lower, of: ["attachment"]) ? nil : fallback()
        case "due":
            return ["overdue", "today", "week", "none"].contains(lower) ? .filter(.due(lower)) : fallback()
        case "is":
            switch lower {
            case "done": return .filter(.done)
            case "owe": return .filter(.owe)
            case "waiting": return .filter(.waiting)
            case "unread": return .filter(.unread)
            case "read": return .filter(.read)
            case "starred": return .filter(.starred)
            case "important": return .filter(.important)
            case "snoozed": return .filter(.snoozed)
            case "needsreply", "needs_reply", "needs-reply": return .filter(.needsReply)
            case "sent": return .filter(.folder(.sent))
            case "draft", "drafts": return .filter(.folder(.drafts))
            case "inbox": return .filter(.folder(.inbox))
            case "trash": return .filter(.folder(.trash))
            case "spam": return .filter(.folder(.spam))
            default:
                return partial(lower, of: ["unread", "read", "starred", "important", "snoozed", "needsreply", "waiting", "owe", "done"]) ? nil : fallback()
            }
        case "in":
            switch lower {
            case "inbox": return .filter(.folder(.inbox))
            case "sent": return .filter(.folder(.sent))
            case "draft", "drafts": return .filter(.folder(.drafts))
            case "trash": return .filter(.folder(.trash))
            case "spam": return .filter(.folder(.spam))
            case "anywhere": return .filter(.folder(.anywhere))
            case "snoozed": return .filter(.snoozed)
            case "starred": return .filter(.starred)
            case "important": return .filter(.important)
            case "done": return .filter(.done)
            case "owe": return .filter(.owe)
            case "waiting": return .filter(.waiting)
            case "unread": return .filter(.unread)
            default: return .filter(.label(value))
            }
        case "label":
            return .filter(.label(value))
        case "before", "after":
            switch parseDay(value) {
            case .valid(let day): return .filter(op == "before" ? .before(day) : .after(day))
            case .partial: return nil
            case .invalid: return fallback()
            }
        case "older_than", "newer_than":
            guard let duration = parseDuration(lower) else { return fallback() }
            return .filter(op == "older_than" ? .olderThan(duration) : .newerThan(duration))
        case "larger", "smaller":
            guard let bytes = parseSize(lower) else { return fallback() }
            return .filter(op == "larger" ? .larger(bytes) : .smaller(bytes))
        case "category":
            if let category = parseCategory(lower) { return .filter(.category(category)) }
            return partial(lower, of: MailCategory.allCases.map(\.rawValue)) ? nil : fallback()
        case "project":
            return .filter(.project(value))
        case "account":
            return .filter(.account(value))
        default:
            return fallback()
        }
    }

    private static func textLeaf(_ value: String, atom: Atom) -> SearchExpr? {
        guard !SearchTokenizer.tokens(in: value).isEmpty else { return nil }
        // The word at the very end is still being typed, and so is a phrase whose quote is not closed.
        return .text(SearchText(value, isPhrase: atom.quoted, isPrefix: atom.open))
    }

    /// A value that is the start of a valid one (`is:unr`) is ignored while typing instead of searched for.
    private static func partial(_ value: String, of options: [String]) -> Bool {
        options.contains { $0.hasPrefix(value) }
    }

    private static func parseCategory(_ value: String) -> MailCategory? {
        if let category = MailCategory(rawValue: value) { return category }
        switch value {
        case "people", "person": return .people
        case "notifications": return .notification
        case "newsletters": return .newsletter
        case "receipts": return .receipt
        case "promotions", "promo": return .promotion
        default: return nil
        }
    }

    enum DayParse { case valid(SearchDay), partial, invalid }

    /// `2026/10/17`, `2026-10-17`; a year or year/month alone is accepted as its first day.
    static func parseDay(_ value: String) -> DayParse {
        let parts = value.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "-" })
        guard parts.count <= 3, parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return .invalid }
        let numbers = parts.map { Int($0) }
        // Trailing separator or an empty part means the next part is still coming.
        if parts.last?.isEmpty == true || parts[0].count < 4 { return parts.allSatisfy { $0.count <= 4 } ? .partial : .invalid }
        guard let year = numbers[0], (1000...9999).contains(year) else { return .invalid }
        let month = numbers.count > 1 ? numbers[1] : 1
        let day = numbers.count > 2 ? numbers[2] : 1
        guard let month, let day, (1...12).contains(month), (1...31).contains(day) else { return .invalid }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.day, from: date) == day else { return .invalid }
        return .valid(SearchDay(year: year, month: month, day: day))
    }

    /// `3d`, `2w`, `6m`, `1y`; a bare number is days.
    static func parseDuration(_ value: String) -> SearchDuration? {
        guard let last = value.last else { return nil }
        let unit = SearchDuration.Unit(rawValue: String(last))
        let digits = unit == nil ? value : String(value.dropLast())
        guard let count = Int(digits), count >= 0, digits.allSatisfy(\.isASCII) else { return nil }
        return SearchDuration(count, unit ?? .day)
    }

    /// `500`, `10k`, `2m`, `1.5mb`, `1g` (binary multiples).
    static func parseSize(_ value: String) -> Int? {
        var number = value
        var multiplier = 1.0
        for (suffix, factor) in [("gb", 1_073_741_824.0), ("mb", 1_048_576.0), ("kb", 1024.0), ("g", 1_073_741_824.0),
                                 ("m", 1_048_576.0), ("k", 1024.0), ("b", 1.0)] where value.hasSuffix(suffix) {
            number = String(value.dropLast(suffix.count))
            multiplier = factor
            break
        }
        guard !number.isEmpty, number.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              let amount = Double(number), amount >= 0, amount * multiplier < Double(Int.max) else { return nil }
        return Int(amount * multiplier)
    }
}
