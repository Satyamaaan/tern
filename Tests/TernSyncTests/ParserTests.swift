import Foundation
import Testing
import TernCore
@testable import TernSync

// MARK: - Fixtures

private let me = "me@example.com"

private func b64(_ data: Data) -> String { MailParsing.base64URLEncode(data) }
private func b64(_ text: String) -> String { b64(Data(text.utf8)) }

private func leaf(_ type: String, _ data: Data, charset: String? = "utf-8", partId: String = "0",
                  headers: [GmailHeader] = [], filename: String = "") -> GmailMessagePart {
    let contentType = charset.map { "\(type); charset=\"\($0)\"" } ?? type
    return GmailMessagePart(partId: partId, mimeType: type, filename: filename,
                            headers: [GmailHeader(name: "Content-Type", value: contentType)] + headers,
                            body: GmailPartBody(size: data.count, data: b64(data)))
}

private func leaf(_ type: String, _ text: String, partId: String = "0") -> GmailMessagePart {
    leaf(type, Data(text.utf8), partId: partId)
}

private func multipart(_ subtype: String, partId: String = "", _ parts: [GmailMessagePart], headers: [GmailHeader] = []) -> GmailMessagePart {
    GmailMessagePart(partId: partId, mimeType: "multipart/\(subtype)", filename: "",
                     headers: [GmailHeader(name: "Content-Type", value: "multipart/\(subtype); boundary=x")] + headers,
                     body: GmailPartBody(size: 0), parts: parts)
}

private func message(_ payload: GmailMessagePart, headers: [GmailHeader] = [], labels: [String] = ["INBOX"],
                     snippet: String = "") -> GmailMessage {
    var root = payload
    root.headers = [
        GmailHeader(name: "From", value: "Ann Lee <ann@example.com>"),
        GmailHeader(name: "To", value: me),
        GmailHeader(name: "Subject", value: "Hello"),
    ].filter { header in !headers.contains { $0.name == header.name } } + headers + (root.headers ?? [])
    return GmailMessage(id: "m1", threadId: "t1", labelIds: labels, snippet: snippet, historyId: "77",
                        internalDate: "1700000000123", payload: root, sizeEstimate: 2048)
}

private func parse(_ gmail: GmailMessage, format: GmailMessageFormat = .full) -> ParsedMessage {
    GmailMessageParser.parse(gmail, accountId: me, accountEmail: me, format: format)
}

// MARK: - Bodies

@Test func alternativePrefersHTMLAndKeepsPlainText() {
    let parsed = parse(message(multipart("alternative", [
        leaf("text/plain", "Plain version", partId: "0"),
        leaf("text/html", "<p>HTML <b>version</b></p>", partId: "1"),
    ])))
    #expect(parsed.message.bodyHtml == "<p>HTML <b>version</b></p>")
    #expect(parsed.message.bodyText == "Plain version")
    #expect(parsed.message.bodyState == .full)
    #expect(parsed.attachments.isEmpty)
    #expect(!parsed.message.hasAttachments)
}

@Test func htmlOnlyDerivesReadableText() {
    let html = """
        <html><head><title>Ignore me</title><style>p { color: red }</style></head>
        <body><script>alert("x")</script><!-- hidden -->
        <p>Caf&eacute; &amp; bar&nbsp;&#8212; open&#x21;</p><div>Second&zwnj;&nbsp;line</div>
        <table><tr><td>A</td><td>B</td></tr></table><p>1 &lt; 2</p></body></html>
        """
    let parsed = parse(message(leaf("text/html", html, partId: "")))
    #expect(parsed.message.bodyHtml == html)
    #expect(parsed.message.bodyText == "Café & bar — open!\n\nSecond line\n\nA B\n\n1 < 2")
}

@Test func plainTextOnlyMessage() {
    let parsed = parse(message(leaf("text/plain", "Just text\nwith lines", partId: "")))
    #expect(parsed.message.bodyText == "Just text\nwith lines")
    #expect(parsed.message.bodyHtml == nil)
}

@Test func relatedKeepsCidPartsAsInlineAttachments() {
    let image = GmailMessagePart(
        partId: "0.1", mimeType: "image/png", filename: "logo.png",
        headers: [GmailHeader(name: "Content-Type", value: "image/png; name=\"logo.png\""),
                  GmailHeader(name: "Content-ID", value: "<logo@acme>"),
                  GmailHeader(name: "Content-Disposition", value: "inline; filename=\"logo.png\"")],
        body: GmailPartBody(attachmentId: "att-logo", size: 1234))
    let parsed = parse(message(multipart("related", [
        multipart("alternative", partId: "0", [leaf("text/plain", "Hi", partId: "0.0.0"),
                                              leaf("text/html", "<img src=\"cid:logo@acme\">Hi", partId: "0.0.1")]),
        image,
    ])))
    #expect(parsed.message.bodyHtml == "<img src=\"cid:logo@acme\">Hi")
    #expect(parsed.message.bodyText == "Hi")
    let attachment = try! #require(parsed.attachments.first)
    #expect(parsed.attachments.count == 1)
    #expect(attachment.contentId == "logo@acme")
    #expect(attachment.isInline)
    #expect(attachment.attachmentId == "att-logo")
    #expect(attachment.partId == "0.1")
    #expect(attachment.size == 1234)
    #expect(!parsed.message.hasAttachments)
}

