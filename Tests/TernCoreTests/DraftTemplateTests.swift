import Foundation
import Testing
@testable import TernCore

private let utc = TimeZone(identifier: "UTC")!

private func message(
    from: Participant, to: [Participant], cc: [Participant] = [], replyTo: [Participant] = [],
    fromMe: Bool = false, subject: String = "Plan", html: String? = nil, text: String? = "Hello"
) -> MailMessage {
    MailMessage(
        accountId: "me@example.com", id: "m1", threadId: "t1", date: Date(timeIntervalSince1970: 1_791_841_260),
        fromName: from.name, fromEmail: from.email, toList: to, ccList: cc, replyTo: replyTo, subject: subject,
        bodyText: text, bodyHtml: html, bodyState: .full, isFromMe: fromMe)
}

private let me = Participant(name: "Alex Morgan", email: "me@example.com")
private let maya = Participant(name: "Maya Chen", email: "maya@lumen.io")
private let jonas = Participant(name: "Jonas", email: "jonas@lumen.io")
private let sam = Participant(name: "Sam", email: "sam@kite.dev")
private let own: Set<String> = ["me@example.com", "me@work.dev"]

@Test func replySubjectsGetOneRe() {
    #expect(DraftTemplate.replySubject("Plan") == "Re: Plan")
    #expect(DraftTemplate.replySubject("Re: Plan") == "Re: Plan")
    #expect(DraftTemplate.replySubject("RE: re: Aw: Plan") == "Re: Plan")
    #expect(DraftTemplate.replySubject("Re[2]: Plan") == "Re: Plan")
    #expect(DraftTemplate.replySubject("  AW：Plan") == "Re: Plan")
    #expect(DraftTemplate.replySubject("Fwd: Plan") == "Re: Fwd: Plan")
    #expect(DraftTemplate.replySubject("Referral bonus") == "Re: Referral bonus")
    #expect(DraftTemplate.replySubject("") == "Re:")
}

@Test func forwardSubjectsGetOneFwd() {
    #expect(DraftTemplate.forwardSubject("Plan") == "Fwd: Plan")
    #expect(DraftTemplate.forwardSubject("FW: Fwd: Plan") == "Fwd: Plan")
    #expect(DraftTemplate.forwardSubject("Re: Plan") == "Fwd: Re: Plan")
    #expect(DraftTemplate.forwardSubject("Trip notes") == "Fwd: Trip notes")
}

@Test func replyGoesToReplyToOrSender() {
    let plain = message(from: maya, to: [me])
    #expect(DraftTemplate.replyRecipients(to: plain, all: false, ownAddresses: own).to == [maya])
    let list = Participant(name: "Team", email: "team@lumen.io")
    let withReplyTo = message(from: maya, to: [me], replyTo: [list])
    #expect(DraftTemplate.replyRecipients(to: withReplyTo, all: false, ownAddresses: own).to == [list])
}

@Test func replyAllDropsOwnAddressesAndDuplicates() {
    let original = message(
        from: maya, to: [me, jonas, Participant(email: "ME@work.dev")],
        cc: [Participant(email: "MAYA@lumen.io"), sam, Participant(name: "Sam K", email: "Sam@Kite.dev")])
    let result = DraftTemplate.replyRecipients(to: original, all: true, ownAddresses: own)
    #expect(result.to == [maya, jonas])
    #expect(result.cc == [sam])
}

@Test func replyToOwnMessageContinuesToItsRecipients() {
    let mine = message(from: me, to: [maya], cc: [jonas], fromMe: true)
    #expect(DraftTemplate.replyRecipients(to: mine, all: false, ownAddresses: own) == ([maya], []))
    let all = DraftTemplate.replyRecipients(to: mine, all: true, ownAddresses: own)
    #expect(all.to == [maya])
    #expect(all.cc == [jonas])
}

@Test func quoteUsesGmailAttributionAndKeepsHTML() {
    let original = message(from: maya, to: [me], html: "<html><head><style>p{}</style></head><body><p>Hi <b>Alex</b></p></body></html>")
    #expect(DraftTemplate.attribution(for: original, timeZone: utc) == "On Mon, Oct 12, 2026 at 9:41 PM, Maya Chen <maya@lumen.io> wrote:")
    let html = DraftTemplate.quoteHTML(for: original, timeZone: utc)
    #expect(html.hasPrefix(#"<div class="gmail_quote"><div dir="ltr" class="gmail_attr">On Mon, Oct 12, 2026 at 9:41 PM, Maya Chen &lt;<a href="mailto:maya@lumen.io">maya@lumen.io</a>&gt; wrote:<br></div><blockquote class="gmail_quote""#))
    #expect(html.contains("<p>Hi <b>Alex</b></p></blockquote></div>"))
    #expect(!html.contains("<style>"))
}

@Test func plainTextQuoteIsEscaped() {
    let original = message(from: Participant(email: "x@y.co"), to: [me], text: "a < b & c\nnext")
    let html = DraftTemplate.quoteHTML(for: original, timeZone: utc)
    #expect(html.contains("&lt;<a href=\"mailto:x@y.co\">x@y.co</a>&gt; wrote:"))
    #expect(html.contains("<div dir=\"ltr\">a &lt; b &amp; c<br>next</div>"))
}

@Test func forwardHeaderListsTheOriginal() {
    let original = message(from: maya, to: [me], cc: [jonas], subject: "Q4 <plan>", html: "<div>Numbers</div>")
    let html = DraftTemplate.forwardHTML(for: original, timeZone: utc)
    #expect(html.contains("---------- Forwarded message ---------<br>From: <strong class=\"gmail_sendername\" dir=\"auto\">Maya Chen</strong>"))
    #expect(html.contains("Subject: Q4 &lt;plan&gt;<br>"))
    #expect(html.contains("Cc: Jonas &lt;<a href=\"mailto:jonas@lumen.io\">jonas@lumen.io</a>&gt;<br>"))
    #expect(html.hasSuffix("<br><br><div>Numbers</div></div>"))
}
