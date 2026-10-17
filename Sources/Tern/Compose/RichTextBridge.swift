import AppKit
import TernCore

extension NSAttributedString.Key {
    /// Marks bold text; the font follows it (Geist SemiBold).
    static let ternBold = NSAttributedString.Key("tern.bold")
    /// Marks italic text. Geist ships without an italic, so it is drawn with a slight obliqueness.
    static let ternItalic = NSAttributedString.Key("tern.italic")
    /// `RichText.BlockKind` raw value of the paragraph a character belongs to.
    static let ternBlock = NSAttributedString.Key("tern.block")
}

extension Theme {
    /// Fill for recipient pills, attachment chips and the `•••` pill: `hover` in light, `selected` in
    /// dark, where `hover` barely separates from `raised`.
    static let pill = dynamic(light: 0xF1F1EF, dark: 0x272727)
}

/// How the body editor draws each kind of text.
enum EditorStyle {
    static let fontSize: CGFloat = 14
    static let lineHeight: CGFloat = 22
    /// Indent of list item text; the marker sits in front of it.
    static let listIndent: CGFloat = 22
    static let quoteIndent: CGFloat = 14
    static let italicObliqueness: CGFloat = 0.16

    static func font(bold: Bool) -> NSFont { Theme.ui(fontSize, bold ? .semibold : .regular) }

    static func paragraphStyle(_ kind: RichText.BlockKind) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        switch kind {
        case .bullet, .numbered:
            style.firstLineHeadIndent = listIndent
            style.headIndent = listIndent
        case .quote:
            style.firstLineHeadIndent = quoteIndent
            style.headIndent = quoteIndent
        case .paragraph:
            break
        }
        return style
    }

    static func attributes(_ style: RichText.Style = [], link: String? = nil, block: RichText.BlockKind = .paragraph) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(bold: style.contains(.bold)),
            .foregroundColor: block == .quote ? Theme.text2 : Theme.text1,
            .paragraphStyle: paragraphStyle(block),
            .ternBlock: block.rawValue,
        ]
        if style.contains(.bold) { attributes[.ternBold] = true }
        if style.contains(.italic) {
            attributes[.ternItalic] = true
            attributes[.obliqueness] = italicObliqueness
        }
        if style.contains(.underline) { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if let link, let url = URL(string: link) { attributes[.link] = url }
        return attributes
    }

    /// Re-derives font, obliqueness, colour and paragraph style from the semantic attributes.
    static func normalized(_ attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var result = self.attributes(style(of: attributes), link: linkString(attributes[.link]), block: block(of: attributes))
        if let spelling = attributes[.spellingState] { result[.spellingState] = spelling }
        return result
    }

    static func style(of attributes: [NSAttributedString.Key: Any]) -> RichText.Style {
        var style: RichText.Style = []
        if attributes[.ternBold] != nil { style.insert(.bold) }
        if attributes[.ternItalic] != nil { style.insert(.italic) }
        if let underline = attributes[.underlineStyle] as? Int, underline != 0 { style.insert(.underline) }
        return style
    }

    static func block(of attributes: [NSAttributedString.Key: Any]) -> RichText.BlockKind {
        (attributes[.ternBlock] as? String).flatMap(RichText.BlockKind.init(rawValue:)) ?? .paragraph
    }

    static func linkString(_ value: Any?) -> String? {
        switch value {
        case let url as URL: url.absoluteString
        case let string as String: string
        default: nil
        }
    }
}

/// Converts between `RichText` and the editor's attributed string.
enum RichTextBridge {
    static func attributedString(_ text: RichText) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, block) in text.blocks.enumerated() {
            for run in block.runs {
                result.append(NSAttributedString(string: run.text, attributes: EditorStyle.attributes(run.style, link: run.link, block: block.kind)))
            }
            if index < text.blocks.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: EditorStyle.attributes(block: block.kind)))
            }
        }
        return result
    }

    /// Paragraphs split on newlines; each paragraph's kind comes from its first character (or its newline).
    static func richText(_ attributed: NSAttributedString) -> RichText {
        let string = attributed.string as NSString
        var blocks: [RichText.Block] = []
        var start = 0
        repeat {
            let searchRange = NSRange(location: start, length: string.length - start)
            let breakRange = string.rangeOfCharacter(from: paragraphBreaks, options: [], range: searchRange)
            let end = breakRange.location == NSNotFound ? string.length : breakRange.location
            let kind: RichText.BlockKind = start < string.length
                ? EditorStyle.block(of: attributed.attributes(at: start, effectiveRange: nil))
                : blocks.last?.kind ?? .paragraph
            var runs: [RichText.Run] = []
            if end > start {
                attributed.enumerateAttributes(in: NSRange(location: start, length: end - start)) { attributes, range, _ in
                    let text = string.substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "")
                    guard !text.isEmpty else { return }
                    runs.append(RichText.Run(text, style: EditorStyle.style(of: attributes), link: EditorStyle.linkString(attributes[.link])))
                }
            }
            blocks.append(RichText.Block(kind, runs))
            start = end + 1
        } while start <= string.length
        return RichText(blocks)
    }

    private static let paragraphBreaks = CharacterSet(charactersIn: "\n\u{2029}")

    /// Reads RTF or other attributed text from outside: keeps bold, italic, underline and links from
    /// font traits and attributes, drops every other style.
    static func richText(fromForeign attributed: NSAttributedString) -> RichText {
        let cleaned = NSMutableAttributedString(string: attributed.string)
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
            var style: RichText.Style = []
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold) || font.fontName.lowercased().contains("bold") { style.insert(.bold) }
                if traits.contains(.italic) { style.insert(.italic) }
            }
            if let underline = attributes[.underlineStyle] as? Int, underline != 0 { style.insert(.underline) }
            cleaned.setAttributes(EditorStyle.attributes(style, link: EditorStyle.linkString(attributes[.link])), range: range)
        }
        return richText(cleaned)
    }
}
