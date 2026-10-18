import Foundation

// MARK: Colour scheme

/// Media queries in mail, read with a strict ASCII grammar and written back from their tokens: media types,
/// `only`/`not`/`and`/`or`, and parenthesised features whose value is one identifier, number, dimension or
/// ratio. Range syntax, functions, comments, escapes, quotes and anything non-ASCII don't parse. The scan is
/// linear and nothing the mail wrote reaches the output except the tokens themselves, so a query that doesn't
/// parse can't change how the rest of a sheet reads. Lists are read as UTF-8 bytes: every byte of a non-ASCII
/// scalar is 0x80 or above and fails the grammar, so a combining mark can't hide or join an ASCII character.
extension CSSSanitizer {
    /// What one query of a media query list became.
    enum MediaQuery: Equatable {
        /// The query as written back, with `prefers-color-scheme` settled.
        case query(String)
        /// It needs a dark colour scheme and has no `not` or `or` that could make it true without one.
        case dark
        /// It doesn't parse, so the browser treats it as `not all`.
        case invalid
    }

    /// Where a `<style media>` sheet applies.
    enum SheetMedia: Equatable {
        case everywhere
        case never
        case when(String)
    }

    /// Rewrites a media query list so the mail never sees a dark colour scheme: `(prefers-color-scheme:
    /// dark)` never matches, in any case or spacing, after `not`, in `and`/`or` chains and in comma lists,
    /// and a query that needs it is dropped; `(prefers-color-scheme: light)` becomes a marker that
    /// `settleColorScheme` resolves once the mail's mode is known. Mail paints its dark mode with
    /// `!important` white text over backgrounds that stay light on the reader's light card, so it must never
    /// apply. Queries that don't parse are dropped. Returns nil when no query in the list can match.
    static func lightSchemeMedia(_ list: String) -> String? {
        let queries = mediaQueries(list)
        guard !queries.isEmpty else { return "all" }
        let kept = queries.compactMap { query -> String? in
            if case .query(let text) = query { return text }
            return nil
        }
        return kept.isEmpty ? nil : kept.joined(separator: ", ")
    }

    /// A `<style media>` value. Unlike a sheet's own `@media`, one query that doesn't parse drops the whole
    /// sheet: an attribute is a single string the mail controls, and nothing legitimate needs more.
    static func sheetMedia(_ attribute: String) -> SheetMedia {
        let queries = mediaQueries(attribute)
        if queries.isEmpty { return .everywhere }
        var kept: [String] = []
        for query in queries {
            switch query {
            case .invalid: return .never
            case .dark: continue
            case .query(let text): kept.append(text)
            }
        }
        if kept.isEmpty { return .never }
        if kept.contains(where: { $0.lowercased() == "all" }) { return .everywhere }
        return .when(kept.joined(separator: ", "))
    }

    /// Each query of a comma-separated list, rewritten. An empty list (all whitespace) has no queries.
    static func mediaQueries(_ list: String) -> [MediaQuery] {
        let bytes = Array(list.utf8)
        guard !bytes.allSatisfy(isMediaSpace) else { return [] }
        var queries: [MediaQuery] = []
        var depth = 0
        var start = 0
        for (index, byte) in bytes.enumerated() {
            switch byte {
            case UInt8(ascii: "("): depth += 1
            case UInt8(ascii: ")"): depth = max(0, depth - 1)
            case UInt8(ascii: ",") where depth == 0:
                queries.append(mediaQuery(bytes[start..<index]))
                start = index + 1
            default: break
            }
        }
        queries.append(mediaQuery(bytes[start...]))
        return queries
    }

    private static func mediaQuery(_ bytes: ArraySlice<UInt8>) -> MediaQuery {
        guard let tokens = mediaTokens(bytes) else { return .invalid }
        var parser = MediaQueryParser(tokens: tokens)
        guard let text = parser.query() else { return .invalid }
        return parser.needsDark && !parser.negates ? .dark : .query(text)
    }

    /// Stands in for `(prefers-color-scheme: light)` until the mail's mode is known.
    static let lightSchemeScalar: Unicode.Scalar = "\u{E000}"
    static let lightScheme = String(lightSchemeScalar)
    static let alwaysMatches = "(min-width: 0px)"
    static let neverMatches = "(not (min-width: 0px))"