@Test func mixedListsAttachments() {
    let pdf = GmailMessagePart(
        partId: "1", mimeType: "application/pdf", filename: "Q3 report.pdf",
        headers: [GmailHeader(name: "Content-Type", value: "application/pdf; name=\"Q3 report.pdf\""),
                  GmailHeader(name: "Content-Disposition", value: "attachment; filename=\"Q3 report.pdf\"")],
        body: GmailPartBody(attachmentId: "att-pdf", size: 52_000))
    let parsed = parse(message(multipart("mixed", [leaf("text/plain", "See attached", partId: "0"), pdf])))
    #expect(parsed.message.bodyText == "See attached")
    #expect(parsed.message.hasAttachments)
    let attachment = try! #require(parsed.attachments.first)
    #expect(attachment.filename == "Q3 report.pdf")
    #expect(attachment.mimeType == "application/pdf")
    #expect(attachment.size == 52_000)
    #expect(attachment.attachmentId == "att-pdf")
    #expect(!attachment.isInline)
    #expect(attachment.accountId == me && attachment.messageId == "m1")
}

@Test func latin1AndWindows1252Bodies() {
    let latin1 = Data([0x43, 0x61, 0x66, 0xE9, 0x20, 0x6E, 0x61, 0xEF, 0x76, 0x65]) // "Café naïve"
    #expect(parse(message(leaf("text/plain", latin1, charset: "ISO-8859-1", partId: ""))).message.bodyText == "Café naïve")
    let cp1252 = Data([0x93, 0x51, 0x75, 0x6F, 0x74, 0x65, 0x94, 0x20, 0x96, 0x20, 0x80, 0x35]) // “Quote” – €5
    #expect(parse(message(leaf("text/plain", cp1252, charset: "windows-1252", partId: ""))).message.bodyText == "“Quote” – €5")
    // Mislabelled as Latin-1 but really Windows-1252, as browsers assume.
    #expect(parse(message(leaf("text/plain", cp1252, charset: "iso-8859-1", partId: ""))).message.bodyText == "“Quote” – €5")
}

@Test func iso2022JPBodyAndSubject() throws {
    let body = try #require("日本語のテストです".data(using: .iso2022JP))
    let subjectBytes = try #require("会議の件".data(using: .iso2022JP))
    let subject = "=?ISO-2022-JP?B?\(subjectBytes.base64EncodedString())?="
    let parsed = parse(message(leaf("text/plain", body, charset: "ISO-2022-JP", partId: ""),
                               headers: [GmailHeader(name: "Subject", value: subject)]))
    #expect(parsed.message.bodyText == "日本語のテストです")
    #expect(parsed.message.subject == "会議の件")
}

@Test func undeclaredCharsetFallsBack() {
    // Invalid UTF-8 with no charset: decoded as Latin-1 rather than dropped.
    let parsed = parse(message(leaf("text/plain", Data([0x41, 0xE9, 0x42]), charset: nil, partId: "")))
    #expect(parsed.message.bodyText == "AéB")
}

@Test func forwardedMessageIsInlinedWithHeaders() {
    let inner = GmailMessagePart(
        partId: "1.0", mimeType: "multipart/alternative", filename: "",
        headers: [GmailHeader(name: "From", value: "Bob <bob@example.com>"),
                  GmailHeader(name: "Subject", value: "Original plan"),
                  GmailHeader(name: "Date", value: "Mon, 2 Oct 2023 10:00:00 +0000"),
                  GmailHeader(name: "Content-Type", value: "multipart/alternative; boundary=y")],
        parts: [leaf("text/plain", "The original text", partId: "1.0.0"),
                leaf("text/html", "<p>The original text</p>", partId: "1.0.1")])
    let rfc822 = GmailMessagePart(partId: "1", mimeType: "message/rfc822", filename: "",
                                  headers: [GmailHeader(name: "Content-Type", value: "message/rfc822")],
                                  body: GmailPartBody(size: 400), parts: [inner])
    let parsed = parse(message(multipart("mixed", [leaf("text/plain", "FYI, see below", partId: "0"), rfc822])))
    let text = parsed.message.bodyText ?? ""
    #expect(text.hasPrefix("FYI, see below"))
    #expect(text.contains("---------- Forwarded message ---------"))
    #expect(text.contains("From: Bob <bob@example.com>"))
    #expect(text.contains("Subject: Original plan"))
    #expect(text.contains("The original text"))
    #expect(parsed.message.bodyHtml?.contains("<blockquote><p>The original text</p></blockquote>") == true)
    #expect(parsed.attachments.isEmpty)
}

