import Foundation

/// The starting point of replies and forwards: subjects, recipients and the quoted original, in the
/// same shape Gmail writes so threads and quote folding work in every client.
public enum DraftTemplate {
    // MARK: Subjects

    /// Reply prefixes in the languages mail clients commonly use (Re, Aw, Antw, Sv, Vs, Ref, Rif, Odp, Ynt, 回复…).
    static let replyPrefixes = ["re", "aw", "antw", "sv", "vs", "ref", "rif", "odp", "ynt", "atb", "回复", "回覆", "答复"]
    /// Forward prefixes (Fwd, Fw, Wg, Tr, Rv, Enc, Vl, Fs, Doorst, 转发, 轉寄).
    static let forwardPrefixes = ["fwd", "fw", "wg", "tr", "rv", "enc", "vl", "fs", "doorst", "转发", "轉寄"]

    /// One "Re: " in front, after removing any stack of reply prefixes ("RE: Aw: re[2]: x" → "Re: x").
    /// A forward prefix stays: replying to "Fwd: x" gives "Re: Fwd: x", like Gmail.
    public static func replySubject(_ subject: String) -> String {
        let base = stripping(replyPrefixes, from: subject)
        return base.isEmpty ? "Re:" : "Re: \(base)"
    }

    /// One "Fwd: " in front, after removing any forward prefixes ("FW: Fwd: x" → "Fwd: x").
    public static func forwardSubject(_ subject: String) -> String {
        let base = stripping(forwardPrefixes, from: subject)
        return base.isEmpty ? "Fwd:" : "Fwd: \(base)"
    }

    /// Removes leading `prefix[n]:` / `prefix(n):` / `prefix：` markers, case-insensitively, as many as there are.
    static func stripping(_ prefixes: [String], from subject: String) -> String {
        var rest = Substring(subject).drop(while: \.isWhitespace)
        while let next = droppingPrefix(prefixes, from: rest) { rest = next }
        return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func droppingPrefix(_ prefixes: [String], from text: Substring) -> Substring? {
        let lower = text.lowercased()
        for prefix in prefixes where lower.hasPrefix(prefix) {
            var rest = text.dropFirst(prefix.count).drop(while: { $0 == " " })
            if rest.first == "[" || rest.first == "(" {
                let close: Character = rest.first == "[" ? "]" : ")"
                let digits = rest.dropFirst().prefix(while: \.isNumber)
                guard !digits.isEmpty, rest.dropFirst(1 + digits.count).first == close else { continue }
                rest = rest.dropFirst(2 + digits.count).drop(while: { $0 == " " })
            }
            guard rest.first == ":" || rest.first == "：" else { continue }
            return rest.dropFirst().drop(while: \.isWhitespace)
        }
        return nil
    }

    // MARK: Recipients

    /// Who a reply goes to. Reply: the Reply-To (or From) of the message; reply all adds its To and Cc.
    /// When the message is your own, the reply continues to its recipients. Your own addresses are
    /// removed and duplicates collapse case-insensitively; an address in To never repeats in Cc.
    public static func replyRecipients(
        to message: MailMessage, all: Bool, ownAddresses: Set<String>
    ) -> (to: [Participant], cc: [Participant]) {
        let own = Set(ownAddresses.map { $0.lowercased() })
        let fromMe = message.isFromMe || own.contains(message.fromEmail.lowercased())
        var to: [Participant]
        var cc: [Participant] = []
        if fromMe {
            to = message.toList
            if all { cc = message.ccList }
        } else {
            to = message.replyTo.isEmpty ? [message.from] : message.replyTo
            if all {
                to += message.toList
                cc = message.ccList
            }
        }
        to = RecipientParser.deduplicated(to, excluding: own)
        if to.isEmpty { to = fromMe ? RecipientParser.deduplicated(message.toList) : [message.from] }
        cc = RecipientParser.deduplicated(cc, excluding: own.union(to.map { $0.email.lowercased() }))
        return (to, cc)
    }

    // MARK: Quotes

    /// "On Mon, Oct 12, 2026 at 9:41 AM, Maya Chen <maya@lumen.io> wrote:"
    public static func attribution(for message: MailMessage, timeZone: TimeZone = .current) -> String {
        "On \(dateText(message.date, timeZone: timeZone)), \(senderText(message.from)) wrote:"
    }

    /// The reply quote: attribution plus the original in a `gmail_quote` blockquote.
    public static func quoteHTML(for message: MailMessage, timeZone: TimeZone = .current) -> String {
        let attribution = "On \(dateText(message.date, timeZone: timeZone)), \(senderHTML(message.from)) wrote:"
        return """
            <div class="gmail_quote"><div dir="ltr" class="gmail_attr">\(attribution)<br></div>\
            <blockquote class="gmail_quote" style="margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex">\
            \(originalHTML(of: message))</blockquote></div>
            """
    }

    /// The forwarded-message block: Gmail's header lines, then the original.
    public static func forwardHTML(for message: MailMessage, timeZone: TimeZone = .current) -> String {
        var header = "---------- Forwarded message ---------<br>"
        header += "From: <strong class=\"gmail_sendername\" dir=\"auto\">\(RichText.htmlEscaped(message.fromName.isEmpty ? message.fromEmail : message.fromName))</strong>"
        if !message.fromName.isEmpty { header += " <span dir=\"auto\">&lt;\(mailto(message.fromEmail))&gt;</span>" }
        header += "<br>Date: \(dateText(message.date, timeZone: timeZone))<br>"
        header += "Subject: \(RichText.htmlEscaped(message.subject))<br>"
        if !message.toList.isEmpty { header += "To: \(peopleHTML(message.toList))<br>" }
        if !message.ccList.isEmpty { header += "Cc: \(peopleHTML(message.ccList))<br>" }
        return "<div class=\"gmail_quote\"><div dir=\"ltr\" class=\"gmail_attr\">\(header)</div><br><br>\(originalHTML(of: message))</div>"
    }

    /// The message body to quote: its HTML without document wrappers, or the plain text escaped.
    public static func originalHTML(of message: MailMessage) -> String {
        if let html = message.bodyHtml, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return bodyFragment(html)
        }
        let text = message.bodyText ?? message.snippet
        return "<div dir=\"ltr\">\(RichText.htmlEscaped(text))</div>"
    }

