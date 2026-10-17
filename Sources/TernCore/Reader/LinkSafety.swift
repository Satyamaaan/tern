import Foundation

/// Compares a link's visible text with where it actually goes, to warn before a phishing click.
public enum LinkSafety {
    public struct Mismatch: Equatable, Sendable {
        /// The domain the link text shows, e.g. "paypal.com".
        public var shown: String
        /// The host the link opens, e.g. "paypa1-login.ru".
        public var actual: String
    }

    /// Returns the mismatch when the link text is itself a web address on a different site than the
    /// link's destination. Click-tracking redirects of mailing services count as consistent.
    public static func mismatch(text: String, href: String) -> Mismatch? {
        guard let url = URL(string: href), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), let shown = shownDomain(in: text) else { return nil }
        let actual = registrableDomain(host)
        guard registrableDomain(shown) != actual else { return nil }
        if redirectors.contains(actual) { return nil }
        return Mismatch(shown: shown, actual: host)
    }

    /// The host a link opens, as shown in the hover pill. Nil for non-web links.
    public static func displayHost(_ href: String) -> String? {
        guard let url = URL(string: href), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url.host?.lowercased()
    }

    /// The domain a link's visible text claims, when the whole text is a web address
    /// ("paypal.com", "https://www.paypal.com/signin"). Sentences and labels return nil.
    static func shownDomain(in text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines.union(["\u{00A0}", "<", ">", "\"", "'"]))
        guard !value.isEmpty, !value.contains(" "), value.count < 400 else { return nil }
        let explicit = value.lowercased().hasPrefix("http://") || value.lowercased().hasPrefix("https://")
        if let range = value.range(of: "://") { value = String(value[range.upperBound...]) }
        if let end = value.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { value = String(value[..<end]) }
        if let at = value.lastIndex(of: "@") { value = String(value[value.index(after: at)...]) }
        if let colon = value.firstIndex(of: ":") { value = String(value[..<colon]) }
        value = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let labels = value.split(separator: ".")
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }),
              let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return nil }
        let hasWWW = value.hasPrefix("www.")
        if !explicit, !hasWWW, fileExtensions.contains(String(tld)) { return nil }
        return value
    }

    /// The part of a host a company actually owns: "mail.google.com" → "google.com",
    /// "news.bbc.co.uk" → "bbc.co.uk".
    public static func registrableDomain(_ host: String) -> String {
        let labels = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")).split(separator: ".")
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if secondLevelSuffixes.contains(lastTwo) { return labels.suffix(3).joined(separator: ".") }
        return lastTwo
    }

    private static let secondLevelSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk", "com.au", "net.au", "org.au", "edu.au",
        "gov.au", "co.nz", "org.nz", "co.jp", "ne.jp", "or.jp", "ac.jp", "com.br", "net.br", "org.br", "com.mx",
        "co.in", "net.in", "org.in", "co.za", "com.sg", "com.hk", "com.tr", "co.kr", "com.cn", "com.tw", "co.il",
        "com.ar", "com.co", "com.pe", "co.id", "com.my", "com.ph", "com.vn", "com.ua", "com.pl", "co.at",
        "github.io", "herokuapp.com", "vercel.app", "netlify.app", "pages.dev", "web.app", "blogspot.com",
    ]

    /// Mailing-service click trackers: the text names the real site, the href goes through the tracker.
    private static let redirectors: Set<String> = [
        "list-manage.com", "mailchimp.com", "mcsv.net", "sendgrid.net", "mandrillapp.com", "hubspotlinks.com",
        "hs-sites.com", "exacttarget.com", "mailgun.org", "awstrack.me", "substack.com", "beehiiv.com",
        "convertkit-mail.com", "ck.page", "klclick.com", "klclick1.com", "customeriomail.com", "mlsend.com",
        "rs6.net", "createsend.com", "cmail19.com", "cmail20.com", "sparkpostmail.com", "mailjet.com",
        "postmarkapp.com", "intercom-clicks.com", "safelinks.protection.outlook.com", "google.com",
        "linkedin.com", "medium.com", "e.customeriomail.com", "lnks.gd", "links.iterable.com", "iterable.com",
        "braze.com", "bnc.lt", "app.link", "urldefense.com", "urldefense.proofpoint.com", "mimecast.com",
    ]

    /// Things that look like domains in link text but are file names or project names ("Next.js").
    private static let fileExtensions: Set<String> = [
        "js", "ts", "jsx", "tsx", "md", "py", "rb", "go", "rs", "sh", "txt", "pdf", "png", "jpg", "jpeg", "gif",
        "html", "htm", "css", "json", "zip", "exe", "swift", "kt", "java", "cpp", "doc", "docx", "xls", "xlsx",
        "ppt", "pptx", "csv", "mov", "mp4", "mp3", "dmg", "pkg", "yml", "yaml", "toml", "lock",
    ]
}