@Test func forwardedAsAttachmentIsAlsoListed() {
    let inner = GmailMessagePart(partId: "1.0", mimeType: "text/plain", filename: "",
                                 headers: [GmailHeader(name: "Subject", value: "Invoice 7"),
                                           GmailHeader(name: "Content-Type", value: "text/plain")],
                                 body: GmailPartBody(size: 5, data: b64("Pay me")))
    let rfc822 = GmailMessagePart(partId: "1", mimeType: "message/rfc822", filename: "",
                                  headers: [GmailHeader(name: "Content-Type", value: "message/rfc822"),
                                            GmailHeader(name: "Content-Disposition", value: "attachment")],
                                  body: GmailPartBody(attachmentId: "att-eml", size: 300), parts: [inner])
    let parsed = parse(message(multipart("mixed", [leaf("text/plain", "Forwarding", partId: "0"), rfc822])))
    #expect(parsed.message.bodyText?.contains("Pay me") == true)
    #expect(parsed.attachments.map(\.filename) == ["Invoice 7.eml"])
    #expect(parsed.message.hasAttachments)
}

@Test func rfc2231AndEncodedWordFilenames() {
    let euro = GmailMessagePart(
        partId: "1", mimeType: "application/pdf", filename: "",
        headers: [GmailHeader(name: "Content-Type", value: "application/pdf"),
                  GmailHeader(name: "Content-Disposition", value: "attachment; filename*=UTF-8''%E2%82%AC%20rates%202024.pdf")],
        body: GmailPartBody(attachmentId: "a1", size: 10))
    let continued = GmailMessagePart(
        partId: "2", mimeType: "text/csv", filename: "",
        headers: [GmailHeader(name: "Content-Type", value: "text/csv"),
                  GmailHeader(name: "Content-Disposition",
                              value: "attachment;\r\n filename*0*=iso-8859-1'fr'r%E9sum%E9;\r\n filename*1=\"_final\";\r\n filename*2*=.csv")],
        body: GmailPartBody(attachmentId: "a2", size: 10))
    let encodedWord = GmailMessagePart(
        partId: "3", mimeType: "image/jpeg", filename: "",
        headers: [GmailHeader(name: "Content-Type", value: "image/jpeg; name=\"=?UTF-8?B?w7xiZXIuanBn?=\"")],
        body: GmailPartBody(attachmentId: "a3", size: 10))
    let unnamed = GmailMessagePart(partId: "4", mimeType: "image/png", filename: "",
                                   headers: [GmailHeader(name: "Content-Type", value: "image/png")],
                                   body: GmailPartBody(attachmentId: "a4", size: 10))
    let parsed = parse(message(multipart("mixed", [leaf("text/plain", "x", partId: "0"), euro, continued, encodedWord, unnamed])))
    #expect(parsed.attachments.map(\.filename) == ["€ rates 2024.pdf", "résumé_final.csv", "über.jpg", "image.png"])
}

@Test func calendarInviteInAlternativeIsAnAttachment() {
    let invite = leaf("text/calendar", Data("BEGIN:VCALENDAR".utf8), partId: "2", filename: "invite.ics")
    let parsed = parse(message(multipart("alternative", [leaf("text/plain", "Join us", partId: "0"),
                                                       leaf("text/html", "<p>Join us</p>", partId: "1"), invite])))
    #expect(parsed.message.bodyText == "Join us")
    #expect(parsed.attachments.map(\.filename) == ["invite.ics"])
}

// MARK: - Headers

