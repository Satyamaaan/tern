import Foundation
import Testing
@testable import TernCore

// Mail CSS that tries to make the browser read the sanitized sheet differently from the sanitizer: structural
// characters hidden behind combining marks, broken media queries, strings and comments that never close. The
// output must always parse the way it was written, and nothing in it may reach the shadow host.

private func clean(_ html: String) -> SanitizedMail {
    MailSanitizer.sanitize(html: html)
}

/// Reads sanitizer output the way WebKit tokenizes CSS, one Unicode scalar at a time, and checks the structure
/// is what the sanitizer meant: blocks balance, strings end on their line, brackets close before any `{` or `}`,
/// and nothing escapes a character or opens a comment.
private func isWellFormed(_ css: String) -> Bool {
    var braces = 0
    var brackets: [Unicode.Scalar] = []
    var quote: Unicode.Scalar?
    var previous: Unicode.Scalar = " "
    for scalar in css.unicodeScalars {
        if scalar.value < 0x20, !"\t\n\r\u{C}".unicodeScalars.contains(scalar) { return false }
        if scalar.value == 0x7F { return false }
        if let open = quote {
            if scalar == open {
                quote = nil
            } else if "\n\r\u{C}\\".unicodeScalars.contains(scalar) {
                return false
            }
            previous = scalar
            continue
        }
        switch scalar {
        case "\"", "'": quote = scalar
        case "(", "[": brackets.append(scalar)
        case ")": if brackets.popLast() != "(" { return false }
        case "]": if brackets.popLast() != "[" { return false }
        case "{":
            if !brackets.isEmpty { return false }
            braces += 1
        case "}":
            if !brackets.isEmpty || braces == 0 { return false }
            braces -= 1
        case "\\": return false
        case "*" where previous == "/": return false
        default: break
        }
        previous = scalar
    }
    return braces == 0 && quote == nil && brackets.isEmpty
}

private func reachesHost(_ css: String) -> Bool {
    let lower = css.lowercased()
    return [":host", "::part", "::slotted"].contains { lower.range(of: $0, options: .literal) != nil }
}

/// `&#x…;` for every scalar, so any character can sit inside an attribute.
private func entities(_ text: String) -> String {
    text.unicodeScalars.map { "&#x\(String($0.value, radix: 16));" }.joined()
}

private let structural = ["{", "}", ";", "@", "/", "*", "\\", "(", ")", ",", ":", "\"", "'", "<", ">"]
/// Combining acute, zero-width joiner, variation selector 16, combining enclosing keycap, combining grave.
private let marks = ["\u{301}", "\u{200D}", "\u{FE0F}", "\u{20E3}", "\u{300}"]
private let escape = "contain: none !important; overflow: visible !important; position: absolute !important"

@Test func combiningMarkInAMediaAttributeCantReachTheHost() {
    let mail = clean("""
        <style media="all {&#x301;, :host">
        & { contain:none !important; overflow:visible !important; position:absolute !important; inset:0 !important }
        </style><p>Hi</p>
        """)
    #expect(mail.css.isEmpty, "a media list that isn't plain ASCII drops its sheet: \(mail.css)")
    #expect(!reachesHost(mail.css))
}

@Test func marksAfterStructuralCharactersInMediaAttributes() {
    for character in structural {
        for mark in marks {
            let media = entities("all \(character)\(mark), :host")
            let mail = clean("""
                <style media="\(media)">& { \(escape) }</style><style>.after { width: 1px }</style><p>Hi</p>
                """)
            #expect(!reachesHost(mail.css), "\(character)+U+\(String(mark.unicodeScalars.first!.value, radix: 16))")
            #expect(isWellFormed(mail.css), "\(mail.css)")
            #expect(mail.css.trimmingCharacters(in: .newlines) == ".after { width: 1px }", "the rejected sheet drops alone: \(mail.css)")
        }
    }
}

