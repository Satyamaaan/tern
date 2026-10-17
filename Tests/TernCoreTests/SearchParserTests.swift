import Foundation
import Testing
@testable import TernCore

private func parse(_ text: String) -> SearchExpr? { SearchQuery(text).root }

private func word(_ value: String, prefix: Bool = false) -> SearchExpr {
    .text(SearchText(value, isPrefix: prefix))
}

private func phrase(_ value: String, prefix: Bool = false) -> SearchExpr {
    .text(SearchText(value, isPhrase: true, isPrefix: prefix))
}

private func field(_ field: SearchField, _ value: String, prefix: Bool = false, phrase: Bool = false) -> SearchExpr {
    .field(field, SearchText(value, isPhrase: phrase, isPrefix: prefix))
}

// MARK: - Text

@Test func plainWordsAreAnImplicitAnd() {
    #expect(parse("hello world ") == .and([word("hello"), word("world")]))
}

@Test func theLastWordIsAPrefixWhileTyping() {
    #expect(parse("hello wor") == .and([word("hello"), word("wor", prefix: true)]))
    #expect(parse("hello wor ") == .and([word("hello"), word("wor")]))
    #expect(parse("t") == word("t", prefix: true))
}

@Test func emptyAndPunctuationOnlyInputHasNoQuery() {
    #expect(parse("") == nil)
    #expect(parse("   \n\t ") == nil)
    #expect(SearchQuery("&&& ... --").isEmpty)
    #expect(SearchQuery("   ").isEmpty)
}

@Test func quotedPhrases() {
    #expect(parse("\"gate b12\" ") == phrase("gate b12"))
    #expect(parse("\"gate b12\"") == phrase("gate b12"))
    #expect(parse("tacos \"gate b12\" ") == .and([word("tacos"), phrase("gate b12")]))
}

@Test func anUnclosedQuoteIsAPhraseStillBeingTyped() {
    #expect(parse("\"gate b1") == phrase("gate b1", prefix: true))
    #expect(parse("\"") == nil)
}

@Test func punctuatedWordsKeepTheirTextAndSplitIntoTokens() {
    #expect(parse("ENG-412 ") == word("ENG-412"))
    #expect(SearchText("ann@example.com").tokens == ["ann", "example", "com"])
    #expect(parse("https://example.com/a?b=1 ") == word("https://example.com/a?b=1"))
}

// MARK: - Negation, OR, groups

@Test func negation() {
    #expect(parse("-spam ") == .not(word("spam")))
    #expect(parse("tacos -spam ") == .and([word("tacos"), .not(word("spam"))]))
    #expect(parse("-\"free money\" ") == .not(phrase("free money")))
    #expect(parse("-from:bob ") == .not(field(.from, "bob")))
    #expect(parse("--spam ") == word("spam"))
}

@Test func aHyphenInsideAWordIsNotANegation() {
    #expect(parse("e-mail ") == word("e-mail"))
}

@Test func negatedWordsAreNeverPrefixes() {
    #expect(parse("-spa") == .not(word("spa")))
}

@Test func orBindsTighterThanTheImplicitAnd() {
    #expect(parse("cats OR dogs ") == .or([word("cats"), word("dogs")]))
    #expect(parse("a b OR c ") == .and([word("a"), .or([word("b"), word("c")])]))
    #expect(parse("a OR b OR c ") == .or([word("a"), word("b"), word("c")]))
}

@Test func lowercaseOrIsJustAWord() {
    #expect(parse("cats or dogs ") == .and([word("cats"), word("or"), word("dogs")]))
}

@Test func parenthesesGroup() {
    #expect(parse("(a OR b) c ") == .and([.or([word("a"), word("b")]), word("c")]))
    #expect(parse("-(a b) ") == .not(.and([word("a"), word("b")])))
    #expect(parse("((a)) ") == word("a"))
}

@Test func bracesAreAnOrGroup() {
    #expect(parse("{from:a from:b} ") == .or([field(.from, "a"), field(.from, "b")]))
}

