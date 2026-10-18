import Foundation

/// The structure of a style sheet as WebKit reads it: the CSS Syntax tokenizer, cut down to what decides where
/// rules, preludes and blocks begin and end, with brackets matched the way the parser nests them.
///
/// A string ends at its quote or at a line break and honours escapes; `\{` is part of a name, not a block; a comment
/// is a token of its own, so `/*` inside a string isn't one; an unquoted `url(…)` is one token up to its `)`, braces
/// and all; and a closing bracket that doesn't match the innermost open one is ordinary text.
///
/// Where WebKit would swallow the rest of the sheet, the reading recovers locally instead, so one broken rule
/// doesn't take every rule after it: a `(`, `[` or function that never closes, and an unquoted `url(` with no `)`,
/// read as plain text. WebKit keeps no rule after such a point, so this only keeps rules it would have dropped;
/// every rule it does keep is read in the same block here.
struct CSSStructure {
    enum Kind: Equatable {
        case whitespace
        case comment
        /// A quoted string or an unquoted `url(…)`; nothing inside is structure.
        case opaque
        case atKeyword
        /// `(`, `[`, `{`, or a function name with its `(`, carrying the bracket.
        case open(Unicode.Scalar)
        case close(Unicode.Scalar)
        case semicolon
        /// `<!--` and `-->`, which the browser skips between top-level rules.
        case cdo
        case cdc
        case other
    }

    struct Token {
        var kind: Kind
        /// Offsets into `scalars`.
        var range: Range<Int>
    }

    let scalars: [Unicode.Scalar]
    let tokens: [Token]
    /// For each open bracket, the index of the token that closes it; nil when it never closes, in which case a `{`
    /// runs to the end of the sheet and a `(` or `[` is plain text.
    let match: [Int?]

    init(_ text: some Sequence<Unicode.Scalar>) {
        let scalars = Array(text)
        let lexer = Lexer(scalars)
        var tokens: [Token] = []
        var index = 0
        while index < scalars.count {
            let (kind, end) = lexer.token(at: index)
            tokens.append(Token(kind: kind, range: index..<end))
            index = end
        }
        self.scalars = scalars
        self.tokens = tokens
        match = Self.matches(tokens)
    }

    /// The text of the tokens in `range` without comments. With `skippingBlocks`, a `{…}` block at the range's own
    /// level is left out (a bracketed group keeps any block inside it).
    ///
    /// Nil when leaving something out joins the tokens on either side into different ones, so the text would read
    /// back as something the browser never saw: `@/**/font-face` as the at-rule `@font-face`, `a/**/b` as one name,
    /// `0/**/1px` as `01px`. Whitespace on both sides of a comment reads back as one run, which is the same.
    func text(_ range: Range<Int>, skippingBlocks: Bool = false) -> String? {
        var output = String.UnicodeScalarView()
        /// What each kept token should read back as.
        var kept: [(kind: Kind, length: Int)] = []
        var joined = false
        func keep(_ token: Token) {
            guard token.kind != .comment else {
                joined = true
                return
            }
            output.append(contentsOf: scalars[token.range])
            if token.kind == .whitespace, kept.last?.kind == .whitespace {
                kept[kept.count - 1].length += token.range.count
            } else {
                kept.append((token.kind, token.range.count))
            }
        }
        var index = range.lowerBound
        while index < range.upperBound {
            let token = tokens[index]
            if skippingBlocks, case .open(let bracket) = token.kind {
                if bracket == "{" {
                    index = match[index].map { $0 + 1 } ?? range.upperBound
                    joined = true
                    continue
                }
                if let close = match[index] {
                    for inner in tokens[index...close] { keep(inner) }
                    index = close + 1
                    continue
                }
            }
            keep(token)
            index += 1
        }
        guard joined else { return String(output) }
        let reread = CSSStructure(output)
        guard reread.tokens.count == kept.count else { return nil }
        for (token, original) in zip(reread.tokens, kept) where token.kind != original.kind || token.range.count != original.length {
            return nil
        }
        return String(output)
    }

    /// Pairs brackets as the parser nests them, then reads again with every `(`, `[` and function that never
    /// closed as plain text, so a closer it swallowed can close an outer block.
    private static func matches(_ tokens: [Token]) -> [Int?] {
        var plain = Set<Int>()
        var match = [Int?](repeating: nil, count: tokens.count)
        for pass in 0..<2 {
            match = [Int?](repeating: nil, count: tokens.count)
            var stack: [Int] = []
            for (index, token) in tokens.enumerated() {
                switch token.kind {
                case .open where !plain.contains(index):
                    stack.append(index)
                case .close(let closer):
                    guard let top = stack.last, case .open(let opener) = tokens[top].kind,
                          closer == Self.closer(of: opener) else { break }
                    match[top] = index
                    stack.removeLast()
                default:
                    break
                }
            }
            plain = Set(stack.filter { tokens[$0].kind != .open("{") })
            if pass == 0, plain.isEmpty { break }
        }
        return match
    }

