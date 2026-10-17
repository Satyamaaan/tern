import Foundation
import Testing
@testable import TernCore

@Test func splitsTrailingQuoteWithAttribution() {
    let parts = PlainTextMail.split("""
        Hi Maya,

        Friday at 10 works.

        Thanks,
        Alex

        On Mon, Oct 12, 2026 at 10:42 AM Maya Chen <maya@lumen.io> wrote:
        > Can we move our 1:1?
        >
        > Maya
        """)
    #expect(parts.body == "Hi Maya,\n\nFriday at 10 works.\n\nThanks,\nAlex")
    #expect(parts.quote?.hasPrefix("On Mon, Oct 12") == true)
    #expect(parts.quote?.hasSuffix("> Maya") == true)
    #expect(parts.signature == nil)
}

@Test func joinsAttributionWrappedOverTwoLines() {
    let parts = PlainTextMail.split("""
        Yes.

        On Mon, Oct 12, 2026 at 10:42 AM Maya Chen <
        maya@lumen.io> wrote:

        > Question?
        """)
    #expect(parts.body == "Yes.")
    #expect(parts.quote?.hasPrefix("On Mon, Oct 12, 2026 at 10:42 AM Maya Chen <") == true)
}

@Test func findsSignatureAndMobileFooter() {
    let delimited = PlainTextMail.split("See attached.\n\n-- \nJonas Weber\nKiteworks")
    #expect(delimited.body == "See attached.")
    #expect(delimited.signature == "-- \nJonas Weber\nKiteworks")

    let mobile = PlainTextMail.split("On my way.\n\nSent from my iPhone")
    #expect(mobile.body == "On my way.")
    #expect(mobile.signature == "Sent from my iPhone")
}

@Test func splitsOutlookOriginalMessage() {
    let parts = PlainTextMail.split("""
        Approved.

        -----Original Message-----
        From: Maya Chen
        Sent: Monday, October 12, 2026 10:42 AM
        Subject: SOW
        """)
    #expect(parts.body == "Approved.")
    #expect(parts.quote?.hasPrefix("-----Original Message-----") == true)
}

@Test func keepsInterleavedRepliesVisible() {
    let parts = PlainTextMail.split("""
        > Can you do Friday?
        Yes, 10am.
        > And the budget?
        Approved.
        """)
    #expect(parts.quote == nil)
    #expect(parts.body.hasSuffix("Approved."))
}

@Test func keepsForwardedTextVisible() {
    let parts = PlainTextMail.split("""
        FYI

        ---------- Forwarded message ---------
        From: Ops <ops@example.com>

        > the server is down
        """)
    #expect(parts.quote == nil)
}

@Test func linkifiesAndEscapes() {
    let html = PlainTextMail.linkify("Docs: https://example.com/a?b=1&c=2, www.tern.dev or mail me@tern.dev <3")
    #expect(html.contains("<a href=\"https://example.com/a?b=1&amp;c=2\" rel=\"noreferrer noopener\">https://example.com/a?b=1&amp;c=2</a>,"))
    #expect(html.contains("href=\"http://www.tern.dev\""))
    #expect(html.contains("href=\"mailto:me@tern.dev\""))
    #expect(html.hasSuffix("&lt;3"))
}

@Test func rendersPlainTextWithFoldedQuote() {
    let mail = PlainTextMail.html("Thanks!\n\nOn Tue, Jonas wrote:\n> old <b>text</b>")
    #expect(mail.mode == .plain)
    #expect(mail.hasCollapsedQuote)
    #expect(mail.html.hasPrefix("<div class=\"tern-plain\">Thanks!<div class=\"tern-quote-toggle\""))
    #expect(mail.html.contains("<div class=\"tern-quote\" hidden>On Tue, Jonas wrote:<div class=\"tern-inline-quote\">old &lt;b&gt;text&lt;/b&gt;</div></div>"))
}
