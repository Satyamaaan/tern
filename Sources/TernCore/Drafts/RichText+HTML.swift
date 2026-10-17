import Foundation

extension RichText {
    /// Reads HTML into the supported formatting, dropping everything else (styles, images, tables become
    /// paragraphs, scripts and heads disappear). Fast and forgiving; meant for our own drafts, pasted
    /// HTML, signatures and AI output, not for rendering arbitrary mail.
    public init(html: String) {
        var builder = HTMLBuilder()
        for token in DraftHTMLTokenizer(html) { builder.consume(token) }
        self.init(builder.finish())
    }

    /// The visible text of an HTML fragment, one line per block.
    public static func plainText(fromHTML html: String) -> String {
        RichText(html: html).plainText
    }
}

// MARK: - Tokenizer

enum DraftHTMLToken: Equatable {
    case start(name: String, attributes: [String: String], selfClosing: Bool)
    case end(name: String)
    case text(String)
}

/// Splits HTML into tags and text. Comments, doctypes and processing instructions are skipped; the
/// contents of raw-text elements (script, style) come through as one text token.
struct DraftHTMLTokenizer: Sequence, IteratorProtocol {
    private let scalars: [Unicode.Scalar]
    private var index = 0
    private var rawTextEnd: String?

    init(_ html: String) {
        scalars = Array(html.unicodeScalars)
    }

    mutating func next() -> DraftHTMLToken? {
        guard index < scalars.count else { return nil }
        if let rawTextEnd {
            self.rawTextEnd = nil
            let close = "</" + rawTextEnd
            let start = index
            while index < scalars.count, !matches(close, at: index) { index += 1 }
            let text = String(String.UnicodeScalarView(scalars[start..<index]))
            return text.isEmpty ? next() : .text(text)
        }
        if scalars[index] == "<" {
            if matches("<!--", at: index) {
                index = find("-->", from: index + 4).map { $0 + 3 } ?? scalars.count
                return next()
            }
            if index + 1 < scalars.count, scalars[index + 1] == "!" || scalars[index + 1] == "?" {
                index = find(">", from: index).map { $0 + 1 } ?? scalars.count
                return next()
            }
            if let token = readTag() { return token }
            // A stray "<" is text.
            index += 1
            return .text("<")
        }
        let start = index
        while index < scalars.count, scalars[index] != "<" { index += 1 }
        return .text(decodeEntities(String(String.UnicodeScalarView(scalars[start..<index]))))
    }

    /// Case-insensitive match of an ASCII pattern.
    private func matches(_ text: String, at position: Int) -> Bool {
        var offset = position
        for scalar in text.unicodeScalars {
            guard offset < scalars.count, Self.lowered(scalars[offset].value) == Self.lowered(scalar.value) else { return false }
            offset += 1
        }
        return true
    }

    private static func lowered(_ value: UInt32) -> UInt32 { (65...90).contains(value) ? value + 32 : value }

    private func find(_ text: String, from position: Int) -> Int? {
        var offset = position
        while offset < scalars.count {
            if matches(text, at: offset) { return offset }
            offset += 1
        }
        return nil
    }

    private static func isNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == ":" || scalar == "_"
    }

    private mutating func readTag() -> DraftHTMLToken? {
        var position = index + 1
        var closing = false
        if position < scalars.count, scalars[position] == "/" { closing = true; position += 1 }
        let nameStart = position
        while position < scalars.count, Self.isNameScalar(scalars[position]) { position += 1 }
        guard position > nameStart else { return nil }
        let name = String(String.UnicodeScalarView(scalars[nameStart..<position])).lowercased()

        var attributes: [String: String] = [:]
        var selfClosing = false
        while position < scalars.count {
            let scalar = scalars[position]
            if scalar == ">" { position += 1; break }
            if scalar == "/" { selfClosing = true; position += 1; continue }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { position += 1; continue }
            let attributeStart = position
            while position < scalars.count, !CharacterSet.whitespacesAndNewlines.contains(scalars[position]),
                  scalars[position] != "=", scalars[position] != ">", scalars[position] != "/" {
                position += 1
            }
            let attributeName = String(String.UnicodeScalarView(scalars[attributeStart..<position])).lowercased()
            while position < scalars.count, CharacterSet.whitespacesAndNewlines.contains(scalars[position]) { position += 1 }
            var value = ""
            if position < scalars.count, scalars[position] == "=" {
                position += 1
                while position < scalars.count, CharacterSet.whitespacesAndNewlines.contains(scalars[position]) { position += 1 }
                if position < scalars.count, scalars[position] == "\"" || scalars[position] == "'" {
                    let quote = scalars[position]
                    position += 1
                    let valueStart = position
                    while position < scalars.count, scalars[position] != quote { position += 1 }
                    value = String(String.UnicodeScalarView(scalars[valueStart..<Swift.min(position, scalars.count)]))
                    position += 1
                } else {
                    let valueStart = position
                    while position < scalars.count, !CharacterSet.whitespacesAndNewlines.contains(scalars[position]),
                          scalars[position] != ">" {
                        position += 1
                    }
                    value = String(String.UnicodeScalarView(scalars[valueStart..<position]))
                }
            }
            if !attributeName.isEmpty { attributes[attributeName] = decodeEntities(value) }
        }
        index = position
        if closing { return .end(name: name) }
        if !selfClosing, ["script", "style", "title", "textarea"].contains(name) { rawTextEnd = name }
        return .start(name: name, attributes: attributes, selfClosing: selfClosing)
    }
}

