import Foundation
import Testing
@testable import TernCore

private func clean(_ html: String, images: Bool = false) -> SanitizedMail {
    MailSanitizer.sanitize(html: html, options: .init(allowRemoteImages: images) { cid in "tern-cid://m/a/m/\(cid)" })
}

@Test func dropsActiveContent() {
    let mail = clean("""
        <p onclick="steal()" onmouseover=x>Hi</p><script>alert(1)</script><iframe src="https://evil.example"></iframe>
        <object data="x.swf"></object><embed src="x.swf"><applet code=x></applet>
        <form action="https://evil.example/login"><input name=pw type=password><button>Go</button><select><option>a</select></form>
        <meta http-equiv="refresh" content="0;url=https://evil.example"><base href="https://evil.example/">
        <svg><script>alert(2)</script><image href="https://evil.example/x"/></svg><math><mi>x</mi></math>
        <noscript><img src=x onerror=alert(3)></noscript><title><img src=x onerror=alert(4)></title>
        <template><img src=x onerror=alert(5)></template><link rel=stylesheet href="https://evil.example/s.css">
        """)
    #expect(mail.html.contains("<p>Hi</p>"))
    #expect(mail.html.contains("Go"))
    for banned in ["script", "alert", "iframe", "object", "embed", "applet", "<form", "<input", "<button", "select",
                   "meta", "base", "svg", "math", "noscript", "onerror", "onclick", "onmouseover", "template", "<link",
                   "evil.example"] {
        #expect(!mail.html.lowercased().contains(banned), "found \(banned) in \(mail.html)")
    }
}

@Test func onlySafeLinkSchemesSurvive() {
    let mail = clean("""
        <a href="javascript:alert(1)">a</a><a href="JaVa&#x09;ScRipt:alert(1)">b</a><a href=" java
        script:alert(1)">c</a><a href="vbscript:x">d</a><a href="data:text/html,<script>alert(1)</script>">e</a>
        <a href="file:///etc/passwd">f</a><a href="https://ok.example/a?b=1&amp;c=2" target="_blank">ok</a>
        <a href="mailto:maya@lumen.io">mail</a><a href="//cdn.example/x">proto</a><a href="relative/path">rel</a>
        """)
    #expect(!mail.html.lowercased().contains("script:"))
    #expect(!mail.html.contains("data:text"))
    #expect(!mail.html.contains("file:"))
    #expect(mail.html.contains("href=\"https://ok.example/a?b=1&amp;c=2\""))
    #expect(mail.html.contains("href=\"mailto:maya@lumen.io\""))
    #expect(mail.html.contains("href=\"https://cdn.example/x\""))
    #expect(!mail.html.contains("relative/path"))
    #expect(!mail.html.contains("target="))
    #expect(mail.html.components(separatedBy: "rel=\"noreferrer noopener\"").count == 11)
}

@Test func blocksRemoteImagesAndTrackers() {
    let html = """
        <img src="https://cdn.example/hero.png" width="600" height="300" alt="Hero">
        <img src="https://t.example/open.gif" width="1" height="1">
        <img src="https://mailtrack.io/trace/x.png" width="20" height="20">
        <img src="data:image/png;base64,iVBORw0KGgo=" alt="dot"><img src="data:text/html;base64,PHNjcmlwdD4=">
        <img src="cid:logo@acme" alt="Logo"><img src="cid:&lt;banner@acme&gt;">
        <table background="https://cdn.example/bg.png"><tr><td>x</td></tr></table>
        """
    let blocked = clean(html)
    #expect(blocked.blockedRemoteCount == 2)
    #expect(blocked.html.contains("data-tern-blocked"))
    #expect(blocked.html.contains("width=\"600\" height=\"300\""))
    #expect(!blocked.html.contains("cdn.example"))
    #expect(!blocked.html.contains("open.gif"))
    #expect(!blocked.html.contains("mailtrack"))
    #expect(blocked.html.contains("src=\"data:image/png;base64,iVBORw0KGgo=\""))
    #expect(!blocked.html.contains("data:text"))
    #expect(blocked.html.contains("src=\"tern-cid://m/a/m/logo@acme\""))
    #expect(blocked.html.contains("src=\"tern-cid://m/a/m/banner@acme\""))

    let allowed = clean(html, images: true)
    #expect(allowed.blockedRemoteCount == 0)
    #expect(allowed.html.contains("src=\"https://cdn.example/hero.png\" referrerpolicy=\"no-referrer\""))
    #expect(!allowed.html.contains("open.gif"), "tracking pixels never load")
    #expect(!allowed.html.contains("mailtrack"))
}

@Test func cleansStylesAndStyleSheets() {
    let mail = clean("""
        <style>@import url("https://evil.example/x.css"); @charset "utf-8";
        body { color: #222222; margin: 0 } html, :root { font-size: 16px } .hero { background: url(https://cdn.example/bg.png) #fff }
        @media (prefers-color-scheme: dark) { body { background: #000 } }
        @media screen and (max-width: 600px) { .col { width: 100% !important } }
        @font-face { font-family: X; src: url(https://fonts.example/x.woff2) }
        .bad { width: expression(alert(1)); behavior: url(x.htc); -moz-binding: url(x) }</style>
        <div style="color:red; background:url(javascript:alert(1)); position:fixed; top:0; behavior:url(x.htc); width: e\\78pression(1)">x</div>
        """)
    #expect(!mail.css.contains("@import"))
    #expect(!mail.css.contains("evil.example"))
    #expect(!mail.css.contains("fonts.example"))
    #expect(!mail.css.contains("expression"))
    #expect(!mail.css.contains("behavior"))
    #expect(!mail.css.contains("binding"))
    #expect(!mail.css.contains("prefers-color-scheme"))
    #expect(mail.css.contains(".tern-body { color: light-dark(#222222, "))
    #expect(mail.css.contains(":host, :host { font-size: 16px }"))
    #expect(mail.css.contains("@media screen and (max-width: 600px) {.col { width: 100% !important }"))
    #expect(mail.css.contains("background: none #fff"))
    #expect(mail.blockedRemoteCount == 1)
    #expect(mail.html.contains("style=\"color: red; top: 0\""))
}

