import Foundation

/// A locally detected credential. Codes retain leading zeroes and omit grouping separators.
public enum LoginCredential: Hashable, Sendable {
    case code(String)
    case magicLink(URL)
}

/// Conservative, network-free hints from the current message, never its quoted history.
public enum LoginAssistance {
    /// Returns at most one unambiguous code followed by at most one unambiguous HTTPS login link.
    public static func extract(subject: String, text: String, html: String? = nil) -> [LoginCredential] {
        let subject = String(subject.prefix(1_000))
        let plain = currentText(String(text.prefix(32_000)))
        var codes = codeCandidates(subject).union(codeCandidates(plain))
        var links = plainLinks(plain)
        if let html, html.utf8.count <= 128_000 {
            let document = HTMLDocument.parse(html)
            // Stylesheets can hide arbitrary descendants. Without a CSS cascade, abstain.
            if document.styles.isEmpty, !hidden(document.bodyAttributes) {
                _ = MailQuotes.collapse(in: document.root)
                var visible = ""
                collect(document.root, text: &visible, links: &links)
                codes.formUnion(codeCandidates(currentText(visible)))
            }
        }
        var result: [LoginCredential] = []
        if codes.count == 1, let code = codes.first { result.append(.code(code)) }
        if links.count == 1, let link = links.first { result.append(.magicLink(link)) }
        return result
    }

    /// A credential is recent for twenty minutes, allowing one minute of clock skew.
    public static func isFresh(date: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return age >= -60 && age <= 20 * 60
    }

    private static func currentText(_ text: String) -> String {
        let body = PlainTextMail.split(text).body
        var lines: [String] = []
        for line in body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if matches(#"^(?:On .+wrote:|[- ]*(?:Original Message|Forwarded message)|From:)"#, trimmed) { break }
            if !trimmed.hasPrefix(">") { lines.append(line) }
        }
        return lines.joined(separator: "\n")
    }

    private static let cue = #"(?:verification|security|authentication|login|log[ -]?in|sign[ -]?in|one[ -]?time|temporary|access)\s+(?:passcode|code|password)|\bOTP\b|\bpasscode\b"#

    private static func codeCandidates(_ input: String) -> Set<String> {
        // Keep URLs out of both the candidates and their contextual evidence.
        let value = input.replacingOccurrences(of: #"https?://\S+"#, with: "", options: [.regularExpression, .caseInsensitive])
        let ns = value as NSString
        let pattern = #"(?<![\p{L}\p{N}.$,+-])[0-9]+(?:[ \u00a0\u202f-][0-9]+)*(?![\p{L}\p{N}%-]|[.,][0-9])"#
        var result = Set<String>()
        for match in regex(pattern).matches(in: value, range: NSRange(location: 0, length: ns.length)) {
            let start = max(0, match.range.location - 65)
            let end = min(ns.length, NSMaxRange(match.range) + 45)
            let vicinity = ns.substring(with: NSRange(location: start, length: end - start))
            guard matches(cue, vicinity),
                  !matches(#"\b(invoice|order|tracking|phone|discount|coupon|total|amount|receipt|year)\b|[$€£]"#, vicinity) else { continue }
            let code = ns.substring(with: match.range).filter { $0.isASCII && $0.isNumber }
            guard (4...8).contains(code.count) else { continue }
            result.insert(code)
        }
        return result
    }

    private static func plainLinks(_ value: String) -> Set<URL> {
        let ns = value as NSString
        var links = Set<URL>()
        for match in regex(#"https://[^\s<>\"']+"#).matches(in: value, range: NSRange(location: 0, length: ns.length)) {
            let raw = ns.substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: ").,;!"))
            let start = max(0, match.range.location - 100)
            let context = ns.substring(with: NSRange(location: start, length: match.range.location - start))
            if let url = magicLink(raw, label: context) { links.insert(url) }
        }
        return links
    }

    private static func magicLink(_ raw: String, label: String) -> URL? {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https",
              RemoteDestination.allows(url), LinkSafety.destination(of: url) == url,
              LinkSafety.mismatch(text: label, href: raw) == nil else { return nil }
        let evidence = (url.path + "?" + (url.query ?? "")).removingPercentEncoding ?? ""
        guard !matches(#"reset|password|unsubscribe|redirect|tracking|/click\b|[?&](?:url|redirect_uri|redirect_to|destination)="#, evidence),
              matches(#"\b(?:login|signin|sign-in|sign_in|magic|authenticate|auth|verify)\b"#, evidence),
              matches(#"[?&](?:token|code|ticket|key|otp)=[^&]{6,}|/(?:magic|login|signin|verify)/[^/]{12,}"#, evidence),
              matches(#"\b(?:sign[ -]?in|log[ -]?in|magic link|authenticate|verify your (?:email|account))\b"#, label) else { return nil }
        return url
    }

    private static func hidden(_ attributes: [HTMLAttribute]) -> Bool {
        attributes.contains { attribute in
            let value = attribute.value.lowercased().filter { !$0.isWhitespace }
            return attribute.name == "hidden" || (attribute.name == "aria-hidden" && value == "true")
                || (attribute.name == "style" && matches(#"display:none|visibility:(?:hidden|collapse)|opacity:0|font-size:0|(?:max-)?height:0|mso-hide:all"#, value))
        }
    }

    private static func collect(_ node: HTMLNode, text: inout String, links: inout Set<URL>) {
        guard text.utf8.count < 32_000 else { return }
        if node.kind == .text { text += HTMLEntities.decode(node.text); return }
        guard node.kind == .element, !hidden(node.attributes), node.name != "blockquote",
              !MailHTMLPolicy.dropWithContent.contains(node.name),
              !node.classes.contains(where: { $0.contains("quote") || $0 == "gmail_attr" || $0 == "moz-cite-prefix" }),
              !["divRplyFwdMsg", "x_divRplyFwdMsg", "appendonsend", "OLK_SRC_BODY_SECTION"].contains(node.attribute("id") ?? "") else { return }
        if ["div", "p", "br", "tr", "td", "li"].contains(node.name) { text += "\n" }
        var local = ""
        for child in node.children {
            // Outlook's separator starts a quote extending through its following siblings.
            if ["divRplyFwdMsg", "x_divRplyFwdMsg", "appendonsend", "OLK_SRC_BODY_SECTION"].contains(child.attribute("id") ?? "")
                || child.hasClass("OutlookMessageHeader") { break }
            guard text.utf8.count + local.utf8.count < 32_000 else { break }
            collect(child, text: &local, links: &links)
        }
        if node.name == "a", let href = node.attribute("href"), let url = magicLink(href, label: local) { links.insert(url) }
        text += local
        if ["div", "p", "tr", "li"].contains(node.name) { text += "\n" }
    }

    /// Compiled once per pattern; matching on a compiled expression is safe from any thread.
    private static let compiled = NSCache<NSString, NSRegularExpression>()

    private static func regex(_ pattern: String) -> NSRegularExpression {
        if let cached = compiled.object(forKey: pattern as NSString) { return cached }
        // All patterns are internal constants, never sender-supplied expressions.
        let expression = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        compiled.setObject(expression, forKey: pattern as NSString)
        return expression
    }

    private static func matches(_ pattern: String, _ value: String) -> Bool {
        regex(pattern).firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
}
