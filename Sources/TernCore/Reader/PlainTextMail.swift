import Foundation

/// Plain-text mail: finds the quoted reply and the signature, links URLs, and renders HTML for the
/// reader (Inter 14/22 with `white-space: pre-wrap`, so the sender's line breaks survive).
public enum PlainTextMail {
    /// A plain-text body split into what the sender wrote, their signature and the quoted reply below.
    public struct Parts: Equatable, Sendable {
        public var body: String
        public var signature: String?
        public var quote: String?
    }

    public static func split(_ text: String) -> Parts {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var end = lines.count
        var quote: String?
        if let start = quoteStart(lines) {
            let quoted = lines[start...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let before = lines[..<start].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty, !quoted.isEmpty {
                end = start
                quote = quoted
            }
        }
        var signature: String?
        if let start = signatureStart(lines[..<end]) {
            let signed = lines[start..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let before = lines[..<start].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty, !signed.isEmpty {
                signature = signed
                end = start
            }
        }
        let body = lines[..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Parts(body: body, signature: signature, quote: quote)
    }

    /// Renders a plain-text body for the reader.
    public static func html(_ text: String, collapseQuotes: Bool = true) -> SanitizedMail {
        let parts = collapseQuotes ? split(text) : Parts(body: text.trimmingCharacters(in: .whitespacesAndNewlines))
        var html = "<div class=\"tern-plain\">" + format(parts.body)
        if let signature = parts.signature { html += "<div class=\"tern-sig\">" + format(signature) + "</div>" }
        if let quote = parts.quote {
            html += "<div class=\"tern-quote-toggle\" role=\"button\" tabindex=\"0\" aria-label=\"Show quoted text\">•••</div>"
            html += "<div class=\"tern-quote\" hidden>" + format(quote) + "</div>"
        }
        html += "</div>"
        return SanitizedMail(
            html: html, css: "", bodyStyle: "", mode: .plain, blockedRemoteCount: 0,
            hasCollapsedQuote: parts.quote != nil)
    }

    /// Escapes text for HTML and wraps http(s), www. and email addresses in links.
    public static func linkify(_ text: String) -> String {
        let nsText = text as NSString
        var output = ""
        var location = 0
        for match in detector.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            guard let url = match.url, let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" || scheme == "mailto" else { continue }
            output += HTMLEntities.escape(nsText.substring(with: NSRange(location: location, length: match.range.location - location)))
            let label = nsText.substring(with: match.range)
            output += "<a href=\"\(HTMLEntities.escape(url.absoluteString))\" rel=\"noreferrer noopener\">\(HTMLEntities.escape(label))</a>"
            location = match.range.location + match.range.length
        }
        output += HTMLEntities.escape(nsText.substring(from: location))
        return output
    }

    // MARK: Pieces

    /// Lines that start with `>` become an indented block; everything else is linkified text.
    static func format(_ text: String) -> String {
        var output = ""
        var quoteRun: [Substring] = []
        var textRun: [Substring] = []
        func flushText() {
            guard !textRun.isEmpty else { return }
            output += linkify(textRun.joined(separator: "\n"))
            textRun = []
        }
        func flushQuote() {
            guard !quoteRun.isEmpty else { return }
            let stripped = quoteRun.map { line -> Substring in
                var line = line.dropFirst()
                if line.first == " " { line = line.dropFirst() }
                return line
            }
            output += "<div class=\"tern-inline-quote\">" + format(stripped.joined(separator: "\n")) + "</div>"
            quoteRun = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(">") {
                if !textRun.isEmpty, textRun.last?.isEmpty == true { textRun.removeLast() }
                flushText()
                quoteRun.append(line)
            } else {
                flushQuote()
                if textRun.isEmpty, line.isEmpty, !output.isEmpty { continue }
                textRun.append(line)
            }
        }
        flushQuote()
        flushText()
        return output
    }

    private static func quoteStart(_ lines: [String]) -> Int? {
        var forward: Int?
        var outlook: Int?
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if forwardMarkers.contains(where: { trimmed.localizedCaseInsensitiveContains($0) }) {
                forward = index
                break
            }
            if trimmed.range(of: #"^-{2,}\s*Original Message\s*-{2,}$"#, options: [.regularExpression, .caseInsensitive]) != nil {
                outlook = index
                break
            }
            if trimmed.count >= 10, trimmed.allSatisfy({ $0 == "_" }), nextNonEmpty(lines, after: index)?.hasPrefix("From:") == true {
                outlook = index
                break
            }
            if trimmed.hasPrefix("From:"), index == 0 || lines[index - 1].trimmingCharacters(in: .whitespaces).isEmpty,
               lines[(index + 1)..<min(lines.count, index + 6)].contains(where: { $0.hasPrefix("Sent:") || $0.hasPrefix("Date:") }) {
                outlook = index
                break
            }
        }
        var trailing: Int?
        var cursor = lines.count - 1
        while cursor >= 0, lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty { cursor -= 1 }
        var firstQuoted: Int?
        while cursor >= 0 {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") {
                firstQuoted = cursor
            } else if !trimmed.isEmpty {
                break
            }
            cursor -= 1
        }
        if let first = firstQuoted {
            trailing = first
            if let attribution = attributionStart(lines, before: first) { trailing = attribution }
        }
        let start = [outlook, trailing].compactMap { $0 }.min()
        if let forward, let start, forward < start { return nil }
        return start
    }

    /// "On Tue, Oct 14 at 9:02 AM Maya Chen <maya@lumen.io> wrote:", which clients wrap over up to three lines.
    private static func attributionStart(_ lines: [String], before index: Int) -> Int? {
        var cursor = index - 1
        while cursor >= 0, lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty { cursor -= 1 }
        guard cursor >= 0 else { return nil }
        var joined = ""
        for start in stride(from: cursor, through: max(0, cursor - 2), by: -1) {
            let line = lines[start].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { break }
            joined = joined.isEmpty ? line : line + " " + joined
            if joined.range(of: attributionPattern, options: [.regularExpression, .caseInsensitive]) != nil,
               joined.range(of: #"^(On|Am|Le|El|Il|Op|Em|W dniu|Den|На)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                return start
            }
        }
        return nil
    }

    private static func signatureStart(_ lines: ArraySlice<String>) -> Int? {
        if let delimiter = lines.lastIndex(where: { $0 == "-- " || $0 == "--" }) { return delimiter }
        guard let last = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        let line = lines[last].trimmingCharacters(in: .whitespaces)
        return mobileSignatures.contains(where: { line.hasPrefix($0) }) ? last : nil
    }

    private static func nextNonEmpty(_ lines: [String], after index: Int) -> String? {
        lines[(index + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?.trimmingCharacters(in: .whitespaces)
    }

    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static let attributionPattern =
        #"(wrote|schrieb|a écrit|escribió|ha scritto|scrisse|schreef|napisał|skrev|kirjoitti|написал|escreveu)\s*:\s*$"#

    private static let forwardMarkers = [
        "Forwarded message", "Begin forwarded message", "Weitergeleitete Nachricht", "Message transféré",
        "Mensaje reenviado", "Messaggio inoltrato",
    ]

    private static let mobileSignatures = [
        "Sent from my ", "Get Outlook for ", "Sent from Mail for ", "Sent from Yahoo Mail", "Sent via ",
        "Sent with Proton Mail",
    ]
}

extension PlainTextMail.Parts {
    init(body: String) {
        self.init(body: body, signature: nil, quote: nil)
    }
}
