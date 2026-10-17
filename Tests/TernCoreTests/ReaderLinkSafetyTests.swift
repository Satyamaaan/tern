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

@Test func followsRedirectorsToTheRealDestination() {
    // Google's /url, Outlook Safe Links and Proofpoint are judged by where they lead.
    #expect(LinkSafety.mismatch(text: "paypal.com", href: "https://www.google.com/url?q=https://paypa1.ru/x&sa=D")?.actual == "paypa1.ru")
    #expect(LinkSafety.mismatch(text: "youtube.com", href: "https://www.google.com/url?q=https%3A%2F%2Fwww.youtube.com%2Fwatch") == nil)
    let safelinks = "https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Fevil.example%2Flogin&data=05%7C01"
    #expect(LinkSafety.mismatch(text: "chase.com", href: safelinks)?.actual == "evil.example")
    #expect(LinkSafety.mismatch(text: "evil.example", href: safelinks) == nil)
    let proofpoint2 = "https://urldefense.proofpoint.com/v2/url?u=https-3A__login.my-2Dbank.example_signin&d=DwMF&c=x"
    #expect(LinkSafety.mismatch(text: "mybank.com", href: proofpoint2)?.actual == "login.my-bank.example")
    #expect(LinkSafety.mismatch(text: "my-bank.example", href: proofpoint2) == nil)
    let proofpoint3 = "https://urldefense.com/v3/__https://phish.example/a*20b__;JQ!!abc$"
    #expect(LinkSafety.mismatch(text: "microsoft.com", href: proofpoint3)?.actual == "phish.example")
    #expect(LinkSafety.mismatch(text: "linkedin.com", href: "https://www.linkedin.com/redir/redirect?url=https%3A%2F%2Fevil.example") != nil)
    #expect(LinkSafety.mismatch(text: "apple.com", href: "https://protect-us.mimecast.com/s/AbC?domain=apple.com") == nil)
    #expect(LinkSafety.mismatch(text: "apple.com", href: "https://protect-us.mimecast.com/s/AbC?domain=evil.example") != nil)
    // Wrappers inside wrappers.
    let nested = "https://nam12.safelinks.protection.outlook.com/?url=" +
        "https%3A%2F%2Fwww.google.com%2Furl%3Fq%3Dhttps%253A%252F%252Fevil.example"
    #expect(LinkSafety.mismatch(text: "paypal.com", href: nested)?.actual == "evil.example")
    #expect(LinkSafety.destination(of: URL(string: nested)!).host == "evil.example")
}

@Test func userContentHostsAreNotTrustedWholesale() {
    #expect(LinkSafety.mismatch(text: "paypal.com", href: "https://sites.google.com/view/paypal-verify") != nil)
    #expect(LinkSafety.mismatch(text: "paypal.com", href: "https://medium.com/@attacker/verify") != nil)
    #expect(LinkSafety.mismatch(text: "paypal.com", href: "https://attacker.substack.com/p/verify") != nil)
    #expect(LinkSafety.mismatch(text: "paypal.com", href: "https://www.google.com/url") != nil, "a wrapper without its destination is where it goes")
    // Opaque mailing-service trackers still pass.
    #expect(LinkSafety.mismatch(text: "nytimes.com", href: "https://email.mg2.substack.com/c/eJx") == nil)
    #expect(LinkSafety.mismatch(text: "stripe.com", href: "https://substack.com/redirect/2/garbage") == nil)
    let payload = Data(#"{"e":"https://evil.example/x"}"#.utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
    #expect(LinkSafety.mismatch(text: "stripe.com", href: "https://substack.com/redirect/2/\(payload).sig")?.actual == "evil.example")
}
