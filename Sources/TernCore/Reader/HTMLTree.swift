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
    /// Contents of every `<style>` element and its `media` attribute, in document order.
    var styles: [(css: String, media: String?)]

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
    private static let buttonScope = defaultScope.union(["button"])
    private static let listItemScope = defaultScope.union(["ul", "ol"])
    private static let definitionScope = defaultScope.union(["dl"])
    private static let headings: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]
    private static let rowScope: Set<String> = ["table", "tbody", "thead", "tfoot", "html"]
    private static let cellScope: Set<String> = ["tr", "table", "html"]
    private static let tableScope: Set<String> = ["table", "html"]
    private static let htmlScope: Set<String> = ["html"]

    static func parse(_ html: String) -> HTMLDocument {
        let root = HTMLNode(element: "#root")
        var stack = OpenElements(root: root)
        var bodyAttributes: [HTMLAttribute]?
        var styles: [(css: String, media: String?)] = []
        var rawOwner: String?
        var styleMedia: String?

        func prepare(for name: String) {
            if closesParagraph.contains(name) {
                stack.close("p", boundaries: buttonScope)
            }
            switch name {
            case "li": stack.close("li", boundaries: listItemScope)
            case "dd", "dt": stack.close("dd", or: "dt", boundaries: definitionScope)
            case "h1", "h2", "h3", "h4", "h5", "h6":
                if headings.contains(stack.current.name) { stack.popCurrent() }
            case "tr": stack.close("tr", boundaries: rowScope)
            case "td", "th": stack.close("td", or: "th", boundaries: cellScope)
            case "tbody", "thead", "tfoot": stack.close("tbody", or: "thead", "tfoot", boundaries: tableScope)
            case "a": stack.close("a", boundaries: defaultScope)
            case "option": if stack.current.name == "option" { stack.popCurrent() }
            default: break
            }
        }

        HTMLTokenizer.tokenize(html) { token in
            switch token {
            case .text(let text):
                stack.current.append(HTMLNode(text: text))

            case .rawText(let text):
                if rawOwner == "style" { styles.append((text, styleMedia)) }

            case .startTag(let name, let attributes, _):
                rawOwner = HTMLTokenizer.rawTextElements.contains(name) ? name : nil
                if name == "style" { styleMedia = attributes.first { $0.name == "media" }?.value }
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
                stack.current.append(node)
                if !voidElements.contains(name), stack.count < maxDepth { stack.push(node) }

            case .endTag(let name):
                switch name {
                case "html", "head", "body": return
                default: break
                }
                if HTMLTokenizer.rawTextElements.contains(name) { rawOwner = nil; return }
                switch name {
                case "td", "th", "tr", "tbody", "thead", "tfoot", "caption", "colgroup":
                    stack.close(name, boundaries: tableScope)
                case "table":
                    stack.close("table", boundaries: htmlScope)
                case "li":
                    stack.close("li", boundaries: listItemScope)
                default:
                    stack.close(name, boundaries: defaultScope)
                }
            }
        }
        return HTMLDocument(root: root, bodyAttributes: bodyAttributes ?? [], styles: styles)
    }
}

/// The open elements, innermost last, with the stack positions of each element name, so the scope checks behind
/// implied and stray end tags look up a few names instead of walking up to `HTMLDocument.maxDepth` elements.
private struct OpenElements {
    private var nodes: [HTMLNode]
    /// Positions in `nodes` by element name, in increasing order. The root is never closed and isn't listed.
    private var positions: [String: [Int]] = [:]

    init(root: HTMLNode) { nodes = [root] }

    var current: HTMLNode { nodes[nodes.count - 1] }
    var count: Int { nodes.count }

    mutating func push(_ node: HTMLNode) {
        positions[node.name, default: []].append(nodes.count)
        nodes.append(node)
    }

    mutating func popCurrent() { pop(from: nodes.count - 1) }

    /// Pops up to and including the nearest open element with one of the names, unless an element named in
    /// `boundaries` is open above it. Returns whether anything was closed.
    @discardableResult
    mutating func close(_ name: String, or others: String..., boundaries: Set<String>) -> Bool {
        var target = positions[name]?.last ?? 0
        for other in others { target = max(target, positions[other]?.last ?? 0) }
        guard target > 0 else { return false }
        for boundary in boundaries where (positions[boundary]?.last ?? 0) > target { return false }
        pop(from: target)
        return true
    }

    private mutating func pop(from index: Int) {
        // The popped elements hold the highest positions, so each one is the last entry for its name.
        for node in nodes[index...] { positions[node.name]?.removeLast() }
        nodes.removeSubrange(index...)
    }
}