@Test func headersAndFlags() throws {
    let parsed = parse(message(leaf("text/plain", "x", partId: ""), headers: [
        GmailHeader(name: "From", value: "=?UTF-8?Q?M=C3=BCller=2C_Hans?= <hans@example.de>"),
        GmailHeader(name: "To", value: "\"Doe, John\" <john@example.com>, jane@example.com (Jane Roe), Team: a@x.com, \"B\" <b@x.com>;"),
        GmailHeader(name: "Cc", value: "undisclosed-recipients:;"),
        GmailHeader(name: "Reply-To", value: "<replies@example.com>"),
        GmailHeader(name: "Subject", value: "=?UTF-8?B?SGVsbG8s?=\r\n =?UTF-8?B?IHdvcmxk?= and =?iso-8859-1?q?caf=E9?="),
        GmailHeader(name: "Message-ID", value: " <abc@mail.example.com> "),
        GmailHeader(name: "In-Reply-To", value: "<parent@mail.example.com>"),
        GmailHeader(name: "References", value: "<root@x>\r\n <parent@mail.example.com>"),
        GmailHeader(name: "List-Unsubscribe", value: "<mailto:u@x.com>, <https://x.com/u>"),
        GmailHeader(name: "List-Unsubscribe-Post", value: "List-Unsubscribe=One-Click"),
    ], labels: ["INBOX", "UNREAD", "STARRED"], snippet: "It&#39;s here &amp; now"))
    let m = parsed.message
    #expect(m.fromName == "Müller, Hans")
    #expect(m.fromEmail == "hans@example.de")
    #expect(m.toList == [Participant(name: "Doe, John", email: "john@example.com"),
                         Participant(name: "Jane Roe", email: "jane@example.com"),
                         Participant(email: "a@x.com"), Participant(name: "B", email: "b@x.com")])
    #expect(m.ccList.isEmpty)
    #expect(m.replyTo == [Participant(email: "replies@example.com")])
    #expect(m.subject == "Hello, world and café")
    #expect(m.rfcMessageId == "<abc@mail.example.com>")
    #expect(m.inReplyTo == "<parent@mail.example.com>")
    #expect(m.refs == "<root@x> <parent@mail.example.com>")
    #expect(m.listUnsubscribe == "<mailto:u@x.com>, <https://x.com/u>")
    #expect(m.listUnsubscribePost == "List-Unsubscribe=One-Click")
    #expect(m.snippet == "It's here & now")
    #expect(m.date == Date(timeIntervalSince1970: 1_700_000_000.123))
    #expect(m.isUnread && m.isStarred && !m.isFromMe)
    #expect(m.historyId == "77")
    #expect(m.sizeEstimate == 2048)
}

@Test func fromMeBySentLabelOrAddress() {
    let sent = parse(message(leaf("text/plain", "x", partId: ""), labels: ["SENT"]))
    #expect(sent.message.isFromMe)
    let byAddress = parse(message(leaf("text/plain", "x", partId: ""),
                                  headers: [GmailHeader(name: "From", value: "Me <ME@example.com>")], labels: ["INBOX"]))
    #expect(byAddress.message.isFromMe)
}

@Test func metadataFormatHasNoBody() {
    let parsed = parse(message(leaf("text/plain", "x", partId: "")), format: .metadata)
    #expect(parsed.message.bodyState == .metadata)
    #expect(parsed.message.bodyText == nil)
    #expect(parsed.message.bodyHtml == nil)
    #expect(parsed.message.subject == "Hello")
}

@Test func addressListEdgeCases() {
    #expect(MailParsing.addresses("Sales Team, bob@example.com") == [Participant(email: "bob@example.com")])
    #expect(MailParsing.addresses("Doe, John, Jr. <john@x.com>") == [Participant(name: "Doe, John, Jr.", email: "john@x.com")])
    #expect(MailParsing.addresses("Doe, John <john@x.com>, ann@y.com") ==
            [Participant(name: "Doe, John", email: "john@x.com"), Participant(email: "ann@y.com")])
    #expect(MailParsing.addresses("\"Quote \\\"Q\\\" Person\" <q@x.com>") == [Participant(name: "Quote \"Q\" Person", email: "q@x.com")])
    #expect(MailParsing.addresses("=?UTF-8?B?5bGx55Sw?= =?UTF-8?B?5aSq6YOO?= <taro@example.jp>") ==
            [Participant(name: "山田太郎", email: "taro@example.jp")])
    #expect(MailParsing.addresses("bob@x.com (Bob (the builder) Smith)") == [Participant(name: "Bob (the builder) Smith", email: "bob@x.com")])
    #expect(MailParsing.addresses("\"bob@x.com\" <bob@x.com>") == [Participant(email: "bob@x.com")])
    #expect(MailParsing.addresses("<@relay.example:ann@example.com>") == [Participant(email: "ann@example.com")])
    #expect(MailParsing.addresses("Friends: ; , solo@x.com").map(\.email) == ["solo@x.com"])
    #expect(MailParsing.addresses("").isEmpty)
}

@Test func encodedWordsSplitAcrossMultibyteCharacters() {
    // "é" split between two adjacent words in the same charset.
    #expect(MailParsing.decodeHeader("=?UTF-8?Q?caf=C3?= =?UTF-8?Q?=A9_ok?=") == "café ok")
    #expect(MailParsing.decodeHeader("Re: =?utf-8?Q?Hello?= there") == "Re: Hello there")
    #expect(MailParsing.decodeHeader("Not =? an encoded word") == "Not =? an encoded word")
}