/// Decodes `&amp;`, `&#39;`, `&#x2014;` and the common named entities.
func decodeEntities(_ text: String) -> String {
    guard text.contains("&") else { return text }
    var out = ""
    var rest = Substring(text)
    while let amp = rest.firstIndex(of: "&") {
        out += rest[..<amp]
        let after = rest[rest.index(after: amp)...]
        guard let semi = after.prefix(12).firstIndex(of: ";") else {
            out += "&"
            rest = after
            continue
        }
        let name = after[..<semi]
        var decoded: String?
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
            decoded = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
        } else if name.hasPrefix("#") {
            decoded = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
        } else {
            decoded = namedEntities[String(name)]
        }
        if let decoded {
            out += decoded
            rest = after[after.index(after: semi)...]
        } else {
            out += "&"
            rest = after
        }
    }
    out += rest
    return out
}

private let namedEntities: [String: String] = [
    "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
    "mdash": "—", "ndash": "–", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
    "laquo": "«", "raquo": "»", "bull": "•", "middot": "·", "copy": "©", "reg": "®", "trade": "™",
    "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "deg": "°", "times": "×", "divide": "÷",
    "rarr": "→", "larr": "←", "zwnj": "\u{200C}", "zwj": "\u{200D}", "shy": "\u{00AD}", "thinsp": "\u{2009}",
    "ensp": "\u{2002}", "emsp": "\u{2003}", "eacute": "é", "egrave": "è", "aacute": "á", "agrave": "à",
    "uuml": "ü", "ouml": "ö", "auml": "ä", "szlig": "ß", "ccedil": "ç", "ntilde": "ñ",
]

// MARK: - Builder

private struct HTMLBuilder {
    private struct Inline {
        var tag: String
        var style: RichText.Style
        var link: String?
    }

    private var blocks: [RichText.Block] = []
    private var current = RichText.Block()
    private var sawBreak = false
    private var inline: [Inline] = []
    private var lists: [RichText.BlockKind] = []
    private var quoteDepth = 0
    private var preDepth = 0
    private var skipDepth = 0
    private var skipTag: String?

    private static let blockTags: Set<String> = [
        "div", "p", "li", "ul", "ol", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "table",
        "tbody", "thead", "tfoot", "tr", "td", "th", "section", "article", "header", "footer", "center",
        "hr", "dl", "dt", "dd", "address", "figure", "figcaption", "nav", "aside", "main", "body", "html",
        "form", "fieldset", "caption",
    ]
    private static let skippedTags: Set<String> = [
        "head", "script", "style", "title", "noscript", "template", "svg", "object", "iframe", "select",
        "textarea", "button", "map",
    ]
    private static let voidTags: Set<String> = [
        "br", "img", "hr", "meta", "link", "input", "area", "base", "col", "embed", "param", "source",
        "track", "wbr",
    ]

    private var style: RichText.Style { inline.reduce([]) { $0.union($1.style) } }
    private var link: String? { inline.last(where: { $0.link != nil })?.link }

    mutating func consume(_ token: DraftHTMLToken) {
        if skipDepth > 0 {
            switch token {
            case .start(let name, _, let selfClosing) where name == skipTag && !selfClosing: skipDepth += 1
            case .end(let name) where name == skipTag: skipDepth -= 1
            default: break
            }
            return
        }
        switch token {
        case .text(let text):
            append(text)
        case .start(let name, let attributes, let selfClosing):
            if Self.skippedTags.contains(name) {
                if !selfClosing { skipDepth = 1; skipTag = name }
                return
            }
            start(name, attributes)
            if selfClosing && !Self.voidTags.contains(name) { end(name) }
        case .end(let name):
            end(name)
        }
    }

