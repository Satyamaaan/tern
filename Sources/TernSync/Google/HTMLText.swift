import Foundation

/// Turns an HTML body into readable plain text: paragraphs and line breaks kept, lists as "- ",
/// quotes as "> ", links as "text (url)", entities decoded, scripts and styles dropped. Used for
/// the text/plain half of outgoing mail; small and fast, no WebKit.
public enum HTMLText {
    public static func plainText(fromHTML html: String) -> String {
        var renderer = Renderer()
        renderer.run(Array(html.unicodeScalars))
        return renderer.finish()
    }

    private struct Renderer {
        var out = String.UnicodeScalarView()
        var pendingBreaks = 0
        var atLineStart = true
        var lastWasSpace = true
        var quoteDepth = 0
        var preDepth = 0
        var links: [String?] = []
        var linkTextStart: [Int] = []
        var lists: [Int?] = []   // nil = bulleted, otherwise next number

        static let paragraphTags: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "table", "pre", "ul", "ol", "dl"]
        static let lineTags: Set<String> = ["div", "tr", "section", "article", "header", "footer", "nav", "aside",
                                            "main", "figure", "figcaption", "address", "dt", "dd", "center", "form"]
        static let skippedTags: Set<String> = ["head", "style", "script", "title", "template", "noscript", "svg"]

        mutating func run(_ s: [Unicode.Scalar]) {
            var i = 0
            while i < s.count {
                let c = s[i]
                if c == "<" {
                    if hasPrefix(s, i, "<!--") {
                        i = indexAfter(s, from: i + 4, closing: "-->")
                        continue
                    }
                    guard let close = firstIndex(of: ">", in: s, from: i + 1) else {
                        text(String(String.UnicodeScalarView(s[i...])))
                        return
                    }
                    let tag = Tag(String(String.UnicodeScalarView(s[(i + 1)..<close])))
                    i = close + 1
                    if !tag.isClosing, Self.skippedTags.contains(tag.name), !tag.selfClosing {
                        i = indexAfter(s, from: i, closing: "</\(tag.name)", caseInsensitive: true)
                        if let end = firstIndex(of: ">", in: s, from: max(0, i - 1)) { i = end + 1 }
                        continue
                    }
                    handle(tag)
                } else if c == "&" {
                    let (decoded, next) = HTMLText.entity(s, at: i)
                    text(decoded)
                    i = next
                } else {
                    var j = i
                    while j < s.count, s[j] != "<", s[j] != "&" { j += 1 }
                    text(String(String.UnicodeScalarView(s[i..<j])))
                    i = j
                }
            }
        }

        mutating func handle(_ tag: Tag) {
            switch tag.name {
            case "br":
                lineBreak(force: true)
            case "hr":
                paragraphBreak()
            case "blockquote":
                paragraphBreak()
                quoteDepth = max(0, quoteDepth + (tag.isClosing ? -1 : 1))
            case "pre":
                paragraphBreak()
                preDepth = max(0, preDepth + (tag.isClosing ? -1 : 1))
            case "ul", "ol":
                if tag.isClosing {
                    _ = lists.popLast()
                } else {
                    lists.append(tag.name == "ol" ? 1 : nil)
                }
                lists.isEmpty ? paragraphBreak() : lineBreak()
            case "li":
                lineBreak()
                if !tag.isClosing {
                    let indent = String(repeating: "  ", count: max(0, lists.count - 1))
                    if let number = lists.last ?? nil {
                        lists[lists.count - 1] = number + 1
                        raw("\(indent)\(number). ")
                    } else {
                        raw("\(indent)- ")
                    }
                }
            case "td", "th":
                if !tag.isClosing, !atLineStart { raw("  ") }
            case "a":
                if tag.isClosing {
                    guard let href = links.popLast() ?? nil, let start = linkTextStart.popLast() else { break }
                    let label = String(String.UnicodeScalarView(out.dropFirst(start)))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    var target = href
                    if target.lowercased().hasPrefix("mailto:") { target = String(target.dropFirst(7)) }
                    if !label.isEmpty, label != target, label != href {
                        raw(" (\(target))")
                    } else if label.isEmpty {
                        text(target)
                    }
                } else {
                    let href = tag.attribute("href").flatMap { url -> String? in
                        let lower = url.lowercased()
                        return lower.hasPrefix("http:") || lower.hasPrefix("https:") || lower.hasPrefix("mailto:") ? url : nil
                    }
                    links.append(href)
                    linkTextStart.append(out.count)
                }
            default:
                if Self.paragraphTags.contains(tag.name) {
                    paragraphBreak()
                } else if Self.lineTags.contains(tag.name) {
                    lineBreak()
                }
            }
        }

        mutating func text(_ string: String) {
            if preDepth > 0 {
                for (index, line) in string.components(separatedBy: "\n").enumerated() {
                    if index > 0 { lineBreak(force: true) }
                    if !line.isEmpty { raw(line) }
                }
                return
            }
            for scalar in string.unicodeScalars {
                if scalar.properties.isWhitespace && scalar != "\u{00A0}" {
                    lastWasSpace = true
                    continue
                }
                if lastWasSpace && !atLineStart && pendingBreaks == 0 { emit(" ") }
                lastWasSpace = false
                emit(scalar == "\u{00A0}" ? " " : scalar)
            }
        }

        /// Text that bypasses whitespace collapsing (list markers, link targets, <pre>).
        mutating func raw(_ string: String) {
            for scalar in string.unicodeScalars { emit(scalar) }
            lastWasSpace = false
        }

        mutating func emit(_ scalar: Unicode.Scalar) {
            flushBreaks()
            if atLineStart, quoteDepth > 0 {
                out.append(contentsOf: String(repeating: "> ", count: quoteDepth).unicodeScalars)
            }
            out.append(scalar)
            atLineStart = false
        }