@Test func marksAfterStructuralCharactersInSheets() {
    for character in structural {
        for mark in marks {
            let hidden = character + mark
            let sheets = [
                "p { font-family: a \(hidden) } :host { \(escape) } .after { width: 1px }",
                "p\(hidden) { color: red } :host { \(escape) } .after { width: 1px }",
                "@media screen\(hidden) { :host { \(escape) } } .after { width: 1px }",
                "@supports (display: grid)\(hidden) { :host { \(escape) } } .after { width: 1px }",
                "p { color: red }\(hidden), :host {\(hidden); \(escape) } .after { width: 1px }",
                "p { content: \"\(hidden)\" } \(hidden):host { \(escape) }",
                "@media all {\(hidden), :host { & { \(escape) } } }",
            ]
            for sheet in sheets {
                let css = clean("<style>\(sheet)</style><p>Hi</p>").css
                #expect(!reachesHost(css), "\(sheet) → \(css)")
                #expect(isWellFormed(css), "\(sheet) → \(css)")
            }
        }
    }
}

@Test func marksAfterTheSeparatorsOfADeclaration() {
    // `;` + a mark still ends the declaration, so `position: fixed` is seen and dropped.
    let mail = clean("<style>p { color: red;\u{301} position: fixed }</style><p style=\"color: red;\u{200D}position: fixed\">Hi</p>")
    #expect(!mail.css.contains("fixed"))
    #expect(!mail.html.contains("fixed"))
    let spaced = clean("<style>p { position: fixed ! important } q { position: STICKY\t!IMPORTANT }</style><p>Hi</p>")
    #expect(spaced.css.isEmpty, "\(spaced.css)")
    // A mark after `(` doesn't hide `url(` from the URL policy.
    let fetch = clean("""
        <style>p { background: url(\u{301}https://evil.example/a.png) } @font-face { font-family: x; src: url(\u{301}https://fonts.example/x.woff) }</style>
        <p style="background-image: url(\u{200D}https://evil.example/b.png)">Hi</p>
        """)
    #expect(!fetch.css.contains("evil.example") && !fetch.html.contains("evil.example"))
    #expect(!fetch.css.contains("fonts.example"))
    // `:host` followed by a mark is still `:host` to the sanitizer.
    #expect(CSSSanitizer.rewriteSelector(":host\u{301} p").isEmpty)
    #expect(CSSSanitizer.rewriteSelector(":HOST\u{200D}(.x)").isEmpty)
}

@Test func controlCharactersNeverReachTheOutput() {
    let controls = ["\u{0}", "\u{1}", "\u{8}", "\u{B}", "\u{1B}", "\u{7F}"]
    for control in controls {
        let sheets = [
            "p\(control) { color: red } .after { width: 1px }",
            "p { color: red\(control) } .after { width: 1px }",
            "p { content: \"a\(control)b\" } .after { width: 1px }",
            "@media screen\(control) { p { color: red } } .after { width: 1px }",
            "@supports (display\(control): grid) { p { color: red } } .after { width: 1px }",
            "\u{1}body { color: red } .after { width: 1px }",
        ]
        for sheet in sheets {
            let css = clean("<style>\(sheet)</style><p>Hi</p>").css
            #expect(isWellFormed(css), "\(sheet.debugDescription) → \(css.debugDescription)")
            #expect(css.contains(".after { width: 1px }"), "\(sheet.debugDescription) → \(css.debugDescription)")
            #expect(!css.contains(".tern-body"), "only `body` itself becomes the body wrapper")
        }
        let attribute = clean("<style media=\"screen\(entities(control))\">p { color: red }</style><p>Hi</p>")
        #expect(attribute.css.isEmpty)
    }
}

@Test func lookAlikeBracesAreJustText() {
    // Full-width, small and ornament braces, semicolons and parentheses are ordinary letters to CSS.
    for lookAlike in ["\u{FF5B}", "\u{FF5D}", "\u{FF1B}", "\u{FE5B}", "\u{FE5C}", "\u{2774}", "\u{2775}", "\u{FF08}", "\u{FF09}"] {
        let css = clean("""
            <style>p\(lookAlike) contain: none\(lookAlike) :host { \(escape) } .after { width: 1px }</style>
            <style media="all \(lookAlike), :host">p { color: red }</style><p>Hi</p>
            """).css
        #expect(!reachesHost(css))
        #expect(isWellFormed(css))
        #expect(css.trimmingCharacters(in: .newlines) == ".after { width: 1px }", "\(css)")
    }
}