    // MARK: Tokens

    fileprivate enum MediaToken {
        case word(String)
        case number(String)
        case colon
        case slash
        case open
        case close
    }

    /// Splits one query into tokens, or nil for anything outside the grammar.
    private static func mediaTokens(_ bytes: ArraySlice<UInt8>) -> [MediaToken]? {
        var tokens: [MediaToken] = []
        var index = bytes.startIndex
        func byte(_ offset: Int) -> UInt8? {
            index + offset < bytes.endIndex ? bytes[index + offset] : nil
        }
        /// Reads `[A-Za-z0-9_-]*` from `index`.
        func name() -> String {
            let start = index
            while let next = byte(0), isNameByte(next) { index += 1 }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
        while let current = byte(0) {
            switch current {
            case _ where isMediaSpace(current):
                index += 1
            case UInt8(ascii: "("):
                tokens.append(.open)
                index += 1
            case UInt8(ascii: ")"):
                tokens.append(.close)
                index += 1
            case UInt8(ascii: ":"):
                tokens.append(.colon)
                index += 1
            case UInt8(ascii: "/"):
                tokens.append(.slash)
                index += 1
            case _ where startsNumber(current, byte(1), byte(2)):
                let start = index
                if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { index += 1 }
                while let next = byte(0), isDigit(next) { index += 1 }
                if byte(0) == UInt8(ascii: "."), let after = byte(1), isDigit(after) {
                    index += 1
                    while let next = byte(0), isDigit(next) { index += 1 }
                }
                if let next = byte(0), startsName(next, byte(1)) { _ = name() }
                tokens.append(.number(String(decoding: bytes[start..<index], as: UTF8.self)))
            case _ where startsName(current, byte(1)):
                let word = name()
                // `and(` and `not(` are function tokens, not keywords; queries never call functions.
                if byte(0) == UInt8(ascii: "(") { return nil }
                tokens.append(.word(word))
            default:
                return nil
            }
        }
        return tokens
    }

    /// CSS whitespace: space, tab, line feed, carriage return and form feed.
    static func isMediaSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

    private static func isLetter(_ byte: UInt8) -> Bool { (byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x7A }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        isLetter(byte) || isDigit(byte) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
    }

    private static func startsName(_ first: UInt8, _ second: UInt8?) -> Bool {
        if isLetter(first) || first == UInt8(ascii: "_") { return true }
        guard first == UInt8(ascii: "-"), let second else { return false }
        return isLetter(second) || second == UInt8(ascii: "-") || second == UInt8(ascii: "_")
    }

    private static func startsNumber(_ first: UInt8, _ second: UInt8?, _ third: UInt8?) -> Bool {
        func digits(_ a: UInt8?, _ b: UInt8?) -> Bool {
            guard let a else { return false }
            return isDigit(a) || a == UInt8(ascii: ".") && b.map(isDigit) == true
        }
        if first == UInt8(ascii: "+") || first == UInt8(ascii: "-") { return digits(second, third) }
        return digits(first, second)
    }
}

/// Recursive descent over one query's tokens (Media Queries 4, without range syntax or general-enclosed),
/// writing the query back as it goes. Brackets nest at most eight deep.
private struct MediaQueryParser {
    typealias Token = CSSSanitizer.MediaToken

    let tokens: [Token]
    var position = 0
    /// A `prefers-color-scheme` other than `light` appeared.
    var needsDark = false
    /// `not` or `or` appeared, so a never-matching feature doesn't make the whole query false.
    var negates = false

    static let maxDepth = 8
    static let reservedTypes: Set<String> = ["only", "not", "and", "or", "layer"]

    init(tokens: [Token]) { self.tokens = tokens }

    mutating func query() -> String? {
        guard !tokens.isEmpty else { return nil }
        let result: String?
        if let word = keyword(at: position), !(word == "not" && isOpen(at: position + 1)) {
            result = typedQuery()
        } else {
            result = condition(allowOr: true, depth: 0)
        }
        return position == tokens.count ? result : nil
    }

