import Foundation
import Testing
@testable import TernCore

// The tree builder tracks where each element name sits on the open-element stack, so implied end tags and stray end
// tags no longer walk the stack. It must build exactly the tree the walking version built.

/// The walking tree builder `HTMLDocument.parse` used before, kept verbatim as the reference.
private func referenceParse(_ html: String) -> HTMLDocument {
    let closesParagraph: Set<String> = [
        "address", "article", "aside", "blockquote", "center", "details", "dialog", "dir", "div", "dl",
        "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header",
        "hgroup", "hr", "main", "menu", "nav", "ol", "p", "pre", "section", "summary", "table", "ul", "li",
        "dd", "dt", "listing", "xmp", "plaintext",
    ]
    let defaultScope: Set<String> = ["td", "th", "table", "caption", "object", "marquee", "applet", "template", "html"]
    let root = HTMLNode(element: "#root")
    var stack: [HTMLNode] = [root]
    var bodyAttributes: [HTMLAttribute]?
    var styles: [(css: String, media: String?)] = []
    var rawOwner: String?
    var styleMedia: String?

    func current() -> HTMLNode { stack[stack.count - 1] }

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
            current().append(node)
            if !HTMLDocument.voidElements.contains(name), stack.count < HTMLDocument.maxDepth { stack.append(node) }
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

/// The whole document as one string: every element with its attributes, every text node, the body attributes and
/// the style sheets.
private func outline(_ document: HTMLDocument) -> String {
    func write(_ node: HTMLNode, into output: inout String) {
        switch node.kind {
        case .text: output += "\"\(node.text)\""
        case .trusted: output += "!\(node.text)"
        case .element:
            output += "<\(node.name)"
            for attribute in node.attributes { output += " \(attribute.name)=\(attribute.value.debugDescription)" }
            output += ">"
            for child in node.children { write(child, into: &output) }
            output += "</\(node.name)>"
        }
    }
    var output = document.bodyAttributes.map { "\($0.name)=\($0.value)" }.joined(separator: " ") + "\n"
    for style in document.styles { output += "style[\(style.media ?? "")]: \(style.css)\n" }
    write(document.root, into: &output)
    return output
}

/// Markup that exercises every implied end tag and scope boundary: paragraphs closed by blocks and kept open by
/// buttons and table cells, list items and definitions across nested lists, rows and cells without end tags,
/// headings inside headings, nested links and options, stray end tags, boundary end tags, and nesting past
/// `HTMLDocument.maxDepth`.
private let corpus: [String] = [
    "<p>one<p>two<div>three</div><p>four</p></p>",
    "<p>a<button>b<div>c</div>d</button>e<div>f</div>",
    "<p>a<table><tr><td>b<div>c</div><p>d<ul><li>e</ul></td></tr></table>g<div>h</div>",
    "<ul><li>a<li>b<ul><li>c<li>d</ul><li>e</ul><ol><li>f<div><li>g</div></ol>",
    "<dl><dt>a<dd>b<dt>c<dl><dd>d<dt>e</dl><dd>f</dl><dd>stray",
    "<h1>a<h2>b</h2><h3>c<p>d<h4>e</h1>f",
    "<table><tr><td>a<td>b<tr><th>c<td>d</table><table><tbody><tr><td>e<tbody><tr><td>f<thead><tr><th>g</table>",
    "<table><caption>a<p>b</caption><colgroup><col></colgroup><tr><td>c</td></tr></table></td></tr></caption>",
    "<a href=\"#1\">a<a href=\"#2\">b<table><tr><td><a href=\"#3\">c<a href=\"#4\">d</td></tr></table></a></a>",
    "<select><option>a<option>b<optgroup><option>c</select>",
    "<div><span><b>a</i></span></b></div></div></p></li></dd></a></td></tr></table></object></template>",
    "<object><p>a<div>b</object><marquee><li>c<li>d</marquee><template><p>e<div>f</template>",
    "<p>a<applet><p>b</applet><div>c<html><p>d</html><div>e",
    "<button><p>a<button><div>b</button></button><p>c<p>d",
    "<ul><li><p>a<li>b</ul><p>c<ol><li>d</li></li></ol>",
    "<p>text <br> more <img src=x> <hr> after <input> end",
    "<style media=\"print\">p{color:red}</style><body bgcolor=\"#fff\" text=\"#333\"><p>x</p><body bgcolor=\"#000\">y",
    "<div><script>if (a < b) { </div> }</script><p>a<textarea></p></textarea>b<title><p></title>c",
    String(repeating: "<div>", count: 450) + "deep" + String(repeating: "</div>", count: 460) + "<p>after",
    String(repeating: "<span><p>", count: 300) + "x" + String(repeating: "</p></span>", count: 310),
    "<p><table><tr><td>" + String(repeating: "<span>", count: 395) + String(repeating: "<div>x", count: 40) + "</td></tr></table>tail",
    String(repeating: "<li><dd><a href=#>", count: 140) + "<ul><li>y</ul></a>" + String(repeating: "</li>", count: 150),
]

/// A tag soup from a small vocabulary that mixes the cases above at random.
private func soup(seed: UInt64, tags: Int) -> String {
    var state = seed
    func next(_ bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(bound))
    }
    let names = ["p", "div", "li", "ul", "ol", "dd", "dt", "dl", "table", "tr", "td", "th", "tbody", "thead", "tfoot",
                 "caption", "colgroup", "a", "button", "h1", "h2", "h3", "option", "span", "b", "object", "template",
                 "marquee", "applet", "html", "body", "br", "img", "blockquote", "pre", "section", "font"]
    var html = ""
    for _ in 0..<tags {
        let name = names[next(names.count)]
        switch next(5) {
        case 0, 1, 2: html += "<\(name)>"
        case 3: html += "</\(name)>"
        default: html += "t\(next(10))"
        }
    }
    return html
}