    private mutating func start(_ name: String, _ attributes: [String: String]) {
        switch name {
        case "br", "td", "th":
            break
        case _ where Self.blockTags.contains(name):
            // A block opening inside an empty one (e.g. `<li><div>`) continues it.
            if !current.runs.isEmpty || sawBreak { flush() }
        default:
            break
        }
        switch name {
        case "br":
            appendRaw(String(RichText.lineBreak))
            sawBreak = true
            return
        case "ul", "ol":
            lists.append(name == "ul" ? .bullet : .numbered)
            return
        case "li":
            current.kind = lists.last ?? .bullet
            return
        case "blockquote":
            quoteDepth += 1
            return
        case "pre":
            preDepth += 1
            return
        case "hr":
            return
        case "td", "th":
            // Cells of one row read as one paragraph, separated by spaces.
            if current.text.isEmpty { flush() } else { appendRaw(" ") }
            return
        default:
            break
        }
        if Self.blockTags.contains(name) {
            if name.hasPrefix("h"), name.count == 2 { inline.append(Inline(tag: name, style: .bold)) }
            return
        }
        var element = Inline(tag: name, style: [])
        switch name {
        case "b", "strong": element.style.insert(.bold)
        case "i", "em", "cite", "var", "dfn": element.style.insert(.italic)
        case "u", "ins": element.style.insert(.underline)
        case "a":
            if let href = attributes["href"]?.trimmingCharacters(in: .whitespacesAndNewlines), !href.isEmpty,
               !href.lowercased().hasPrefix("javascript:") {
                element.link = href
            }
        default: break
        }
        if let css = attributes["style"]?.lowercased() {
            let declarations = css.split(separator: ";").map { $0.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) } }
            for pair in declarations where pair.count == 2 {
                let (property, value) = (pair[0], pair[1])
                if property == "font-weight", ["bold", "bolder", "600", "700", "800", "900"].contains(value) {
                    element.style.insert(.bold)
                } else if property == "font-style", value.hasPrefix("italic") || value.hasPrefix("oblique") {
                    element.style.insert(.italic)
                } else if property.hasPrefix("text-decoration"), value.contains("underline") {
                    element.style.insert(.underline)
                }
            }
        }
        guard !Self.voidTags.contains(name) else { return }
        inline.append(element)
    }

    private mutating func end(_ name: String) {
        switch name {
        case "ul", "ol":
            flush()
            if !lists.isEmpty { lists.removeLast() }
            return
        case "blockquote":
            flush()
            quoteDepth = max(0, quoteDepth - 1)
            return
        case "pre":
            flush()
            preDepth = max(0, preDepth - 1)
            return
        case "td", "th":
            return
        default:
            break
        }
        if Self.blockTags.contains(name) {
            flush()
            if name.hasPrefix("h"), name.count == 2, let index = inline.lastIndex(where: { $0.tag == name }) {
                inline.remove(at: index)
            }
            return
        }
        if let index = inline.lastIndex(where: { $0.tag == name }) { inline.removeSubrange(index...) }
    }

    /// Text from the document: whitespace collapses unless inside `<pre>`.
    private mutating func append(_ text: String) {
        guard preDepth == 0 else {
            appendRaw(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: String(RichText.lineBreak)))
            return
        }
        var collapsed = ""
        var lastWasSpace = current.text.last.map { $0 == " " || $0 == RichText.lineBreak } ?? true
        for character in text {
            if character == " " || character == "\n" || character == "\r" || character == "\t" || character == "\r\n" {
                if !lastWasSpace { collapsed.append(" ") }
                lastWasSpace = true
            } else {
                collapsed.append(character == "\u{00A0}" ? " " : character)
                lastWasSpace = false
            }
        }
        appendRaw(collapsed)
    }

    private mutating func appendRaw(_ text: String) {
        guard !text.isEmpty else { return }
        if current.runs.isEmpty, current.kind == .paragraph, quoteDepth > 0 { current.kind = .quote }
        let style = style, link = link
        if let last = current.runs.last, last.style == style, last.link == link {
            current.runs[current.runs.count - 1].text += text
        } else {
            current.runs.append(RichText.Run(text, style: style, link: link))
        }
    }

    /// Ends the current block. A block holding only a `<br>` is an empty line; one with nothing is dropped.
    private mutating func flush() {
        var block = current
        // A trailing break inside a block doesn't show as a line of its own.
        if var last = block.runs.last, last.text.last == RichText.lineBreak {
            last.text.removeLast()
            block.runs[block.runs.count - 1] = last
        }
        // Collapsed spaces at a block's end aren't visible either.
        while var last = block.runs.last, last.text.last == " " {
            last.text.removeLast()
            if last.text.isEmpty { block.runs.removeLast() } else { block.runs[block.runs.count - 1] = last }
        }
        block.runs.removeAll { $0.text.isEmpty }
        if !block.runs.isEmpty || sawBreak || block.kind != .paragraph && block.kind != .quote {
            if block.kind == .paragraph, quoteDepth > 0 { block.kind = .quote }
            blocks.append(block)
        }
        current = RichText.Block()
        sawBreak = false
    }

    mutating func finish() -> [RichText.Block] {
        flush()
        return blocks
    }
}