@Test func anOperatorAppliesToAParenthesizedGroup() {
    #expect(parse("subject:(dinner movie) ") == .and([field(.subject, "dinner"), field(.subject, "movie")]))
    #expect(parse("from:(ann OR bob) ") == .or([field(.from, "ann"), field(.from, "bob")]))
}

@Test func danglingAndStrayStructureIsForgiven() {
    #expect(parse("a OR ") == word("a"))
    #expect(parse("OR a ") == word("a"))
    #expect(parse("a OR OR b ") == .or([word("a"), word("b")]))
    #expect(parse("(a ") == word("a"))
    #expect(parse("a) ") == word("a"))
    #expect(parse("(-) a ") == word("a"))
    #expect(parse("a AND b ") == .and([word("a"), word("b")]))
}

// MARK: - Operators

@Test func textOperators() {
    #expect(parse("from:bob ") == field(.from, "bob"))
    #expect(parse("FROM:bob ") == field(.from, "bob"))
    #expect(parse("to:ann@example.com ") == field(.to, "ann@example.com"))
    #expect(parse("cc:ann ") == field(.cc, "ann"))
    #expect(parse("bcc:ann ") == field(.bcc, "ann"))
    #expect(parse("subject:invoice ") == field(.subject, "invoice"))
    #expect(parse("subject:\"q4 plan\" ") == field(.subject, "q4 plan", phrase: true))
    #expect(parse("filename:report.pdf ") == field(.filename, "report.pdf"))
}

@Test func anOperatorValueBeingTypedIsAPrefix() {
    #expect(parse("from:bo") == field(.from, "bo", prefix: true))
    #expect(parse("subject:inv") == field(.subject, "inv", prefix: true))
    #expect(parse("filename:rep") == field(.filename, "rep"))
}

@Test func filters() {
    #expect(parse("has:attachment ") == .filter(.hasAttachment))
    #expect(parse("is:unread ") == .filter(.unread))
    #expect(parse("is:read ") == .filter(.read))
    #expect(parse("is:starred ") == .filter(.starred))
    #expect(parse("is:important ") == .filter(.important))
    #expect(parse("is:snoozed ") == .filter(.snoozed))
    #expect(parse("is:needsreply ") == .filter(.needsReply))
    #expect(parse("in:inbox ") == .filter(.folder(.inbox)))
    #expect(parse("in:sent ") == .filter(.folder(.sent)))
    #expect(parse("in:drafts ") == .filter(.folder(.drafts)))
    #expect(parse("in:trash ") == .filter(.folder(.trash)))
    #expect(parse("in:spam ") == .filter(.folder(.spam)))
    #expect(parse("in:anywhere ") == .filter(.folder(.anywhere)))
    #expect(parse("in:snoozed ") == .filter(.snoozed))
    #expect(parse("label:Finance ") == .filter(.label("Finance")))
    #expect(parse("label:\"My Label\" ") == .filter(.label("My Label")))
    #expect(parse("category:newsletter ") == .filter(.category(.newsletter)))
    #expect(parse("category:people ") == .filter(.category(.people)))
    #expect(parse("project:lumen ") == .filter(.project("lumen")))
    #expect(parse("account:alex@northwind.studio ") == .filter(.account("alex@northwind.studio")))
}

@Test func datesAndDurations() {
    #expect(parse("before:2026/10/17 ") == .filter(.before(SearchDay(year: 2026, month: 10, day: 17))))
    #expect(parse("after:2026-01-05 ") == .filter(.after(SearchDay(year: 2026, month: 1, day: 5))))
    #expect(parse("after:2026 ") == .filter(.after(SearchDay(year: 2026))))
    #expect(parse("after:2026/03 ") == .filter(.after(SearchDay(year: 2026, month: 3))))
    #expect(parse("older_than:7d ") == .filter(.olderThan(SearchDuration(7, .day))))
    #expect(parse("newer_than:2w ") == .filter(.newerThan(SearchDuration(2, .week))))
    #expect(parse("newer_than:3m ") == .filter(.newerThan(SearchDuration(3, .month))))
    #expect(parse("older_than:1y ") == .filter(.olderThan(SearchDuration(1, .year))))
    #expect(parse("older_than:10 ") == .filter(.olderThan(SearchDuration(10, .day))))
}

