import Foundation

/// Open tracking in mail: pixels and beacons that tell the sender when, where and how often a message was
/// read. The sanitizer drops them before the reader asks for anything, so they never load, whatever the
/// images setting.
enum MailTrackers {
    /// Hosts and URL fragments of tracking services, matched anywhere in the lowercased URL.
    static let fragments: [String] = [
        "mailtrack.io", "t.yesware.com", "mailstat.us", "track.hubspot.com", "pixel.mailchimp.com",
        "list-manage.com/track", "sendgrid.net/wf/open", "mandrillapp.com/track", "t.sidekickopen",
        "email.mg.", "open.convertkit", "trk.klclick", "links.iterable.com/e/o", "superhuman.com/~",
        "bl-1.com", "emltrk.com", "getnotify.com", "pixel.wp.com", "pmtrk",
    ]

    /// File names that only open trackers use.
    static let pixelFiles: Set<String> = ["open.gif", "open.png", "open.php", "pixel.gif", "1x1.gif", "1x1.png", "beacon.gif"]

    /// True for an http(s) image URL that is an open tracker: a known tracking host, or the URL shapes mail
    /// services give their open pixels, also on a sender's own link domain.
    static func isTracker(_ url: String) -> Bool {
        let lower = url.lowercased()
        if fragments.contains(where: { lower.contains($0) }) { return true }
        guard let (host, path) = hostAndPath(lower) else { return false }
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        let segments = path.split(separator: "/")

        // HubSpot, Amazon SES opens (`/L0/` is a click), Postmark.
        if on("t.hubspotemail.net") || on("track.hubspot.com") { return true }
        if on("awstrack.me"), path.hasPrefix("/i0/") { return true }
        if on("pstmrk.it"), path.hasPrefix("/open") { return true }
        // Customer.io, Iterable and senders' own link domains: `/e/o/<token>`.
        if segments.count >= 3, segments[0] == "e", segments[1] == "o" { return true }
        // SendGrid, also on a sender's link domain.
        if path.hasPrefix("/wf/open") { return true }
        // Mailgun on its `email.` link domains: `/o/<token>`, a long token with no file extension.
        if host.hasPrefix("email."), segments.count == 2, segments[0] == "o", segments[1].count >= 20, !segments[1].contains(".") {
            return true
        }
        // Mailchimp and the generic `/track/open`, `/track/open.php`.
        if zip(segments, segments.dropFirst()).contains(where: { $0 == "track" && ($1 == "open" || $1.hasPrefix("open.")) }) {
            return true
        }
        if let file = segments.last, pixelFiles.contains(String(file)) { return true }
        return segments.contains("beacon")
    }

    /// The host (no user info or port) and the percent-decoded path of an absolute URL, lowercased, with
    /// `\` read as `/` the way browsers read it.
    static func hostAndPath(_ lower: String) -> (String, String)? {
        guard let start = lower.range(of: "//") else { return nil }
        let rest = lower[start.upperBound...].replacingOccurrences(of: "\\", with: "/")
        let hostEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        var host = String(rest[..<hostEnd])
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        if !host.hasPrefix("["), let colon = host.lastIndex(of: ":") { host = String(host[..<colon]) }
        while host.hasSuffix(".") { host.removeLast() }
        let tail = rest[hostEnd...]
        let pathEnd = tail.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? tail.endIndex
        let raw = String(tail[..<pathEnd])
        return (host, (raw.removingPercentEncoding ?? raw).lowercased())
    }

    /// A remote image drawn 0–2 px wide or tall, or hidden by its style or the `hidden` attribute: a
    /// tracking pixel, whatever its URL.
    static func isPixel(width: String?, height: String?, style: String?, hidden: Bool) -> Bool {
        if hidden { return true }
        if let width = attributeLength(width), width <= 2 { return true }
        if let height = attributeLength(height), height <= 2 { return true }
        for declaration in (style ?? "").lowercased().split(separator: ";") {
            guard let colon = declaration.firstIndex(of: ":") else { continue }
            let property = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = declaration[declaration.index(after: colon)...].replacingOccurrences(of: "!important", with: "")
                .filter { !$0.isWhitespace }
            switch property {
            case "display": if value == "none" { return true }
            case "visibility": if value == "hidden" || value == "collapse" { return true }
            case "opacity": if let opacity = Double(value.hasSuffix("%") ? String(value.dropLast()) : value), opacity <= 0 { return true }
            case "width", "height", "max-width", "max-height":
                if let length = cssLength(value), length <= 2 { return true }
            default: continue
            }
        }
        return false
    }

    /// A `width`/`height` attribute in pixels ("1", "1px", " 0 "); nil for percentages and anything else.
    static func attributeLength(_ value: String?) -> Double? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces).lowercased()
        return Double(trimmed.hasSuffix("px") ? String(trimmed.dropLast(2)) : trimmed)
    }

    /// A CSS length in pixels: `px`, `pt` or a bare number; nil for relative units and keywords.
    static func cssLength(_ value: String) -> Double? {
        if value.hasSuffix("px") { return Double(value.dropLast(2)) }
        if value.hasSuffix("pt") { return Double(value.dropLast(2)).map { $0 * 4 / 3 } }
        return Double(value)
    }
}
