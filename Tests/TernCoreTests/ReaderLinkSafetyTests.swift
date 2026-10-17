import Foundation
import Testing
@testable import TernCore

@Test func warnsWhenTextNamesAnotherSite() {
    #expect(LinkSafety.mismatch(text: "paypal.com", href: "https://paypa1-secure.ru/login")
            == LinkSafety.Mismatch(shown: "paypal.com", actual: "paypa1-secure.ru"))
    #expect(LinkSafety.mismatch(text: "https://www.chase.com/verify", href: "http://chase.verify-account.io/x") != nil)
    #expect(LinkSafety.mismatch(text: "bbc.co.uk", href: "https://bbc.evil.co.uk/") != nil)
}

@Test func acceptsSameSiteAndSubdomains() {
    #expect(LinkSafety.mismatch(text: "https://www.paypal.com/signin", href: "https://www.paypal.com/signin?x=1") == nil)
    #expect(LinkSafety.mismatch(text: "paypal.com", href: "https://email.paypal.com/c/123") == nil)
    #expect(LinkSafety.mismatch(text: "bbc.co.uk", href: "https://news.bbc.co.uk/1") == nil)
    #expect(LinkSafety.mismatch(text: "WWW.Example.com", href: "https://example.com") == nil)
}

@Test func ignoresTextThatIsNotAnAddress() {
    #expect(LinkSafety.mismatch(text: "Click here", href: "https://evil.example") == nil)
    #expect(LinkSafety.mismatch(text: "Read paypal.com news", href: "https://evil.example") == nil)
    #expect(LinkSafety.mismatch(text: "Next.js", href: "https://nextjs.org") == nil)
    #expect(LinkSafety.mismatch(text: "v1.2", href: "https://evil.example") == nil)
    #expect(LinkSafety.mismatch(text: "maya@lumen.io", href: "mailto:maya@lumen.io") == nil)
}

@Test func trustsMailingServiceRedirects() {
    #expect(LinkSafety.mismatch(text: "nytimes.com", href: "https://nytimes.us3.list-manage.com/track/click?u=1") == nil)
    #expect(LinkSafety.mismatch(text: "stripe.com/docs", href: "https://u123.ct.sendgrid.net/ls/click?upn=x") == nil)
}

@Test func registrableDomains() {
    #expect(LinkSafety.registrableDomain("mail.google.com") == "google.com")
    #expect(LinkSafety.registrableDomain("news.bbc.co.uk") == "bbc.co.uk")
    #expect(LinkSafety.registrableDomain("example.com") == "example.com")
    #expect(LinkSafety.displayHost("https://Docs.Example.com/a") == "docs.example.com")
    #expect(LinkSafety.displayHost("mailto:x@y.z") == nil)
}