@Test func sizes() {
    #expect(parse("larger:10K ") == .filter(.larger(10 * 1024)))
    #expect(parse("larger:2M ") == .filter(.larger(2 * 1_048_576)))
    #expect(parse("smaller:1.5MB ") == .filter(.smaller(1_572_864)))
    #expect(parse("larger:500 ") == .filter(.larger(500)))
    #expect(parse("larger:1G ") == .filter(.larger(1_073_741_824)))
}

@Test func operatorsCombineWithText() {
    #expect(parse("from:bob invoice -is:read ") == .and([field(.from, "bob"), word("invoice"), .not(.filter(.read))]))
}

// MARK: - Partial and unknown input

@Test func anOperatorWithNoValueYetIsIgnored() {
    #expect(parse("from:") == nil)
    #expect(parse("from: ") == nil)
    #expect(parse("tacos from:") == word("tacos"))
    #expect(parse("label:") == nil)
    #expect(parse("subject:\"") == nil)
    #expect(parse("from:(") == nil)
}

@Test func aPartialEnumeratedValueIsIgnoredWhileTyping() {
    #expect(parse("is:unr") == nil)
    #expect(parse("has:att") == nil)
    #expect(parse("category:news") == nil)
    #expect(parse("tacos is:s") == word("tacos"))
}

@Test func aPartialDateIsIgnoredWhileTyping() {
    #expect(parse("before:2") == nil)
    #expect(parse("before:202") == nil)
    #expect(parse("before:2026/") == nil)
    #expect(parse("after:2026-") == nil)
}

@Test func unknownOperatorsAreText() {
    #expect(parse("foo:bar ") == word("foo:bar"))
    #expect(parse("list:news ") == word("list:news"))
    #expect(parse("http://example.com ") == word("http://example.com"))
}

@Test func invalidValuesOfKnownOperatorsAreText() {
    #expect(parse("is:banana ") == word("is:banana"))
    #expect(parse("has:wings ") == word("has:wings"))
    #expect(parse("category:zebra ") == word("category:zebra"))
    #expect(parse("before:2026/13/40 ") == word("before:2026/13/40"))
    #expect(parse("before:2026/02/30 ") == word("before:2026/02/30"))
    #expect(parse("older_than:soon ") == word("older_than:soon"))
    #expect(parse("larger:huge ") == word("larger:huge"))
}

@Test func anyStringParsesWithoutCrashing() {
    var generator = SystemRandomNumberGenerator()
    let alphabet = Array("abc XYZ019:\"()-{}*'\\@._ OR AND from:to:is:has:label:before:larger: \n\t🙂é\u{0}%_[]|^$?+")
    for _ in 0..<4_000 {
        let length = Int.random(in: 0...40, using: &generator)
        let text = String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
        _ = SearchQuery(text).root
        _ = SearchQuery(text).gmailQuery
        _ = SearchQuery(text).highlighter.ranges(in: "Some subject with words")
    }
}

@Test func everyPrefixOfARealisticQueryParses() {
    let query = "from:\"Maya Chen\" (invoice OR receipt) -is:read has:attachment after:2026/01/05 larger:2M label:\"My Label\" "
    for end in query.indices {
        _ = SearchQuery(String(query[..<end]))
    }
    #expect(!SearchQuery(query).isEmpty)
}

// MARK: - Trash visibility

@Test func trashAndSpamAreOnlyShownWhenAskedFor() {
    #expect(!SearchQuery("tacos").includesTrashOrSpam)
    #expect(SearchQuery("tacos in:trash ").includesTrashOrSpam)
    #expect(SearchQuery("in:spam ").includesTrashOrSpam)
    #expect(SearchQuery("tacos in:anywhere ").includesTrashOrSpam)
    #expect(SearchQuery("label:trash ").includesTrashOrSpam)
}

// MARK: - Gmail translation

