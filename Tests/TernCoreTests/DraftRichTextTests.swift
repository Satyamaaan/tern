import Foundation
import Testing
@testable import TernCore

private typealias Block = RichText.Block
private typealias Run = RichText.Run

@Test func richTextSerializesCleanHTML() {
    let text = RichText([
        Block(.paragraph, [Run("Hi "), Run("Maya", style: .bold), Run(",")]),
        Block(.paragraph),
        Block(.bullet, [Run("one")]),
        Block(.bullet, [Run("two", style: [.italic, .underline])]),
        Block(.numbered, [Run("see "), Run("the doc", link: "https://x.dev/a?b=1&c=2")]),
        Block(.quote, [Run("quoted < text")]),
        Block(.paragraph, [Run("line\u{2028}break  twice")]),
    ])
    #expect(text.html == """
        <div>Hi <strong>Maya</strong>,</div><div><br></div>\
        <ul><li>one</li><li><em><u>two</u></em></li></ul>\
        <ol><li>see <a href="https://x.dev/a?b=1&amp;c=2">the doc</a></li></ol>\
        <blockquote style="margin:0 0 0 0.8ex;border-left:1px solid #ccc;padding-left:1ex"><div>quoted &lt; text</div></blockquote>\
        <div>line<br>break &nbsp;twice</div>
        """)
}

@Test func richTextRoundTripsThroughHTML() {
    let text = RichText([
        Block(.paragraph, [Run("Hello "), Run("bold italic", style: [.bold, .italic]), Run(" end")]),
        Block(.paragraph),
        Block(.paragraph, [Run(" leading and  double spaces")]),
        Block(.bullet, [Run("a")]),
        Block(.bullet, []),
        Block(.numbered, [Run("b", link: "mailto:b@c.de")]),
        Block(.quote, [Run("q1")]),
        Block(.quote, []),
        Block(.paragraph, [Run("trailing break\u{2028}")]),
    ])
    #expect(RichText(html: text.html) == text)
}

@Test func htmlParserReadsForeignMarkup() {
    let html = """
        <!DOCTYPE html><html><head><title>x</title><style>.a{color:red}</style></head>
        <body><!-- note --><p class="MsoNormal">Hi&nbsp;there &amp; <span style="font-weight:700">you</span></p>
        <h2>Agenda</h2>
        <ul>
          <li><div>First</div></li>
          <li>Second <i>item</i></li>
        </ul>
        <table><tr><td>Cell A</td><td>Cell B</td></tr></table>
        <script>alert(1)</script>
        <p>Line one<br>Line two<br></p><div><br></div><blockquote>Quoted</blockquote>
        <a href="javascript:evil()">bad</a> <a href=https://ok.dev>ok</a> &#8212; &#x1F600;
        </body></html>
        """
    let text = RichText(html: html)
    #expect(text.blocks == [
        Block(.paragraph, [Run("Hi there & "), Run("you", style: .bold)]),
        Block(.paragraph, [Run("Agenda", style: .bold)]),
        Block(.bullet, [Run("First")]),
        Block(.bullet, [Run("Second "), Run("item", style: .italic)]),
        Block(.paragraph, [Run("Cell A Cell B")]),
        Block(.paragraph, [Run("Line one\u{2028}Line two")]),
        Block(.paragraph),
        Block(.quote, [Run("Quoted")]),
        Block(.paragraph, [Run("bad "), Run("ok", link: "https://ok.dev"), Run(" — 😀")]),
    ])
}

@Test func plainTextConvertsBothWays() {
    let text = RichText(plainText: "Hi Maya,\n\n- first\n* second\n1. one\n> quoted\nSee **this** at https://x.dev/doc.")
    #expect(text.blocks.map(\.kind) == [.paragraph, .paragraph, .bullet, .bullet, .numbered, .quote, .paragraph])
    #expect(text.blocks[6].runs == [Run("See "), Run("this", style: .bold), Run(" at "), Run("https://x.dev/doc", link: "https://x.dev/doc"), Run(".")])
    #expect(text.plainText == "Hi Maya,\n\n• first\n• second\n1. one\n> quoted\nSee this at https://x.dev/doc.")
    #expect(RichText(plainText: "  \n").isEmpty)
    #expect(!text.isEmpty)
}

@Test func draftContentSplitsBodySignatureAndQuote() {
    let draft = Draft(accountId: "me@example.com", kind: .reply)
    let quote = #"<div class="gmail_quote"><div dir="ltr" class="gmail_attr">On …, Maya wrote:<br></div><blockquote class="gmail_quote">x</blockquote></div>"#
    let content = DraftContent(
        draft: draft, body: RichText([Block(.paragraph, [Run("Thanks!")])]),
        signatureHtml: "<b>Alex</b><br>Northwind", quoteHtml: quote)
    #expect(content.draft.bodyHtml == #"<div>Thanks!</div><br><div class="gmail_signature" data-smartmail="gmail_signature"><b>Alex</b><br>Northwind</div><br>"# + quote)
    let reopened = DraftContent(stored: content.draft)
    #expect(reopened.body == content.body)
    #expect(reopened.signatureHtml == content.signatureHtml)
    #expect(reopened.quoteHtml == quote)

    var noSignature = content
    noSignature.signatureHtml = nil
    let again = DraftContent(stored: noSignature.assembledDraft())
    #expect(again.signatureHtml == nil)
    #expect(again.quoteHtml == quote)
    #expect(again.body.plainText == "Thanks!")
}

@Test func draftContentReadsGmailWrittenDrafts() {
    var draft = Draft(accountId: "me@example.com")
    draft.bodyHtml = #"<div dir="ltr">Hello<div><br></div><div><br clear="all"></div><br><span class="gmail_signature_prefix">-- </span><br><div dir="ltr" class="gmail_signature" data-smartmail="gmail_signature">Alex</div></div><br><div class="gmail_quote gmail_quote_container"><blockquote>old</blockquote></div>"#
    let content = DraftContent(stored: draft)
    #expect(content.signatureHtml == "Alex")
    #expect(content.quoteHtml?.hasPrefix(#"<div class="gmail_quote gmail_quote_container">"#) == true)
    #expect(content.body.plainText.hasPrefix("Hello"))
}

@Test func importedLinksKeepOnlyWebMailAndPhoneSchemes() {
    let text = RichText(html: """
        <p><a href="java&#10;script:alert(1)">a</a> <a href="JAVASCRIPT:x">b</a> <a href="data:text/html,x">c</a> \
        <a href="file:///etc/passwd">d</a> <a href="/relative">e</a> <a href=" https://ok.dev ">f</a> \
        <a href="mailto:maya@lumen.io">g</a> <a href="tel:+14155550142">h</a></p>
        """)
    let links = text.blocks.flatMap(\.runs).compactMap(\.link)
    #expect(links == ["https://ok.dev", "mailto:maya@lumen.io", "tel:+14155550142"])
    #expect(text.plainText == "a b c d e f g h")
}

@Test func modelWrittenLinksShowWhereTheyGo() {
    let draft = RichText(html: """
        <p>Thanks, <a href="https://evil.example/collect?d=secret">see you then</a>.</p>
        <p>Log in at <a href="https://evil.example/login">paypal.com</a> or <a href="https://docs.google.com/d/1">docs.google.com/d/1</a>.</p>
        <p>Mail <a href="mailto:x@evil.example">Maya</a>, read <a href="https://www.google.com/url?q=https://evil.example/y">this</a>, \
        call <a href="tel:+1555">me</a>.</p>
        """).revealingLinks()
    #expect(draft.plainText == """
        Thanks, see you then (evil.example).
        Log in at evil.example or docs.google.com/d/1.
        Mail Maya (x@evil.example), read this (evil.example), call me.
        """)
    let runs = draft.blocks.flatMap(\.runs)
    #expect(runs.first { $0.text == "evil.example" }?.link == "https://evil.example/login", "the text now names the real host")
    #expect(runs.first { $0.text == "docs.google.com/d/1" }?.link == "https://docs.google.com/d/1")
    #expect(!runs.contains { $0.link?.hasPrefix("tel:") == true }, "a model never adds a phone link")

    let plain = RichText(plainText: "Agenda is at https://lumen.io/agenda, see you Thursday.").revealingLinks()
    #expect(plain == RichText(plainText: "Agenda is at https://lumen.io/agenda, see you Thursday."), "bare URLs already show themselves")
}
