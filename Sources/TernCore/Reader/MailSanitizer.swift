import Foundation

/// A message body made safe to show in the reader's web view.
public struct SanitizedMail: Hashable, Sendable {
    public enum Mode: String, Sendable {
        /// Plain-text mail rendered in the reader's own typography.
        case plain
        /// HTML that doesn't paint its own colors; follows the reader's light/dark theme.
        case simple
        /// HTML that paints its own backgrounds; stays on a light card in dark mode.
        case rich
    }

    /// Body markup, placed inside the `.tern-body` wrapper.
    public var html: String
    /// Sanitized contents of the mail's `<style>` elements.
    public var css: String
    /// Inline style for the `.tern-body` wrapper, from the mail's `<body>` attributes.
    public var bodyStyle: String
    public var mode: Mode
    /// Remote images and backgrounds left out because the sender isn't trusted.
    public var blockedRemoteCount: Int
    /// True when quoted text was folded behind a `•••` toggle.
    public var hasCollapsedQuote: Bool
}

/// Turns hostile mail HTML into markup that cannot run code, submit forms, navigate the reader, load
/// remote content without permission, or escape its box. It parses with HTML5-like rules and writes
/// back only allowlisted elements and attributes, so what WebKit parses is what was checked.
public enum MailSanitizer {
    public struct Options: Sendable {
        /// Load remote images and backgrounds (the sender is trusted).
        public var allowRemoteImages: Bool
        /// Maps a `cid:` content id (without angle brackets) to a URL the web view can load.
        public var resolveContentId: @Sendable (String) -> String?
        /// Maps an allowed http(s) image URL to the URL the web view loads it through. The reader
        /// can't fetch http(s) itself, so a remote image loads only where this put it.
        public var remoteImageURL: @Sendable (String) -> String
        /// Fold quoted replies behind a toggle.
        public var collapseQuotes: Bool

        public init(
            allowRemoteImages: Bool = false, collapseQuotes: Bool = true,
            remoteImageURL: @escaping @Sendable (String) -> String = { $0 },
            resolveContentId: @escaping @Sendable (String) -> String? = { _ in nil }
        ) {
            self.allowRemoteImages = allowRemoteImages
            self.collapseQuotes = collapseQuotes
            self.remoteImageURL = remoteImageURL
            self.resolveContentId = resolveContentId
        }
    }

    public static func sanitize(html: String, options: Options = Options()) -> SanitizedMail {
        let document = HTMLDocument.parse(html)
        let collapsed = options.collapseQuotes && MailQuotes.collapse(in: document.root)
        var writer = Writer(options: options)
        let css = document.styles.map { writer.css.stylesheet($0.css, media: $0.media) }.joined(separator: "\n")
        let bodyStyle = writer.bodyStyle(document.bodyAttributes)
        var output = ""
        output.reserveCapacity(html.utf8.count)
        for child in document.root.children { writer.write(child, into: &output) }
        let rich = writer.css.findings.paintsOwnColors || writer.paintsOwnColors
        return SanitizedMail(
            html: output, css: CSSSanitizer.settleColorScheme(css, paintsOwnColors: rich), bodyStyle: bodyStyle,
            mode: rich ? .rich : .simple,
            blockedRemoteCount: writer.css.findings.blockedRemote + writer.blockedRemote,
            hasCollapsedQuote: collapsed)
    }

    /// Stack for sanitizing: writing a body out recurses once per element level, up to `HTMLDocument.maxDepth`, and
    /// so do the quote finder and freeing the parsed tree. Dispatch and Swift concurrency threads have 512 KB, which a
    /// debug build overruns at the depth cap; the main thread has 8 MB.
    public static let stackSize = 8 << 20

    /// Runs `work` on a thread of its own with `stackSize` of stack and returns its result. Sanitizing off the main
    /// thread goes through here.
    public static func onDeepStack<Value: Sendable>(
        qualityOfService: QualityOfService = .userInitiated, _ work: @escaping @Sendable () -> Value
    ) async -> Value {
        await withCheckedContinuation { continuation in
            let thread = Thread { continuation.resume(returning: work()) }
            thread.stackSize = stackSize
            thread.qualityOfService = qualityOfService
            thread.start()
        }
    }

