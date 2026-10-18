import Foundation

/// An update's "What's new": the appcast item's description turned into lines the update card draws in Inter.
/// Reads the small HTML subset scripts/appcast.swift writes (`h1`–`h6`, `p`, `ul`/`ol` with `li`, inline tags
/// whose text is kept) and plain text with `-` bullets; anything else keeps only its text.
struct ReleaseNotes: Equatable {
    enum Line: Equatable {
        case heading(String)
        case paragraph(String)
        case bullet(String)
    }

    var lines: [Line]

    var isEmpty: Bool { lines.isEmpty }

    init(lines: [Line]) {
        self.lines = lines
    }

    init(_ description: String?) {
        guard let description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.lines = []
            return
        }
        lines = description.contains("<") ? Self.parseHTML(description) : Self.parsePlain(description)
    }

    private enum Block { case heading, paragraph, bullet }

    private static func parseHTML(_ html: String) -> [Line] {
        var lines: [Line] = []
        var block: Block?
        var text = ""
        func flush() {
            let clean = collapse(decode(text))
            if !clean.isEmpty {
                switch block ?? .paragraph {
                case .heading: lines.append(.heading(clean))
                case .paragraph: lines.append(.paragraph(clean))
                case .bullet: lines.append(.bullet(clean))
                }
            }
            text = ""
        }
        let tag = #/<(/?)([A-Za-z][A-Za-z0-9]*)[^>]*>/#
        var rest = html[...]
        while let match = rest.firstMatch(of: tag) {
            text += rest[rest.startIndex..<match.range.lowerBound]
            rest = rest[match.range.upperBound...]
            let closing = !match.output.1.isEmpty
            switch match.output.2.lowercased() {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flush()
                block = closing ? nil : .heading
            case "p", "div":
                flush()
                block = closing ? nil : .paragraph
            case "li":
                flush()
                block = closing ? nil : .bullet
            case "ul", "ol":
                flush()
                block = nil
            case "br":
                text += " "
            default:
                break
            }
        }
        text += rest
        flush()
        return lines
    }

    private static func parsePlain(_ text: String) -> [Line] {
        var lines: [Line] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { lines.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if let bullet = ["- ", "* ", "• "].first(where: line.hasPrefix) {
                flush()
                lines.append(.bullet(String(line.dropFirst(bullet.count))))
            } else if line.hasPrefix("#") {
                flush()
                lines.append(.heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return lines
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "mdash": "—", "ndash": "–", "hellip": "…", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“",
    ]

    private static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacing(#/&(#[xX]?[0-9A-Fa-f]+|[A-Za-z]+);/#) { match in
            let name = String(match.output.1)
            if name.hasPrefix("#") {
                let hex = name.dropFirst().first.map { $0 == "x" || $0 == "X" } ?? false
                let digits = name.dropFirst(hex ? 2 : 1)
                if let value = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(value) {
                    return String(Character(scalar))
                }
                return String(match.output.0)
            }
            return entities[name.lowercased()] ?? String(match.output.0)
        }
    }
}
