import Foundation
import TernCore
import UniformTypeIdentifiers

/// A Gmail message converted to local records.
public struct ParsedMessage: Sendable, Hashable {
    public var message: MailMessage
    public var attachments: [MailAttachment]
}

/// Converts Gmail API messages into `MailMessage` + `MailAttachment` records: decodes headers and
/// address lists, walks the MIME tree for the HTML and plain-text bodies (alternative, related,
/// mixed, forwarded message/rfc822), converts charsets, and lists attachments.
public enum GmailMessageParser {
    /// - Parameters:
    ///   - format: What `gmail` was fetched with. `.full` stores the body (`bodyState = .full`);
    ///     anything else stores headers and labels only.
    public static func parse(_ gmail: GmailMessage, accountId: String, accountEmail: String,
                             format: GmailMessageFormat = .full) -> ParsedMessage {
        let payload = gmail.payload
        func header(_ name: String) -> String? { payload?.header(name) }
        func list(_ name: String) -> [Participant] { header(name).map(MailParsing.addresses) ?? [] }

        let from = list("From").first ?? list("Sender").first
        let labels = gmail.labelIds ?? []
        let fromMe = from.map { $0.email.caseInsensitiveCompare(accountEmail) == .orderedSame } ?? false

        var message = MailMessage(
            accountId: accountId, id: gmail.id, threadId: gmail.threadId, historyId: gmail.historyId,
            date: date(of: gmail), fromName: from?.name ?? "", fromEmail: from?.email ?? "",
            toList: list("To"), ccList: list("Cc"), bccList: list("Bcc"), replyTo: list("Reply-To"),
            subject: header("Subject").map(cleanText) ?? "",
            snippet: MailParsing.decodeEntities(gmail.snippet ?? ""),
            labelIds: labels, isFromMe: fromMe,
            rfcMessageId: header("Message-ID").map(cleanText).flatMap(nonEmpty),
            inReplyTo: header("In-Reply-To").map(cleanText).flatMap(nonEmpty),
            refs: header("References").map(cleanText).flatMap(nonEmpty),
            listUnsubscribe: header("List-Unsubscribe").map(cleanText).flatMap(nonEmpty),
            listUnsubscribePost: header("List-Unsubscribe-Post").map(cleanText).flatMap(nonEmpty),
            sizeEstimate: gmail.sizeEstimate ?? 0)

        guard format == .full else { return ParsedMessage(message: message, attachments: []) }

        var attachments: [MailAttachment] = []
        message.bodyState = .full
        message.bodyText = ""
        if let payload {
            let content = BodyExtractor(accountId: accountId, messageId: gmail.id).extract(payload, depth: 0)
            message.bodyText = content.plainText()
            message.bodyHtml = content.html()
            var seen = Set<String>()
            attachments = content.attachments.filter { seen.insert($0.partId).inserted }
        }
        message.hasAttachments = attachments.contains { !$0.isInline }
        return ParsedMessage(message: message, attachments: attachments)
    }

    private static func date(of gmail: GmailMessage) -> Date {
        if let internalDate = gmail.internalDate, let ms = Double(internalDate) {
            return Date(timeIntervalSince1970: ms / 1000)
        }
        if let header = gmail.payload?.header("Date"), let date = parseRFC2822Date(header) { return date }
        return Date(timeIntervalSince1970: 0)
    }

