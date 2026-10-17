import Foundation

/// Plain-text helpers shared by the rule classifier and the AI prompts.
public enum MailText {
    /// The new text of a message: quoted replies, forwarded headers and signatures-after-quotes are cut.
    public static func stripQuoted(_ text: String) -> String {
        var kept: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") { continue }
            if isQuoteHeader(trimmed) { break }
            kept.append(line)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Collapses whitespace to single spaces and cuts to `limit` characters, ending with "…" when cut.
    public static func compact(_ text: String, limit: Int) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(max(0, limit - 1))).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Lowercased domain of an address, "" when there is none.
    public static func domain(of email: String) -> String {
        guard let at = email.lastIndex(of: "@") else { return "" }
        return email[email.index(after: at)...].lowercased()
    }

    /// Lowercased part before the "@".
    public static func localPart(of email: String) -> String {
        guard let at = email.lastIndex(of: "@") else { return email.lowercased() }
        return email[..<at].lowercased()
    }

    /// True when `domain` is `parent` or one of its subdomains.
    public static func domain(_ domain: String, isWithin parent: String) -> Bool {
        domain == parent || domain.hasSuffix("." + parent)
    }

    /// Case- and accent-insensitive form for "contains" comparisons.
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func isQuoteHeader(_ line: String) -> Bool {
        if line.hasPrefix("On "), line.hasSuffix("wrote:") { return true }
        if line.hasPrefix("-----Original Message-----") { return true }
        if line.hasPrefix("---------- Forwarded message") { return true }
        if line.hasPrefix("From: "), line.contains("@") { return true }
        return false
    }
}
