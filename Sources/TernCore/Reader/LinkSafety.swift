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
    /// link's destination. Redirectors that carry the destination (Google, Outlook Safe Links,
    /// Proofpoint, LinkedIn…) are followed to it; opaque click trackers of mailing services count as
    /// consistent.
    public static func mismatch(text: String, href: String) -> Mismatch? {
        guard let url = URL(string: href), isWeb(url), let shown = shownDomain(in: text) else { return nil }
        let target = destination(of: url)
        guard let host = target.host?.lowercased() else { return nil }
        guard registrableDomain(shown) != registrableDomain(host) else { return nil }
        if isClickTracker(host: host, path: target.path) { return nil }
        return Mismatch(shown: shown, actual: host)
    }

    /// Where a link really goes: wrapping redirectors are followed to the destination they carry.
    /// A wrapper whose destination can't be read is its own destination.
    public static func destination(of url: URL) -> URL {
        var current = url
        for _ in 0..<4 {
            guard let next = unwrapped(current), isWeb(next), next != current else { break }
            current = next
        }
        return current
    }

    private static func isWeb(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return (scheme == "http" || scheme == "https") && url.host?.isEmpty == false
    }

    /// The destination a known wrapping redirector carries in its URL.
    private static func unwrapped(_ url: URL) -> URL? {
        guard let host = url.host?.lowercased(), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        func query(_ names: String...) -> URL? {
            for name in names {
                if let value = components.queryItems?.first(where: { $0.name == name })?.value, let url = URL(string: value) {
                    return url
                }
            }
            return nil
        }
        let path = url.path
        let site = registrableDomain(host)
        if site.hasPrefix("google."), path == "/url" { return query("q", "url") }
        if host.hasSuffix(".safelinks.protection.outlook.com") { return query("url") }
        if host == "urldefense.proofpoint.com", path.hasPrefix("/v2/url"),
           let encoded = components.queryItems?.first(where: { $0.name == "u" })?.value {
            // v2: "-" stands for "%" and "_" for "/": https-3A__www.example.com_a → https://www.example.com/a
            let decoded = encoded.replacingOccurrences(of: "-", with: "%").replacingOccurrences(of: "_", with: "/")
            return decoded.removingPercentEncoding.flatMap(URL.init(string:))
        }
        if host == "urldefense.com", url.absoluteString.contains("/v3/__") {
            // v3: /v3/__<url>__;<checksum>. Characters it re-encoded become "*", which never occur in a host.
            let text = url.absoluteString
            guard let start = text.range(of: "/v3/__")?.upperBound,
                  let end = text.range(of: "__;", range: start..<text.endIndex)?.lowerBound else { return nil }
            let inner = String(text[start..<end])
            guard let scheme = inner.range(of: "://") else { return nil }
            let rest = inner[scheme.upperBound...]
            let hostEnd = rest.firstIndex { "/?#*:".contains($0) } ?? rest.endIndex
            return URL(string: String(inner[..<scheme.upperBound]) + rest[..<hostEnd] + "/")
        }
        if site == "mimecast.com", let domain = components.queryItems?.first(where: { $0.name == "domain" })?.value {
            // Mimecast keeps only the destination's domain.
            return URL(string: "https://\(domain)/")
        }
        if site == "linkedin.com", path.hasPrefix("/redir/") || path.hasPrefix("/safety/go") { return query("url") }
        if site == "facebook.com", path == "/l.php" { return query("u") }
        if site == "youtube.com", path == "/redirect" { return query("q") }
        if site == "medium.com", path == "/r" || path == "/r/" { return query("url") }
        if site == "slack-redir.net" { return query("url") }
        if site == "substack.com", path.hasPrefix("/redirect/") { return substackDestination(path) }
        return nil
    }

    /// Substack's `/redirect/2/<base64 JSON>.<signature>` keeps the destination in the JSON's "e".
    private static func substackDestination(_ path: String) -> URL? {
        guard let token = path.split(separator: "/").last?.split(separator: ".").first else { return nil }
        var base64 = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["e"] as? String else { return nil }
        return URL(string: value)
    }

    /// Opaque click trackers of mailing services: the text names the real site, the href goes through
    /// the tracker and the URL doesn't say where. Hosts where anyone can publish don't count.
    private static func isClickTracker(host: String, path: String) -> Bool {
        let site = registrableDomain(host)
        if clickTrackers.contains(site) { return true }
        switch site {
        case "substack.com": return host.hasPrefix("email.") || path.hasPrefix("/redirect/")
        case "beehiiv.com": return host.hasSuffix("mail.beehiiv.com")
        case "mimecast.com": return host.hasPrefix("protect")
        default: return false
        }
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

    /// Registrable domains used only for mailing-service click tracking.
    private static let clickTrackers: Set<String> = [
        "list-manage.com", "mcsv.net", "sendgrid.net", "mandrillapp.com", "hubspotlinks.com", "hubspotemail.net",
        "exacttarget.com", "mailgun.org", "awstrack.me", "convertkit-mail.com", "convertkit-mail2.com", "klclick.com",
        "klclick1.com", "customeriomail.com", "mlsend.com", "rs6.net", "createsend.com", "cmail19.com", "cmail20.com",
        "sparkpostmail.com", "mailjet.com", "postmarkapp.com", "intercom-clicks.com", "lnks.gd", "iterable.com",
        "braze.com",
    ]

    /// Things that look like domains in link text but are file names or project names ("Next.js").
    private static let fileExtensions: Set<String> = [
        "js", "ts", "jsx", "tsx", "md", "py", "rb", "go", "rs", "sh", "txt", "pdf", "png", "jpg", "jpeg", "gif",
        "html", "htm", "css", "json", "zip", "exe", "swift", "kt", "java", "cpp", "doc", "docx", "xls", "xlsx",
        "ppt", "pptx", "csv", "mov", "mp4", "mp3", "dmg", "pkg", "yml", "yaml", "toml", "lock",
    ]
}
