import Foundation

/// The icons a home page declares in its `<head>`: `<link rel="icon">`, `"shortcut icon"` and
/// `"apple-touch-icon"`, resolved against the page (and its `<base href>`), https only, no SVG,
/// largest declared size first.
enum LogoPageIcons {
    static func icons(in html: String, base: URL) -> [URL] {
        var html = html
        if let end = html.range(of: "</head", options: .caseInsensitive) { html = String(html[..<end.lowerBound]) }
        html = html.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)

        var base = base
        var found: [(url: URL, size: Int)] = []
        let text = html as NSString
        for match in tagPattern.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            let tag = text.substring(with: match.range(at: 1)).lowercased()
            let attributes = attributes(text.substring(with: match.range(at: 2)))
            guard let href = attributes["href"].map(decodeEntities), !href.isEmpty else { continue }
            if tag == "base" {
                if let url = URL(string: href, relativeTo: base)?.absoluteURL { base = url }
                continue
            }
            let rel = Set((attributes["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
            guard rel.contains("icon") || rel.contains("apple-touch-icon") || rel.contains("apple-touch-icon-precomposed"),
                  !(attributes["type"] ?? "").lowercased().contains("svg"),
                  let url = URL(string: href, relativeTo: base)?.absoluteURL, url.scheme?.lowercased() == "https",
                  !["svg", "svgz"].contains(url.pathExtension.lowercased()),
                  !found.contains(where: { $0.url == url }) else { continue }
            found.append((url, declaredSize(attributes["sizes"], touchIcon: !rel.contains("icon"))))
        }
        return found.enumerated()
            .sorted { $0.element.size != $1.element.size ? $0.element.size > $1.element.size : $0.offset < $1.offset }
            .map(\.element.url)
    }

    private static let tagPattern = try! NSRegularExpression(pattern: "<(link|base)\\b([^>]*)>", options: .caseInsensitive)
    private static let attributePattern = try! NSRegularExpression(
        pattern: "([^\\s\"'=<>/`]+)(?:\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'=<>`]+)))?")

    /// Attribute names (lowercased) to values; the first occurrence wins, as in browsers.
    private static func attributes(_ text: String) -> [String: String] {
        let ns = text as NSString
        var result: [String: String] = [:]
        for match in attributePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            guard result[name] == nil else { continue }
            let value = (2...4).lazy.map { match.range(at: $0) }.first { $0.location != NSNotFound }
            result[name] = value.map(ns.substring(with:)) ?? ""
        }
        return result
    }

    /// The largest square side in `sizes` ("32x32 192x192"). Touch icons without one are 180 px by
    /// convention; other icons without one rank last.
    private static func declaredSize(_ sizes: String?, touchIcon: Bool) -> Int {
        let declared = (sizes ?? "").lowercased().split(whereSeparator: \.isWhitespace).compactMap { size -> Int? in
            let sides = size.split(separator: "x").compactMap { Int($0) }
            return sides.count == 2 ? sides.min() : nil
        }
        return declared.max() ?? (touchIcon ? 180 : 0)
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var result = text
        for (entity, character) in [("&quot;", "\""), ("&#34;", "\""), ("&apos;", "'"), ("&#39;", "'"), ("&lt;", "<"),
                                    ("&gt;", ">"), ("&#x2f;", "/"), ("&#x2F;", "/"), ("&#47;", "/"), ("&amp;", "&"), ("&#38;", "&")] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