@Test func gmailQueryTranslatesStandardOperators() {
    #expect(SearchQuery("from:bob invoice ").gmailQuery == "from:bob invoice")
    #expect(SearchQuery("\"gate b12\" -spam ").gmailQuery == "\"gate b12\" -spam")
    #expect(SearchQuery("is:unread has:attachment in:inbox ").gmailQuery == "is:unread has:attachment in:inbox")
    #expect(SearchQuery("subject:\"q4 plan\" ").gmailQuery == "subject:\"q4 plan\"")
    #expect(SearchQuery("label:\"My Label\" ").gmailQuery == "label:My-Label")
    #expect(SearchQuery("after:2026-1-5 ").gmailQuery == "after:2026/01/05")
    #expect(SearchQuery("older_than:2w ").gmailQuery == "older_than:14d")
    #expect(SearchQuery("newer_than:3m ").gmailQuery == "newer_than:3m")
    #expect(SearchQuery("larger:2M ").gmailQuery == "larger:2097152")
    #expect(SearchQuery("filename:report.pdf ").gmailQuery == "filename:report.pdf")
    #expect(SearchQuery("(a OR b) c ").gmailQuery == "(a OR b) c")
    #expect(SearchQuery("-(a b) ").gmailQuery == "-(a b)")
}

@Test func gmailQueryDropsTernOnlyOperators() {
    #expect(SearchQuery("category:newsletter ").gmailQuery == nil)
    #expect(SearchQuery("project:lumen ").gmailQuery == nil)
    #expect(SearchQuery("account:alex@x.com ").gmailQuery == nil)
    #expect(SearchQuery("is:needsreply ").gmailQuery == nil)
    #expect(SearchQuery("is:snoozed ").gmailQuery == nil)
    #expect(SearchQuery("invoice category:receipt account:alex@x.com ").gmailQuery == "invoice")
    #expect(SearchQuery("from:bob project:lumen is:unread ").gmailQuery == "from:bob is:unread")
}

@Test func gmailQueryWidensInsteadOfNarrowingAroundDroppedClauses() {
    // Dropping one side of an OR would narrow it, so the whole clause goes.
    #expect(SearchQuery("invoice (category:receipt OR from:stripe) ").gmailQuery == "invoice")
    #expect(SearchQuery("invoice -category:receipt ").gmailQuery == "invoice")
}

@Test func gmailQueryIsNilForEmptyInput() {
    #expect(SearchQuery("").gmailQuery == nil)
    #expect(SearchQuery("from:").gmailQuery == nil)
}

// MARK: - Highlighting

@Test func highlighterMarksWordsPrefixesAndPhrases() {
    // "lisb" is not the last word, so it must match whole words; "flights" does.
    let words = SearchQuery("lisb flights ").highlighter
    #expect(words.ranges(in: "Lisbon flights for Friday") == [NSRange(location: 7, length: 7)])
    let prefix = SearchQuery("flights lisb").highlighter
    #expect(prefix.ranges(in: "Lisbon flights for Friday") == [NSRange(location: 0, length: 6), NSRange(location: 7, length: 7)])

    let exact = SearchQuery("\"gate b12\" ").highlighter
    #expect(exact.ranges(in: "Boarding at Gate B12 now") == [NSRange(location: 12, length: 8)])
    #expect(exact.ranges(in: "Gate closes, B12 is far").isEmpty)
}

@Test func highlighterIgnoresCaseAndDiacriticsAndNegations() {
    let query = SearchQuery("lucia -flights ").highlighter
    #expect(query.ranges(in: "Lucía Gómez sent flights") == [NSRange(location: 0, length: 5)])
}

@Test func highlighterUsesUTF16Offsets() {
    let ranges = SearchQuery("tacos ").highlighter.ranges(in: "🙂 Tacos")
    #expect(ranges == [NSRange(location: 3, length: 5)])
}

@Test func highlighterMergesOverlaps() {
    let ranges = SearchQuery("york \"new york\" ").highlighter.ranges(in: "New York, New York")
    #expect(ranges == [NSRange(location: 0, length: 8), NSRange(location: 10, length: 8)])
}
