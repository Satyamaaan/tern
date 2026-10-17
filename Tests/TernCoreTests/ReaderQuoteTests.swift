import Foundation
import Testing
@testable import TernCore

private func fold(_ html: String) -> SanitizedMail { MailSanitizer.sanitize(html: html) }

private func visible(_ mail: SanitizedMail) -> String {
    guard let range = mail.html.range(of: "<div class=\"tern-quote\" hidden>") else { return mail.html }
    return String(mail.html[..<range.lowerBound])
}

@Test func foldsGmailQuoteWithItsAttribution() {
    let mail = fold("""
        <div dir="ltr">Sounds good, Friday works.</div><br><div class="gmail_quote"><div dir="ltr" class="gmail_attr">On Mon, Oct 12, 2026 at 10:42 AM Maya Chen &lt;maya@lumen.io&gt; wrote:<br></div>
        <blockquote class="gmail_quote" style="margin:0 0 0 .8ex;border-left:1px #ccc solid;padding-left:1ex">Can we move our 1:1?</blockquote></div>
        """)
    #expect(mail.hasCollapsedQuote)
    #expect(visible(mail).contains("Sounds good"))
    #expect(!visible(mail).contains("Can we move"))
    #expect(mail.html.contains("<div class=\"tern-quote-toggle\""))
}

@Test func foldsAttributionLineBeforeABlockquote() {
    let mail = fold("""
        <div>Thanks!</div><div>On Oct 3, 2026 at 10:42 AM, Maya Chen wrote:</div><blockquote class="gmail_quote">Old text</blockquote>
        """)
    #expect(visible(mail) == "<div>Thanks!</div><div class=\"tern-quote-toggle\" role=\"button\" tabindex=\"0\" aria-label=\"Show quoted text\">•••</div>")
}

@Test func foldsAppleMailCite() {
    let mail = fold(#"<div>Yes.</div><div><br><blockquote type="cite"><div>On Oct 3, Maya wrote:</div><div>Question?</div></blockquote></div>"#)
    #expect(mail.hasCollapsedQuote)
    #expect(!visible(mail).contains("Question?"))
}

@Test func foldsOutlookReplyToTheEnd() {
    let mail = fold("""
        <div class="WordSection1"><p class="MsoNormal">Approved.</p><div id="appendonsend"></div>
        <hr style="display:inline-block;width:98%" tabindex="-1"><div id="divRplyFwdMsg" dir="ltr"><b>From:</b> Maya Chen<br><b>Sent:</b> Monday</div>
        <div><p>Original request</p></div><p>More old text</p></div>
        """)
    #expect(mail.hasCollapsedQuote)
    #expect(visible(mail).contains("Approved."))
    #expect(!visible(mail).contains("<hr"))
    #expect(!visible(mail).contains("Original request"))
    #expect(!visible(mail).contains("More old text"))
}

@Test func foldsOutlookDesktopHeaderBlock() {
    let mail = fold("""
        <div class="WordSection1"><p class="MsoNormal">See below.</p>
        <div><div style="border:none;border-top:solid #E1E1E1 1.0pt;padding:3.0pt 0in 0in 0in"><p class="MsoNormal"><b>From:</b> Jonas</p></div></div>
        <p class="MsoNormal">Earlier message</p></div>
        """)
    #expect(mail.hasCollapsedQuote)
    #expect(!visible(mail).contains("Earlier message"))
    #expect(visible(mail).contains("See below."))
}

@Test func leavesForwardsOpen() {
    let mail = fold("""
        <div>FYI</div><div class="gmail_quote"><div class="gmail_attr">---------- Forwarded message ---------<br>From: Ops</div><div>Server is down</div></div>
        """)
    #expect(!mail.hasCollapsedQuote)
    #expect(mail.html.contains("Server is down"))
}

@Test func leavesQuoteOnlyMailOpen() {
    let mail = fold(#"<blockquote type="cite">Only quoted text here</blockquote>"#)
    #expect(!mail.hasCollapsedQuote)
    #expect(!mail.html.contains("hidden"))
}

@Test func foldsOnlyTheOutermostOfNestedQuotes() {
    let mail = fold("""
        <div>Latest</div><div class="gmail_quote">older<div class="gmail_quote">oldest</div></div>
        """)
    #expect(mail.html.components(separatedBy: "tern-quote-toggle").count == 2)
}
