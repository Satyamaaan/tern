import Foundation

/// What the composer should start from. Mirrors the app's `ComposeRequest`, which TernCore can't see.
public enum DraftIntent: Hashable, Sendable {
    /// A new message, optionally from a given account and to given people.
    case new(accountId: String?, to: [Participant] = [])
    case reply(ThreadKey, all: Bool)
    case forward(ThreadKey)
    /// Reopen a local draft by its id.
    case existing(id: String)
}

/// A draft split into the part the user edits and the parts kept aside: the account signature and
/// the quoted original (reply) or forwarded message. `Draft.bodyHtml` always holds the assembled
/// HTML, so the sender sends it as is.
public struct DraftContent: Hashable, Sendable {
    public var draft: Draft
    /// The editable body.
    public var body: RichText
    /// Signature HTML, kept as written; nil when there is none or the user removed it.
    public var signatureHtml: String?
    /// The `gmail_quote` block: quoted original or forwarded message. Shown collapsed (`•••`).
    public var quoteHtml: String?

    public init(draft: Draft, body: RichText = RichText(), signatureHtml: String? = nil, quoteHtml: String? = nil) {
        self.draft = draft
        self.body = body
        self.signatureHtml = signatureHtml
        self.quoteHtml = quoteHtml
        self.draft.bodyHtml = html
    }

    /// Splits a stored draft back into body, signature and quote.
    public init(stored draft: Draft) {
        let parts = Self.split(draft.bodyHtml)
        self.draft = draft
        self.body = RichText(html: parts.body)
        self.signatureHtml = parts.signature
        self.quoteHtml = parts.quote
    }

    static let signatureOpen = #"<div class="gmail_signature" data-smartmail="gmail_signature">"#

    /// Body, then signature, then quote, each separated by one blank line.
    public var html: String {
        var html = body.html
        if let signatureHtml { html += "<br>\(Self.signatureOpen)\(signatureHtml)</div>" }
        if let quoteHtml { html += "<br>\(quoteHtml)" }
        return html
    }

    /// The draft with `bodyHtml` assembled from the current parts.
    public func assembledDraft(updatedAt: Date = Date()) -> Draft {
        var draft = draft
        draft.bodyHtml = html
        draft.updatedAt = updatedAt
        return draft
    }

    /// Nothing worth keeping: no typed text or files, and for new mail no recipients or subject either.
    /// Prefilled reply recipients, subjects and quotes don't count.
    public var isBlank: Bool {
        guard body.isEmpty else { return false }
        let ownFiles = draft.attachments.filter { $0.remote == nil }
        let recipients = draft.toList.count + draft.ccList.count + draft.bccList.count
        switch draft.kind {
        case .new:
            return ownFiles.isEmpty && recipients == 0
                && draft.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .reply, .replyAll:
            return ownFiles.isEmpty
        case .forward:
            return recipients == 0 && ownFiles.isEmpty
        }
    }

    /// Finds the quote (`class="gmail_quote…"`) and signature (`class="gmail_signature"`) blocks by their
    /// opening `<div`. Works for drafts Tern wrote and, roughly, for Gmail's own.
    static func split(_ html: String) -> (body: String, signature: String?, quote: String?) {
        var rest = Substring(html)
        var quote: String?
        if let start = openingDiv(of: #"class="gmail_quote"#, in: rest) {
            quote = String(rest[start...])
            rest = rest[..<start]
            if rest.hasSuffix("<br>") { rest = rest.dropLast(4) }
        }
        var signature: String?
        if let start = openingDiv(of: #"class="gmail_signature""#, in: rest),
           let tagEnd = rest[start...].firstIndex(of: ">") {
            let innerStart = rest.index(after: tagEnd)
            let close = matchingClose(in: rest, from: innerStart)
            signature = String(rest[innerStart..<(close?.lowerBound ?? rest.endIndex)])
            var before = rest[..<start]
            if before.hasSuffix("<br>") { before = before.dropLast(4) }
            for prefix in [#"<span class="gmail_signature_prefix">-- </span><br>"#, "-- <br>"] where before.hasSuffix(prefix) {
                before = before.dropLast(prefix.count)
            }
            // Gmail nests the signature inside the body's wrapper; keep whatever closes after it.
            rest = Substring(String(before) + (close.map { String(rest[$0.upperBound...]) } ?? ""))
        }
        return (String(rest), signature, quote)
    }

    /// The `</div>` that closes a div whose content starts at `start`.
    private static func matchingClose(in html: Substring, from start: Substring.Index) -> Range<Substring.Index>? {
        var depth = 1
        var position = start
        while let close = html[position...].range(of: "</div>", options: .caseInsensitive) {
            if let open = html[position..<close.lowerBound].range(of: "<div", options: .caseInsensitive) {
                depth += 1
                position = open.upperBound
                continue
            }
            depth -= 1
            if depth == 0 { return close }
            position = close.upperBound
        }
        return nil
    }

    /// The `<div` that opens the element carrying `marker` in its attributes.
    private static func openingDiv(of marker: String, in html: Substring) -> Substring.Index? {
        guard let match = html.range(of: marker),
              let open = html[..<match.lowerBound].range(of: "<div", options: .backwards) else { return nil }
        // The marker must belong to this tag, not to something after it closed.
        guard !html[open.upperBound..<match.lowerBound].contains(">") else { return nil }
        return open.lowerBound
    }
}
