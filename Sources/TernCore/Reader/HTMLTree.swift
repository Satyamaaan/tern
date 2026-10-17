import Foundation

/// A small mutable DOM for mail bodies. Built from `HTMLTokenizer` with the implied-end-tag rules
/// mail actually exercises (paragraphs, list items, table cells); everything else nests as written.
final class HTMLNode {
    enum Kind {
        case element
        /// Text as written, character references still encoded.
        case text
        /// Markup we generated ourselves; serialized verbatim, never sanitized.
        case trusted
    }

    let kind: Kind
    var name: String
    var attributes: [HTMLAttribute]
    var text: String
    var children: [HTMLNode] = []
    weak var parent: HTMLNode?

    init(element name: String, attributes: [HTMLAttribute] = []) {
        kind = .element
        self.name = name
        self.attributes = attributes
        text = ""
    }

    init(text: String) {
        kind = .text
        name = ""
        attributes = []
        self.text = text
    }

    init(trusted markup: String) {
        kind = .trusted
        name = ""
        attributes = []
        text = markup
    }

    func attribute(_ name: String) -> String? { attributes.first { $0.name == name }?.value }

    var classes: [Substring] { (attribute("class") ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }) }

    func hasClass(_ name: String) -> Bool { classes.contains { $0 == name } }

    func append(_ child: HTMLNode) {
        child.parent = self
        children.append(child)
    }

    func insert(_ child: HTMLNode, at index: Int) {
        child.parent = self
        children.insert(child, at: index)
    }

    /// Visible text with entities decoded and whitespace collapsed, from roughly the first `limit` bytes.
    func textContent(limit: Int = .max) -> String {
        var output = ""
        var budget = limit
        collectText(into: &output, budget: &budget)
        return HTMLEntities.decode(output)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func collectText(into output: inout String, budget: inout Int) {
        guard budget > 0 else { return }
        switch kind {
        case .text:
            output += text
            budget -= text.utf8.count
        case .trusted: break
        case .element:
            if MailHTMLPolicy.dropWithContent.contains(name) { return }
            if name == "br" || name == "p" || name == "div" || name == "tr" { output += " " }
            for child in children where budget > 0 { child.collectText(into: &output, budget: &budget) }
        }
    }

    /// The first non-blank text inside this node, decoded and trimmed.
    func firstText() -> String? {
        for child in children {
            switch child.kind {
            case .text:
                let text = HTMLEntities.decode(child.text).trimmingCharacters(in: .whitespacesAndNewlines.union(["\u{00A0}"]))
                if !text.isEmpty { return text }
            case .element:
                if MailHTMLPolicy.dropWithContent.contains(child.name) { continue }
                if let text = child.firstText() { return text }
            case .trusted:
                continue
            }
        }
        return nil
    }

    var isWhitespaceText: Bool {
        kind == .text && text.allSatisfy { $0.isWhitespace } && !text.contains("&nbsp;")
    }
}

/// A parsed mail body: the element tree plus what lived in `<head>` and on `<body>`.
struct HTMLDocument {
    var root: HTMLNode
    var bodyAttributes: [HTMLAttribute]
    /// Contents of every `<style>` element, in document order.
    var styles: [String]

    static let maxDepth = 400

    static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source",
        "track", "wbr", "keygen", "basefont", "bgsound", "frame",
    ]

    private static let closesParagraph: Set<String> = [
        "address", "article", "aside", "blockquote", "center", "details", "dialog", "dir", "div", "dl",
        "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header",
        "hgroup", "hr", "main", "menu", "nav", "ol", "p", "pre", "section", "summary", "table", "ul", "li",
        "dd", "dt", "listing", "xmp", "plaintext",
    ]

    private static let defaultScope: Set<String> = [
        "td", "th", "table", "caption", "object", "marquee", "applet", "template", "html",
    ]

    static func parse(_ html: String) -> HTMLDocument {
        let root = HTMLNode(element: "#root")
        var stack: [HTMLNode] = [root]
        var bodyAttributes: [HTMLAttribute]?
        var styles: [String] = []
        var rawOwner: String?

        func current() -> HTMLNode { stack[stack.count - 1] }

        /// Pops up to and including the nearest open `name`, unless a boundary element comes first.
        @discardableResult
        func close(_ names: Set<String>, boundaries: Set<String>) -> Bool {
            var index = stack.count - 1
            while index > 0 {
                let node = stack[index]
                if names.contains(node.name) {
                    stack.removeSubrange(index...)
                    return true
                }
                if boundaries.contains(node.name) { return false }
                index -= 1
            }
            return false
        }

        func prepare(for name: String) {
            if closesParagraph.contains(name) {
                close(["p"], boundaries: defaultScope.union(["button"]))
            }
            switch name {
            case "li": close(["li"], boundaries: defaultScope.union(["ul", "ol"]))
            case "dd", "dt": close(["dd", "dt"], boundaries: defaultScope.union(["dl"]))
            case "h1", "h2", "h3", "h4", "h5", "h6":
                if ["h1", "h2", "h3", "h4", "h5", "h6"].contains(current().name) { stack.removeLast() }
            case "tr": close(["tr"], boundaries: ["table", "tbody", "thead", "tfoot", "html"])
            case "td", "th": close(["td", "th"], boundaries: ["tr", "table", "html"])
            case "tbody", "thead", "tfoot": close(["tbody", "thead", "tfoot"], boundaries: ["table", "html"])
            case "a": close(["a"], boundaries: defaultScope)
            case "option": if current().name == "option" { stack.removeLast() }
            default: break
            }
        }

        HTMLTokenizer.tokenize(html) { token in
            switch token {
            case .text(let text):
                current().append(HTMLNode(text: text))

            case .rawText(let text):
                if rawOwner == "style" { styles.append(text) }

            case .startTag(let name, let attributes, _):
                rawOwner = HTMLTokenizer.rawTextElements.contains(name) ? name : nil
                switch name {
                case "html", "head": return
                case "body":
                    if bodyAttributes == nil { bodyAttributes = attributes }
                    return
                default: break
                }
                if HTMLTokenizer.rawTextElements.contains(name) { return }
                prepare(for: name)
                let node = HTMLNode(element: name, attributes: attributes)
                current().append(node)
                if !voidElements.contains(name), stack.count < maxDepth { stack.append(node) }

            case .endTag(let name):
                switch name {
                case "html", "head", "body": return
                default: break
                }
                if HTMLTokenizer.rawTextElements.contains(name) { rawOwner = nil; return }
                switch name {
                case "td", "th", "tr", "tbody", "thead", "tfoot", "caption", "colgroup":
                    close([name], boundaries: ["table", "html"])
                case "table":
                    close(["table"], boundaries: ["html"])
                case "li":
                    close(["li"], boundaries: defaultScope.union(["ul", "ol"]))
                default:
                    close([name], boundaries: defaultScope)
                }
            }
        }
        return HTMLDocument(root: root, bodyAttributes: bodyAttributes ?? [], styles: styles)
    }
}
