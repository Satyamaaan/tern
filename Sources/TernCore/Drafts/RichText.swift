import Foundation

/// The formatting a draft body can hold: paragraphs, bulleted and numbered items and quotes, each a run
/// of text with bold, italic, underline and links. The editor maps it to an attributed string; mail
/// goes out as the clean HTML from `html`.
public struct RichText: Hashable, Sendable {
    /// U+2028, a line break inside one block (Shift-Return, `<br>`).
    public static let lineBreak: Character = "\u{2028}"

    public struct Style: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let bold = Style(rawValue: 1)
        public static let italic = Style(rawValue: 2)
        public static let underline = Style(rawValue: 4)
    }

    public struct Run: Hashable, Sendable {
        public var text: String
        public var style: Style
        /// Absolute URL string.
        public var link: String?

        public init(_ text: String, style: Style = [], link: String? = nil) {
            self.text = text
            self.style = style
            self.link = link
        }
    }

    public enum BlockKind: String, Hashable, Sendable, Codable {
        case paragraph, bullet, numbered, quote
    }

    public struct Block: Hashable, Sendable {
        public var kind: BlockKind
        public var runs: [Run]

        public init(_ kind: BlockKind = .paragraph, _ runs: [Run] = []) {
            self.kind = kind
            self.runs = runs
        }

        public var text: String { runs.map(\.text).joined() }
    }

    public var blocks: [Block]

    public init(_ blocks: [Block] = []) {
        self.blocks = blocks
    }

    /// True when there is no visible text.
    public var isEmpty: Bool {
        blocks.allSatisfy { $0.text.allSatisfy { $0.isWhitespace || $0 == Self.lineBreak } }
    }

    // MARK: Plain text

    /// Readable text: one line per block, `• ` / `1. ` / `> ` prefixes.
    public var plainText: String {
        var number = 0
        return blocks.map { block in
            number = block.kind == .numbered ? number + 1 : 0
            let text = block.text.replacingOccurrences(of: String(Self.lineBreak), with: "\n")
            switch block.kind {
            case .paragraph: return text
            case .bullet: return "• " + text
            case .numbered: return "\(number). " + text
            case .quote: return "> " + text
            }
        }.joined(separator: "\n")
    }

    /// Reads plain text (e.g. AI output): one block per line; `- `, `* `, `• ` start bullets, `1. ` numbered
    /// items, `> ` quotes; `**bold**` and bare http(s) links are kept.
    public init(plainText: String) {
        let lines = plainText.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        var blocks: [Block] = []
        for raw in lines {
            var line = String(raw)
            var kind = BlockKind.paragraph
            let trimmed = line.drop(while: { $0 == " " })
            if let prefix = ["- ", "* ", "• "].first(where: trimmed.hasPrefix) {
                kind = .bullet
                line = String(trimmed.dropFirst(prefix.count))
            } else if trimmed.hasPrefix("> ") || trimmed == ">" {
                kind = .quote
                line = String(trimmed.dropFirst(min(2, trimmed.count)))
            } else if let match = trimmed.firstMatch(of: #/^(\d{1,3})[.)] /#) {
                kind = .numbered
                line = String(trimmed[match.range.upperBound...])
            }
            blocks.append(Block(kind, Self.inlineRuns(fromPlain: line)))
        }
        while let last = blocks.last, last.text.isEmpty, blocks.count > 1 { blocks.removeLast() }
        self.blocks = blocks
    }

    private static func inlineRuns(fromPlain line: String) -> [Run] {
        var runs: [Run] = []
        var bold = false
        for (index, piece) in line.components(separatedBy: "**").enumerated() {
            if index > 0 { bold.toggle() }
            guard !piece.isEmpty else { continue }
            var rest = Substring(piece)
            while let match = rest.firstMatch(of: #/https?:\/\/[^\s<>"]*[^\s<>".,;:!?)\]]/#) {
                if match.range.lowerBound > rest.startIndex {
                    runs.append(Run(String(rest[..<match.range.lowerBound]), style: bold ? .bold : []))
                }
                let url = String(match.output)
                runs.append(Run(url, style: bold ? .bold : [], link: url))
                rest = rest[match.range.upperBound...]
            }
            if !rest.isEmpty { runs.append(Run(String(rest), style: bold ? .bold : [])) }
        }
        return runs
    }

    // MARK: HTML out

    /// Clean HTML: `<div>` per paragraph (an empty one is `<div><br></div>`, like Gmail), `<ul>/<ol>/<li>`,
    /// `<blockquote>`, `<strong>`, `<em>`, `<u>`, `<a href>` and `<br>`.
    public var html: String {
        var out = ""
        var index = 0
        while index < blocks.count {
            let kind = blocks[index].kind
            var end = index
            while end < blocks.count, blocks[end].kind == kind { end += 1 }
            let group = blocks[index..<end]
            switch kind {
            case .paragraph:
                for block in group { out += "<div>\(Self.inlineHTML(block.runs, emptyAsBreak: true))</div>" }
            case .bullet, .numbered:
                let tag = kind == .bullet ? "ul" : "ol"
                out += "<\(tag)>"
                for block in group { out += "<li>\(Self.inlineHTML(block.runs, emptyAsBreak: true))</li>" }
                out += "</\(tag)>"
            case .quote:
                out += #"<blockquote style="margin:0 0 0 0.8ex;border-left:1px solid #ccc;padding-left:1ex">"#
                for block in group { out += "<div>\(Self.inlineHTML(block.runs, emptyAsBreak: true))</div>" }
                out += "</blockquote>"
            }
            index = end
        }
        return out
    }

    static func inlineHTML(_ runs: [Run], emptyAsBreak: Bool) -> String {
        let runs = merged(runs)
        var out = ""
        var index = 0
        var atStart = true
        while index < runs.count {
            let link = runs[index].link
            var end = index
            while end < runs.count, runs[end].link == link { end += 1 }
            var inner = ""
            for run in runs[index..<end] {
                var text = escapeText(run.text, atStart: atStart)
                if !run.text.isEmpty { atStart = run.text.last == lineBreak }
                if run.style.contains(.underline) { text = "<u>\(text)</u>" }
                if run.style.contains(.italic) { text = "<em>\(text)</em>" }
                if run.style.contains(.bold) { text = "<strong>\(text)</strong>" }
                inner += text
            }
            if let link { out += "<a href=\"\(escapeAttribute(link))\">\(inner)</a>" } else { out += inner }
            index = end
        }
        if out.isEmpty && emptyAsBreak { return "<br>" }
        // A trailing line break needs a second one to show as an empty line.
        if runs.last?.text.last == lineBreak { out += "<br>" }
        return out
    }

    /// Joins neighbouring runs with the same style and link; drops empty runs.
    static func merged(_ runs: [Run]) -> [Run] {
        var result: [Run] = []
        for run in runs where !run.text.isEmpty {
            if let last = result.last, last.style == run.style, last.link == run.link {
                result[result.count - 1].text += run.text
            } else {
                result.append(run)
            }
        }
        return result
    }

    /// Escapes text and keeps the user's spacing (HTML would collapse runs of spaces).
    static func escapeText(_ text: String, atStart: Bool) -> String {
        var out = ""
        var previousWasSpace = atStart
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case lineBreak, "\n": out += "<br>"; previousWasSpace = true; continue
            case "\t": out += "&nbsp;&nbsp;&nbsp;&nbsp;"; previousWasSpace = true; continue
            case " ", "\u{00A0}":
                out += previousWasSpace ? "&nbsp;" : " "
                previousWasSpace = true
                continue
            default: out.append(character)
            }
            previousWasSpace = false
        }
        return out
    }

    static func escapeAttribute(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Escapes plain text for an HTML body, `<br>` for line ends.
    public static func htmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "<br>")
    }
}
