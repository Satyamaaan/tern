import Foundation

/// What a mail's CSS revealed while it was sanitized.
struct CSSFindings {
    /// Remote images left out because the sender isn't trusted.
    var blockedRemote = 0
    /// The mail paints its own non-white backgrounds or uses light text, so it needs a light card in dark mode.
    var paintsOwnColors = false
}

/// Cleans inline `style` attributes and `<style>` sheets from mail. Drops anything that can run code,
/// load remote content without permission, or escape the message's box; rewrites `html`/`body`
/// selectors to the message wrapper; and turns plain colors into `light-dark()` pairs so simple mails
/// read well in dark mode.
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

    // MARK: Declarations

    mutating func declarations(_ css: String) -> String {
        let text = Self.stripComments(css)
        var output: [String] = []
        for declaration in Self.split(text, on: ";") {
            guard let colon = declaration.firstIndex(of: ":") else { continue }
            let property = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !property.isEmpty, property.allSatisfy({ $0.isLetter || $0 == "-" || $0.isNumber }),
                  !value.isEmpty, let cleaned = clean(property: property, value: &value) else { continue }
            output.append("\(property): \(cleaned)")
        }
        return output.joined(separator: "; ")
    }

    private mutating func clean(property: String, value: inout String) -> String? {
        let lower = value.lowercased()
        if Self.forbiddenProperties.contains(property) { return nil }
        if value.contains("\\") || lower.contains("expression") || lower.contains("javascript:")
            || lower.contains("vbscript:") || lower.contains("@import") || value.contains("<") {
            return nil
        }
        if property == "position" {
            let mode = lower.replacingOccurrences(of: "!important", with: "").trimmingCharacters(in: .whitespaces)
            if mode == "fixed" || mode == "sticky" { return nil }
        }
        var important = ""
        if let range = value.range(of: "!important", options: .caseInsensitive) {
            important = " !important"
            value.removeSubrange(range)
            value = value.trimmingCharacters(in: .whitespaces)
        }
        if lower.contains("url(") {
            guard let rewritten = rewriteURLs(in: value) else { return nil }
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
        return value + important
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

    /// Applies the URL policy to every `url(…)`. Blocked or dropped URLs become `none`.
    private mutating func rewriteURLs(in value: String) -> String? {
        var output = ""
        var rest = Substring(value)
        while let start = rest.range(of: "url(", options: .caseInsensitive) {
            output += rest[..<start.lowerBound]
            guard let close = rest[start.upperBound...].firstIndex(of: ")") else { return nil }
            var raw = rest[start.upperBound..<close].trimmingCharacters(in: .whitespaces)
            if raw.count >= 2, let first = raw.first, first == "\"" || first == "'", raw.last == first {
                raw = String(raw.dropFirst().dropLast())
            }
            switch urlPolicy(raw) {
            case .keep(let url): output += "url(\"\(url.replacingOccurrences(of: "\"", with: "%22"))\")"
            case .blocked:
                findings.blockedRemote += 1
                output += "none"
            case .drop: output += "none"
            }
            rest = rest[rest.index(after: close)...]
        }
        output += rest
        return output
    }

    // MARK: Style sheets

    /// Sanitizes a whole `<style>` element. Selectors for `html`, `body` and `:root` are pointed at
    /// `.tern-body`; `@import`, remote `@font-face`, dark-mode media blocks and unknown at-rules go.
    mutating func stylesheet(_ css: String) -> String {
        let text = Self.stripComments(css)
        var output = ""
        var index = text.startIndex
        sheet(text, &index, depth: 0, into: &output)
        return output
    }

    private mutating func sheet(_ text: String, _ index: inout String.Index, depth: Int, into output: inout String) {
        while index < text.endIndex {
            skipWhitespace(text, &index)
            guard index < text.endIndex else { return }
            if text[index] == "}" {
                index = text.index(after: index)
                return
            }
            if text[index] == "@" {
                let prelude = readPrelude(text, &index)
                let keyword = prelude.prefix { !$0.isWhitespace && $0 != "{" }.lowercased()
                guard index < text.endIndex, text[index] == "{" else {
                    if index < text.endIndex { index = text.index(after: index) }
                    continue
                }
                index = text.index(after: index)
                switch keyword {
                case "@media", "@supports":
                    let lowered = prelude.lowercased()
                    if lowered.contains("prefers-color-scheme") && lowered.contains("dark") || depth > 4 {
                        skipBlock(text, &index)
                    } else {
                        var inner = ""
                        sheet(text, &index, depth: depth + 1, into: &inner)
                        output += "\(prelude.trimmingCharacters(in: .whitespaces)) {\(inner)}\n"
                    }
                case "@font-face":
                    let body = readBlock(text, &index)
                    let lower = body.lowercased()
                    if !lower.contains("url(") || !lower.contains("http") && !lower.contains("//") {
                        let cleaned = declarations(body)
                        if cleaned.lowercased().contains("src") { output += "@font-face {\(cleaned)}\n" }
                    }
                default:
                    skipBlock(text, &index)
                }
                continue
            }
            let selector = readPrelude(text, &index)
            guard index < text.endIndex, text[index] == "{" else { return }
            index = text.index(after: index)
            let body = readBlock(text, &index)
            let cleanedSelector = Self.rewriteSelector(selector)
            let cleaned = declarations(body)
            if !cleanedSelector.isEmpty, !cleaned.isEmpty {
                output += "\(cleanedSelector) { \(cleaned) }\n"
            }
        }
    }

    /// Points document-level selectors at the shadow root: `html` and `:root` become `:host`,
    /// `body` becomes the message wrapper.
    static func rewriteSelector(_ selector: String) -> String {
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("<"), !trimmed.contains("\\") else { return "" }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        var output = documentSelector.stringByReplacingMatches(in: trimmed, range: range, withTemplate: "$1\u{1}$2")
        output = output.replacingOccurrences(of: "\u{1}html", with: ":host", options: .caseInsensitive)
            .replacingOccurrences(of: "\u{1}:root", with: ":host", options: .caseInsensitive)
            .replacingOccurrences(of: "\u{1}body", with: ".tern-body", options: .caseInsensitive)
        return output
    }

    private static let documentSelector = try! NSRegularExpression(
        pattern: #"(^|[\s>+~,(])(html|body|:root)(?=$|[\s>+~,.#:\[)])"#, options: [.caseInsensitive])

    private func readPrelude(_ text: String, _ index: inout String.Index) -> String {
        let start = index
        var quote: Character?
        while index < text.endIndex {
            let character = text[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "{" || character == ";" || character == "}" {
                break
            }
            index = text.index(after: index)
        }
        return String(text[start..<index])
    }

    /// Reads declarations up to the matching `}`; nested blocks are skipped.
    private func readBlock(_ text: String, _ index: inout String.Index) -> String {
        var output = ""
        var quote: Character?
        while index < text.endIndex {
            let character = text[index]
            index = text.index(after: index)
            if let open = quote {
                if character == open { quote = nil }
                output.append(character)
                continue
            }
            switch character {
            case "\"", "'":
                quote = character
                output.append(character)
            case "{":
                skipBlock(text, &index)
            case "}":
                return output
            default:
                output.append(character)
            }
        }
        return output
    }

    private func skipBlock(_ text: String, _ index: inout String.Index) {
        var depth = 1
        var quote: Character?
        while index < text.endIndex, depth > 0 {
            let character = text[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
            }
            index = text.index(after: index)
        }
    }

    private func skipWhitespace(_ text: String, _ index: inout String.Index) {
        while index < text.endIndex, text[index].isWhitespace || text[index] == ";" { index = text.index(after: index) }
    }

    // MARK: Helpers

    private static let forbiddenProperties: Set<String> = [
        "behavior", "-moz-binding", "-ms-behavior", "-webkit-user-modify", "zoom",
    ]

    static func stripComments(_ css: String) -> String {
        guard css.contains("/*") else { return css }
        var output = ""
        var rest = Substring(css)
        while let start = rest.range(of: "/*") {
            output += rest[..<start.lowerBound]
            guard let end = rest[start.upperBound...].range(of: "*/") else { return output }
            rest = rest[end.upperBound...]
        }
        output += rest
        return output
    }

    /// Splits on a separator outside quotes and parentheses.
    static func split(_ text: String, on separator: Character) -> [Substring] {
        var parts: [Substring] = []
        var depth = 0
        var quote: Character?
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth = max(0, depth - 1)
            } else if character == separator, depth == 0 {
                parts.append(text[start..<index])
                start = text.index(after: index)
            }
            index = text.index(after: index)
        }
        if start < text.endIndex { parts.append(text[start...]) }
        return parts
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