    /// Strips `<!DOCTYPE>`, `<html>`, `<head>…</head>`, `<body>` and scripts so a document can sit inside a quote.
    static func bodyFragment(_ html: String) -> String {
        var text = html
        if let bodyStart = text.range(of: "<body", options: .caseInsensitive),
           let tagEnd = text[bodyStart.upperBound...].firstIndex(of: ">") {
            text = String(text[text.index(after: tagEnd)...])
            if let bodyEnd = text.range(of: "</body", options: [.caseInsensitive, .backwards]) {
                text = String(text[..<bodyEnd.lowerBound])
            }
        } else {
            text = removingElement("head", from: text)
        }
        text = removingElement("script", from: text)
        for pattern in ["<!doctype", "<html", "</html"] {
            while let start = text.range(of: pattern, options: .caseInsensitive),
                  let end = text[start.upperBound...].firstIndex(of: ">") {
                text.removeSubrange(start.lowerBound...end)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removingElement(_ name: String, from html: String) -> String {
        var text = html
        while let start = text.range(of: "<\(name)", options: .caseInsensitive) {
            guard let end = text.range(of: "</\(name)>", options: .caseInsensitive, range: start.upperBound..<text.endIndex) else {
                text.removeSubrange(start.lowerBound...)
                break
            }
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return text
    }

    // MARK: Formatting

    /// "Mon, Oct 12, 2026 at 9:41 AM", in English like the quote line Gmail writes.
    public static func dateText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE, MMM d, yyyy 'at' h:mm a"
        return formatter.string(from: date)
    }

    /// "Maya Chen <maya@lumen.io>", or "<maya@lumen.io>" without a name.
    static func senderText(_ person: Participant) -> String {
        person.name.isEmpty ? "<\(person.email)>" : "\(person.name) <\(person.email)>"
    }

    static func senderHTML(_ person: Participant) -> String {
        let address = "&lt;\(mailto(person.email))&gt;"
        return person.name.isEmpty ? address : "\(RichText.htmlEscaped(person.name)) \(address)"
    }

    static func peopleHTML(_ people: [Participant]) -> String {
        people.map(senderHTML).joined(separator: ", ")
    }

    static func mailto(_ email: String) -> String {
        let escaped = RichText.htmlEscaped(email)
        return "<a href=\"mailto:\(escaped)\">\(escaped)</a>"
    }
}