    private static func closer(of opener: Unicode.Scalar) -> Unicode.Scalar {
        switch opener {
        case "(": ")"
        case "[": "]"
        default: "}"
        }
    }
}

/// The CSS Syntax tokenizer (css-syntax-3 §4), reporting only each token's kind and end.
private struct Lexer {
    let s: [Unicode.Scalar]
    /// For each offset, the first `)` at or after it that no escape consumes, which is where an unquoted URL started
    /// before it ends; `s.count` when there is none.
    let closeParen: [Int]

    init(_ scalars: [Unicode.Scalar]) {
        s = scalars
        // A `)` is escaped when an odd run of backslashes comes right before it; hex escapes never consume a `)`.
        var next = [Int](repeating: scalars.count, count: scalars.count + 1)
        var slashes = [Int](repeating: 0, count: scalars.count)
        for index in scalars.indices where scalars[index] == "\\" {
            slashes[index] = (index > 0 ? slashes[index - 1] : 0) + 1
        }
        for index in scalars.indices.reversed() {
            let escaped = index > 0 && slashes[index - 1] % 2 == 1
            next[index] = scalars[index] == ")" && !escaped ? index : next[index + 1]
        }
        closeParen = next
    }

    subscript(_ index: Int) -> Unicode.Scalar? { index < s.count ? s[index] : nil }

    func token(at start: Int) -> (CSSStructure.Kind, Int) {
        let scalar = s[start]
        switch scalar {
        case "/" where self[start + 1] == "*":
            var index = start + 2
            while index < s.count {
                if s[index] == "*", self[index + 1] == "/" { return (.comment, index + 2) }
                index += 1
            }
            return (.comment, s.count)
        case _ where Self.isWhitespace(scalar):
            var index = start + 1
            while let next = self[index], Self.isWhitespace(next) { index += 1 }
            return (.whitespace, index)
        case "\"", "'":
            return (.opaque, string(from: start + 1, quote: scalar))
        case "#":
            if let next = self[start + 1], Self.isName(next) || isEscape(at: start + 1) { return (.other, name(from: start + 1).end) }
            return (.other, start + 1)
        case "(", "[", "{":
            return (.open(scalar), start + 1)
        case ")", "]", "}":
            return (.close(scalar), start + 1)
        case ";":
            return (.semicolon, start + 1)
        case "+", ".":
            return (.other, startsNumber(at: start) ? number(from: start) : start + 1)
        case "-":
            if startsNumber(at: start) { return (.other, number(from: start)) }
            if self[start + 1] == "-", self[start + 2] == ">" { return (.cdc, start + 3) }
            return startsName(at: start) ? identLike(from: start) : (.other, start + 1)
        case "<":
            if self[start + 1] == "!", self[start + 2] == "-", self[start + 3] == "-" { return (.cdo, start + 4) }
            return (.other, start + 1)
        case "@":
            return startsName(at: start + 1) ? (.atKeyword, name(from: start + 1).end) : (.other, start + 1)
        case "\\":
            return isEscape(at: start) ? identLike(from: start) : (.other, start + 1)
        case "0"..."9":
            return (.other, number(from: start))
        default:
            return Self.isNameStart(scalar) ? identLike(from: start) : (.other, start + 1)
        }
    }

    /// A name, a function token, or an unquoted `url(…)`.
    private func identLike(from start: Int) -> (CSSStructure.Kind, Int) {
        let (end, isURL) = name(from: start)
        guard self[end] == "(" else { return (.other, end) }
        guard isURL else { return (.open("("), end + 1) }
        var index = end + 1
        while let first = self[index], let second = self[index + 1], Self.isWhitespace(first), Self.isWhitespace(second) {
            index += 1
        }
        let quoted = { (scalar: Unicode.Scalar?) in scalar == "\"" || scalar == "'" }
        if quoted(self[index]) || self[index].map(Self.isWhitespace) == true && quoted(self[index + 1]) {
            return (.open("("), end + 1)
        }
        // With no `)` left the browser would drop the rest of the sheet; read on as a function instead.
        let close = closeParen[index]
        return close < s.count ? (.opaque, close + 1) : (.open("("), end + 1)
    }