    /// A URL for an inline `cid:` part, served by the reader's scheme handler.
    public static func contentIdURL(accountId: String, messageId: String, contentId: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        func encode(_ part: String) -> String { part.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        return "\(contentIdScheme)://m/\(encode(accountId))/\(encode(messageId))/\(encode(contentId))"
    }

    /// Splits a `contentIdURL` back into its parts.
    public static func parseContentIdURL(_ url: URL) -> (accountId: String, messageId: String, contentId: String)? {
        guard url.scheme == contentIdScheme else { return nil }
        let parts = url.absoluteString.dropFirst("\(contentIdScheme)://m/".count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, let account = parts[0].removingPercentEncoding,
              let message = parts[1].removingPercentEncoding, let cid = parts[2].removingPercentEncoding else { return nil }
        return (account, message, cid)
    }

    public static let contentIdScheme = "tern-cid"
}

// MARK: - Policy

enum MailHTMLPolicy {
    static let allowedElements: Set<String> = [
        "a", "abbr", "acronym", "address", "area", "article", "aside", "b", "bdi", "bdo", "big", "blockquote",
        "br", "caption", "center", "cite", "code", "col", "colgroup", "dd", "del", "details", "dfn", "div", "dl",
        "dt", "em", "figcaption", "figure", "font", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header",
        "hgroup", "hr", "i", "img", "ins", "kbd", "li", "main", "map", "mark", "nav", "ol", "p", "pre", "q", "rp",
        "rt", "ruby", "s", "samp", "section", "small", "span", "strike", "strong", "sub", "summary", "sup",
        "table", "tbody", "td", "tfoot", "th", "thead", "time", "tr", "tt", "u", "ul", "var", "wbr",
    ]

    /// Removed together with everything inside them. Anything else unknown (forms, `o:p`, custom tags)
    /// is unwrapped: the element goes, its children stay.
    static let dropWithContent: Set<String> = [
        "script", "style", "iframe", "frame", "frameset", "object", "embed", "applet", "noscript", "noembed",
        "noframes", "template", "svg", "math", "title", "head", "meta", "link", "base", "select", "textarea",
        "input", "option", "optgroup", "datalist", "audio", "video", "canvas", "param", "source", "track",
        "portal", "xml", "dialog", "keygen", "plaintext", "xmp", "basefont", "bgsound", "image",
    ]

    static let globalAttributes: Set<String> = [
        "align", "valign", "bgcolor", "border", "cellpadding", "cellspacing", "class", "color", "dir", "face",
        "height", "width", "size", "hspace", "vspace", "id", "lang", "nowrap", "title", "alt", "style", "role",
        "colspan", "rowspan", "span", "start", "type", "reversed", "scope", "headers", "abbr", "summary",
        "bordercolor", "frame", "rules", "clear", "noshade", "char", "charoff", "compact", "datetime", "open",
    ]
}

// MARK: - Writer

private struct Writer {
    let options: MailSanitizer.Options
    var css: CSSSanitizer
    var blockedRemote = 0
    var paintsOwnColors = false

    init(options: MailSanitizer.Options) {
        self.options = options
        css = CSSSanitizer { raw in Self.imageDecision(raw, options: options) }
    }

    mutating func write(_ node: HTMLNode, into output: inout String) {
        switch node.kind {
        case .trusted:
            output += node.text
            for child in node.children { write(child, into: &output) }
            output += node.attribute("close") ?? ""
        case .text:
            output += Self.escapeText(node.text)
        case .element:
            let name = node.name
            if MailHTMLPolicy.dropWithContent.contains(name) { return }
            guard MailHTMLPolicy.allowedElements.contains(name) else {
                for child in node.children { write(child, into: &output) }
                return
            }
            if name == "img", Self.isTrackingPixel(node) || Self.isTracker(node) { return }
            output += "<" + name
            writeAttributes(of: node, into: &output)
            output += ">"
            if HTMLDocument.voidElements.contains(name) { return }
            for child in node.children { write(child, into: &output) }
            output += "</" + name + ">"
        }
    }

    mutating func writeAttributes(of node: HTMLNode, into output: inout String) {
        let name = node.name
        var style = ""
        var placeholder = false
        for attribute in node.attributes {
            let key = attribute.name
            let value = attribute.value
            switch key {
            case "href":
                guard name == "a" || name == "area", let url = Self.linkURL(value) else { continue }
                output += " href=\"\(HTMLEntities.escape(url))\""
            case "src":
                guard name == "img" else { continue }
                switch Self.imageDecision(value, options: options) {
                case .keep(let url):
                    output += " src=\"\(HTMLEntities.escape(url))\""
                    if Self.isRemote(value) { output += " referrerpolicy=\"no-referrer\" loading=\"lazy\"" }
                case .blocked:
                    blockedRemote += 1
                    placeholder = true
                    output += " data-tern-blocked=\"\""
                case .drop:
                    placeholder = true
                    output += " data-tern-missing=\"\""
                }
            case "background":
                guard ["table", "td", "th", "tr"].contains(name) else { continue }
                paintsOwnColors = true
                switch Self.imageDecision(value, options: options) {
                case .keep(let url): output += " background=\"\(HTMLEntities.escape(url))\""
                case .blocked: blockedRemote += 1
                case .drop: break
                }
            case "usemap":
                guard name == "img", value.hasPrefix("#") else { continue }
                output += " usemap=\"\(HTMLEntities.escape(value))\""
            case "name":
                guard name == "a" || name == "map" else { continue }
                output += " name=\"\(HTMLEntities.escape(value))\""
            case "shape", "coords":
                guard name == "area" else { continue }
                output += " \(key)=\"\(HTMLEntities.escape(value))\""
            case "alt" where name == "area":
                output += " alt=\"\(HTMLEntities.escape(value))\""
            case "style":
                let cleaned = css.declarations(value)
                if !cleaned.isEmpty { style = style.isEmpty ? cleaned : style + "; " + cleaned }
            case "bgcolor":
                guard let color = CSSColor(value) else { continue }
                if color.isNearWhite {
                    let generated = "background-color: light-dark(\(color.hexString), transparent)"
                    style = style.isEmpty ? generated : generated + "; " + style
                } else {
                    paintsOwnColors = true
                    output += " bgcolor=\"\(color.hexString)\""
                }
            case "color":
                guard let color = CSSColor(value) else { continue }
                if name == "font" {
                    if color.isLight { paintsOwnColors = true }
                    let generated = "color: \(color.adaptiveText(original: color.hexString))"
                    style = style.isEmpty ? generated : generated + "; " + style
                } else {
                    output += " color=\"\(color.hexString)\""
                }
            case "class":
                let classes = value.split(whereSeparator: \.isWhitespace).filter { !$0.hasPrefix("tern-") }
                if !classes.isEmpty { output += " class=\"\(HTMLEntities.escape(classes.joined(separator: " ")))\"" }
            case "width", "height":
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isNumber || $0 == "." || $0 == "%" || $0 == "p" || $0 == "x" }) else { continue }
                output += " \(key)=\"\(trimmed)\""
            default:
                guard MailHTMLPolicy.globalAttributes.contains(key)
                    || (key.hasPrefix("aria-") && key.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") })
                else { continue }
                output += " \(key)=\"\(HTMLEntities.escape(value))\""
            }
        }
        if name == "a" { output += " rel=\"noreferrer noopener\"" }
        if placeholder, let width = Self.pixels(node.attribute("width")), let height = Self.pixels(node.attribute("height")) {
            let ratio = "aspect-ratio: \(width) / \(height)"
            style = style.isEmpty ? ratio : style + "; " + ratio
        }
        if !style.isEmpty { output += " style=\"\(HTMLEntities.escape(style))\"" }
    }

    /// Style for the `.tern-body` wrapper from `<body bgcolor text background style>`.
    mutating func bodyStyle(_ attributes: [HTMLAttribute]) -> String {
        var parts: [String] = []
        for attribute in attributes {
            switch attribute.name {
            case "bgcolor":
                guard let color = CSSColor(attribute.value) else { continue }
                if color.isNearWhite {
                    parts.append("background-color: light-dark(\(color.hexString), transparent)")
                } else {
                    paintsOwnColors = true
                    parts.append("background-color: \(color.hexString)")
                }
            case "text":
                guard let color = CSSColor(attribute.value) else { continue }
                if color.isLight { paintsOwnColors = true }
                parts.append("color: \(color.adaptiveText(original: color.hexString))")
            case "background":
                paintsOwnColors = true
                switch Self.imageDecision(attribute.value, options: options) {
                case .keep(let url): parts.append("background-image: url(\"\(url.replacingOccurrences(of: "\"", with: "%22"))\")")
                case .blocked: blockedRemote += 1
                case .drop: break
                }
            case "style":
                let cleaned = css.declarations(attribute.value)
                if !cleaned.isEmpty { parts.append(cleaned) }
            default:
                continue
            }
        }
        return parts.joined(separator: "; ")
    }

    // MARK: URLs

    /// Absolute http(s), mailto and tel links, and in-message anchors. Everything else is dropped.
    static func linkURL(_ raw: String) -> String? {
        let url = cleanURL(raw)
        guard !url.isEmpty else { return nil }
        if url.hasPrefix("#") { return url }
        if url.hasPrefix("//") { return "https:" + url }
        switch scheme(of: url) {
        case "http", "https", "mailto", "tel": return url
        default: return nil
        }
    }

    static func imageDecision(_ raw: String, options: MailSanitizer.Options) -> CSSSanitizer.URLDecision {
        var url = cleanURL(raw)
        guard !url.isEmpty else { return .drop }
        if url.hasPrefix("//") { url = "https:" + url }
        switch scheme(of: url) {
        case "http", "https":
            if MailTrackers.isTracker(url) { return .drop }
            return options.allowRemoteImages ? .keep(options.remoteImageURL(url)) : .blocked
        case "data":
            let lower = url.lowercased()
            let images = ["data:image/png", "data:image/jpeg", "data:image/jpg", "data:image/gif", "data:image/webp",
                          "data:image/bmp", "data:image/avif", "data:image/heic", "data:image/svg+xml"]
            return images.contains(where: { lower.hasPrefix($0) }) ? .keep(url) : .drop
        case "cid":
            var id = String(url.dropFirst(4))
            id = id.removingPercentEncoding ?? id
            if id.hasPrefix("<"), id.hasSuffix(">") { id = String(id.dropFirst().dropLast()) }
            return options.resolveContentId(id).map { .keep($0) } ?? .drop
        default:
            return .drop
        }
    }

    static func isRemote(_ raw: String) -> Bool {
        let url = cleanURL(raw)
        return url.hasPrefix("//") || ["http", "https"].contains(scheme(of: url) ?? "")
    }

    /// Removes the whitespace and control characters browsers ignore inside URLs, so
    /// `java\nscript:` can't slip past the scheme check.
    static func cleanURL(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars where scalar.value > 0x20 && scalar.value != 0x7F {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    static func scheme(of url: String) -> String? {
        guard let colon = url.firstIndex(of: ":") else { return nil }
        let candidate = url[..<colon]
        guard let first = candidate.first, first.isLetter,
              candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") }) else {
            return nil
        }
        return candidate.lowercased()
    }

    // MARK: Helpers

    /// An image whose URL is an open tracker goes without a trace, like a pixel: no stand-in box in the mail.
    static func isTracker(_ node: HTMLNode) -> Bool {
        guard let source = node.attribute("src"), isRemote(source) else { return false }
        var url = cleanURL(source)
        if url.hasPrefix("//") { url = "https:" + url }
        return MailTrackers.isTracker(url)
    }

    static func isTrackingPixel(_ node: HTMLNode) -> Bool {
        guard let source = node.attribute("src"), isRemote(source) else { return false }
        return MailTrackers.isPixel(width: node.attribute("width"), height: node.attribute("height"),
                                    style: node.attribute("style"), hidden: node.attribute("hidden") != nil)
    }

    /// A whole-pixel size from a `width`/`height` attribute ("600", "600px"); nil for percentages.
    static func pixels(_ value: String?) -> Int? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "px", with: "")
        guard let number = Double(trimmed), number >= 1 else { return nil }
        return Int(number.rounded())
    }

    static func escapeText(_ text: String) -> String {
        guard text.utf8.contains(where: { $0 == 0x3C || $0 == 0x3E }) else { return text }
        return text.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
