import Foundation

extension RichText {
    /// For text a model wrote, where a prompt-injected email could plant a link: every link shows where
    /// it goes. Only http(s) and mailto stay links. Link text that names another site becomes the real
    /// host; other text gets the host (or address) after it, as plain text.
    public func revealingLinks() -> RichText {
        var result = self
        for index in result.blocks.indices {
            let runs = result.blocks[index].runs
            var revealed: [Run] = []
            var start = 0
            while start < runs.count {
                guard let link = runs[start].link else {
                    revealed.append(runs[start])
                    start += 1
                    continue
                }
                // Neighbouring runs with the same link (a bold word inside it) are one link.
                var end = start
                while end + 1 < runs.count, runs[end + 1].link == link { end += 1 }
                revealed += Self.reveal(Array(runs[start...end]), link: link)
                start = end + 1
            }
            result.blocks[index].runs = revealed
        }
        return result
    }

    private static func reveal(_ runs: [Run], link: String) -> [Run] {
        let text = runs.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let unlinked = runs.map { Run($0.text, style: $0.style) }
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased() else { return unlinked }
        switch scheme {
        case "mailto":
            let address = (String(link.dropFirst("mailto:".count)).components(separatedBy: "?").first ?? "")
                .removingPercentEncoding ?? ""
            guard address.contains("@") else { return unlinked }
            return text.localizedCaseInsensitiveContains(address) ? runs : runs + [Run(" (\(address))")]
        case "http", "https":
            guard let host = LinkSafety.destination(of: url).host?.lowercased(), !host.isEmpty else { return unlinked }
            guard LinkSafety.shownDomain(in: text) != nil else { return runs + [Run(" (\(host))")] }
            if LinkSafety.mismatch(text: text, href: link) == nil { return runs }
            return [Run(host, style: runs.first?.style ?? [], link: link)]
        default:
            return unlinked
        }
    }
}
