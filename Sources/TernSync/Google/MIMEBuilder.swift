import Foundation
import TernCore

public enum MIMEBuilderError: Error, Equatable, Sendable {
    /// An attachment's file could not be read.
    case attachmentUnreadable(path: String)
}

/// Builds the RFC 5322 message Tern sends through Gmail (`send(raw:)`, drafts).
///
/// Structure, innermost first:
/// - `multipart/alternative`: text/plain (derived from the HTML) and text/html.
/// - Inline images: the HTML half becomes `multipart/related` with the images, each with a
///   Content-ID. An attachment is inline when the HTML shows it with `<img src="…">` pointing at its
///   file (a `file://` URL or the bare path); the builder rewrites that src to `cid:…`.
/// - Other attachments: everything is wrapped in `multipart/mixed`.
///
/// Text parts are quoted-printable (base64 when mostly non-ASCII); attachments are base64 in
/// 76-character lines. Non-ASCII names and subjects use RFC 2047 encoded words, non-ASCII filenames
/// RFC 2231. Lines end in CRLF and stay within 998 characters.
public struct MIMEBuilder {
    public var date: Date
    public var timeZone: TimeZone
    /// Makes boundaries and Content-IDs unique; injectable for stable test output.
    var makeToken: () -> String = { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    public init(date: Date = Date(), timeZone: TimeZone = .current) {
        self.date = date
        self.timeZone = timeZone
    }

    /// Builds a message from a draft.
    /// - Parameters:
    ///   - from: the sending identity (address and display name).
    ///   - inReplyTo: the replied-to message's `rfcMessageId`, for replies.
    ///   - references: that message's own References header (`MailMessage.refs`); the builder
    ///     appends `inReplyTo` to it.
    public static func build(draft: Draft, from: Participant, inReplyTo: String? = nil,
                             references: String? = nil) throws -> Data {
        try MIMEBuilder().build(draft: draft, from: from, inReplyTo: inReplyTo, references: references)
    }

    public func build(draft: Draft, from: Participant, inReplyTo: String? = nil, references: String? = nil) throws -> Data {
        var html = draft.bodyHtml
        var inline: [(DraftAttachment, contentId: String)] = []
        var regular: [DraftAttachment] = []
        for attachment in draft.attachments {
            if attachment.mimeType.lowercased().hasPrefix("image/"),
               let rewritten = Self.replaceImageSource(in: html, path: attachment.path) {
                let contentId = "\(makeToken())@tern"
                html = rewritten.replacingOccurrences(of: Self.cidPlaceholder, with: "cid:\(contentId)")
                inline.append((attachment, contentId))
            } else {
                regular.append(attachment)
            }
        }

        var lines = headers(draft: draft, from: from, inReplyTo: inReplyTo, references: references)
        lines.append("MIME-Version: 1.0")
        var message = lines.joined(separator: MIMEEncoding.crlf) + MIMEEncoding.crlf

        let plain = HTMLText.plainText(fromHTML: html)
        var htmlPart = textPart(html, subtype: "html")
        if !inline.isEmpty {
            var images: [String] = []
            for (attachment, contentId) in inline {
                images.append(try filePart(attachment, disposition: "inline", contentId: contentId))
            }
            htmlPart = multipart("related", [htmlPart] + images, extra: ";\r\n type=\"text/html\"")
        }
        var body = multipart("alternative", [textPart(plain, subtype: "plain"), htmlPart])
        if !regular.isEmpty {
            var parts = [body]
            for attachment in regular { parts.append(try filePart(attachment, disposition: "attachment", contentId: nil)) }
            body = multipart("mixed", parts)
        }
        message += body
        return Data(message.utf8)
    }

    // MARK: Headers

    private func headers(draft: Draft, from: Participant, inReplyTo: String?, references: String?) -> [String] {
        var lines: [String] = []
        if let sender = MIMEEncoding.addressHeader("From", [from]) { lines.append(sender) }
        if let to = MIMEEncoding.addressHeader("To", draft.toList) { lines.append(to) }
        if let cc = MIMEEncoding.addressHeader("Cc", draft.ccList) { lines.append(cc) }
        // Gmail delivers to Bcc recipients and removes the header from what others receive.
        if let bcc = MIMEEncoding.addressHeader("Bcc", draft.bccList) { lines.append(bcc) }
        lines.append(MIMEEncoding.unstructuredHeader("Subject", draft.subject))
        lines.append("Date: " + MIMEEncoding.date(date, timeZone: timeZone))
        let domain = from.email.split(separator: "@").last.map(String.init).flatMap { $0.isEmpty ? nil : $0 } ?? "tern.local"
        lines.append("Message-ID: <\(makeToken())@\(MIMEEncoding.sanitize(domain))>")

        let parent = inReplyTo.flatMap(MIMEEncoding.messageId)
        if let parent { lines.append("In-Reply-To: " + parent) }
        var chain = references.map(MIMEEncoding.messageIds(in:)) ?? []
        if let parent, chain.last != parent { chain.append(parent) }
        var seen = Set<String>()
        chain = chain.filter { seen.insert($0).inserted }
        if !chain.isEmpty { lines.append(MIMEEncoding.fold("References:", chain, separator: " ")) }
        return lines
    }

    // MARK: Parts

    private func textPart(_ text: String, subtype: String) -> String {
        let (encoding, body) = MIMEEncoding.encodeText(text)
        return "Content-Type: text/\(subtype); charset=\"UTF-8\"\r\n"
            + "Content-Transfer-Encoding: \(encoding)\r\n\r\n" + body
    }

    private func filePart(_ attachment: DraftAttachment, disposition: String, contentId: String?) throws -> String {
        guard let data = FileManager.default.contents(atPath: attachment.path) else {
            throw MIMEBuilderError.attachmentUnreadable(path: attachment.path)
        }
        let type = attachment.mimeType.trimmingCharacters(in: .whitespaces)
        let mimeType = type.contains("/") ? MIMEEncoding.sanitize(type) : "application/octet-stream"
        let filename = attachment.filename.isEmpty ? URL(fileURLWithPath: attachment.path).lastPathComponent : attachment.filename
        var part = "Content-Type: \(mimeType)"
        if MIMEEncoding.isPlainASCII(filename) {
            part += MIMEEncoding.parameter("name", filename)
        } else {
            // Encoded words in `name` are not standard (RFC 2047 excludes parameters) but are what
            // older clients read; the RFC 2231 filename below is the real one.
            let words = MIMEEncoding.encodedWords(MIMEEncoding.sanitize(filename))
            if words.count <= 12 { part += ";\r\n name=\"" + words.joined(separator: "\r\n ") + "\"" }
        }
        part += "\r\n"
        part += "Content-Disposition: \(disposition)" + MIMEEncoding.parameter("filename", filename) + "\r\n"
        if let contentId { part += "Content-ID: <\(contentId)>\r\n" }
        part += "Content-Transfer-Encoding: base64\r\n\r\n"
        part += MIMEEncoding.base64Lines(data)
        return part
    }

    private func multipart(_ subtype: String, _ parts: [String], extra: String = "") -> String {
        let boundary = "tern-\(subtype)-\(makeToken())"
        var text = "Content-Type: multipart/\(subtype);\r\n boundary=\"\(boundary)\"\(extra)\r\n\r\n"
        for part in parts {
            text += "--\(boundary)\r\n" + part
            if !part.hasSuffix("\r\n") { text += "\r\n" }
        }
        text += "--\(boundary)--\r\n"
        return text
    }

    // MARK: Inline images

    private static let cidPlaceholder = "\u{0}tern-cid\u{0}"

    /// Replaces every `src` that points at `path` with a placeholder; nil when none does.
    static func replaceImageSource(in html: String, path: String) -> String? {
        let fileURL = URL(fileURLWithPath: path)
        let candidates = Set([fileURL.absoluteString, "file://" + path, path,
                              fileURL.absoluteString.removingPercentEncoding ?? ""].filter { !$0.isEmpty })
        var result = html
        var replaced = false
        for candidate in candidates.sorted(by: { $0.count > $1.count }) {
            for quote in ["\"", "'"] {
                for attribute in ["src=", "SRC="] {
                    let needle = attribute + quote + candidate + quote
                    if result.contains(needle) {
                        result = result.replacingOccurrences(of: needle, with: attribute + quote + cidPlaceholder + quote)
                        replaced = true
                    }
                }
            }
        }
        return replaced ? result : nil
    }
}