@Test func treeMatchesTheWalkingBuilder() {
    var documents = corpus
    for seed in 1...300 { documents.append(soup(seed: UInt64(seed), tags: 40 + seed * 3)) }
    documents.append(soup(seed: 9_001, tags: 20_000))
    for html in documents {
        let expected = outline(referenceParse(html))
        let actual = outline(HTMLDocument.parse(html))
        #expect(actual == expected, "\(html.prefix(200))")
    }
}

// MARK: Timing

private let skipPerf = ProcessInfo.processInfo.environment["TERN_SKIP_PERF"] == "1"

/// Best of five, in milliseconds.
private func milliseconds(_ body: () -> Void) -> Double {
    (0..<5).map { _ in
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }.min()!
}

/// About `bytes` of markup made of `unit`.
private func repeated(_ unit: String, bytes: Int) -> String {
    String(repeating: unit, count: bytes / unit.utf8.count)
}

/// Runs `body` on a thread with the main thread's 8 MB stack: the budget is for the main thread, and a debug build
/// needs more than the 512 KB of a test thread to recurse through a tree at `HTMLDocument.maxDepth`.
private func onMainSizedStack(_ body: @escaping @Sendable () -> Void) {
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        body()
        done.signal()
    }
    thread.stackSize = 8 << 20
    thread.start()
    done.wait()
}

@Test(.enabled(if: !skipPerf, "TERN_SKIP_PERF=1"))
func deepNestingParsesWithoutWalkingTheStack() {
    // Each case made every tag walk up to 400 open elements: a block start looking for a `<p>` to close (none open,
    // or one held open behind a table cell), a stray end tag looking for its element, a link looking for an open
    // link. 100 KB is the most the reader sanitizes on the main thread when a thread opens
    // (`ReaderPayload.inlineSanitizeLimit`).
    let deep = String(repeating: "<div>", count: 400)
    let cases = [
        ("100 KB of <div>", repeated("<div>", bytes: 100_000)),
        ("<div> under a <p> held open by a cell",
         "<p><table><tr><td>" + String(repeating: "<span>", count: 395) + repeated("<div>", bytes: 98_000)),
        ("stray end tags under 400 elements", deep + repeated("</b></li>", bytes: 98_000)),
        ("links under 400 elements", deep + repeated("<a href=#>x</a>", bytes: 98_000)),
    ]
    // The same tags without depth: every lookup ends one element up.
    let flat = milliseconds { _ = HTMLDocument.parse(repeated("<div></div>", bytes: 100_000)) }
    for (name, html) in cases {
        nonisolated(unsafe) var parse = 0.0, sanitize = 0.0
        onMainSizedStack {
            parse = milliseconds { _ = HTMLDocument.parse(html) }
            sanitize = milliseconds { _ = MailSanitizer.sanitize(html: html) }
        }
        print(String(format: "%@: parse %.2f ms (flat %.2f ms), sanitize %.2f ms", name, parse, flat, sanitize))
        // Debug-build numbers. Walking the stack made these about 15× the flat parse.
        #expect(parse < 3 * flat, "\(name): parse \(parse) ms, flat \(flat) ms")
        #expect(sanitize < 75, "\(name) took \(sanitize) ms to sanitize")
    }
}

@Test func depthCapNestingSanitizesOffTheMainThread() async {
    // The reader sanitizes off the main thread through `onDeepStack`. On a 512 KB task or Dispatch thread a debug build
    // runs out of stack writing a body nested to `HTMLDocument.maxDepth`, finding its quotes and freeing its tree.
    let depth = HTMLDocument.maxDepth + 50
    let cases = [
        String(repeating: "<div>", count: depth) + "deep" + String(repeating: "</div>", count: depth),
        "<style>p { color: #333 }</style>" + String(repeating: "<span style=\"color: #111\">", count: depth) + "deep",
        "<p>Reply</p><div>On Mon, A wrote:</div>" + String(repeating: "<blockquote type=\"cite\"><div>", count: depth / 2) + "deep",
        String(repeating: "<table><tr><td>", count: depth / 3) + "deep",
    ]
    for html in cases {
        let mail = await MailSanitizer.onDeepStack { MailSanitizer.sanitize(html: html) }
        #expect(mail.html.contains("deep"))
    }
}
