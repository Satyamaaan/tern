import Foundation
import Testing
import TernCore
@testable import TernSync

/// A parsed MIME entity, for checking Tern's own output.
private struct Entity {
    var headers: [String: String]
    var body: Data
    var children: [Entity]

    init(_ data: Data) throws {
        let (fields, body) = MultipartReader.headersAndBody(data)
        headers = fields
        self.body = body
        children = []
        if let type = header("Content-Type"), type.lowercased().hasPrefix("multipart/") {
            let boundary = try #require(GmailBatch.boundary(fromContentType: type))
            children = try MultipartReader.split(body, boundary: boundary).map(Entity.init)
        }
    }

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var mimeType: String { (header("Content-Type") ?? "").split(separator: ";").first.map(String.init) ?? "" }

    /// The body with its transfer encoding removed.
    var decoded: Data {
        switch header("Content-Transfer-Encoding")?.lowercased() {
        case "base64": Data(base64Encoded: String(decoding: body, as: UTF8.self), options: .ignoreUnknownCharacters) ?? Data()
        case "quoted-printable": decodeQuotedPrintable(String(decoding: body, as: UTF8.self))
        default: body
        }
    }

    var text: String { String(decoding: decoded, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n") }
}

private func decodeQuotedPrintable(_ text: String) -> Data {
    var out = Data()
    let bytes = Array(text.utf8)
    var i = 0
    while i < bytes.count {
        if bytes[i] == UInt8(ascii: "=") {
            if i + 2 < bytes.count, bytes[i + 1] == 13, bytes[i + 2] == 10 { i += 3; continue }
            if i + 2 < bytes.count, let value = UInt8(String(decoding: bytes[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                out.append(value)
                i += 3
                continue
            }
        }
        out.append(bytes[i])
        i += 1
    }
    return out
}

/// Decodes `=?UTF-8?B?…?=` words; whitespace between adjacent encoded words is dropped.
private func decodeEncodedWords(_ value: String) -> String {
    var result = ""
    var lastWasWord = false
    for token in value.split(separator: " ", omittingEmptySubsequences: false) {
        if token.hasPrefix("=?UTF-8?B?"), token.hasSuffix("?="),
           let data = Data(base64Encoded: String(token.dropFirst(10).dropLast(2))) {
            result += String(decoding: data, as: UTF8.self)
            lastWasWord = true
        } else {
            if !result.isEmpty || lastWasWord { result += " " }
            result += token
            lastWasWord = false
        }
    }
    return result
}

private let me = Participant(name: "Mia Example", email: "me@example.com")
private let fixedDate = Date(timeIntervalSince1970: 1_792_224_000)  // 2026-10-17 08:00:00 UTC

private func build(_ draft: Draft, from: Participant = me, inReplyTo: String? = nil, references: String? = nil) throws -> (String, Entity) {
    var builder = MIMEBuilder(date: fixedDate, timeZone: TimeZone(identifier: "UTC")!)
    var counter = 0
    builder.makeToken = {
        counter += 1
        // As long as the real 32-hex-digit tokens, so line-length checks see real boundaries.
        return String(format: "tok%029d", counter)
    }
    let data = try builder.build(draft: draft, from: from, inReplyTo: inReplyTo, references: references)
    let text = String(decoding: data, as: UTF8.self)
    return (text, try Entity(data))
}

/// RFC 5322 line rules: CRLF only, nothing over 998 characters. Tern's own output also keeps every
/// line, headers and bodies, within 78 for the short MIME types these tests use.
private func checkLines(_ text: String) {
    #expect(!text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    #expect(!text.replacingOccurrences(of: "\r\n", with: "").contains("\r"))
    for line in text.components(separatedBy: "\r\n") {
        #expect(line.count <= 78, "long line: \(line)")
    }
}

private func temporaryFile(_ name: String, _ data: Data) throws -> String {
    let directory = FileManager.default.temporaryDirectory.appending(path: "tern-mime-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: name)
    try data.write(to: url)
    return url.path
}

@Suite struct GoogleMIMETests {
    @Test func plainMessage() throws {
        let draft = Draft(
            accountId: "me@example.com",
            toList: [Participant(name: "Doe, Jane", email: "jane@example.com"), Participant(email: "bob@example.com")],
            ccList: [Participant(name: "Carol \"CJ\" Jones", email: "cj@example.com")],
            bccList: [Participant(email: "secret@example.com")],
            subject: "Quarterly numbers",
            bodyHtml: "<p>Hello <b>there</b>,</p><p>Line two = fine.</p>")
        let (text, message) = try build(draft)
        checkLines(text)

        #expect(message.header("From") == "Mia Example <me@example.com>")
        #expect(message.header("To") == #""Doe, Jane" <jane@example.com>, bob@example.com"#)
        #expect(message.header("Cc") == #""Carol \"CJ\" Jones" <cj@example.com>"#)
        #expect(message.header("Bcc") == "secret@example.com")
        #expect(message.header("Subject") == "Quarterly numbers")
        #expect(message.header("Date") == "Sat, 17 Oct 2026 08:00:00 +0000")
        #expect(message.header("Message-ID") == "<tok00000000000000000000000000001@example.com>")
        #expect(message.header("MIME-Version") == "1.0")
        #expect(message.header("In-Reply-To") == nil)

        #expect(message.mimeType == "multipart/alternative")
        #expect(message.children.map(\.mimeType) == ["text/plain", "text/html"])
        #expect(message.children[0].header("Content-Type") == #"text/plain; charset="UTF-8""#)
        #expect(message.children[0].header("Content-Transfer-Encoding") == "quoted-printable")
        // The CRLF before each boundary belongs to the delimiter (RFC 2046), not the body.
        #expect(message.children[0].text == "Hello there,\n\nLine two = fine.")
        #expect(message.children[1].text == "<p>Hello <b>there</b>,</p><p>Line two = fine.</p>")
        #expect(text.contains("Line two =3D fine."))
    }

    @Test func nonASCIIHeadersUseEncodedWords() throws {
        let subject = "Café meeting — über 🚀 naïve résumé, " + String(repeating: "très long ", count: 8)
        let longName = String(repeating: "とても長い名前", count: 8)
        let draft = Draft(accountId: "a", toList: [Participant(name: "山田太郎", email: "taro@example.jp"),
                                                   Participant(name: longName, email: "long@example.jp")],
                          subject: subject, bodyHtml: "<p>こんにちは、世界。今日はいい天気ですね。</p>")
        let (text, message) = try build(draft, from: Participant(name: "José Müller", email: "jose@example.de"))
        checkLines(text)

        let words = text.components(separatedBy: CharacterSet(charactersIn: " \r\n")).filter { $0.hasPrefix("=?") }
        #expect(!words.isEmpty)
        #expect(words.allSatisfy { $0.count <= 75 && $0.hasSuffix("?=") })
        #expect(decodeEncodedWords(try #require(message.header("Subject"))) == subject)
        let from = try #require(message.header("From"))
        #expect(from.hasSuffix(" <jose@example.de>"))
        #expect(decodeEncodedWords(String(from.dropLast(" <jose@example.de>".count))) == "José Müller")
        let to = try #require(message.header("To")).components(separatedBy: ", ")
        #expect(to.count == 2)
        #expect(decodeEncodedWords(String(to[0].dropLast(" <taro@example.jp>".count))) == "山田太郎")
        #expect(decodeEncodedWords(String(to[1].dropLast(" <long@example.jp>".count))) == longName)

        // Mostly non-ASCII text is smaller as base64.
        #expect(message.children[1].header("Content-Transfer-Encoding") == "base64")
        #expect(message.children[0].text == "こんにちは、世界。今日はいい天気ですね。")
    }

    @Test func replyHeaders() throws {
        let draft = Draft(accountId: "a", kind: .reply, toList: [Participant(email: "ann@example.com")], subject: "Re: Plans")
        let (_, reply) = try build(draft, inReplyTo: "CAB123@mail.gmail.com", references: "<r1@x.com>\r\n <r2@x.com>")
        #expect(reply.header("In-Reply-To") == "<CAB123@mail.gmail.com>")
        #expect(reply.header("References") == "<r1@x.com> <r2@x.com> <CAB123@mail.gmail.com>")

        let (_, again) = try build(draft, inReplyTo: "<r2@x.com>", references: "<r1@x.com> <r2@x.com>")
        #expect(again.header("References") == "<r1@x.com> <r2@x.com>")

        // References come from mail other people wrote; nothing in them may become a header.
        let (text, hostile) = try build(draft, inReplyTo: "<ok@x.com>\r\nBcc: spy@evil.com",
                                        references: "<a@b\r\nBcc: spy@evil.com\r\nX: <q@x> <fine@x.com> <bad id@x>")
        #expect(!text.components(separatedBy: "\r\n").contains { $0.hasPrefix("Bcc:") || $0.hasPrefix("X:") })
        #expect(hostile.header("In-Reply-To") == nil)
        #expect(hostile.header("References") == "<fine@x.com>")

        let longChain = (0..<40).map { "<message-\($0)-with-a-fairly-long-id@mail.example.com>" }.joined(separator: " ")
        let (longText, long) = try build(draft, inReplyTo: "<last@x.com>", references: longChain)
        checkLines(longText)
        #expect(long.header("References")?.hasSuffix("<last@x.com>") == true)
    }

    @Test func attachmentsAreBase64InMixed() throws {
        let binary = Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let report = try temporaryFile("report.pdf", binary)
        let longName = "Prüfbericht – März 2026 (final version with a rather long name for testing).pdf"
        let notes = try temporaryFile("notes.txt", Data("hello".utf8))
        let draft = Draft(accountId: "a", toList: [Participant(email: "x@example.com")], subject: "Files",
                          bodyHtml: "<p>See attached.</p>",
                          attachments: [DraftAttachment(path: report, filename: "report.pdf", mimeType: "application/pdf", size: 5000),
                                        DraftAttachment(path: notes, filename: longName, mimeType: "", size: 5)])
        let (text, message) = try build(draft)
        checkLines(text)

        #expect(message.mimeType == "multipart/mixed")
        #expect(message.children.map(\.mimeType) == ["multipart/alternative", "application/pdf", "application/octet-stream"])
        let pdf = message.children[1]
        #expect(pdf.header("Content-Disposition") == #"attachment; filename="report.pdf""#)
        #expect(pdf.header("Content-Type") == #"application/pdf; name="report.pdf""#)
        #expect(pdf.decoded == binary)
        let lines = String(decoding: pdf.body, as: UTF8.self).components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(lines.dropLast().allSatisfy { $0.count == 76 })
        #expect(lines.allSatisfy { $0.count <= 76 })

        // RFC 2231 continuation: filename*0*=UTF-8''…; filename*1*=…
        let disposition = try #require(message.children[2].header("Content-Disposition"))
        #expect(disposition.hasPrefix("attachment; filename*0*=UTF-8''Pr%C3%BCfbericht"))
        let pieces = disposition.components(separatedBy: ";").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(pieces.count > 1)
        let joined = pieces.map { $0.split(separator: "=", maxSplits: 1)[1] }.joined()
        #expect(joined.dropFirst("UTF-8''".count).removingPercentEncoding == longName)
        #expect(decodeEncodedWords(String(try #require(message.children[2].header("Content-Type"))
            .split(separator: "\"")[1])) == longName)
        #expect(message.children[2].decoded == Data("hello".utf8))
    }

    @Test func inlineImagesUseRelated() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 7, count: 300))
        let path = try temporaryFile("pasted image.png", png)
        let fileURL = URL(fileURLWithPath: path).absoluteString
        let draft = Draft(accountId: "a", toList: [Participant(email: "x@example.com")], subject: "Look",
                          bodyHtml: #"<p>Look:</p><img src="\#(fileURL)" alt="chart">"#,
                          attachments: [DraftAttachment(path: path, filename: "pasted image.png", mimeType: "image/png", size: png.count)])
        let (text, message) = try build(draft)
        checkLines(text)