    /// `[only | not]? <media-type> [and <media-condition-without-or>]?`
    private mutating func typedQuery() -> String? {
        var words: [String] = []
        if let modifier = keyword(at: position), modifier == "only" || modifier == "not" {
            if modifier == "not" { negates = true }
            words.append(text(at: position))
            position += 1
        }
        guard let type = keyword(at: position), !Self.reservedTypes.contains(type) else { return nil }
        words.append(text(at: position))
        position += 1
        if position == tokens.count { return words.joined(separator: " ") }
        guard keyword(at: position) == "and" else { return nil }
        words.append(text(at: position))
        position += 1
        guard let rest = condition(allowOr: false, depth: 0) else { return nil }
        words.append(rest)
        return words.joined(separator: " ")
    }

    /// `not <in-parens>`, or `<in-parens>` followed by only `and`s or only `or`s.
    private mutating func condition(allowOr: Bool, depth: Int) -> String? {
        if keyword(at: position) == "not" {
            negates = true
            let word = text(at: position)
            position += 1
            return inParens(depth: depth).map { "\(word) \($0)" }
        }
        guard var output = inParens(depth: depth) else { return nil }
        var joiner: String?
        while let word = keyword(at: position), word == "and" || word == "or" {
            guard allowOr || word == "and", joiner == nil || joiner == word else { return nil }
            if word == "or" { negates = true }
            joiner = word
            let written = text(at: position)
            position += 1
            guard let next = inParens(depth: depth) else { return nil }
            output += " \(written) \(next)"
        }
        return output
    }

    /// `( <media-feature> )` or `( <media-condition> )`.
    private mutating func inParens(depth: Int) -> String? {
        guard depth < Self.maxDepth, isOpen(at: position) else { return nil }
        position += 1
        if let name = keyword(at: position), name != "not", isColon(at: position + 1) || isClose(at: position + 1) {
            let written = text(at: position)
            position += 1
            var value: String?
            if isColon(at: position) {
                position += 1
                guard let read = featureValue() else { return nil }
                value = read
            }
            guard isClose(at: position) else { return nil }
            position += 1
            return feature(name: written, value: value)
        }
        guard let inner = condition(allowOr: true, depth: depth + 1), isClose(at: position) else { return nil }
        position += 1
        return "(\(inner))"
    }

    /// One identifier, number or dimension, or a ratio of two plain numbers.
    private mutating func featureValue() -> String? {
        guard position < tokens.count else { return nil }
        switch tokens[position] {
        case .word(let word):
            position += 1
            return word
        case .number(let number):
            position += 1
            guard position < tokens.count, case .slash = tokens[position] else { return number }
            guard position + 1 < tokens.count, case .number(let denominator) = tokens[position + 1],
                  Self.isPlain(number), Self.isPlain(denominator) else { return nil }
            position += 2
            return "\(number)/\(denominator)"
        default:
            return nil
        }
    }

    private mutating func feature(name: String, value: String?) -> String {
        guard name.lowercased() == "prefers-color-scheme" else {
            return value.map { "(\(name): \($0))" } ?? "(\(name))"
        }
        guard let value else { return CSSSanitizer.alwaysMatches }
        if value.lowercased() == "light" { return CSSSanitizer.lightScheme }
        needsDark = true
        return CSSSanitizer.neverMatches
    }

    private static func isPlain(_ number: String) -> Bool {
        number.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || $0 == UInt8(ascii: ".") }
    }

    /// The lowercased word at `index`, if that token is a word.
    private func keyword(at index: Int) -> String? {
        guard index < tokens.count, case .word(let word) = tokens[index] else { return nil }
        return word.lowercased()
    }

    /// A word as the mail wrote it.
    private func text(at index: Int) -> String {
        if case .word(let word) = tokens[index] { return word }
        return ""
    }

    private func isOpen(at index: Int) -> Bool {
        guard index < tokens.count, case .open = tokens[index] else { return false }
        return true
    }

    private func isClose(at index: Int) -> Bool {
        guard index < tokens.count, case .close = tokens[index] else { return false }
        return true
    }

    private func isColon(at index: Int) -> Bool {
        guard index < tokens.count, case .colon = tokens[index] else { return false }
        return true
    }
}