    /// Reads a name of name code points and escapes; `isURL` when it decodes to `url` in any case.
    private func name(from start: Int) -> (end: Int, isURL: Bool) {
        var index = start
        var length = 0
        var isURL = true
        while let scalar = self[index] {
            var decoded = scalar
            if Self.isName(scalar) {
                index += 1
            } else if isEscape(at: index) {
                (decoded, index) = escape(at: index)
            } else {
                break
            }
            if length < 3, Self.lowercased(decoded) != Self.url[length] { isURL = false }
            length += 1
        }
        return (index, isURL && length == 3)
    }

    private func number(from start: Int) -> Int {
        var index = start
        if s[index] == "+" || s[index] == "-" { index += 1 }
        func digits() { while let scalar = self[index], Self.isDigit(scalar) { index += 1 } }
        digits()
        if self[index] == ".", let next = self[index + 1], Self.isDigit(next) {
            index += 1
            digits()
        }
        if self[index] == "e" || self[index] == "E" {
            let sign = self[index + 1] == "+" || self[index + 1] == "-" ? 1 : 0
            if let next = self[index + 1 + sign], Self.isDigit(next) {
                index += 1 + sign
                digits()
            }
        }
        if startsName(at: index) { return name(from: index).end }
        return self[index] == "%" ? index + 1 : index
    }

    /// Reads a string's contents and closing quote. A line break ends it unconsumed; a backslash before a line
    /// break continues it.
    private func string(from start: Int, quote: Unicode.Scalar) -> Int {
        var index = start
        while let scalar = self[index] {
            if scalar == quote { return index + 1 }
            if Self.isNewline(scalar) { return index }
            if scalar == "\\" {
                guard let next = self[index + 1] else { return index + 1 }
                if Self.isNewline(next) {
                    index += next == "\r" && self[index + 2] == "\n" ? 3 : 2
                } else {
                    index = escape(at: index).end
                }
                continue
            }
            index += 1
        }
        return index
    }

    /// Reads an escape at a backslash: up to six hex digits and one whitespace, or any one code point.
    private func escape(at start: Int) -> (scalar: Unicode.Scalar, end: Int) {
        var index = start + 1
        guard let first = self[index] else { return ("\u{FFFD}", index) }
        guard let firstDigit = Self.hexValue(first) else { return (first, index + 1) }
        var value = UInt32(firstDigit)
        index += 1
        while index - start <= 6, let next = self[index], let digit = Self.hexValue(next) {
            value = value * 16 + UInt32(digit)
            index += 1
        }
        if let next = self[index], Self.isWhitespace(next) { index += next == "\r" && self[index + 1] == "\n" ? 2 : 1 }
        let decoded = value == 0 ? nil : Unicode.Scalar(value)
        return (decoded ?? "\u{FFFD}", index)
    }

    private func isEscape(at index: Int) -> Bool {
        guard self[index] == "\\" else { return false }
        return self[index + 1].map(Self.isNewline) != true
    }

    private func startsName(at index: Int) -> Bool {
        guard let first = self[index] else { return false }
        if first == "-" {
            guard let second = self[index + 1] else { return false }
            return Self.isNameStart(second) || second == "-" || isEscape(at: index + 1)
        }
        return Self.isNameStart(first) || isEscape(at: index)
    }

    private func startsNumber(at index: Int) -> Bool {
        guard let first = self[index] else { return false }
        var offset = index
        if first == "+" || first == "-" { offset += 1 }
        guard let scalar = self[offset] else { return false }
        if Self.isDigit(scalar) { return true }
        return scalar == "." && self[offset + 1].map(Self.isDigit) == true
    }

    private static let url: [Unicode.Scalar] = ["u", "r", "l"]

    private static func isNewline(_ scalar: Unicode.Scalar) -> Bool { scalar == "\n" || scalar == "\r" || scalar == "\u{C}" }
    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool { scalar == " " || scalar == "\t" || isNewline(scalar) }
    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool { ("0"..."9").contains(scalar) }

    private static func isNameStart(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || scalar == "_" || !scalar.isASCII
    }

    private static func isName(_ scalar: Unicode.Scalar) -> Bool { isNameStart(scalar) || isDigit(scalar) || scalar == "-" }

    private static func lowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        ("A"..."Z").contains(scalar) ? Unicode.Scalar(scalar.value + 32)! : scalar
    }

    private static func hexValue(_ scalar: Unicode.Scalar) -> Int? {
        switch scalar {
        case "0"..."9": Int(scalar.value - 48)
        case "a"..."f": Int(scalar.value - 87)
        case "A"..."F": Int(scalar.value - 55)
        default: nil
        }
    }
}
