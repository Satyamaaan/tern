import Foundation
import Testing
@testable import TernCore

struct LoginAssistanceTests {
    @Test(arguments: [
        ("Your verification code is 012345.", "012345"),
        ("Sign-in code: 1234", "1234"),
        ("Security code: 12345678", "12345678"),
        ("Your one-time code is 012-345", "012345"),
        ("Your one-time code is 01-23-45", "012345"),
        ("OTP: 0 1 2 3 4 5", "012345"),
        ("🔐 Your login code: 012 345", "012345"),
        ("Verification code: 012\u{202f}345", "012345"),
        ("Verification code: 012\u{00a0}345", "012345"),
    ])
    func codes(_ value: (String, String)) {
        #expect(LoginAssistance.extract(subject: "", text: value.0) == [.code(value.1)])
    }

    @Test(arguments: [
        "Invoice 123456. Visit our login page.",
        "Order code 123456", "Discount code 123456", "Tracking number 12345678",
        "Phone: +1 555-123-4567. Your login code is arriving soon.",
        "Your login code costs $1234.50", "Security code for order 123456",
        "Verification code: 123456789", "Login code: abc123", "Year 2026: login code help",
        "Verification code: １２３４５６", "Verification code: ١٢٣٤٥٦",
        "Login code: 123456 or 654321", "> Your login code: 123456",
        "On Tuesday, A wrote:\nLogin code: 123456",
        "Thanks\n\n-----Original Message-----\nLogin code: 123456",
        "Total: 123456\n" + String(repeating: "ordinary invoice detail. ", count: 20) + "Login code help",
    ])
    func rejectsCodes(_ text: String) {
        #expect(LoginAssistance.extract(subject: "Login code", text: text).isEmpty)
    }

    @Test func htmlAndAmbiguity() {
        #expect(LoginAssistance.extract(subject: "", text: "", html: "<p>Verification code: <b>012&#51;&nbsp;456</b></p>") == [.code("0123456")])
        #expect(LoginAssistance.extract(subject: "Login code: 123456", text: "", html: "<p>Login code: 654321</p>").isEmpty)
        #expect(LoginAssistance.extract(subject: "", text: "Login code: 123456", html: "<p>Login code: 654321</p>").isEmpty)
        #expect(LoginAssistance.extract(subject: "Login code: 123456", text: "Login code: 654321", html: "<p>Login code: 111111</p>").isEmpty)
        #expect(LoginAssistance.extract(subject: "Login code: 012345", text: "Login code: 012345") == [.code("012345")])
    }

    @Test(arguments: [
        "<script>Login code: 123456</script>",
        "<div hidden>Login code: 123456</div>",
        "<div style='display: none'>Login code: 123456</div>",
        "<div style='visibility:hidden'>Login code: 123456</div>",
        "<div aria-hidden='true'>Login code: 123456</div>",
        "<blockquote>Login code: 123456</blockquote>",
        "<div class='gmail_quote'>Login code: 123456</div>",
        "<style>.x {display:none}</style><div class='x'>Login code: 123456</div>",
        "<body hidden><p>Login code: 123456</p></body>",
        "<div id='divRplyFwdMsg'>Earlier message</div><p>Login code: 123456</p>",
    ])
    func hiddenHTML(_ html: String) {
        #expect(LoginAssistance.extract(subject: "", text: "", html: html).isEmpty)
    }

    @Test func linksAndOrdering() throws {
        let url = try #require(URL(string: "https://accounts.acme.com/login?token=abcdef123456&mode=email"))
        #expect(LoginAssistance.extract(subject: "Login code: 012345", text: "Sign in: https://accounts.acme.com/login?token=abcdef123456&mode=email") == [.code("012345"), .magicLink(url)])
        #expect(LoginAssistance.extract(subject: "", text: "", html: "<a href='https://accounts.acme.com/login?token=abcdef123456&amp;mode=email'>Sign <b>in</b></a>") == [.magicLink(url)])
        #expect(LoginAssistance.extract(subject: "", text: "Sign in: https://accounts.acme.com/login?token=abcdef123456&mode=email\nSign in: https://accounts.acme.com/login?token=other123456").isEmpty)
    }

    @Test(arguments: [
        "http://acme.com/login?token=abcdef123", "tern://login?token=abcdef123",
        "https://user:password@acme.com/login?token=abcdef123",
        "https://localhost/login?token=abcdef123", "https://192.168.1.1/login?token=abcdef123",
        "https://[::1]/login?token=abcdef123", "https://3232235777/login?token=abcdef123",
        "https://host.local/login?token=abcdef123", "https://acme.com:8080/login?token=abcdef123",
        "https://acme.com/reset-password?token=abcdef123", "https://acme.com/unsubscribe?token=abcdef123",
        "https://acme.com/click?token=abcdef123", "https://acme.com/login",
        "https://acme.com/login?token=abcdef123&url=https://evil.com",
    ])
    func rejectsLinks(_ raw: String) {
        #expect(LoginAssistance.extract(subject: "", text: "Sign in: " + raw).isEmpty)
        #expect(LoginAssistance.extract(subject: "", text: "", html: "<a href='\(raw)'>Sign in</a>").isEmpty)
    }

    @Test func hiddenLinksAndMissingContext() {
        let anchor = "<a href='https://acme.com/login?token=abcdef123'>Sign in</a>"
        #expect(LoginAssistance.extract(subject: "", text: "", html: "<div hidden>\(anchor)</div>").isEmpty)
        #expect(LoginAssistance.extract(subject: "", text: "", html: "<blockquote>\(anchor)</blockquote>").isEmpty)
        #expect(LoginAssistance.extract(subject: "", text: "https://acme.com/login?token=abcdef123").isEmpty)
    }

    @Test(arguments: [(0.0, true), (1200.0, true), (1200.001, false), (-60.0, true), (-60.001, false)])
    func freshness(_ value: (Double, Bool)) {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(LoginAssistance.isFresh(date: now.addingTimeInterval(-value.0), now: now) == value.1)
    }
}