@Test func classifiesSimpleAndRichMail() {
    let simple = clean("""
        <div dir="ltr"><div style="color:rgb(34,34,34);font-family:Arial">Hi Alex,</div>
        <div><font color="#000000">Thanks</font></div><div style="background-color:#ffffff">ok</div></div>
        """)
    #expect(simple.mode == .simple)
    #expect(simple.html.contains("color: light-dark(rgb(34,34,34), "))
    #expect(simple.html.contains("background-color: light-dark(#ffffff, transparent)"))

    let rich = clean("""
        <table width="100%" bgcolor="#f4f1ec"><tr><td><table width="600" style="background:#ffffff">
        <tr><td style="color:#ffffff;background-color:#1c1b19">Read more</td></tr></table></td></tr></table>
        """)
    #expect(rich.mode == .rich)
    #expect(rich.html.contains("bgcolor=\"#f4f1ec\""))
}

@Test func keepsTreeShapeForMessyMarkup() {
    let mail = clean("<div><p>one<p>two</div><table><tr><td>a<td>b<tr><td>c</table><ul><li>x<li>y</ul>a < b")
    #expect(mail.html == "<div><p>one</p><p>two</p></div><table><tr><td>a</td><td>b</td></tr><tr><td>c</td></tr></table><ul><li>x</li><li>y</li></ul>a &lt; b")
}

@Test func escapesAttributeValues() {
    let mail = clean(#"<img alt='"><script>alert(1)</script>' src="data:image/gif;base64,R0lG"><p title="a&quot;b">x</p>"#)
    #expect(!mail.html.contains("<script"))
    #expect(mail.html.contains("alt=\"&quot;&gt;&lt;script&gt;alert(1)&lt;/script&gt;\""))
    #expect(mail.html.contains("title=\"a&quot;b\""))
}

@Test func dropsCommentsAndConditionalBlocks() {
    let mail = clean("<p>a</p><!--[if mso]><table><tr><td>MSO only</td></tr></table><![endif]--><!--<script>x</script>--><p>b</p>")
    #expect(mail.html == "<p>a</p><p>b</p>")
}

@Test func unwrapsUnknownElements() {
    let mail = clean("<p class=MsoNormal>Hello<o:p></o:p></p><custom-tag>inside</custom-tag><center>c</center>")
    #expect(mail.html == "<p class=\"MsoNormal\">Hello</p>inside<center>c</center>")
}

@Test func movesBodyAttributesToTheWrapper() {
    let mail = clean(##"<html><head><style>p{margin:0}</style></head><body bgcolor="#ffffff" text="#333333" style="margin:0"><p>x</p></body></html>"##)
    #expect(mail.bodyStyle.contains("background-color: light-dark(#ffffff, transparent)"))
    #expect(mail.bodyStyle.contains("color: light-dark(#333333, "))
    #expect(mail.bodyStyle.contains("margin: 0"))
    #expect(mail.css.contains("p { margin: 0 }"))
    #expect(mail.html == "<p>x</p>")
}

@Test func removesReservedClassNames() {
    let mail = clean(#"<div class="tern-quote-toggle keep">fake</div>"#)
    #expect(mail.html == "<div class=\"keep\">fake</div>")
}

@Test func contentIdURLRoundTrips() throws {
    let string = MailSanitizer.contentIdURL(accountId: "alex@kiteworks.dev", messageId: "18c2/x", contentId: "image001.png@01DA")
    let url = try #require(URL(string: string))
    let parts = try #require(MailSanitizer.parseContentIdURL(url))
    #expect(parts.accountId == "alex@kiteworks.dev")
    #expect(parts.messageId == "18c2/x")
    #expect(parts.contentId == "image001.png@01DA")
}

@Test func darkVariantsAreReadableOnDark() throws {
    for hex in ["#000000", "#222222", "#1155cc", "#cc0000", "#5f6368"] {
        let color = try #require(CSSColor(hex))
        #expect(color.darkModeVariant.luminance > 0.3, "\(hex) → \(color.darkModeVariant.hexString)")
    }
}

@Test func sanitizesLargeNewslettersQuickly() {
    var html = "<html><body><table width=\"600\">"
    for index in 0..<2_000 {
        html += "<tr><td style=\"padding:8px;color:#333\"><a href=\"https://example.com/\(index)\">Item \(index)</a> <img src=\"https://cdn.example/\(index).png\" width=\"40\" height=\"40\"></td></tr>"
    }
    html += "</table></body></html>"
    let start = Date()
    let mail = clean(html)
    let elapsed = Date().timeIntervalSince(start)
    #expect(mail.blockedRemoteCount == 2_000)
    #expect(elapsed < 1.5, "took \(elapsed) s for \(html.utf8.count) bytes")
}
