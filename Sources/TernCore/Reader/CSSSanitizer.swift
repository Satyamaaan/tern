import Foundation

/// What a mail's CSS revealed while it was sanitized.
struct CSSFindings {
    /// Remote images left out because the sender isn't trusted.
    var blockedRemote = 0
    /// The mail paints its own non-white backgrounds or uses light text, so it needs a light card in dark mode.
    var paintsOwnColors = false
}

/// Cleans inline `style` attributes and `<style>` sheets from mail. Drops anything that can run code,
/// load remote content without permission, or reach outside the message; rewrites `html`/`body`
/// selectors to the message wrappers; turns plain colors into `light-dark()` pairs so simple mails
/// read well in dark mode; and keeps the mail's own dark mode out (see `lightSchemeMedia`).
///
/// CSS is read one Unicode scalar at a time, as the browser reads it: `{` followed by a combining mark is
/// one character to Swift but still a `{` to WebKit. The output is written back from what was read, and every
/// piece of mail text in it (a selector, a value, an `@supports` condition) must be `isSelfContained`, so the
/// browser can't read the output's structure differently from the sanitizer.
struct CSSSanitizer {
    var urlPolicy: (String) -> URLDecision
    var findings = CSSFindings()

    enum URLDecision {
        case keep(String)
        case blocked
        case drop
    }

    init(urlPolicy: @escaping (String) -> URLDecision) {
        self.urlPolicy = urlPolicy
    }

    private typealias Scalars = String.UnicodeScalarView

    // MARK: Declarations