    private static let dateFormatters: [DateFormatter] = [
        "EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yy HH:mm:ss Z",
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    static func parseRFC2822Date(_ value: String) -> Date? {
        var text = MailParsing.collapseWhitespace(MailParsing.unfold(value))
        if let comment = text.firstIndex(of: "(") { text = String(text[..<comment]).trimmingCharacters(in: .whitespaces) }
        for formatter in dateFormatters {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    static func cleanText(_ raw: String) -> String {
        MailParsing.decodeHeader(raw).replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonEmpty(_ value: String) -> String? { value.isEmpty ? nil : value }
}

// MARK: - MIME tree

/// The readable content of a MIME subtree: body segments in order, plus its attachments.
private struct Content {
    struct Segment {
        var html: String?
        /// Real text/plain content (never derived from the HTML).
        var text: String?
    }

    var segments: [Segment] = []
    var attachments: [MailAttachment] = []

    var hasHTML: Bool { segments.contains { $0.html != nil } }
    var hasPlainText: Bool { segments.contains { $0.text != nil } }

    mutating func append(_ other: Content) {
        segments += other.segments
        attachments += other.attachments
    }

    /// Plain text for the whole subtree: text/plain where present, otherwise derived from the HTML.
    func plainText() -> String {
        segments.map { segment in
            if let text = segment.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            return segment.html.map(MailParsing.plainText(fromHTML:)) ?? ""
        }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    /// HTML for the subtree when any part of it is HTML; plain segments are escaped in.
    func html() -> String? {
        guard hasHTML else { return nil }
        return segments.map { segment in
            segment.html ?? "<div style=\"white-space: pre-wrap\">\(MailParsing.escapeHTML(segment.text ?? ""))</div>"
        }.joined(separator: "\n")
    }
}

private struct BodyExtractor {
    let accountId: String
    let messageId: String

    private static let maxDepth = 24

    func extract(_ part: GmailMessagePart, depth: Int) -> Content {
        guard depth < Self.maxDepth else { return Content() }
        let contentType = MailParsing.parameterizedValue(part.header("Content-Type") ?? part.mimeType ?? "text/plain")
        let type = (part.mimeType.flatMap { $0.isEmpty ? nil : $0 } ?? contentType.value).lowercased()
        let disposition = part.header("Content-Disposition").map(MailParsing.parameterizedValue)
        let isAttachment = disposition?.value == "attachment"
        let filename = Self.filename(of: part, contentType: contentType, disposition: disposition)

        if type.hasPrefix("multipart/") {
            let children = part.parts ?? []
            switch type {
            case "multipart/alternative":
                return alternative(children, depth: depth)
            case "multipart/related":
                return related(children, start: contentType.parameters["start"], depth: depth)
            default:
                var content = Content()
                for child in children { content.append(extract(child, depth: depth + 1)) }
                return content
            }
        }

        if type == "message/rfc822" {
            var content = forwarded(part, depth: depth)
            if isAttachment || content.segments.isEmpty, let attachment = attachment(part, type: type, filename: filename, disposition: disposition, forceInline: false) {
                content.attachments.append(attachment)
            }
            return content
        }

        let isBodyText = type == "text/plain" || type == "text/html" || type == "message/delivery-status"
        if isBodyText, !isAttachment, filename.isEmpty {
            guard let data = part.body?.data.flatMap(MailParsing.base64URLDecode) else { return Content() }
            let text = MailParsing.decodeText(data, charset: contentType.parameters["charset"])
            let segment = type == "text/html" ? Content.Segment(html: text, text: nil) : Content.Segment(html: nil, text: text)
            return Content(segments: [segment])
        }

        var content = Content()
        if let attachment = attachment(part, type: type, filename: filename, disposition: disposition, forceInline: false) {
            content.attachments.append(attachment)
        }
        return content
    }

    /// Alternatives of the same content: HTML from the last child that has it, plain text from the
    /// first child that is plain text. Attachments (e.g. inline images in a related child) are kept.
    private func alternative(_ children: [GmailMessagePart], depth: Int) -> Content {
        let contents = children.map { extract($0, depth: depth + 1) }
        var result = Content()
        for content in contents { result.attachments += content.attachments }
        let htmlChild = contents.last { $0.hasHTML }
        let textChild = contents.first { $0.hasPlainText && !$0.hasHTML }
        let html = htmlChild?.html()
        let text = textChild?.plainText()
        if html != nil || text != nil { result.segments = [Content.Segment(html: html, text: text)] }
        return result
    }

    /// A root body plus the resources it references by Content-ID (inline images).
    private func related(_ children: [GmailMessagePart], start: String?, depth: Int) -> Content {
        guard !children.isEmpty else { return Content() }
        let startId = start.map(Self.stripAngles)
        let rootIndex = startId.flatMap { id in children.firstIndex { $0.header("Content-ID").map(Self.stripAngles) == id } } ?? 0
        var content = extract(children[rootIndex], depth: depth + 1)
        for (index, child) in children.enumerated() where index != rootIndex {
            let childType = (child.mimeType ?? "").lowercased()
            if childType.hasPrefix("multipart/") || childType == "message/rfc822" {
                content.append(extract(child, depth: depth + 1))
                continue
            }
            let contentType = MailParsing.parameterizedValue(child.header("Content-Type") ?? childType)
            let disposition = child.header("Content-Disposition").map(MailParsing.parameterizedValue)
            let filename = Self.filename(of: child, contentType: contentType, disposition: disposition)
            if let attachment = attachment(child, type: childType.isEmpty ? contentType.value : childType, filename: filename,
                                           disposition: disposition, forceInline: true) {
                content.attachments.append(attachment)
            }
        }
        return content
    }

    /// A forwarded message, rendered below a header block so it's readable and searchable.
    private func forwarded(_ part: GmailMessagePart, depth: Int) -> Content {
        guard let children = part.parts, !children.isEmpty else { return Content() }
        let inner = children.count == 1 ? children[0] : GmailMessagePart(partId: part.partId, mimeType: "multipart/mixed", parts: children)
        let headerSource = [inner, part].first { $0.header("From") != nil || $0.header("Subject") != nil } ?? inner
        let innerContent = extract(inner, depth: depth + 1)

        var lines: [(String, String)] = []
        for name in ["From", "Date", "Subject", "To", "Cc"] {
            if let value = headerSource.header(name) { lines.append((name, GmailMessageParser.cleanText(value))) }
        }
        let headerText = (["---------- Forwarded message ---------"] + lines.map { "\($0.0): \($0.1)" }).joined(separator: "\n")
        let body = innerContent.plainText()

        var segment = Content.Segment(html: nil, text: body.isEmpty ? headerText : headerText + "\n\n" + body)
        if let innerHTML = innerContent.html() {
            let headerHTML = lines.map { "<b>\($0.0):</b> \(MailParsing.escapeHTML($0.1))" }.joined(separator: "<br>\n")
            segment.html = """
                <div class="tern-forwarded"><p>---------- Forwarded message ---------<br>
                \(headerHTML)</p>
                <blockquote>\(innerHTML)</blockquote></div>
                """
        }
        return Content(segments: [segment], attachments: innerContent.attachments)
    }

    private func attachment(_ part: GmailMessagePart, type: String, filename: String,
                            disposition: MailParsing.ParameterizedValue?, forceInline: Bool) -> MailAttachment? {
        let attachmentId = part.body?.attachmentId
        let data = part.body?.data
        let size = part.body?.size ?? data.flatMap(MailParsing.base64URLDecode)?.count ?? 0
        guard attachmentId != nil || data != nil || size > 0 || part.parts != nil else { return nil }
        let contentId = part.header("Content-ID").map(Self.stripAngles).flatMap { $0.isEmpty ? nil : $0 }
        let isInline = disposition?.value != "attachment" && (contentId != nil || forceInline)
        let partId = (part.partId ?? "").isEmpty ? "0" : part.partId!
        return MailAttachment(
            accountId: accountId, messageId: messageId, partId: partId, attachmentId: attachmentId,
            filename: filename.isEmpty ? Self.defaultFilename(type: type, part: part) : filename,
            mimeType: type, size: size, contentId: contentId, isInline: isInline)
    }

    /// Content-Disposition filename (RFC 2231 aware), then Content-Type name, then Gmail's filename;
    /// encoded words are decoded and any path is dropped.
    private static func filename(of part: GmailMessagePart, contentType: MailParsing.ParameterizedValue,
                                 disposition: MailParsing.ParameterizedValue?) -> String {
        let candidates = [disposition?.parameters["filename"], contentType.parameters["name"], part.filename]
        guard let raw = candidates.compactMap({ $0 }).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return "" }
        let decoded = MailParsing.decodeHeader(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        let last = decoded.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? decoded
        return last
    }

    private static func defaultFilename(type: String, part: GmailMessagePart) -> String {
        if type == "message/rfc822" {
            let subject = part.parts?.first?.header("Subject").map(GmailMessageParser.cleanText) ?? ""
            return (subject.isEmpty ? "message" : subject.replacingOccurrences(of: "/", with: "-")) + ".eml"
        }
        let base: String
        if type.hasPrefix("image/") {
            base = "image"
        } else if type == "text/calendar" || type == "application/ics" {
            base = "invite"
        } else {
            base = "attachment"
        }
        guard let ext = UTType(mimeType: type)?.preferredFilenameExtension else { return base }
        return "\(base).\(ext)"
    }

    static func stripAngles(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("<") { text.removeFirst() }
        if text.hasSuffix(">") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