@Test func anInvalidMediaAttributeDoesntSwallowLaterSheets() {
    for media in ["all /*", "all /* x */", "(min-width: 600px", "screen)", "screen and (max-width: 600px", "((min-width: 1px)",
                  "screen, ", "all\u{0}", "\"screen\"", "screen; .x", "@media screen", "screen and (min-width: 0\\9)",
                  "(width >= 600px)", "screen and(max-width: 600px)", "(prefers-color-scheme:)"] {
        let mail = clean("<style media=\"\(entities(media))\">p { color: red }</style><style>.after { width: 1px }</style><p>Hi</p>")
        #expect(mail.css.trimmingCharacters(in: .newlines) == ".after { width: 1px }", "\(media) → \(mail.css)")
    }
}

@Test func brokenSyntaxInsideASheetStaysLocal() {
    let mail = clean("""
        <style>
        @media (min-width: 600px { .a { color: red } }
        .b { width: 1px }
        @supports ((display: grid) { .c { color: red } }
        .d { width: 1px }
        p:is(.e { color: red }
        .f { width: 1px }
        p { content: "never closed
        } :host { \(escape) }
        .g { width: 1px }
        .h { width: calc(1px + (2px) }
        .i { width: 1px }
        </style>
        <style>@media screen /* { .j { color: red } }</style>
        <style>.k { width: 1px }</style><p>Hi</p>
        """)
    for name in [".a", ".c", ".e", ".h", ".j"] { #expect(!mail.css.contains(name + " "), "\(name) is broken: \(mail.css)") }
    for name in [".b", ".d", ".f", ".g", ".i", ".k"] { #expect(mail.css.contains(name + " { width: 1px }"), "\(name) survives: \(mail.css)") }
    #expect(!reachesHost(mail.css))
    #expect(isWellFormed(mail.css))
    #expect(!mail.css.contains("never closed"))
}

@Test func unterminatedStringsAndCommentsCantRestructureTheOutput() {
    // A string that runs past its line ends there in the browser, and a comment hidden behind a mark is still
    // a comment; neither may leave text that reopens a rule around `:host`.
    let mail = clean("""
        <style>
        p { content: "a
        } :host { \(escape) } q { content: "b" }
        p /*\u{301} { color: red }
        .x { content: "*/, :host { \(escape) } x{" }
        </style>
        <style>.y { content: '\u{301}'; font-family: "a\u{C}b" }</style><p>Hi</p>
        """)
    #expect(!reachesHost(mail.css), "\(mail.css)")
    #expect(isWellFormed(mail.css), "\(mail.css)")
    #expect(mail.css.contains("q { content: \"b\" }"))
    #expect(mail.css.contains(".y { content: '\u{301}' }"))
}

@Test func emptyFeatureValuesNeverMatch() {
    #expect(CSSSanitizer.lightSchemeMedia("(prefers-color-scheme:)") == nil)
    #expect(CSSSanitizer.lightSchemeMedia("(prefers-color-scheme: )") == nil)
    #expect(CSSSanitizer.lightSchemeMedia("screen and (max-width:)") == nil)
    #expect(CSSSanitizer.lightSchemeMedia("(:dark)") == nil)
    #expect(CSSSanitizer.lightSchemeMedia("()") == nil)
    #expect(CSSSanitizer.lightSchemeMedia("(prefers-color-scheme: dark light)") == nil)
    #expect(CSSSanitizer.lightSchemeMedia("(prefers-color-scheme:), print") == "print", "only the broken query goes")
    let mail = clean("""
        <style>@media (prefers-color-scheme:){p{color:white}} @media (prefers-color-scheme: ) { .a { color: #fff } } .b { width: 1px }</style>
        <table bgcolor="#f4f4f5"><tr><td><p>Hi</p></td></tr></table>
        """)
    #expect(!mail.css.contains("white") && !mail.css.contains("#fff"), "\(mail.css)")
    #expect(mail.css.contains(".b { width: 1px }"))
}

@Test func mediaQueriesAreWrittenBackFromTheirTokens() {
    let valid = [
        "only screen and (max-width:480px)": "only screen and (max-width: 480px)",
        "screen and (-webkit-min-device-pixel-ratio: 2), (min-resolution: 192dpi)":
            "screen and (-webkit-min-device-pixel-ratio: 2), (min-resolution: 192dpi)",
        "(min-aspect-ratio: 16 / 9)": "(min-aspect-ratio: 16/9)",
        "(hover: hover) and (pointer: fine)": "(hover: hover) and (pointer: fine)",
        "not all and (monochrome)": "not all and (monochrome)",
        "((min-width: 1px) and (max-width: 2px)) or (orientation: portrait)":
            "((min-width: 1px) and (max-width: 2px)) or (orientation: portrait)",
        "(min-width: .5em) and (max-width: -1px)": "(min-width: .5em) and (max-width: -1px)",
        "SCREEN\nAND\t(MAX-WIDTH : 600PX)": "SCREEN AND (MAX-WIDTH: 600PX)",
        "  ": "all",
    ]
    for (list, written) in valid { #expect(CSSSanitizer.lightSchemeMedia(list) == written, "\(list.debugDescription)") }
    let invalid = [
        "screen and(max-width: 1px)", "not(screen)", "(width >= 600px)", "(400px < width < 700px)", "screen yahoo",
        "screen and (max-width: 1px) or (min-width: 2px)", "(a) and (b) or (c)", "not (a) and (b)", "only (a)", "and",
        "(max-width: 1px\\0)", "(max-width: \"1px\")", "(min-width: 0\\9)", "scr\u{435}en", "screen\u{A0}and (a)",
        "(max-width: 1px;)", "(max-width: 1px} p {)", "(max-width: 1px /* */)", "(max-width: 10%)",
        "(min-aspect-ratio: -16/9)", "(min-aspect-ratio: 16/)", "(a: b c)", "(a, b)", "url(x)", "@media",
        String(repeating: "(", count: 9) + "a" + String(repeating: ")", count: 9),
    ]
    for list in invalid { #expect(CSSSanitizer.lightSchemeMedia(list) == nil, "\(list.debugDescription)") }
    #expect(CSSSanitizer.lightSchemeMedia(String(repeating: "(", count: 8) + "a" + String(repeating: ")", count: 8)) != nil)
}

@Test func styleMediaAttributesUseTheWrittenBackList() {
    #expect(CSSSanitizer.sheetMedia("") == .everywhere)
    #expect(CSSSanitizer.sheetMedia(" ALL ") == .everywhere)
    #expect(CSSSanitizer.sheetMedia("print, all") == .everywhere)
    #expect(CSSSanitizer.sheetMedia("screen and (max-width:600px)") == .when("screen and (max-width: 600px)"))
    #expect(CSSSanitizer.sheetMedia("(prefers-color-scheme: dark)") == .never)
    #expect(CSSSanitizer.sheetMedia("(prefers-color-scheme: dark), print") == .when("print"))
    #expect(CSSSanitizer.sheetMedia("print, (max-width: 1px") == .never, "one broken query drops the sheet")
    let mail = clean("<style media=\"screen   and (max-width:600px)\">.a { width: 1px }</style><p>Hi</p>")
    #expect(mail.css == "@media screen and (max-width: 600px) {\n.a { width: 1px }\n}\n")
}

@Test func nestedMediaAndSupportsKeepTheirRules() {
    // Each broken block sits in a sheet of its own: an unclosed bracket swallows everything after it in its sheet
    // (see `sheetStructureMatchesWebKit`).
    let mail = clean("""
        <style>
        @supports (display: grid) {
          @media (prefers-color-scheme: dark) { .a { color: #fff } }
          .c { display: grid }
        }
        @media screen { @supports (display: flex) { @media (prefers-color-scheme: light) { .d { display: block } } } }
        @supports selector(:host) { .f { display: block } }
        @media screen { @media screen { @media screen { @media screen { @media screen { @media screen { .deep { color: red } } } } } } }
        .after { width: 1px }
        </style>
        <style>@supports (display: grid) { @media (min-width: 1px { .b { color: red } } }</style>
        <style>@supports (a: b)) , :host { .e { \(escape) } } .after2 { width: 1px }</style><p>Hi</p>
        """)
    #expect(!mail.css.contains(".a ") && !mail.css.contains(".b ") && !mail.css.contains(".e ") && !mail.css.contains(".f "), "\(mail.css)")
    #expect(mail.css.contains("@supports (display: grid) {.c { display: grid }"))
    #expect(mail.css.contains("@media screen {@supports (display: flex) {@media (prefers-color-scheme: light) {.d { display: block }"))
    #expect(!mail.css.contains(".deep"))
    #expect(outline(mail.css).hasSuffix(" .after @supports (display: grid){} .after2"), "\(outline(mail.css))")
    #expect(isWellFormed(mail.css))
    #expect(!reachesHost(mail.css))
}

// MARK: WebKit's error recovery

/// Sanitized CSS as its rules: selectors, and `@media …{…}` around the rules inside, so a test sees which block
/// every rule ended up in.
private func outline(_ css: String) -> String {
    let scalars = Array(css.unicodeScalars)
    var index = 0
    func block() -> [String] {
        var items: [String] = []
        var prelude = String.UnicodeScalarView()
        var quote: Unicode.Scalar?
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            if let open = quote {
                if scalar == open { quote = nil }
                prelude.append(scalar)
                continue
            }
            switch scalar {
            case "\"", "'":
                quote = scalar
                prelude.append(scalar)
            case "{":
                let name = String(prelude).trimmingCharacters(in: .whitespacesAndNewlines)
                prelude = String.UnicodeScalarView()
                if name.hasPrefix("@") {
                    items.append("\(name){\(block().joined(separator: " "))}")
                } else {
                    items.append(name)
                    while index < scalars.count {
                        let inner = scalars[index]
                        index += 1
                        if let open = quote {
                            if inner == open { quote = nil }
                        } else if inner == "\"" || inner == "'" {
                            quote = inner
                        } else if inner == "}" {
                            break
                        }
                    }
                }
            case "}":
                return items
            default:
                prelude.append(scalar)
            }
        }
        return items
    }
    return block().joined(separator: " ")
}

/// Sheets read by WebKit (macOS 15) through a probe that printed each one's CSSOM, and the rules it kept in each
/// block. A rule the sanitizer drops on purpose is left out of the expected outline (`:is(})`, escapes, declarations
/// that aren't self-contained); every rule both keep must sit in the same block.
@Test func sheetStructureMatchesWebKit() {
    let cases: [(String, String)] = [
        // A stray `}` or `;` at the top joins the next rule's prelude, and only that rule goes.
        (".a{color:#111}} .b{color:red} .c{color:blue}", ".a .c"),
        (".a { x: y } } } .b { color: red } .c { color: blue }", ".a .c"),
        (".a; .b{color:red} .c{color:blue}", ".c"),
        (".a { color: red }; .b { color: blue } .c { color: green }", ".a .c"),
        ("p { color: red } ;", "p"),
        ("@media print { .p{color:red} } } .lost{color:red} .kept{color:blue}", "@media print{.p} .kept"),
        // An at-rule without a block ends at `;`, or at the `}` of the block around it without taking it; at the top
        // a `}` is part of its prelude.
        ("@media print{@import \"x\"} .after{color:red}", "@media print{} .after"),
        ("@media screen { .a { color: red } @import 'x' } .b{color:blue}", "@media screen{.a} .b"),
        ("@import \"x\" } .a { color: red } .b { color: blue }", ".b"),
        // Inside @media and @supports, `;`, `<!--` and `-->` start a prelude.
        ("@media screen { .a; .b {color:red} .c {color:blue} }", "@media screen{.c}"),
        ("@media screen { color: red; .b {color:red} }", "@media screen{}"),
        ("p{color:red} @media screen { .m{color:red} ; .n{color:blue} }", "p @media screen{.m}"),
        ("@supports (display:grid) { .s{color:red} ; .t{color:blue} .u{color:green} }", "@supports (display:grid){.s .u}"),
        ("@media screen { -->.a{color:red} .b{color:blue} }", "@media screen{.b}"),
        ("@media screen { p { color: red } <!-- .x{color:blue} .y{color:green} }", "@media screen{p .y}"),
        // At the top, `<!--` and `-->` are skipped.
        ("<!-- p{margin:10px 0} --> .q{color:red} <!-- .r{color:blue}", "p .q .r"),
        ("@media screen{.a{color:red}} <!-- --> .z{color:blue}", "@media screen{.a} .z"),
        ("p{color:red}--> .q{color:blue}", "p .q"),
        ("p{color:red}<!--.q{color:blue}", "p .q"),
        // Brackets, strings, escapes, comments and unquoted URLs decide where a block ends.
        ("@media screen { p:is(}) { color: red } .in { width: 1px } } .after { width: 1px }", "@media screen{.in} .after"),
        (".a, [title=\"}\"] { color: red } .b{color:blue}", ".a, [title=\"}\"] .b"),
        ("@media screen { .a\\{ { color: red } .in{width:1px} } .after{width:1px}", "@media screen{.in} .after"),
        ("@media screen { .a\\;{color:red} .b{color:blue} }", "@media screen{.b}"),
        ("p { content: \"/*\" } .x { color: red } /* */ .y{color:blue}", "p .x .y"),
        ("p { content: \"a\\\" } .x{color:red} \" } .y{color:blue}", ".y"),
        ("p { content: \"abc\n} .x{color:red}", ".x"),
        ("p { content: \"a\\\n} .x{color:red}\"} .y{color:blue}", ".y"),
        ("p { background: url(a}b) } .x { color: red }", ".x"),
        ("@media screen { p { background: url(}) } .in{color:red} } .after{color:blue}", "@media screen{.in} .after"),
        ("p { background: url( \"a}\" ) } .x{color:red}", "p .x"),
        ("p { background: u\\72l(a}b) } .x{color:red}", ".x"),
        ("p { background: url(a\"b) } .x{color:red}", ".x"),
        ("p { background: url(a\"b }\n.x{color:red} ) } .y{color:blue}", ".y"),
        ("u/**/rl(x;}) .z{color:red} .w{color:blue}", ".w"),
        (".a { color: red; .n { color: blue } width: 2px } .b{color:green}", ".a .b"),
        ("@media screen { @media print { .a{color:red} } } .b{color:blue}", "@media screen{@media print{.a}} .b"),
        ("@media screen { --x: { } .b { color: red } } .c{color:blue}", "@media screen{.b} .c"),
        ("--x: { color: red } .b { color: blue }", ".b"),
        // A `(` that closes far away swallows everything up to it, and the block it opened in stays open to the end.
        ("""
         @supports (display: grid) {
           @media (min-width: 1px { .b { color: red } }
           .c { display: grid }
         }
         @media screen { .d { display: block } }
         @supports (a: b)) , :host { .e { color: red } }
         .after { width: 1px }
         """, "@supports (display: grid){.after}"),
    ]
    for (sheet, expected) in cases {
        let css = clean("<style>\(sheet)</style><p>Hi</p>").css
        #expect(outline(css) == expected, "\(sheet.debugDescription)\n→ \(css.debugDescription)")
        #expect(isWellFormed(css), "\(css)")
    }
}

@Test func brokenBracketsRecoverLocally() {
    // WebKit swallows everything after a bracket that never closes. The sanitizer keeps the rules WebKit kept where
    // WebKit kept them and recovers after the bracket instead of dropping the rest of the sheet.
    let cases: [(String, String)] = [
        (".h { color: red; width: calc(1px + (2px) }\n.i { width: 1px }", ".h .i"),
        ("@media screen { .a { color: red } p:is(.x { color: red } .in { width: 1px } } .after { width: 1px }",
         "@media screen{.a .in} .after"),
        ("p { background: url(x } .after { width: 1px }", ".after"),
    ]
    for (sheet, expected) in cases {
        let css = clean("<style>\(sheet)</style><p>Hi</p>").css
        #expect(outline(css) == expected, "\(sheet.debugDescription)\n→ \(css.debugDescription)")
        #expect(isWellFormed(css))
    }
    #expect(clean("<style>.h { color: red; width: calc(1px + (2px) }</style>").css == ".h { color: red }\n")
}

@Test func htmlCommentMarkersAroundASheet() {
    let mail = clean("""
        <style><!--
        p { margin: 10px 0 }
        .a { color: red }
        --></style><style>
        <!-- @media screen { .b { width: 1px } } -->
        </style><p>Hi</p>
        """)
    #expect(outline(mail.css) == "p .a @media screen{.b}", "\(mail.css)")
}

// MARK: Tern's own elements

@Test func fontFacesAreDropped() {
    // A face declared in the mail's shadow root applies to the whole document, so `local()` could re-glyph Tern's
    // own Inter text, a whole family or single characters.
    let mail = clean("""
        <style>@font-face { font-family: Inter; src: local(Zapfino) }
        @font-face { font-family: Inter; src: local("Zapfino"); unicode-range: U+0057 }
        @FONT-FACE { font-family: "Brand"; src: local(Helvetica Neue) }
        @media screen { @font-face { font-family: Inter; src: local(Zapfino) } .a { font-family: Brand, sans-serif } }
        p { font-family: Inter, sans-serif }</style><p>Hi</p>
        """)
    #expect(!mail.css.lowercased().contains("font-face"), "\(mail.css)")
    #expect(!mail.css.contains("Zapfino") && !mail.css.contains("local("))
    #expect(outline(mail.css) == "@media screen{.a} p")
}

@Test func positionTakesOnlyBoxesThatStayInTheCard() {
    let dropped = [
        "--p:fixed;position:var(--p);inset:0;z-index:9", "position: var(--p, fixed)", "position: env(safe-area-inset-top)",
        "position: attr(data-p type(<custom-ident>))", "position: -webkit-sticky", "position: fixed", "position: STICKY !important",
        "position: absolute\u{301}", "position: fixed, absolute",
    ]
    for style in dropped {
        let mail = clean("<style>.x { \(style) }</style><div style=\"\(style)\">x</div>")
        #expect(!mail.css.contains("position") && !mail.html.contains("position"), "\(style) → \(mail.css) \(mail.html)")
    }
    for mode in ["static", "relative", "absolute", "ABSOLUTE ! important", "inherit", "revert-layer"] {
        let mail = clean("<div style=\"position: \(mode)\">x</div>")
        #expect(mail.html.contains("position: \(mode)"), "\(mode) → \(mail.html)")
    }
}

@Test func selectorsCantNameTernElements() {
    let reserved = [
        ".tern-quote-toggle", ".TERN-QUOTE-TOGGLE", "div.Tern-quote", "#tern-x", ".x .tern-root p", ":is(.tern-quote) b",
        "p:not(.a) ~ .tern-body", ".tern-\u{301}quote", "[class*=tern]", "[class*=\"TERN\"]", "[CLASS^=t]", "[class^='te']",
        "[class$=toggle]", "[class$=\"-body\" i]", "[class|=tern]", "[class~=tern-quote]", "[class=tern-quote-toggle]",
        "*|*[class*=quote]", "[ class *= \"q\" ]", "[svg|class$=root]", "[data-tern-blocked]", "img[data-tern-missing]",
        "[DATA-TERN-BLOCKED=\"\"]", "[id^=tern-]", "div[class*=e]",
    ]
    for selector in reserved {
        #expect(CSSSanitizer.rewriteSelector(selector).isEmpty, "\(selector)")
        #expect(clean("<style>\(selector) { display: none }</style><p>Hi</p>").css.isEmpty, "\(selector)")
    }
    let allowed = [
        "table[class=body] .container", "[class*=col]", ".pattern-bg", ".intern", ".tern", "[class^=\"mobile-\"]",
        ".lantern p", "[title*=tern]", "[class$=x]", "[class=quote]", "[id=main]", "[id*=e]", ".t\u{301}ern-quote",
    ]
    for selector in allowed {
        #expect(!CSSSanitizer.rewriteSelector(selector).isEmpty, "\(selector)")
    }
    #expect(CSSSanitizer.rewriteSelector("body .x") == ".tern-body .x", "html and body still point at the wrappers")
    #expect(CSSSanitizer.rewriteSelector("--x:hover").isEmpty)
}

// MARK: Linear time

/// Mail CSS built to make a backtracking or quadratic reader slow: long runs of spaces inside a feature, deep
/// and unbalanced brackets, endless `and` chains and comma lists, unterminated strings and comments.
private func adversarialSheet(bytes: Int) -> String {
    let sheets = [
        "@media (prefers-color-scheme:" + String(repeating: " ", count: 400) + "!) {p{color:red}}",
        "@media " + String(repeating: "(", count: 200) + "a {p{color:red}}",
        "@media " + String(repeating: "(a) and ", count: 50) + "(b {p{color:red}}",
        "@media " + String(repeating: "(a:),", count: 100) + "(prefers-color-scheme: {p{color:red}}",
        "p { content: \"" + String(repeating: "(", count: 200) + "\n}",
        "@supports " + String(repeating: "(", count: 200) + "{p{color:red}}",
        "/*" + String(repeating: "*", count: 100) + "*/ q { width: 1px }",
    ]
    let attributes = [
        String(repeating: "(prefers-color-scheme: ", count: 30),
        "screen and " + String(repeating: "(a) and ", count: 40) + "(b",
        String(repeating: "(", count: 300),
    ]
    let unit = sheets.map { "<style>\($0)</style>\n" }.joined()
        + attributes.map { "<style media=\"\($0)\">p{color:red}</style>\n" }.joined()
    var html = ""
    while html.utf8.count < bytes { html += unit }
    return html + "<p>Hi</p>"
}

@Test func adversarialMediaQueriesStillSanitize() {
    let mail = clean(adversarialSheet(bytes: 100_000))
    #expect(isWellFormed(mail.css))
    #expect(!mail.css.contains("color:red") && !mail.css.contains("color: red"), "\(mail.css.prefix(400))")
    #expect(mail.css.contains("q { width: 1px }"))
    let reproducer = "<style>@media (prefers-color-scheme:" + String(repeating: " ", count: 16_000) + "!) {p{color:red}}</style>"
    #expect(clean(reproducer).css.isEmpty)
}

/// Sheets built to make the structural reading slow: unquoted URLs, brackets and blocks that never close,
/// backslash runs, strings that run to their line, comments and markers.
private func adversarialStructure(bytes: Int) -> String {
    let pieces = [
        "p { background: url(" + String(repeating: "\\", count: 41) + ")", "url(", "u\\72l(", "calc(", "[", "{", "(",
        "\"" + String(repeating: "\\\"", count: 20) + "\n", "/* x */", "<!--", "-->", "}", ";", ".tern-x[class*=", "@media (",
    ]
    var css = ""
    var index = 0
    while css.utf8.count < bytes {
        css += pieces[index % pieces.count] + " a "
        index += 1
    }
    return "<style>" + css + "</style><style>q { width: 1px }</style><p>Hi</p>"
}

private let skipPerf = ProcessInfo.processInfo.environment["TERN_SKIP_PERF"] == "1"

/// Best of five, in milliseconds.
private func milliseconds(_ html: String) -> Double {
    (0..<5).map { _ in
        let start = DispatchTime.now().uptimeNanoseconds
        _ = MailSanitizer.sanitize(html: html)
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }.min()!
}

@Test(.enabled(if: !skipPerf, "TERN_SKIP_PERF=1"))
func adversarialMediaQueriesSanitizeInLinearTime() {
    let small = milliseconds(adversarialSheet(bytes: 25_000))
    let large = milliseconds(adversarialSheet(bytes: 100_000))
    let spaces = { (count: Int) in
        milliseconds("<style>@media (prefers-color-scheme:" + String(repeating: " ", count: count) + "!) {p{color:red}}</style>")
    }
    let spacesSmall = spaces(25_000), spacesLarge = spaces(100_000)
    print(String(format: "adversarial media CSS: 25 KB %.2f ms, 100 KB %.2f ms; 25k spaces %.2f ms, 100k spaces %.2f ms",
                 small, large, spacesSmall, spacesLarge))
    #expect(large < 100, "100 KB of adversarial media queries took \(large) ms")
    #expect(spacesLarge < 100, "the backtracking reproducer took \(spacesLarge) ms")
    // Four times the input: linear is about 4×, quadratic 16×.
    #expect(large / small < 8, "25 KB \(small) ms → 100 KB \(large) ms")
    #expect(spacesLarge / max(spacesSmall, 0.05) < 8, "25k spaces \(spacesSmall) ms → 100k spaces \(spacesLarge) ms")
}

@Test func adversarialStructureStillSanitizes() {
    let mail = clean(adversarialStructure(bytes: 100_000))
    #expect(isWellFormed(mail.css))
    #expect(mail.css.contains("q { width: 1px }"))
}

@Test(.enabled(if: !skipPerf, "TERN_SKIP_PERF=1"))
func adversarialStructureSanitizesInLinearTime() {
    let small = milliseconds(adversarialStructure(bytes: 25_000))
    let large = milliseconds(adversarialStructure(bytes: 100_000))
    print(String(format: "adversarial sheet structure: 25 KB %.2f ms, 100 KB %.2f ms", small, large))
    #expect(large < 100, "100 KB of adversarial sheet structure took \(large) ms")
    #expect(large / small < 8, "25 KB \(small) ms → 100 KB \(large) ms")
}
