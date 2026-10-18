import Foundation
import Testing
@testable import TernCore

// Mail that styles itself for dark mode. Rich mail sits on a light card in dark mode, so it must always see
// a light colour scheme; simple mail follows the reader's theme as before.

private func clean(_ html: String) -> SanitizedMail {
    MailSanitizer.sanitize(html: html)
}

/// Light tables painted inline, `color-scheme: light dark` on the root and a dark-mode block that turns all
/// text white: on the light card the text would vanish.
private let darkAwareNewsletter = """
    <html><head>
    <meta name="color-scheme" content="light dark"><meta name="supported-color-schemes" content="light dark">
    <style>
    :root { color-scheme: light dark; supported-color-schemes: light dark; }
    body { margin: 0; background-color: #f4f4f5; color: #3f3f46; }
    @media (prefers-color-scheme: dark) {
      body, .email-body { background-color: #333 !important; color: #FFF !important; }
      p, h1, span { color: #FFF !important; }
    }
    </style></head>
    <body class="email-body" bgcolor="#f4f4f5" style="color-scheme: light dark">
    <table width="100%" bgcolor="#f4f4f5"><tr><td>
    <table width="520" style="background-color:#ffffff"><tr><td><h1>Monthly report</h1><p>Usage went up.</p></td></tr></table>
    </td></tr></table></body></html>
    """

@Test func richMailNeverSeesItsDarkMode() {
    let mail = clean(darkAwareNewsletter)
    #expect(mail.mode == .rich)
    #expect(!mail.css.contains("color-scheme"), "neither the dark block nor color-scheme on the root survives")
    #expect(!mail.css.contains("#FFF"))
    #expect(!mail.css.contains("#333"))
    #expect(!mail.bodyStyle.contains("color-scheme"))
    #expect(!mail.html.contains("color-scheme"), "meta tags never reach the page")
    #expect(mail.css.contains(".tern-body { margin: 0; background-color: #f4f4f5; color: light-dark(#3f3f46, "))
}

@Test func darkConditionsNeverMatch() {
    // Queries that need a dark scheme can't match at all.
    #expect(CSSSanitizer.lightSchemeMedia("(prefers-color-scheme: dark)") == nil)
    #expect(CSSSanitizer.lightSchemeMedia("screen and (prefers-color-scheme: dark)") == nil)
    #expect(CSSSanitizer.lightSchemeMedia("only screen and (PREFERS-COLOR-SCHEME:DARK)") == nil)
    #expect(CSSSanitizer.lightSchemeMedia("( prefers-color-scheme : dark ) and (max-width: 600px)") == nil)
    #expect(CSSSanitizer.lightSchemeMedia("(prefers-color-scheme: no-preference)") == nil)
    // In a list, only the dark query goes.
    #expect(CSSSanitizer.lightSchemeMedia("(prefers-color-scheme:dark), print") == "print")
    #expect(CSSSanitizer.lightSchemeMedia("print, screen and (prefers-color-scheme: dark)") == "print")
    // Under `not` and in `or` chains the condition is replaced by one that is always false.
    #expect(CSSSanitizer.lightSchemeMedia("not (prefers-color-scheme: dark)") == "not (not (min-width: 0px))")
    #expect(CSSSanitizer.lightSchemeMedia("not screen and (prefers-color-scheme: dark)") == "not screen and (not (min-width: 0px))")
    #expect(CSSSanitizer.lightSchemeMedia("(prefers-color-scheme: dark) or (max-width: 600px)") == "(not (min-width: 0px)) or (max-width: 600px)")
    // `orientation` holds the letters of `or` but isn't the keyword.
    #expect(CSSSanitizer.lightSchemeMedia("(orientation: portrait) and (prefers-color-scheme: dark)") == nil)
    // Any scheme, and queries that don't ask, stay as they are.
    #expect(CSSSanitizer.lightSchemeMedia("(prefers-color-scheme)") == "(min-width: 0px)")
    #expect(CSSSanitizer.lightSchemeMedia(" screen and (max-width: 600px) ") == "screen and (max-width: 600px)")
}