    mutating func declarations(_ css: String) -> String {
        let text = Self.stripComments(css)
        var output: [String] = []
        for declaration in Self.split(text, on: ";") {
            let scalars = declaration.unicodeScalars
            guard let colon = scalars.firstIndex(of: ":") else { continue }
            let property = String(scalars[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = String(scalars[scalars.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !property.isEmpty, property.unicodeScalars.allSatisfy(Self.isPropertyScalar),
                  !value.isEmpty, let cleaned = clean(property: property, value: &value) else { continue }
            output.append("\(property): \(cleaned)")
        }
        return output.joined(separator: "; ")
    }

    private mutating func clean(property: String, value: inout String) -> String? {
        guard Self.isSelfContained(value), !value.unicodeScalars.contains("<") else { return nil }
        let lower = value.lowercased()
        if Self.forbiddenProperties.contains(property) || Self.colorSchemeProperties.contains(property) { return nil }
        if Self.has(lower, "expression") || Self.has(lower, "javascript:") || Self.has(lower, "vbscript:")
            || Self.has(lower, "@import") || Self.reachesHost(lower) {
            return nil
        }
        if property == "position" {
            // `! important` with a space is still the important flag.
            let mode = String(lower.unicodeScalars.filter { !Self.isSpace($0) })
                .replacingOccurrences(of: "!important", with: "", options: .literal)
            if mode == "fixed" || mode == "sticky" { return nil }
        }
        var important = ""
        if let range = value.range(of: "!important", options: [.caseInsensitive, .literal]) {
            important = " !important"
            value.removeSubrange(range)
            value = value.trimmingCharacters(in: .whitespaces)
        }
        if Self.mayFetch(lower) {
            if Self.inertFunctions.contains(where: { Self.has(lower, $0) }) { return nil }
            // `var()` and `attr()` could hand `src()` or `image-set()` a string the sanitizer never sees.
            let takesStrings = ["src(", "image(", "image-set(", "cross-fade("].contains { Self.has(lower, $0) }
            if takesStrings, Self.has(lower, "var(") || Self.has(lower, "attr(") { return nil }
            guard let rewritten = rewriteFetches(in: value) else { return nil }
            value = rewritten
            if property.hasPrefix("background") { findings.paintsOwnColors = true }
        }
        switch property {
        case "color":
            if let color = CSSColor(value) {
                if color.isLight { findings.paintsOwnColors = true }
                value = color.adaptiveText(original: value)
            }
        case "background-color", "background":
            if let color = CSSColor(value) {
                if color.isNearWhite {
                    value = "light-dark(\(value), transparent)"
                } else if !color.isTransparent {
                    findings.paintsOwnColors = true
                }
            } else if property == "background-color" || Self.paintsBackground(lower) {
                findings.paintsOwnColors = true
            }
        default:
            break
        }
        let result = value + important
        return Self.isSelfContained(result) ? result : nil
    }

    /// True when a `background` shorthand sets a color or an image.
    private static func paintsBackground(_ value: String) -> Bool {
        let words = value.split(whereSeparator: { $0 == " " || $0 == "," })
        return words.contains { word in
            if word.hasPrefix("url(") || word.hasPrefix("linear-gradient") || word.hasPrefix("radial-gradient") { return true }
            if let color = CSSColor(String(word)) { return !color.isNearWhite && !color.isTransparent }
            return false
        }
    }

    /// True when a value calls a function that can load something.
    static func mayFetch(_ lowercased: String) -> Bool {
        ["url(", "src(", "image(", "image-set(", "cross-fade("].contains { has(lowercased, $0) }
            || inertFunctions.contains { has(lowercased, $0) }
    }

    /// Functions mail never needs that can pull in content from elsewhere; a declaration using one is dropped.
    static let inertFunctions = ["element(", "paint(", "-webkit-canvas("]

    /// Functions whose plain string arguments are image URLs.
    private static let imageFunctions: Set<String> = [
        "image-set", "-webkit-image-set", "image", "-webkit-image", "cross-fade", "-webkit-cross-fade",
    ]

    /// Applies the URL policy everywhere CSS can fetch: `url(…)`, `src(…)`, and the strings `image-set()`,
    /// `image()` and `cross-fade()` take as images. Blocked or dropped URLs become `none`; a value that
    /// can't be read safely returns nil.
    private mutating func rewriteFetches(in value: String) -> String? {
        let text = value.unicodeScalars
        var output = Scalars()
        var functions: [String] = []
        var name = Scalars()
        var index = text.startIndex
        func readString(_ quote: Unicode.Scalar) -> String? {
            var string = Scalars()
            text.formIndex(after: &index)
            while index < text.endIndex, text[index] != quote {
                string.append(text[index])
                text.formIndex(after: &index)
            }
            guard index < text.endIndex else { return nil }
            text.formIndex(after: &index)
            return String(string)
        }
        while index < text.endIndex {
            let scalar = text[index]
            switch scalar {
            case "(":
                let function = String(name).lowercased()
                let length = name.count
                name = Scalars()
                text.formIndex(after: &index)
                guard function == "url" || function == "src" else {
                    functions.append(function)
                    output.append(scalar)
                    continue
                }
                // `url(` takes everything up to `)`, quoted or not; `src(` takes one string.
                while index < text.endIndex, Self.isSpace(text[index]) { text.formIndex(after: &index) }
                var raw: String
                if index < text.endIndex, text[index] == "\"" || text[index] == "'" {
                    guard let string = readString(text[index]) else { return nil }
                    raw = string
                } else {
                    guard function == "url" else { return nil }
                    var unquoted = Scalars()
                    while index < text.endIndex, text[index] != ")" {
                        guard text[index] != "\"", text[index] != "'", text[index] != "(" else { return nil }
                        unquoted.append(text[index])
                        text.formIndex(after: &index)
                    }
                    raw = String(unquoted).trimmingCharacters(in: .whitespaces)
                }
                while index < text.endIndex, Self.isSpace(text[index]) { text.formIndex(after: &index) }
                guard index < text.endIndex, text[index] == ")" else { return nil }
                text.formIndex(after: &index)
                output.removeLast(length)
                output.append(contentsOf: replacement(for: raw).unicodeScalars)
            case ")":
                if !functions.isEmpty { functions.removeLast() }
                name = Scalars()
                output.append(scalar)
                text.formIndex(after: &index)
            case "\"", "'":
                guard let string = readString(scalar) else { return nil }
                name = Scalars()
                if let function = functions.last, Self.imageFunctions.contains(function) {
                    output.append(contentsOf: replacement(for: string).unicodeScalars)
                } else {
                    output.append(scalar)
                    output.append(contentsOf: string.unicodeScalars)
                    output.append(scalar)
                }
            default:
                if Self.isNameScalar(scalar) {
                    name.append(scalar)
                } else {
                    name = Scalars()
                }
                output.append(scalar)
                text.formIndex(after: &index)
            }
        }
        return String(output)
    }

    private mutating func replacement(for raw: String) -> String {
        switch urlPolicy(raw) {
        case .keep(let url): return "url(\"\(url.replacingOccurrences(of: "\"", with: "%22"))\")"
        case .blocked:
            findings.blockedRemote += 1
            return "none"
        case .drop: return "none"
        }
    }

    // MARK: Style sheets

    /// Sanitizes a whole `<style>` element. Selectors for `html`, `body` and `:root` are pointed at the
    /// message wrappers; media queries never see a dark colour scheme; `@import`, remote `@font-face`,
    /// media blocks that can't match and unknown at-rules go.
    mutating func stylesheet(_ css: String) -> String {
        // The light-scheme marker can only come from `lightSchemeMedia`.
        let text = Self.stripComments(css).unicodeScalars.filter { $0 != Self.lightSchemeScalar }
        var output = ""
        var index = text.startIndex
        sheet(text, &index, depth: 0, into: &output)
        return output
    }

    /// A `<style media>` sheet: sanitized only when its media list can match, then wrapped in `@media`
    /// written back from the parsed list.
    mutating func stylesheet(_ css: String, media: String?) -> String {
        switch media.map(Self.sheetMedia) ?? .everywhere {
        case .everywhere:
            return stylesheet(css)
        case .never:
            return ""
        case .when(let condition):
            let inner = stylesheet(css)
            return inner.isEmpty ? "" : "@media \(condition) {\n\(inner)}\n"
        }
    }

    private mutating func sheet(_ text: Scalars, _ index: inout Scalars.Index, depth: Int, into output: inout String) {
        while index < text.endIndex {
            skipWhitespace(text, &index)
            guard index < text.endIndex else { return }
            if text[index] == "}" {
                text.formIndex(after: &index)
                return
            }
            if text[index] == "@" {
                let prelude = readPrelude(text, &index)
                let head = prelude.unicodeScalars.prefix { !Self.isSpace($0) && $0 != "{" && $0 != "(" }
                let keyword = String(head).lowercased()
                let rest = String(prelude.unicodeScalars.dropFirst(head.count))
                guard index < text.endIndex, text[index] == "{" else {
                    if index < text.endIndex { text.formIndex(after: &index) }
                    continue
                }
                text.formIndex(after: &index)
                switch keyword {
                case "@media", "@supports":
                    let condition = keyword == "@media"
                        ? Self.lightSchemeMedia(rest).map { "@media \($0)" }
                        : Self.supportsCondition(rest).map { "@supports \($0)" }
                    if let condition, depth <= 4 {
                        var inner = ""
                        sheet(text, &index, depth: depth + 1, into: &inner)
                        output += "\(condition) {\(inner)}\n"
                    } else {
                        skipBlock(text, &index)
                    }
                case "@font-face":
                    let body = readBlock(text, &index)
                    let lower = body.lowercased()
                    let fetches = Self.has(lower, "url(") || Self.has(lower, "src(")
                    if !fetches || !Self.has(lower, "http") && !Self.has(lower, "//") {
                        let cleaned = declarations(body)
                        if Self.has(cleaned.lowercased(), "src") { output += "@font-face {\(cleaned)}\n" }
                    }
                default:
                    skipBlock(text, &index)
                }
                continue
            }
            let selector = readPrelude(text, &index)
            guard index < text.endIndex, text[index] == "{" else { return }
            text.formIndex(after: &index)
            let body = readBlock(text, &index)
            let cleanedSelector = Self.rewriteSelector(selector)
            let cleaned = declarations(body)
            if !cleanedSelector.isEmpty, !cleaned.isEmpty {
                output += "\(cleanedSelector) { \(cleaned) }\n"
            }
        }
    }

    /// An `@supports` condition is written back as the mail wrote it, so it must stand on its own. It can't
    /// select anything, but naming the shadow host is still left out so no output ever mentions it.
    private static func supportsCondition(_ condition: String) -> String? {
        let trimmed = condition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isSelfContained(trimmed), !trimmed.unicodeScalars.contains("<"),
              !reachesHost(trimmed.lowercased()) else { return nil }
        return trimmed
    }

    /// Points document-level selectors at the message's own wrappers: `html` and `:root` become
    /// `.tern-root`, `body` becomes `.tern-body`. Selectors that reach the shadow host or the reader
    /// around it (`:host`, `::part`, `::slotted`) are dropped, so mail can't move or cover Tern's UI.
    static func rewriteSelector(_ selector: String) -> String {
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isSelfContained(trimmed), !trimmed.unicodeScalars.contains("<") else { return "" }
        guard !reachesHost(trimmed.lowercased()) else { return "" }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        var output = documentSelector.stringByReplacingMatches(in: trimmed, range: range, withTemplate: "$1\u{1}$2")
        output = output.replacingOccurrences(of: "\u{1}html", with: ".tern-root", options: .caseInsensitive)
            .replacingOccurrences(of: "\u{1}:root", with: ".tern-root", options: .caseInsensitive)
            .replacingOccurrences(of: "\u{1}body", with: ".tern-body", options: .caseInsensitive)
        return output
    }

    private static let documentSelector = try! NSRegularExpression(
        pattern: #"(^|[\s>+~,(])(html|body|:root)(?=$|[\s>+~,.#:\[)])"#, options: [.caseInsensitive])

    /// Reads up to the next `{`, `;` or `}` outside a string. Like the browser, a string ends at its quote
    /// or at the end of its line.
    private func readPrelude(_ text: Scalars, _ index: inout Scalars.Index) -> String {
        let start = index
        var quote: Unicode.Scalar?
        while index < text.endIndex {
            let scalar = text[index]
            if let open = quote {
                if scalar == open || Self.isNewline(scalar) { quote = nil }
            } else if scalar == "\"" || scalar == "'" {
                quote = scalar
            } else if scalar == "{" || scalar == ";" || scalar == "}" {
                break
            }
            text.formIndex(after: &index)
        }
        return String(text[start..<index])
    }

    /// Reads declarations up to the matching `}`; nested blocks are skipped.
    private func readBlock(_ text: Scalars, _ index: inout Scalars.Index) -> String {
        var output = Scalars()
        var quote: Unicode.Scalar?
        while index < text.endIndex {
            let scalar = text[index]
            text.formIndex(after: &index)
            if let open = quote {
                if scalar == open || Self.isNewline(scalar) { quote = nil }
                output.append(scalar)
                continue
            }
            switch scalar {
            case "\"", "'":
                quote = scalar
                output.append(scalar)
            case "{":
                skipBlock(text, &index)
            case "}":
                return String(output)
            default:
                output.append(scalar)
            }
        }
        return String(output)
    }

    private func skipBlock(_ text: Scalars, _ index: inout Scalars.Index) {
        var depth = 1
        var quote: Unicode.Scalar?
        while index < text.endIndex, depth > 0 {
            let scalar = text[index]
            if let open = quote {
                if scalar == open || Self.isNewline(scalar) { quote = nil }
            } else if scalar == "\"" || scalar == "'" {
                quote = scalar
            } else if scalar == "{" {
                depth += 1
            } else if scalar == "}" {
                depth -= 1
            }
            text.formIndex(after: &index)
        }
    }

    private func skipWhitespace(_ text: Scalars, _ index: inout Scalars.Index) {
        while index < text.endIndex, Self.isSpace(text[index]) || text[index] == ";" { text.formIndex(after: &index) }
    }

    // MARK: Colour scheme

    /// The reader picks the colour scheme, not the mail: a mail's `color-scheme: light dark` on `:root` (which
    /// becomes `.tern-root`) turns every `light-dark()` colour on the light card to its dark side.
    /// `-apple-color-filter` is Apple Mail's dark-mode colour inversion.
    private static let colorSchemeProperties: Set<String> = ["color-scheme", "supported-color-schemes", "-apple-color-filter"]

    /// Resolves the light-scheme markers in a sanitized sheet. Mail that paints its own colours sits on a
    /// light card in dark mode, so its light conditions always match; simple mail follows the reader's theme.
    static func settleColorScheme(_ css: String, paintsOwnColors: Bool) -> String {
        guard css.unicodeScalars.contains(lightSchemeScalar) else { return css }
        return css.replacingOccurrences(
            of: lightScheme, with: paintsOwnColors ? alwaysMatches : "(prefers-color-scheme: light)", options: .literal)
    }

    // MARK: Helpers

    private static let forbiddenProperties: Set<String> = [
        "behavior", "-moz-binding", "-ms-behavior", "-webkit-user-modify", "zoom",
    ]

    /// True when mail text written back verbatim reads the same on its own as inside the output: strings close
    /// on their own line, brackets balance, and outside strings nothing opens or closes a block, ends a
    /// declaration, starts a comment, escapes a character or is a control character.
    static func isSelfContained(_ text: String) -> Bool {
        var brackets: [Unicode.Scalar] = []
        var quote: Unicode.Scalar?
        var previous: Unicode.Scalar = " "
        for scalar in text.unicodeScalars {
            if scalar.value < 0x20 && scalar != "\t" && !isNewline(scalar) || scalar.value == 0x7F { return false }
            if let open = quote {
                if scalar == open {
                    quote = nil
                } else if isNewline(scalar) || scalar == "\\" {
                    return false
                }
                previous = scalar
                continue
            }
            switch scalar {
            case "\"", "'": quote = scalar
            case "(", "[": brackets.append(scalar)
            case ")": guard brackets.popLast() == "(" else { return false }
            case "]": guard brackets.popLast() == "[" else { return false }
            case ";": guard !brackets.isEmpty else { return false }
            case "{", "}", "\\": return false
            case "*" where previous == "/": return false
            default: break
            }
            previous = scalar
        }
        return quote == nil && brackets.isEmpty
    }

    /// Removes `/* … */` comments; an unterminated one runs to the end, as in the browser.
    static func stripComments(_ css: String) -> String {
        let bytes = css.utf8
        guard bytes.contains(UInt8(ascii: "*")) else { return css }
        let slash = UInt8(ascii: "/"), star = UInt8(ascii: "*")
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var iterator = bytes.makeIterator()
        var pending: UInt8?
        while let byte = pending ?? iterator.next() {
            pending = nil
            guard byte == slash, let next = iterator.next() else {
                output.append(byte)
                continue
            }
            guard next == star else {
                output.append(byte)
                pending = next
                continue
            }
            var last: UInt8 = 0
            var closed = false
            while let inner = iterator.next() {
                if last == star, inner == slash {
                    closed = true
                    break
                }
                last = inner
            }
            if !closed { break }
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Splits on a separator outside quotes and parentheses, reading Unicode scalars.
    static func split(_ text: String, on separator: Unicode.Scalar) -> [String] {
        let scalars = text.unicodeScalars
        var parts: [String] = []
        var depth = 0
        var quote: Unicode.Scalar?
        var start = scalars.startIndex
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if let open = quote {
                if scalar == open || isNewline(scalar) { quote = nil }
            } else if scalar == "\"" || scalar == "'" {
                quote = scalar
            } else if scalar == "(" {
                depth += 1
            } else if scalar == ")" {
                depth = max(0, depth - 1)
            } else if scalar == separator, depth == 0 {
                parts.append(String(scalars[start..<index]))
                start = scalars.index(after: index)
            }
            scalars.formIndex(after: &index)
        }
        if start < scalars.endIndex { parts.append(String(scalars[start...])) }
        return parts
    }

    /// True for `:host`, `::part` and `::slotted`, which reach outside the shadow tree.
    private static func reachesHost(_ lowercased: String) -> Bool {
        has(lowercased, ":host") || has(lowercased, "::part") || has(lowercased, "::slotted")
    }

    /// A substring search on UTF-16 units, so a combining mark after the needle can't hide it.
    static func has(_ text: String, _ needle: String) -> Bool {
        text.range(of: needle, options: .literal) != nil
    }

    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.isWhitespace }

    /// The characters that end a CSS string: line feed, carriage return and form feed.
    private static func isNewline(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\n" || scalar == "\r" || scalar == "\u{C}"
    }

    private static func isPropertyScalar(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-"
    }

    /// Letters, digits, `-`, `_` and anything non-ASCII: what a CSS function name is made of.
    private static func isNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        isPropertyScalar(scalar) || ("A"..."Z").contains(scalar) || scalar == "_" || !scalar.isASCII
    }
}

/// An sRGB color parsed from CSS or an HTML color attribute.
struct CSSColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init?(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if value == "transparent" {
            self.init(red: 0, green: 0, blue: 0, alpha: 0)
            return
        }
        if let named = Self.named[value] {
            self.init(hex: named)
            return
        }
        if value.hasPrefix("#") || (value.count == 6 && value.allSatisfy(\.isHexDigit)) {
            var hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
            guard hex.allSatisfy(\.isHexDigit) else { return nil }
            if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6 || hex.count == 8, let number = UInt64(hex, radix: 16) else { return nil }
            if hex.count == 8 {
                self.init(hex: UInt32(number >> 8))
                alpha = Double(number & 0xFF) / 255
            } else {
                self.init(hex: UInt32(number))
            }
            return
        }
        if value.hasPrefix("rgb"), let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")") {
            let parts = value[value.index(after: open)..<close]
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
                .map(String.init)
            guard parts.count == 3 || parts.count == 4 else { return nil }
            func channel(_ part: String) -> Double? {
                if part.hasSuffix("%") { return Double(part.dropLast()).map { $0 / 100 } }
                return Double(part).map { $0 / 255 }
            }
            guard let r = channel(parts[0]), let g = channel(parts[1]), let b = channel(parts[2]) else { return nil }
            var a = 1.0
            if parts.count == 4 {
                if parts[3].hasSuffix("%") { a = (Double(parts[3].dropLast()) ?? 100) / 100 } else { a = Double(parts[3]) ?? 1 }
            }
            self.init(red: min(max(r, 0), 1), green: min(max(g, 0), 1), blue: min(max(b, 0), 1), alpha: a)
            return
        }
        return nil
    }

    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }

    /// WCAG relative luminance, 0 (black) … 1 (white).
    var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    var isTransparent: Bool { alpha < 0.05 }
    var isNearWhite: Bool { isTransparent || luminance > 0.93 }
    var isLight: Bool { !isTransparent && luminance > 0.6 }
    var chroma: Double { max(red, green, blue) - min(red, green, blue) }

    var hexString: String {
        func byte(_ c: Double) -> String { String(format: "%02x", Int((min(max(c, 0), 1) * 255).rounded())) }
        return "#" + byte(red) + byte(green) + byte(blue)
    }

    /// `light-dark(original, lighter)` for dark text colors; other colors stay as written.
    func adaptiveText(original: String) -> String {
        guard !isTransparent, luminance < 0.18 else { return original }
        return "light-dark(\(original), \(darkModeVariant.hexString))"
    }

    /// Dark text mapped onto a dark background: greys invert into the reader's text range,
    /// saturated colors keep their hue and get lighter.
    var darkModeVariant: CSSColor {
        if chroma < 0.12 {
            let gray = 0.92 - 0.6 * luminance.squareRoot()
            return CSSColor(red: gray, green: gray, blue: gray * 0.985)
        }
        var (hue, saturation, lightness) = hsl
        lightness = max(0.7, min(0.82, 1 - lightness * 0.5))
        saturation = min(saturation, 0.85)
        return CSSColor(hue: hue, saturation: saturation, lightness: lightness)
    }

    private var hsl: (Double, Double, Double) {
        let maxValue = max(red, green, blue), minValue = min(red, green, blue)
        let lightness = (maxValue + minValue) / 2
        guard maxValue != minValue else { return (0, 0, lightness) }
        let delta = maxValue - minValue
        let saturation = lightness > 0.5 ? delta / (2 - maxValue - minValue) : delta / (maxValue + minValue)
        var hue: Double
        if maxValue == red { hue = (green - blue) / delta + (green < blue ? 6 : 0) } else if maxValue == green { hue = (blue - red) / delta + 2 } else { hue = (red - green) / delta + 4 }
        hue /= 6
        return (hue, saturation, lightness)
    }

    private init(hue: Double, saturation: Double, lightness: Double) {
        func component(_ p: Double, _ q: Double, _ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        let q = lightness < 0.5 ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation
        let p = 2 * lightness - q
        self.init(
            red: component(p, q, hue + 1 / 3), green: component(p, q, hue), blue: component(p, q, hue - 1 / 3))
    }

    private static let named: [String: UInt32] = [
        "black": 0x000000, "white": 0xFFFFFF, "gray": 0x808080, "grey": 0x808080, "silver": 0xC0C0C0,
        "darkgray": 0xA9A9A9, "darkgrey": 0xA9A9A9, "dimgray": 0x696969, "dimgrey": 0x696969,
        "lightgray": 0xD3D3D3, "lightgrey": 0xD3D3D3, "gainsboro": 0xDCDCDC, "whitesmoke": 0xF5F5F5,
        "snow": 0xFFFAFA, "ivory": 0xFFFFF0, "linen": 0xFAF0E6, "beige": 0xF5F5DC, "red": 0xFF0000,
        "maroon": 0x800000, "darkred": 0x8B0000, "green": 0x008000, "darkgreen": 0x006400, "lime": 0x00FF00,
        "blue": 0x0000FF, "navy": 0x000080, "darkblue": 0x00008B, "mediumblue": 0x0000CD, "purple": 0x800080,
        "teal": 0x008080, "olive": 0x808000, "orange": 0xFFA500, "yellow": 0xFFFF00, "aqua": 0x00FFFF,
        "fuchsia": 0xFF00FF, "brown": 0xA52A2A, "darkslategray": 0x2F4F4F, "darkslategrey": 0x2F4F4F,
        "slategray": 0x708090, "slategrey": 0x708090, "midnightblue": 0x191970, "steelblue": 0x4682B4,
        "royalblue": 0x4169E1, "crimson": 0xDC143C, "firebrick": 0xB22222, "tomato": 0xFF6347,
        "dodgerblue": 0x1E90FF, "cornflowerblue": 0x6495ED, "seagreen": 0x2E8B57, "forestgreen": 0x228B22,
        "ghostwhite": 0xF8F8FF, "floralwhite": 0xFFFAF0, "aliceblue": 0xF0F8FF, "azure": 0xF0FFFF,
        "mintcream": 0xF5FFFA, "honeydew": 0xF0FFF0, "seashell": 0xFFF5EE, "oldlace": 0xFDF5E6,
        "lavender": 0xE6E6FA, "windowtext": 0x000000, "window": 0xFFFFFF,
    ]
}