        mutating func flushBreaks() {
            guard pendingBreaks > 0 else { return }
            if !out.isEmpty {
                for index in 0..<pendingBreaks {
                    out.append("\n")
                    if index < pendingBreaks - 1, quoteDepth > 0 {
                        out.append(contentsOf: String(repeating: ">", count: quoteDepth).unicodeScalars)
                    }
                }
            }
            pendingBreaks = 0
            atLineStart = true
        }

        mutating func lineBreak(force: Bool = false) {
            if force {
                if pendingBreaks > 0 || atLineStart && !out.isEmpty { pendingBreaks += 1 } else { pendingBreaks = 1 }
                pendingBreaks = min(pendingBreaks, 2)
            } else if !atLineStart || pendingBreaks > 0 {
                pendingBreaks = max(pendingBreaks, 1)
            }
            lastWasSpace = true
        }

        mutating func paragraphBreak() {
            if !out.isEmpty { pendingBreaks = 2 }
            lastWasSpace = true
        }

        func finish() -> String {
            let lines = String(out).components(separatedBy: "\n").map { line -> String in
                var line = Substring(line)
                while line.last == " " { line = line.dropLast() }
                return String(line)
            }
            return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        }

        // MARK: Scanning

        func hasPrefix(_ s: [Unicode.Scalar], _ i: Int, _ prefix: String) -> Bool {
            let p = Array(prefix.unicodeScalars)
            guard i + p.count <= s.count else { return false }
            return Array(s[i..<(i + p.count)]) == p
        }

        func firstIndex(of target: Unicode.Scalar, in s: [Unicode.Scalar], from: Int) -> Int? {
            var quote: Unicode.Scalar?
            var j = from
            while j < s.count {
                let c = s[j]
                if let q = quote {
                    if c == q { quote = nil }
                } else if c == "\"" || c == "'" {
                    quote = c
                } else if c == target {
                    return j
                }
                j += 1
            }
            return nil
        }

        /// Index just past `closing`, or the end of input.
        func indexAfter(_ s: [Unicode.Scalar], from: Int, closing: String, caseInsensitive: Bool = false) -> Int {
            let needle = Array((caseInsensitive ? closing.lowercased() : closing).unicodeScalars)
            var j = from
            while j + needle.count <= s.count {
                var matches = true
                for k in 0..<needle.count {
                    var c = s[j + k]
                    if caseInsensitive, c.properties.isUppercase { c = Unicode.Scalar(c.properties.lowercaseMapping) ?? c }
                    if c != needle[k] { matches = false; break }
                }
                if matches { return j + needle.count }
                j += 1
            }
            return s.count
        }
    }

    private struct Tag {
        var name: String
        var isClosing: Bool
        var selfClosing: Bool
        var body: String

        init(_ raw: String) {
            var text = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            isClosing = text.hasPrefix("/")
            if isClosing { text = text.dropFirst() }
            selfClosing = text.hasSuffix("/")
            let nameEnd = text.firstIndex { $0.isWhitespace || $0 == "/" } ?? text.endIndex
            name = text[..<nameEnd].lowercased()
            body = String(text[nameEnd...])
        }

        func attribute(_ wanted: String) -> String? {
            var rest = Substring(body)
            while let equals = rest.firstIndex(of: "=") {
                let name = rest[..<equals].split(whereSeparator: { $0.isWhitespace }).last.map { $0.lowercased() }
                var value = rest[rest.index(after: equals)...].drop { $0.isWhitespace }
                let result: Substring
                if let quote = value.first, quote == "\"" || quote == "'" {
                    value = value.dropFirst()
                    let end = value.firstIndex(of: quote) ?? value.endIndex
                    result = value[..<end]
                    rest = end < value.endIndex ? value[value.index(after: end)...] : ""
                } else {
                    let end = value.firstIndex { $0.isWhitespace } ?? value.endIndex
                    result = value[..<end]
                    rest = value[end...]
                }
                if name == wanted { return HTMLText.decodeEntities(String(result)) }
            }
            return nil
        }
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let scalars = Array(text.unicodeScalars)
        var result = ""
        var i = 0
        while i < scalars.count {
            if scalars[i] == "&" {
                let (decoded, next) = entity(scalars, at: i)
                result += decoded
                i = next
            } else {
                result.unicodeScalars.append(scalars[i])
                i += 1
            }
        }
        return result
    }

    /// Decodes the entity at `i` (which holds "&"); returns the text and the index after it.
    /// Unknown or unterminated entities stay as a literal "&".
    static func entity(_ s: [Unicode.Scalar], at i: Int) -> (String, Int) {
        var j = i + 1
        while j < s.count, j - i <= 32, s[j] != ";", s[j] != "&", s[j] != "<", !s[j].properties.isWhitespace { j += 1 }
        guard j < s.count, s[j] == ";" else { return ("&", i + 1) }
        let name = String(String.UnicodeScalarView(s[(i + 1)..<j]))
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value = digits.first == "x" || digits.first == "X"
                ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            if let value, let scalar = Unicode.Scalar(value) { return (String(scalar), j + 1) }
            return ("&", i + 1)
        }
        if let decoded = entities[name] { return (decoded, j + 1) }
        return ("&", i + 1)
    }

    static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "sbquo": "‚", "bdquo": "„",
        "bull": "•", "middot": "·", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢",
        "laquo": "«", "raquo": "»", "times": "×", "divide": "÷", "deg": "°", "plusmn": "±",
        "para": "¶", "sect": "§", "shy": "", "zwnj": "\u{200C}", "zwj": "\u{200D}",
        "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "check": "✓",
    ]
}
