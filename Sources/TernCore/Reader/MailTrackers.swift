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

    /// File names that only open trackers use (`o.gif`: Campaign Monitor, `open.aspx`: Salesforce Marketing Cloud).
    static let pixelFiles: Set<String> = [
        "open.gif", "open.png", "open.php", "open.aspx", "o.gif", "pixel.gif", "1x1.gif", "1x1.png", "beacon.gif",
    ]

    /// True for an http(s) image URL that is an open tracker: a known tracking host, or the URL shapes mail
    /// services give their open pixels, also on a sender's own link domain.
    static func isTracker(_ url: String) -> Bool {
        let lower = url.lowercased()
        if fragments.contains(where: { lower.contains($0) }) { return true }
        guard let (host, path) = hostAndPath(lower) else { return false }
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        let segments = path.split(separator: "/")

        // HubSpot, Google Analytics, Amazon SES opens (`/L0/` is a click), Postmark, Substack, Mailjet.
        if on("t.hubspotemail.net") || on("track.hubspot.com") || on("google-analytics.com") { return true }
        if on("awstrack.me"), path.hasPrefix("/i0/") { return true }
        if on("pstmrk.it"), path.hasPrefix("/open") { return true }
        if on("eotrx.substackcdn.com"), path.hasPrefix("/open") { return true }
        if on("mjt.lu"), segments.first == "oo" { return true }
        // Customer.io, Iterable and senders' own link domains: `/e/o/<token>`; Brevo: `/tr/op/<token>`.
        if segments.count >= 3, (segments[0] == "e" && segments[1] == "o") || (segments[0] == "tr" && segments[1] == "op") {
            return true
        }
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

    /// A remote image hidden by its style or the `hidden` attribute, or drawn too small to see (`isPixelSize`): a
    /// tracking pixel, whatever its URL. Inline style sizes win over the attributes, as they do on screen.
    static func isPixel(width: String?, height: String?, style: String?, hidden: Bool) -> Bool {
        if hidden { return true }
        var width = attributeLength(width), height = attributeLength(height)
        var maxWidth: Double?, maxHeight: Double?
        for declaration in (style ?? "").lowercased().split(separator: ";") {
            guard let colon = declaration.firstIndex(of: ":") else { continue }
            let property = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = declaration[declaration.index(after: colon)...].replacingOccurrences(of: "!important", with: "")
                .filter { !$0.isWhitespace }
            switch property {
            case "display": if value == "none" { return true }
            case "visibility": if value == "hidden" || value == "collapse" { return true }
            case "opacity": if let opacity = Double(value.hasSuffix("%") ? String(value.dropLast()) : value), opacity <= 0 { return true }
            case "width": width = cssLength(value) ?? share(value)
            case "height": height = cssLength(value) ?? share(value)
            case "max-width": maxWidth = cssLength(value)
            case "max-height": maxHeight = cssLength(value)
            default: continue
            }
        }
        if let maxWidth { width = min(width ?? maxWidth, maxWidth) }
        if let maxHeight { height = min(height ?? maxHeight, maxHeight) }
        return isPixelSize(width: width, height: height)
    }

    /// Too small to see: no width or no height at all, both sides 2 px or less, or one side 1 px or less with the
    /// other unknown. A 600 × 2 divider or a 1 × 20 spacer draws something, so it stays.
    static func isPixelSize(width: Double?, height: Double?) -> Bool {
        if let width, width <= 0 { return true }
        if let height, height <= 0 { return true }
        switch (width, height) {
        case let (width?, height?): return width <= 2 && height <= 2
        case let (width?, nil): return width <= 1
        case let (nil, height?): return height <= 1
        case (nil, nil): return false
        }
    }

    /// A `width`/`height` attribute in pixels ("1", "1px", " 0 ", or a percentage as `share`); nil for anything else.
    static func attributeLength(_ value: String?) -> Double? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces).lowercased()
        return Double(trimmed.hasSuffix("px") ? String(trimmed.dropLast(2)) : trimmed) ?? share(trimmed)
    }

    /// A percentage size is a share of the column: wide unless it is 0%. Nil when `value` isn't a percentage.
    static func share(_ value: String) -> Double? {
        guard value.hasSuffix("%"), let percent = Double(value.dropLast()) else { return nil }
        return percent > 0 ? .infinity : 0
    }

    /// A CSS length in pixels: `px`, `pt` or a bare number; nil for relative units and keywords.
    static func cssLength(_ value: String) -> Double? {
        if value.hasSuffix("px") { return Double(value.dropLast(2)) }
        if value.hasSuffix("pt") { return Double(value.dropLast(2)).map { $0 * 4 / 3 } }
        return Double(value)
    }
}