@Test func darkBlocksGoInEverySpelling() {
    let mail = clean("""
        <style>
        @MEDIA (PREFERS-COLOR-SCHEME: DARK) { .a { color: #fff } }
        @media(prefers-color-scheme:dark){ .b { color: #fff } }
        @media screen and (prefers-color-scheme: dark), (prefers-color-scheme: dark) and (max-width: 600px) { .c { color: #fff } }
        @supports (display: grid) { @media (prefers-color-scheme: dark) { .d { color: #fff } } .e { display: grid } }
        @media screen and (max-width: 600px) { @media (prefers-color-scheme: dark) { .f { color: #fff } } .g { width: 100% } }
        @media not all and (prefers-color-scheme: dark) { .h { color: #111111 } }
        </style><p>Hi</p>
        """)
    for name in [".a", ".b", ".c", ".d", ".f"] { #expect(!mail.css.contains(name + " "), "\(name) is dark-only") }
    #expect(mail.css.contains("@supports (display: grid) {.e { display: grid }"))
    #expect(mail.css.contains("@media screen and (max-width: 600px) {.g { width: 100% }"))
    #expect(mail.css.contains("@media not all and (not (min-width: 0px)) {.h { color: light-dark(#111111, "))
    #expect(mail.mode == .simple, "white text in dark-only blocks doesn't make the mail rich")
}

@Test func lightConditionsMatchOnTheLightCard() {
    let sheet = "<style>.only-light { display: none } @media (prefers-color-scheme: light) { .only-light { display: block } }</style>"
    let rich = clean(sheet + "<table bgcolor=\"#f4f4f5\"><tr><td><p class=\"only-light\">Hi</p></td></tr></table>")
    #expect(rich.mode == .rich)
    #expect(rich.css.contains("@media (min-width: 0px) {.only-light { display: block }"))
    // Simple mail follows the reader's theme, so the condition stays as written.
    let simple = clean(sheet + "<p class=\"only-light\">Hi</p>")
    #expect(simple.mode == .simple)
    #expect(simple.css.contains("@media (prefers-color-scheme: light) {.only-light { display: block }"))
    #expect(!simple.css.contains("\u{E000}"))
    // The marker can't be smuggled in by the mail.
    let forged = clean("<style>@media (max-width: 9px\u{E000}) { .x { width: 1px } } .y\u{E000} { width: 2px }</style><p>Hi</p>")
    #expect(!forged.css.contains("\u{E000}"))
    #expect(!forged.css.contains("prefers-color-scheme"))
}

@Test func styleMediaAttributesAreHonoured() {
    let mail = clean("""
        <style media="(prefers-color-scheme: dark)">.card { background-color: #27272a !important } td { color: #ffffff !important }</style>
        <style media="screen">.total { font-weight: 600 }</style>
        <style media="all">.note { font-size: 12px }</style>
        <style media="screen and (prefers-color-scheme: light)">.light { display: block }</style>
        <style media="screen{} .evil { color: red }">.broken { width: 1px }</style>
        <table class="card" style="background-color:#ffffff"><tr><td class="total">Total</td></tr></table>
        """)
    #expect(!mail.css.contains("#27272a"))
    #expect(!mail.css.contains("#ffffff"))
    #expect(mail.css.contains("@media screen {\n.total { font-weight: 600 }"))
    #expect(mail.css.contains(".note { font-size: 12px }"))
    #expect(!mail.css.contains("@media all"))
    #expect(mail.css.contains("@media screen and (prefers-color-scheme: light) {\n.light { display: block }"))
    #expect(!mail.css.contains("evil") && !mail.css.contains("broken"), "a media list the browser can't parse matches nothing")
    #expect(mail.mode == .simple, "a dark-only sheet doesn't count toward the mode")
}

@Test func mailCantPickTheColorScheme() {
    let mail = clean("""
        <style>.tile { color-scheme: dark; -apple-color-filter: apple-invert-lightness(); color: #222222 }</style>
        <div style="COLOR-SCHEME: only light; color: #222222">Hi</div>
        """)
    #expect(!mail.css.lowercased().contains("color-scheme"))
    #expect(!mail.css.contains("apple-color-filter"))
    #expect(mail.css.contains(".tile { color: light-dark(#222222, "))
    #expect(!mail.html.lowercased().contains("color-scheme"))
    #expect(mail.html.contains("style=\"color: light-dark(#222222, "))
}
