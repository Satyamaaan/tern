import Foundation

extension MailParsing {
    /// Readable plain text from an HTML body, for the search index and previews: drops scripts,
    /// styles, the head and comments, turns block elements into line breaks, decodes entities,
    /// removes invisible padding characters and collapses whitespace.
    public static func plainText(fromHTML html: String) -> String {
        let scalars = Array(html.unicodeScalars)
        var output = String.UnicodeScalarView()
        output.reserveCapacity(scalars.count / 2)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "<", let next = skipMarkup(scalars, from: index, into: &output) {
                index = next
            } else if scalar == "&" {
                index = appendEntity(scalars, from: index, into: &output)
            } else {
                output.append(scalar)
                index += 1
            }
        }
        return normalizeWhitespace(String(output))
    }

    /// Decodes named and numeric character references, e.g. in Gmail's snippets.
    public static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            if scalars[index] == "&" {
                index = appendEntity(scalars, from: index, into: &output)
            } else {
                output.append(scalars[index])
                index += 1
            }
        }
        return String(output)
    }

    /// Escapes text for HTML, keeping its line breaks.
    public static func escapeHTML(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "\n", "\r\n": result += "<br>\n"
            default: result.append(character)
            }
        }
        return result
    }

    // MARK: Markup

    /// Elements whose content is never shown.
    private static let hiddenElements: Set<String> = ["script", "style", "head", "title", "noscript", "template", "svg", "xml"]

    private static let blockElements: Set<String> = [
        "p", "div", "br", "tr", "li", "ul", "ol", "dl", "dt", "dd", "table", "thead", "tbody", "tfoot",
        "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "hr", "section", "article", "header",
        "footer", "main", "nav", "aside", "address", "center", "form", "fieldset", "figure", "figcaption",
    ]

    private static let cellElements: Set<String> = ["td", "th"]

    /// Skips the tag, comment or declaration at `start` and returns the index after it, or nil when
    /// the `<` is literal text.
    private static func skipMarkup(_ s: [Unicode.Scalar], from start: Int, into output: inout String.UnicodeScalarView) -> Int? {
        let count = s.count
        var index = start + 1
        guard index < count else { return nil }

        if s[index] == "!" {
            if matches(s, at: index, "!--") {
                return find(s, "-->", from: index + 3).map { $0 + 3 } ?? count
            }
            return find(s, ">", from: index).map { $0 + 1 } ?? count
        }
        if s[index] == "?" {
            return find(s, ">", from: index).map { $0 + 1 } ?? count
        }

        var closing = false
        if s[index] == "/" { closing = true; index += 1 }
        guard index < count, isASCIILetter(s[index]) else { return nil }
        let nameStart = index
        while index < count, isASCIILetter(s[index]) || isASCIIDigit(s[index]) || s[index] == "-" || s[index] == ":" { index += 1 }
        let name = String(String.UnicodeScalarView(s[nameStart..<index])).lowercased()

        // The end of the tag, honoring quoted attribute values.
        var quote: Unicode.Scalar?
        var previous: Unicode.Scalar = " "
        while index < count {
            let scalar = s[index]
            if let open = quote {
                if scalar == open { quote = nil }
            } else if (scalar == "\"" || scalar == "'") && previous == "=" {
                quote = scalar
            } else if scalar == ">" {
                break
            }
            if !scalar.properties.isWhitespace { previous = scalar }
            index += 1
        }
        let afterTag = min(index + 1, count)

        if !closing, hiddenElements.contains(name) {
            return findClosingTag(s, name: name, from: afterTag) ?? afterTag
        }
        if blockElements.contains(name) {
            output.append("\n")
        } else if cellElements.contains(name) {
            output.append(" ")
        }
        return afterTag
    }

    private static func findClosingTag(_ s: [Unicode.Scalar], name: String, from start: Int) -> Int? {
        let pattern = Array(("</" + name).unicodeScalars)
        var index = start
        while index + pattern.count <= s.count {
            if s[index] == "<", lowercasedMatch(s, at: index, pattern) {
                return find(s, ">", from: index).map { $0 + 1 } ?? s.count
            }
            index += 1
        }
        return nil
    }

    private static func lowercasedMatch(_ s: [Unicode.Scalar], at index: Int, _ pattern: [Unicode.Scalar]) -> Bool {
        for (offset, expected) in pattern.enumerated() {
            let scalar = s[index + offset]
            let lowered = isASCIILetter(scalar) ? Unicode.Scalar(scalar.value | 0x20)! : scalar
            if lowered != expected { return false }
        }
        return true
    }

    private static func matches(_ s: [Unicode.Scalar], at index: Int, _ literal: String) -> Bool {
        let pattern = Array(literal.unicodeScalars)
        guard index + pattern.count <= s.count else { return false }
        return pattern.enumerated().allSatisfy { s[index + $0.offset] == $0.element }
    }

    private static func find(_ s: [Unicode.Scalar], _ literal: String, from start: Int) -> Int? {
        var index = start
        while index < s.count {
            if matches(s, at: index, literal) { return index }
            index += 1
        }
        return nil
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 0x41 && scalar.value <= 0x5A) || (scalar.value >= 0x61 && scalar.value <= 0x7A)
    }

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x30 && scalar.value <= 0x39
    }

    // MARK: Entities

    /// Appends the character reference at `start` (or a literal `&`) and returns the index after it.
    private static func appendEntity(_ s: [Unicode.Scalar], from start: Int, into output: inout String.UnicodeScalarView) -> Int {
        var index = start + 1
        var name = String.UnicodeScalarView()
        while index < s.count, index - start <= 32, s[index] != ";" {
            let scalar = s[index]
            guard isASCIILetter(scalar) || isASCIIDigit(scalar) || scalar == "#" else { break }
            name.append(scalar)
            index += 1
        }
        let terminated = index < s.count && s[index] == ";"
        let key = String(name)
        if let decoded = decodeReference(key), terminated || laxEntities.contains(key) {
            output.append(contentsOf: decoded.unicodeScalars)
            return terminated ? index + 1 : index
        }
        output.append("&")
        return start + 1
    }

    private static func decodeReference(_ name: String) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value: UInt32?
            if digits.first == "x" || digits.first == "X" {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            guard let value else { return nil }
            // Windows-1252 code points that HTML maps to their real characters.
            if (0x80...0x9F).contains(value), let mapped = String(data: Data([UInt8(value)]), encoding: .windowsCP1252) {
                return mapped
            }
            return Unicode.Scalar(value).map { String(Character($0)) }
        }
        return namedEntities[name] ?? namedEntities[name.lowercased()]
    }

    /// Entities commonly written without the trailing semicolon.
    private static let laxEntities: Set<String> = ["amp", "lt", "gt", "quot", "nbsp", "copy", "reg"]

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
        "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}", "zwnj": "\u{200C}", "zwj": "\u{200D}",
        "lrm": "\u{200E}", "rlm": "\u{200F}", "shy": "\u{AD}",
        "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–",
        "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "ldquo": "“", "rdquo": "”", "bdquo": "„",
        "laquo": "«", "raquo": "»", "lsaquo": "‹", "rsaquo": "›", "bull": "•", "middot": "·",
        "prime": "′", "Prime": "″", "dagger": "†", "Dagger": "‡", "permil": "‰",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "curren": "¤", "sect": "§", "para": "¶",
        "deg": "°", "plusmn": "±", "times": "×", "divide": "÷", "micro": "µ", "frac12": "½",
        "frac14": "¼", "frac34": "¾", "sup1": "¹", "sup2": "²", "sup3": "³", "ordf": "ª", "ordm": "º",
        "iexcl": "¡", "iquest": "¿", "brvbar": "¦", "uml": "¨", "macr": "¯", "acute": "´", "cedil": "¸",
        "not": "¬", "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔", "check": "✓",
        "hearts": "♥", "star": "☆", "infin": "∞", "ne": "≠", "le": "≤", "ge": "≥", "minus": "−",
        "Agrave": "À", "Aacute": "Á", "Acirc": "Â", "Atilde": "Ã", "Auml": "Ä", "Aring": "Å", "AElig": "Æ",
        "Ccedil": "Ç", "Egrave": "È", "Eacute": "É", "Ecirc": "Ê", "Euml": "Ë", "Igrave": "Ì", "Iacute": "Í",
        "Icirc": "Î", "Iuml": "Ï", "ETH": "Ð", "Ntilde": "Ñ", "Ograve": "Ò", "Oacute": "Ó", "Ocirc": "Ô",
        "Otilde": "Õ", "Ouml": "Ö", "Oslash": "Ø", "Ugrave": "Ù", "Uacute": "Ú", "Ucirc": "Û", "Uuml": "Ü",
        "Yacute": "Ý", "THORN": "Þ", "szlig": "ß", "agrave": "à", "aacute": "á", "acirc": "â", "atilde": "ã",
        "auml": "ä", "aring": "å", "aelig": "æ", "ccedil": "ç", "egrave": "è", "eacute": "é", "ecirc": "ê",
        "euml": "ë", "igrave": "ì", "iacute": "í", "icirc": "î", "iuml": "ï", "eth": "ð", "ntilde": "ñ",
        "ograve": "ò", "oacute": "ó", "ocirc": "ô", "otilde": "õ", "ouml": "ö", "oslash": "ø", "ugrave": "ù",
        "uacute": "ú", "ucirc": "û", "uuml": "ü", "yacute": "ý", "thorn": "þ", "yuml": "ÿ", "OElig": "Œ",
        "oelig": "œ", "Scaron": "Š", "scaron": "š", "Yuml": "Ÿ", "fnof": "ƒ", "circ": "ˆ", "tilde": "˜",
    ]

    // MARK: Whitespace

    /// Characters newsletters use as invisible padding.
    private static let invisible: Set<Unicode.Scalar> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}", "\u{AD}", "\u{34F}", "\u{180E}"]

    /// Collapses runs of spaces, trims lines, and keeps at most one blank line between paragraphs.
    static func normalizeWhitespace(_ text: String) -> String {
        var lines: [String] = []
        var previousBlank = true
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var line = String.UnicodeScalarView()
            var lastWasSpace = true
            for scalar in rawLine.unicodeScalars {
                if invisible.contains(scalar) { continue }
                if scalar.properties.isWhitespace {
                    if !lastWasSpace { line.append(" ") }
                    lastWasSpace = true
                } else {
                    line.append(scalar)
                    lastWasSpace = false
                }
            }
            if line.last == " " { line.removeLast() }
            if line.isEmpty {
                if !previousBlank { lines.append("") }
                previousBlank = true
            } else {
                lines.append(String(line))
                previousBlank = false
            }
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