        #expect(message.mimeType == "multipart/alternative")
        #expect(message.children.map(\.mimeType) == ["text/plain", "multipart/related"])
        let related = message.children[1]
        #expect(related.header("Content-Type")?.contains(#"type="text/html""#) == true)
        #expect(related.children.map(\.mimeType) == ["text/html", "image/png"])
        let image = related.children[1]
        let contentId = try #require(image.header("Content-ID"))
        #expect(contentId.hasPrefix("<") && contentId.hasSuffix("@tern>"))
        #expect(image.header("Content-Disposition")?.hasPrefix("inline;") == true)
        #expect(image.decoded == png)
        let html = related.children[0].text
        #expect(html.contains(#"src="cid:\#(contentId.dropFirst().dropLast())""#))
        #expect(!html.contains("file://"))
    }

    @Test func forwardedInlineImagesKeepTheirContentId() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47] + Array(repeating: 9, count: 100))
        let path = try temporaryFile("logo.png", png)
        let pdf = try temporaryFile("Agenda.pdf", Data("pdf".utf8))
        let draft = Draft(accountId: "a", toList: [Participant(email: "x@example.com")], subject: "Fwd: Offsite",
                          bodyHtml: #"<p>FYI</p><div class="gmail_quote"><img src="cid:logo@lumen"></div>"#,
                          attachments: [DraftAttachment(path: path, filename: "logo.png", mimeType: "image/png", size: png.count,
                                                        contentId: "logo@lumen"),
                                        DraftAttachment(path: pdf, filename: "Agenda.pdf", mimeType: "application/pdf", size: 3)])
        let (text, message) = try build(draft)
        checkLines(text)

        #expect(message.mimeType == "multipart/mixed")
        let related = message.children[0].children[1]
        #expect(related.children.map(\.mimeType) == ["text/html", "image/png"])
        #expect(related.children[1].header("Content-ID") == "<logo@lumen>")
        #expect(related.children[1].decoded == png)
        #expect(related.children[0].text.contains(#"src="cid:logo@lumen""#))
        #expect(message.children[1].mimeType == "application/pdf")
    }

    @Test func anEditedDraftSendsItsInlineImageInline() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47] + Array(repeating: 7, count: 80))
        let path = try temporaryFile("chart.png", png)
        let stored = Draft(accountId: "a", toList: [Participant(email: "x@example.com")], subject: "Numbers",
                           bodyHtml: #"<div dir="ltr">Here:<div><img src="cid:ii_chart" alt="chart.png" width="400"></div></div>"#,
                           attachments: [DraftAttachment(path: path, filename: "chart.png", mimeType: "image/png", size: png.count,
                                                         contentId: "ii_chart")])
        var content = DraftContent(stored: stored)
        content.body.blocks.append(RichText.Block(.paragraph, [RichText.Run("Thoughts?")]))
        let (text, message) = try build(content.assembledDraft())
        checkLines(text)

        #expect(message.mimeType == "multipart/alternative", "the image isn't a separate attachment")
        let related = message.children[1]
        #expect(related.children.map(\.mimeType) == ["text/html", "image/png"])
        #expect(related.children[1].header("Content-ID") == "<ii_chart>")
        #expect(related.children[0].text.contains(#"<img src="cid:ii_chart" alt="">"#))
        #expect(related.children[0].text.contains("Thoughts?"))
    }

    @Test func draftEncoderAddsSenderNameAndReplyHeaders() throws {
        let store = try MailStore(AppDatabase.inMemory())
        try store.database.writer.write { db in
            try Account(email: "me@example.com", displayName: "Personal").insert(db)
            try Setting(key: DraftStore.SettingKey.senderName("me@example.com"), value: "Mia Example").insert(db)
            try MailStore.upsertMessages(db, [MailMessage(
                accountId: "me@example.com", id: "m2", threadId: "t1", date: Date(), fromEmail: "ann@example.com",
                subject: "Plans", rfcMessageId: "<two@example.com>", refs: "<one@example.com>")])
        }
        let draft = Draft(accountId: "me@example.com", threadId: "t1", replyToMessageId: "m2", kind: .reply,
                          toList: [Participant(email: "ann@example.com")], subject: "Re: Plans", bodyHtml: "<p>Yes</p>")
        let account = Account(email: "me@example.com", displayName: "Personal")
        let message = try Entity(try DraftEncoder.make(store: store)(draft, account))
        #expect(message.header("From") == "Mia Example <me@example.com>")
        #expect(message.header("In-Reply-To") == "<two@example.com>")
        #expect(message.header("References") == "<one@example.com> <two@example.com>")

        var fresh = draft
        fresh.kind = .new
        fresh.threadId = nil
        fresh.replyToMessageId = nil
        let plain = try Entity(try DraftEncoder.make(store: store)(fresh, Account(email: "you@example.com")))
        #expect(plain.header("From") == "you@example.com", "no sender name known: the address alone")
        #expect(plain.header("In-Reply-To") == nil)
    }

    @Test func longNamesStillFold() throws {
        let draft = Draft(accountId: "a", toList: [Participant(name: String(repeating: "Very Long Name ", count: 80), email: "x@example.com")],
                          subject: "e" + String(repeating: "\u{301}", count: 600))
        let (text, _) = try build(draft)
        checkLines(text)
    }

    @Test func headerInjectionIsNeutralised() throws {
        let draft = Draft(accountId: "a", toList: [Participant(name: "Ann\r\nBcc: spy@evil.com", email: "ann@example.com")],
                          subject: "Hi\r\nBcc: spy@evil.com")
        let (text, message) = try build(draft)
        #expect(message.header("Bcc") == nil)
        #expect(!text.components(separatedBy: "\r\n").contains { $0.hasPrefix("Bcc:") })
        #expect(message.header("Subject") == "Hi  Bcc: spy@evil.com")
    }

    @Test func unreadableAttachmentThrows() {
        let draft = Draft(accountId: "a", attachments: [DraftAttachment(path: "/nonexistent/x.pdf", filename: "x.pdf",
                                                                       mimeType: "application/pdf", size: 1)])
        #expect(throws: MIMEBuilderError.attachmentUnreadable(path: "/nonexistent/x.pdf")) {
            try MIMEBuilder.build(draft: draft, from: me)
        }
    }

    @Test func quotedPrintableRules() {
        let line = String(repeating: "abc=déf ", count: 30) + "end with space \t\nsecond line"
        let encoded = MIMEEncoding.quotedPrintable(line)
        let lines = encoded.components(separatedBy: "\r\n")
        #expect(lines.allSatisfy { $0.count <= 76 })
        #expect(encoded.contains("=3D"))
        #expect(encoded.contains("=C3=A9"))
        #expect(encoded.contains("space =09\r\nsecond line"))
        #expect(String(decoding: decodeQuotedPrintable(encoded), as: UTF8.self) == line.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n")
    }

    @Test func htmlToPlainText() {
        let cases: [(String, String)] = [
            ("<p>Hello&nbsp;<b>world</b></p>\n  <p>Second &amp; last</p>", "Hello world\n\nSecond & last"),
            ("Line<br>Next<br/><br>After", "Line\nNext\n\nAfter"),
            ("<ul><li>One</li><li>Two</li></ul><ol><li>A</li><li>B</li></ol>", "- One\n- Two\n\n1. A\n2. B"),
            (#"<a href="https://x.com/a">Docs</a> and <a href="https://y.com">https://y.com</a> <a href="mailto:a@b.c">a@b.c</a>"#,
             "Docs (https://x.com/a) and https://y.com a@b.c"),
            ("<p>Reply</p><blockquote><p>Old line</p><p>Older</p></blockquote><p>Bye</p>",
             "Reply\n\n> Old line\n>\n> Older\n\nBye"),
            ("<html><head><title>T</title><style>p { color: red }</style></head><body><script>if (a < b) alert(1)</script><p>Body</p></body></html>",
             "Body"),
            ("&#8212; &#x1F600; &unknown; &lt;tag&gt; 5 &lt 6", "— 😀 &unknown; <tag> 5 &lt 6"),
            ("<pre>  indented\n    code</pre><div>after</div>", "  indented\n    code\n\nafter"),
            ("<div>one</div><div>two</div><!-- <p>hidden</p> -->", "one\ntwo"),
            ("<table><tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr></table>", "a  b\nc  d"),
            (#"<a name="top">anchor</a> and <a href="https://a.com">A</a>"#, "anchor and A (https://a.com)"),
        ]
        for (html, expected) in cases {
            #expect(HTMLText.plainText(fromHTML: html) == expected, "\(html)")
        }
    }
}
