import Foundation

/// Finds the quoted part of a reply (the earlier messages a mail client pastes below the answer) and
/// folds it behind a `•••` toggle. Forwards and mails that are nothing but a quote stay open.
enum MailQuotes {
    private struct Candidate {
        let parent: HTMLNode
        var range: ClosedRange<Int>
    }

    private enum Kind {
        /// The element itself is the quote.
        case element
        /// The element starts the quote, which runs to the end of its container (Outlook).
        case toEnd
    }

    /// Wraps quotes in the tree. Returns true when anything was folded.
    static func collapse(in root: HTMLNode) -> Bool {
        var candidates: [Candidate] = []
        var claimed = Set<ObjectIdentifier>()
        find(in: root, root: root, candidates: &candidates, claimed: &claimed)
        guard !candidates.isEmpty, hasVisibleText(root, excluding: claimed) else { return false }

        for (_, group) in Dictionary(grouping: candidates, by: { ObjectIdentifier($0.parent) }) {
            for candidate in group.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
                let parent = candidate.parent
                let nodes = Array(parent.children[candidate.range])
                let wrapper = HTMLNode.trusted(open: "<div class=\"tern-quote\" hidden>", close: "</div>")
                for node in nodes { wrapper.append(node) }
                let toggle = HTMLNode.trusted(
                    open: "<div class=\"tern-quote-toggle\" role=\"button\" tabindex=\"0\" aria-label=\"Show quoted text\">•••</div>",
                    close: "")
                parent.children.replaceSubrange(candidate.range, with: [toggle, wrapper])
                toggle.parent = parent
                wrapper.parent = parent
            }
        }
        return true
    }

    private static func find(in node: HTMLNode, root: HTMLNode, candidates: inout [Candidate], claimed: inout Set<ObjectIdentifier>) {
        var index = 0
        while index < node.children.count {
            let child = node.children[index]
            defer { index += 1 }
            guard child.kind == .element, !claimed.contains(ObjectIdentifier(child)) else { continue }
            guard let kind = kind(of: child) else {
                find(in: child, root: root, candidates: &candidates, claimed: &claimed)
                continue
            }
            switch kind {
            case .element:
                var start = index
                if let attribution = attributionIndex(before: index, in: node) { start = attribution }
                let range = start...index
                if isForward(node.children[range]) { continue }
                candidates.append(Candidate(parent: node, range: range))
                for covered in node.children[range] { claimed.insert(ObjectIdentifier(covered)) }
            case .toEnd:
                var target = child
                var container = node
                while container !== root, let parent = container.parent, isSoleContent(target, of: container) {
                    target = container
                    container = parent
                }
                guard var start = container.children.firstIndex(where: { $0 === target }) else { continue }
                if let separator = separatorIndex(before: start, in: container) { start = separator }
                let range = start...(container.children.count - 1)
                if isForward(container.children[range]) { continue }
                candidates.append(Candidate(parent: container, range: range))
                for covered in container.children[range] { claimed.insert(ObjectIdentifier(covered)) }
                if container === node { return }
            }
        }
    }

    private static func kind(of node: HTMLNode) -> Kind? {
        let classes = node.classes
        if classes.contains(where: { quoteClasses.contains(String($0)) }) { return .element }
        if node.name == "blockquote", node.attribute("type")?.lowercased() == "cite" { return .element }
        if let id = node.attribute("id"), toEndIds.contains(id) { return .toEnd }
        if classes.contains("OutlookMessageHeader") { return .toEnd }
        if node.name == "div" || node.name == "p" {
            let bordered = node.attribute("style").map { style in
                let style = style.lowercased().replacingOccurrences(of: " ", with: "")
                return style.contains("border-top:solid") || style.contains("border-top:1pxsolid") || style.contains("border-top-style:solid")
            } ?? false
            if bordered || node.name == "p" || node.children.first?.kind == .text, let text = node.firstText() {
                if bordered, headerPrefixes.contains(where: { text.hasPrefix($0) }) { return .toEnd }
                if text.hasPrefix("---"), text.range(of: #"^-{3,}\s*Original Message\s*-{3,}"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    return .toEnd
                }
            }
        }
        return nil
    }

    /// The "On Tue, Maya wrote:" line right before a quote, skipping blank lines.
    private static func attributionIndex(before index: Int, in parent: HTMLNode) -> Int? {
        var cursor = index - 1
        while cursor >= 0 {
            let node = parent.children[cursor]
            if node.isWhitespaceText || (node.kind == .element && node.name == "br") {
                cursor -= 1
                continue
            }
            if node.kind == .element, node.classes.contains(where: { $0 == "gmail_attr" || $0 == "moz-cite-prefix" }) {
                return cursor
            }
            let text = node.kind == .text ? HTMLEntities.decode(node.text) : node.textContent(limit: 400)
            if text.count < 400, text.range(of: attributionPattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return cursor
            }
            return nil
        }
        return nil
    }

    /// Outlook puts an `<hr>` (and an empty `#appendonsend`) right before its reply header.
    private static func separatorIndex(before index: Int, in parent: HTMLNode) -> Int? {
        var cursor = index - 1
        var found: Int?
        while cursor >= 0 {
            let node = parent.children[cursor]
            if node.isWhitespaceText || (node.kind == .element && node.name == "br") {
                cursor -= 1
                continue
            }
            if node.kind == .element, node.name == "hr" || node.attribute("id") == "appendonsend" {
                found = cursor
                cursor -= 1
                continue
            }
            break
        }
        return found
    }

    private static func isSoleContent(_ node: HTMLNode, of container: HTMLNode) -> Bool {
        container.children.allSatisfy { $0 === node || $0.isWhitespaceText || ($0.kind == .element && $0.name == "br") }
    }

    private static func isForward(_ nodes: ArraySlice<HTMLNode>) -> Bool {
        var text = ""
        for node in nodes {
            text += node.kind == .text ? HTMLEntities.decode(node.text) : node.textContent(limit: 300)
            if text.count > 300 { break }
        }
        return forwardMarkers.contains { text.localizedCaseInsensitiveContains($0) }
    }

    private static func hasVisibleText(_ node: HTMLNode, excluding claimed: Set<ObjectIdentifier>) -> Bool {
        if claimed.contains(ObjectIdentifier(node)) { return false }
        switch node.kind {
        case .text:
            return HTMLEntities.decode(node.text).contains { !$0.isWhitespace && $0 != "\u{00A0}" }
        case .trusted:
            return false
        case .element:
            if MailHTMLPolicy.dropWithContent.contains(node.name) { return false }
            if node.name == "img" { return true }
            return node.children.contains { hasVisibleText($0, excluding: claimed) }
        }
    }

    private static let quoteClasses: Set<String> = [
        "gmail_quote", "gmail_quote_container", "yahoo_quoted", "protonmail_quote", "tutanota_quote",
        "zmail_extra", "x_gmail_quote", "ms-outlook-mobile-reference-message",
    ]

    private static let toEndIds: Set<String> = [
        "divRplyFwdMsg", "x_divRplyFwdMsg", "appendonsend", "OLK_SRC_BODY_SECTION",
        "mail-editor-reference-message-container", "x_mail-editor-reference-message-container",
    ]

    private static let headerPrefixes = ["From:", "Von:", "De :", "De:", "Da:", "Van:", "Från:", "От:"]

    private static let attributionPattern =
        #"(wrote|schrieb|a écrit|escribió|ha scritto|scrisse|schreef|napisał|skrev|kirjoitti|написал\(а\)|написал|escreveu)\s*:?\s*$"#

    private static let forwardMarkers = [
        "Forwarded message", "Begin forwarded message", "Weitergeleitete Nachricht", "Message transféré",
        "Mensaje reenviado", "Messaggio inoltrato", "Doorgestuurd bericht",
    ]
}

extension HTMLNode {
    /// Markup we generate ourselves around sanitized children.
    static func trusted(open: String, close: String) -> HTMLNode {
        let node = HTMLNode(trusted: open)
        node.attributes = [HTMLAttribute(name: "close", value: close)]
        return node
    }
}
