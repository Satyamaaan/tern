import Foundation
import GRDB
import Testing
@testable import TernCore

// A small hand-built mailbox. Newest first the threads are:
//   t3 (1d) t9 (1.5d) t6 (2d, spam) t1 (3d) t7 (5d, trash) t2 (10d) t11 (12d) t10 (15d) t4 (20d) t5 (29d) t8 (40d)

private let utc = TimeZone(identifier: "UTC")!
private let now = ISO8601DateFormatter().date(from: "2026-10-17T12:00:00Z")!
private func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

private let acme = Account(email: "alex@acme.com", displayName: "Acme", sortOrder: 0)
private let home = Account(email: "alex@home.net", displayName: "Home", sortOrder: 1)

private struct Fixture {
    let store: MailStore
    let search: SearchService

    func ids(_ text: String, account: String? = nil, sort: SearchSort = .newest) throws -> [String] {
        try search.searchHits(text, options: options(account: account, sort: sort)).map(\.row.thread.id)
    }

    func options(account: String? = nil, sort: SearchSort = .newest) -> SearchOptions {
        SearchOptions(accountId: account, sort: sort, now: now, timeZone: utc)
    }
}

private func message(
    _ account: Account, _ id: String, thread: String, daysAgo: Double, from: (String, String), to: [String] = [],
    cc: [String] = [], bcc: [String] = [], subject: String, body: String, labels: [String],
    size: Int = 2_000, attachment: Bool = false, mine: Bool = false
) -> MailMessage {
    func people(_ emails: [String]) -> [Participant] { emails.map { Participant(email: $0) } }
    return MailMessage(
        accountId: account.id, id: id, threadId: thread, date: ago(daysAgo), fromName: from.0, fromEmail: from.1,
        toList: people(to.isEmpty ? [account.email] : to), ccList: people(cc), bccList: people(bcc), subject: subject,
        snippet: String(body.prefix(140)), bodyText: body, bodyState: .full, labelIds: labels, isFromMe: mine,
        hasAttachments: attachment, sizeEstimate: size)
}

private func makeFixture() throws -> Fixture {
    let store = MailStore(try AppDatabase.inMemory())
    try store.upsertAccount(acme)
    try store.upsertAccount(home)
    try store.replaceLabels(accountId: acme.id, with: [
        MailLabel(accountId: acme.id, id: "INBOX", name: "Inbox", type: "system"),
        MailLabel(accountId: acme.id, id: "Label_work", name: "Work"),
        MailLabel(accountId: acme.id, id: "Label_clients", name: "Clients/Big Co"),
    ])
    try store.replaceLabels(accountId: home.id, with: [
        MailLabel(accountId: home.id, id: "INBOX", name: "Inbox", type: "system"),
        MailLabel(accountId: home.id, id: "Label_1", name: "Work"),
    ])

    let maya = ("Maya Chen", "maya@northwind.studio")
    let ben = ("Ben Turner", "ben@turner.law")
    try store.upsertMessages([
        message(acme, "m1", thread: "t1", daysAgo: 3, from: maya, subject: "Q4 roadmap review",
                body: "Please review the roadmap before Thursday. Thanks, Maya",
                labels: ["INBOX", "UNREAD", "IMPORTANT", "CATEGORY_PERSONAL"], size: 9_000, attachment: true),
        message(acme, "m2", thread: "t2", daysAgo: 10, from: ("Stripe", "billing@stripe.com"), subject: "Invoice 2026-118",
                body: "Your receipt for the amount of $42 is attached", labels: ["INBOX", "Label_work"], attachment: true),
        message(acme, "m3", thread: "t3", daysAgo: 1, from: ben, cc: ["carol@example.com"], bcc: ["dave@example.com"],
                subject: "Lunch tacos", body: "Tacos at noon? Meet at Gate B12.", labels: ["INBOX", "STARRED"]),
        message(home, "m4", thread: "t4", daysAgo: 20, from: ("SkyAir", "travel@airline.com"), subject: "Lisbon flights",
                body: "Your booking to Lisbon is confirmed. Seat 14A.", labels: ["INBOX"]),
        message(home, "m5a", thread: "t5", daysAgo: 30, from: ("Alex Morgan", home.email), to: ["hotel@lisbon.pt"],
                subject: "Lisbon hotel", body: "Do you have rooms for May?", labels: ["SENT"], mine: true),
        message(home, "m5b", thread: "t5", daysAgo: 29, from: ("Hotel Lisbon", "hotel@lisbon.pt"), subject: "Re: Lisbon hotel",
                body: "Yes, we have rooms available.", labels: ["INBOX"]),
        message(acme, "m6", thread: "t6", daysAgo: 2, from: ("Prize Bot", "spam@bad.biz"), subject: "Win a free prize",
                body: "Claim your free prize and tacos now", labels: ["SPAM"]),
        message(acme, "m7", thread: "t7", daysAgo: 5, from: maya, subject: "Old thread", body: "Nothing to see", labels: ["TRASH"]),
        message(acme, "m8", thread: "t8", daysAgo: 40, from: ben, subject: "Big video", body: "Here is the video",
                labels: ["INBOX", "Label_clients"], size: 5_000_000, attachment: true),
        message(acme, "m9", thread: "t9", daysAgo: 1.5, from: ("Alex Morgan", acme.email), to: [maya.1],
                subject: "Draft note", body: "Remember to ask about the roadmap", labels: ["DRAFT"], mine: true),
        message(acme, "m10", thread: "t10", daysAgo: 15, from: ("Weekly Digest", "news@substack.com"), subject: "Weekly digest",
                body: "A roadmap for better tacos, newsletter edition", labels: ["INBOX", "CATEGORY_PROMOTIONS"]),
        message(home, "m11", thread: "t11", daysAgo: 12, from: ben, subject: "Plan B",
                body: "Alternative plan, see foo:bar for details", labels: ["INBOX", "Label_1"]),
    ], attachments: [
        MailAttachment(accountId: acme.id, messageId: "m1", partId: "1", filename: "Proposal.pdf", mimeType: "application/pdf", size: 5_000),
        MailAttachment(accountId: acme.id, messageId: "m2", partId: "1", filename: "Invoice.pdf", mimeType: "application/pdf", size: 4_000),
        MailAttachment(accountId: acme.id, messageId: "m8", partId: "1", filename: "clip.mov", mimeType: "video/quicktime", size: 4_900_000),
    ])
    try store.database.writer.write { db in
        try ThreadAI(accountId: acme.id, threadId: "t1", category: .people, needsReply: true, messageCount: 1).insert(db)
        try ThreadAI(accountId: acme.id, threadId: "t2", category: .receipt, messageCount: 1).insert(db)
        try ThreadAI(accountId: acme.id, threadId: "t3", category: .people, messageCount: 1).insert(db)
        try ThreadAI(accountId: home.id, threadId: "t4", category: .receipt, messageCount: 1).insert(db)
        try ThreadAI(accountId: acme.id, threadId: "t10", category: .newsletter, messageCount: 1).insert(db)
        try Project(id: "p-lumen", name: "Lumen redesign").insert(db)
        try Project(id: "p-home", name: "Home & travel").insert(db)
        try ThreadProject(accountId: acme.id, threadId: "t1", projectId: "p-lumen", source: .rule).insert(db)
        try ThreadProject(accountId: home.id, threadId: "t4", projectId: "p-home", source: .rule).insert(db)
        try Snooze(accountId: home.id, threadId: "t4", until: now.addingTimeInterval(2 * 86_400)).insert(db)
    }
    try store.rebuildContacts()
    return Fixture(store: store, search: SearchService(store.database))
}

// MARK: - Text

@Test func plainWordsFindThreadsNewestFirst() throws {
    let f = try makeFixture()
    #expect(try f.ids("roadmap") == ["t9", "t1", "t10"])
    #expect(try f.ids("tacos") == ["t3", "t10"])
    #expect(try f.ids("roadmap tacos") == ["t10"])
    #expect(try f.ids("") == [])
    #expect(try f.ids("   ") == [])
}

@Test func theLastWordMatchesAsAPrefix() throws {
    let f = try makeFixture()
    #expect(try f.ids("roadm") == ["t9", "t1", "t10"])
    #expect(try f.ids("r") .contains("t1"))
    #expect(try f.ids("roadm ") == [])        // finished word: whole words only
    #expect(try f.ids("roadm review") == [])  // earlier words are whole words too
    #expect(try f.ids("review roadm") == ["t1"])
}

@Test func searchIgnoresCaseAndDiacritics() throws {
    let f = try makeFixture()
    try f.store.upsertMessages([message(acme, "mx", thread: "tx", daysAgo: 0.5, from: ("Lucía Gómez", "lucia@meridian.design"),
                                        subject: "Café plans", body: "Crème brûlée", labels: ["INBOX"])])
    #expect(try f.ids("LUCIA") == ["tx"])
    #expect(try f.ids("cafe creme brulee") == ["tx"])
    #expect(try f.ids("gomez ") == ["tx"])
}

@Test func phrasesMatchAdjacentWordsInOrder() throws {
    let f = try makeFixture()
    #expect(try f.ids("\"gate b12\"") == ["t3"])
    #expect(try f.ids("\"b12 gate\"") == [])
    #expect(try f.ids("gate b12") == ["t3"])
    #expect(try f.ids("\"meet at gate\" ") == ["t3"])
}

@Test func punctuatedWordsMatchTheirAdjacentTokens() throws {
    let f = try makeFixture()
    #expect(try f.ids("foo:bar ") == ["t11"])
    #expect(try f.ids("Invoice-2026-118 ") == ["t2"])
}

@Test func negationAndOr() throws {
    let f = try makeFixture()
    #expect(try f.ids("tacos -gate") == ["t10"])
    #expect(try f.ids("tacos -is:starred") == ["t10"])
    #expect(try f.ids("tacos -from:ben") == ["t10"])
    #expect(try f.ids("lisbon OR invoice") == ["t2", "t4", "t5"])
    #expect(try f.ids("tacos (gate OR roadmap)") == ["t3", "t10"])
    #expect(try f.ids("from:maya OR from:ben") == ["t3", "t1", "t11", "t8"])
    #expect(try f.ids("{from:maya from:stripe}") == ["t1", "t2"])
    let everythingButTacos = try f.ids("-tacos")
    #expect(!everythingButTacos.contains("t3") && !everythingButTacos.contains("t10"))
    #expect(everythingButTacos.contains("t1") && everythingButTacos.contains("t4"))
}

// MARK: - Operators

@Test func fromMatchesSenderNameAndAddress() throws {
    let f = try makeFixture()
    #expect(try f.ids("from:maya") == ["t1"])
    #expect(try f.ids("from:\"Maya Chen\"") == ["t1"])
    #expect(try f.ids("from:chen") == ["t1"])
    #expect(try f.ids("from:maya@northwind.studio") == ["t1"])
    #expect(try f.ids("from:northwind.studio") == ["t1"])
    #expect(try f.ids("from:@stripe.com") == ["t2"])
    #expect(try f.ids("from:ma") == ["t1"])   // still typing
    #expect(try f.ids("from:stripe invoice") == ["t2"])
    #expect(try f.ids("from:stripe tacos") == [])
}

@Test func fromMeMeansMessagesYouSent() throws {
    let f = try makeFixture()
    #expect(try f.ids("from:me") == ["t9", "t5"])
    #expect(try f.ids("from:me lisbon") == ["t5"])
}

@Test func toCcAndBccLookInTheRightRecipients() throws {
    let f = try makeFixture()
    #expect(try f.ids("to:hotel") == ["t5"])
    #expect(try f.ids("to:maya") == ["t9"])
    #expect(try f.ids("to:carol") == ["t3"])            // to: also finds cc'd and bcc'd people (the index keeps one recipients column)
    #expect(try f.ids("cc:carol") == ["t3"])
    #expect(try f.ids("cc:dave") == [])
    #expect(try f.ids("bcc:dave") == ["t3"])
    #expect(try f.ids("bcc:carol") == [])
    #expect(try f.ids("cc:carol@example.com") == ["t3"])
    #expect(try f.ids("to:me") == ["t3", "t1", "t2", "t11", "t10", "t4", "t5", "t8"])
}

@Test func subjectOnlyLooksAtTheSubject() throws {
    let f = try makeFixture()
    #expect(try f.ids("subject:invoice") == ["t2"])
    #expect(try f.ids("subject:tacos") == ["t3"])
    #expect(try f.ids("subject:lisbon") == ["t4", "t5"])
    #expect(try f.ids("subject:\"lisbon hotel\"") == ["t5"])
    #expect(try f.ids("subject:(lunch tacos)") == ["t3"])
    #expect(try f.ids("subject:video tacos") == [])
}

@Test func hasAttachmentAndFilename() throws {
    let f = try makeFixture()
    #expect(try f.ids("has:attachment") == ["t1", "t2", "t8"])
    #expect(try f.ids("has:attachment from:maya") == ["t1"])
    #expect(try f.ids("filename:pdf") == ["t1", "t2"])
    #expect(try f.ids("filename:proposal") == ["t1"])
    #expect(try f.ids("filename:clip.mov") == ["t8"])
    #expect(try f.ids("filename:\"Invoice.pdf\" amount") == ["t2"])
    #expect(try f.ids("filename:nothing") == [])
}

@Test func readStateAndFlags() throws {
    let f = try makeFixture()
    #expect(try f.ids("is:unread") == ["t1"])
    #expect(try f.ids("is:read") == ["t3", "t9", "t2", "t11", "t10", "t4", "t5", "t8"])
    #expect(try f.ids("is:starred") == ["t3"])
    #expect(try f.ids("is:important") == ["t1"])
    #expect(try f.ids("is:snoozed") == ["t4"])
    #expect(try f.ids("in:snoozed") == ["t4"])
    #expect(try f.ids("is:needsreply") == ["t1"])
    #expect(try f.ids("is:unread -is:needsreply") == [])
}

@Test func inFolders() throws {
    let f = try makeFixture()
    #expect(try f.ids("in:inbox") == ["t3", "t1", "t2", "t11", "t10", "t4", "t5", "t8"])
    #expect(try f.ids("in:sent") == ["t5"])
    #expect(try f.ids("in:drafts") == ["t9"])
    #expect(try f.ids("in:trash") == ["t7"])
    #expect(try f.ids("in:spam") == ["t6"])
    #expect(try f.ids("in:inbox tacos") == ["t3", "t10"])
    #expect(try f.ids("in:trash roadmap") == [])
}

@Test func trashAndSpamStayHiddenUnlessAskedFor() throws {
    let f = try makeFixture()
    #expect(try f.ids("tacos") == ["t3", "t10"])
    #expect(try f.ids("in:anywhere tacos") == ["t3", "t6", "t10"])
    #expect(try f.ids("tacos in:spam") == ["t6"])
    #expect(try f.ids("from:maya") == ["t1"])
    #expect(try f.ids("from:maya in:anywhere") == ["t1", "t7"])
    #expect(try f.ids("label:trash") == ["t7"])
}

@Test func labelsByIdOrNameInAnyCase() throws {
    let f = try makeFixture()
    #expect(try f.ids("label:Work") == ["t2", "t11"])        // same name, different ids in two accounts
    #expect(try f.ids("label:work") == ["t2", "t11"])
    #expect(try f.ids("label:Label_work") == ["t2"])
    #expect(try f.ids("label:label_1") == ["t11"])
    #expect(try f.ids("label:\"Clients/Big Co\"") == ["t8"])
    #expect(try f.ids("label:clients-big-co") == ["t8"])
    #expect(try f.ids("label:INBOX video") == ["t8"])
    #expect(try f.ids("label:starred") == ["t3"])
    #expect(try f.ids("label:nothing") == [])
    #expect(try f.ids("label:work -from:ben") == ["t2"])
}

@Test func datesUseTheThreadsLastActivity() throws {
    let f = try makeFixture()
    #expect(try f.ids("before:2026/10/10") == ["t2", "t11", "t10", "t4", "t5", "t8"])
    #expect(try f.ids("after:2026/10/10") == ["t3", "t9", "t1"])
    #expect(try f.ids("after:2026-10-10 before:2026-10-16") == ["t1"])          // t9 is exactly midnight: not before it
    #expect(try f.ids("after:2026-10-10 before:2026-10-17") == ["t3", "t9", "t1"])
    #expect(try f.ids("older_than:30d") == ["t8"])
    #expect(try f.ids("newer_than:2d") == ["t3", "t9"])
    #expect(try f.ids("newer_than:1w tacos") == ["t3"])
    #expect(try f.ids("older_than:1m roadmap") == [])
    #expect(try f.ids("before:2026/10/10 lisbon") == ["t4", "t5"])
}

@Test func beforeAndAfterUseTheGivenTimeZone() throws {
    let f = try makeFixture()
    // t1 is 3 days before 2026-10-17T12:00Z: 2026-10-14T12:00Z.
    let tokyo = SearchOptions(now: now, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
    let hits = try f.search.searchHits("after:2026/10/14 before:2026/10/15", options: tokyo)
    #expect(hits.map(\.row.thread.id) == ["t1"])
    let la = SearchOptions(now: now, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
    #expect(try f.search.searchHits("after:2026/10/15", options: la).map(\.row.thread.id) == ["t3", "t9"])
}

@Test func sizeLimits() throws {
    let f = try makeFixture()
    #expect(try f.ids("larger:1M") == ["t8"])
    #expect(try f.ids("larger:1M has:attachment") == ["t8"])
    #expect(try f.ids("larger:1G") == [])
    #expect(try f.ids("smaller:1K") == [])
    #expect(try f.ids("smaller:3K from:ben") == ["t3", "t11"])
    #expect(try f.ids("larger:5K smaller:20K") == ["t1"])
}

@Test func categories() throws {
    let f = try makeFixture()
    #expect(try f.ids("category:receipt") == ["t2", "t4"])
    #expect(try f.ids("category:people") == ["t3", "t1"])
    #expect(try f.ids("category:newsletter") == ["t10"])
    #expect(try f.ids("category:security") == [])
    #expect(try f.ids("category:receipt invoice") == ["t2"])
    #expect(try f.ids("-category:people in:inbox") == ["t2", "t11", "t10", "t4", "t5", "t8"])
}

@Test func projects() throws {
    let f = try makeFixture()
    #expect(try f.ids("project:lumen") == ["t1"])
    #expect(try f.ids("project:\"Lumen redesign\"") == ["t1"])
    #expect(try f.ids("project:lumen-redesign") == ["t1"])
    #expect(try f.ids("project:home") == ["t4"])
    #expect(try f.ids("project:nope") == [])
    #expect(try f.ids("project:lumen roadmap") == ["t1"])
}

@Test func accounts() throws {
    let f = try makeFixture()
    #expect(try f.ids("account:alex@home.net") == ["t11", "t4", "t5"])
    #expect(try f.ids("account:home") == ["t11", "t4", "t5"])
    #expect(try f.ids("account:Acme tacos") == ["t3", "t10"])
    #expect(try f.ids("account:nobody") == [])
    #expect(try f.ids("tacos", account: home.id) == [])
    #expect(try f.ids("lisbon", account: home.id) == ["t4", "t5"])
    #expect(try f.ids("lisbon", account: acme.id) == [])
    #expect(try f.ids("account:acme", account: home.id) == [])
}

@Test func operatorsCombine() throws {
    let f = try makeFixture()
    #expect(try f.ids("from:maya is:unread has:attachment") == ["t1"])
    #expect(try f.ids("from:maya -is:unread") == [])
    #expect(try f.ids("in:inbox -is:read") == ["t1"])
    #expect(try f.ids("is:starred OR is:unread") == ["t3", "t1"])
    #expect(try f.ids("(from:maya OR from:stripe) has:attachment") == ["t1", "t2"])
    #expect(try f.ids("tacos (is:starred OR from:news)") == ["t3", "t10"])
}

// MARK: - Partial and odd input

@Test func partialOperatorsNeverBreakTheSearch() throws {
    let f = try makeFixture()
    #expect(try f.ids("from:") == [])
    #expect(try f.ids("tacos from:") == ["t3", "t10"])
    #expect(try f.ids("tacos is:") == ["t3", "t10"])
    #expect(try f.ids("tacos before:2026/") == ["t3", "t10"])
    #expect(try f.ids("tacos label:") == ["t3", "t10"])
    #expect(try f.ids("is:unr") == [])
    let query = "from:\"Maya Chen\" (roadmap OR receipt) -is:read has:attachment after:2026/01/05 larger:2K label:\"My Label\" "
    for end in query.indices { _ = try f.search.search(String(query[..<end])) }
}

@Test func searchFindsNewMailAndForgetsDeletedMail() throws {
    let f = try makeFixture()
    try f.store.upsertMessages([message(acme, "mz", thread: "tz", daysAgo: 0.1, from: ("Zed", "zed@example.com"),
                                        subject: "Zebra crossing", body: "Quokka", labels: ["INBOX"])])
    #expect(try f.ids("quokka") == ["tz"])
    try f.store.deleteMessages(accountId: acme.id, ids: ["mz"])
    #expect(try f.ids("quokka") == [])
    #expect(try f.ids("zebra") == [])
}

@Test func labelChangesAreVisibleToTheNextSearch() throws {
    let f = try makeFixture()
    #expect(try f.ids("is:unread") == ["t1"])
    try f.store.perform(.markRead, on: [ThreadKey(accountId: acme.id, threadId: "t1")])
    #expect(try f.ids("is:unread") == [])
    #expect(try f.ids("in:inbox roadmap") == ["t1", "t10"])
    try f.store.perform(.archive, on: [ThreadKey(accountId: acme.id, threadId: "t1")])
    #expect(try f.ids("in:inbox roadmap") == ["t10"])
}

@Test func theMigrationKeepsTheIndexInStepWithMessages() throws {
    let f = try makeFixture()
    let tables = try f.store.database.reader.read { db in
        try String.fetchAll(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'message_fts'")
    }
    #expect(tables.first?.contains("prefix='1 2 3'") == true)
    #expect(try f.ids("t").contains("t3"))   // one-letter prefix
}

// MARK: - Injection

@Test func searchSyntaxTypedByTheUserIsJustText() throws {
    let f = try makeFixture()
    // FTS5 operators written in text must not act as operators.
    #expect(try f.ids("tacos NOT gate") == [])
    #expect(try f.ids("tacos AND gate") == ["t3"])
    #expect(try f.ids("NEAR(tacos gate)") == [])
    #expect(try f.ids("tacos NEAR gate") == [])
    #expect(try f.ids("tacos OR \"x") .contains("t3"))
    #expect(try f.ids("subject : tacos") == [])   // not the operator, so it needs the word "subject"
    #expect(try f.ids("body:tacos") == [])
    #expect(try f.ids("rowid:3") == [])
    #expect(try f.ids("rank:1") == [])
    #expect(try f.ids("{subject}: tacos") == [])
    #expect(try f.ids("searchSender:maya") == [])
    #expect(try f.ids("*") == [])
    #expect(try f.ids("tacos*") == ["t3", "t10"])
    #expect(try f.ids("^tacos") == ["t3", "t10"])
    #expect(try f.ids("\"tacos\"*") .contains("t3"))
}

@Test func hostileInputDoesNotReachSQL() throws {
    let f = try makeFixture()
    let hostile = [
        "'; DROP TABLE thread; --", "x') OR 1=1 --", "\" OR \"\"=\"", "label:\"a' OR 1=1 --\"", "from:\"') UNION SELECT 1 --\"",
        "project:\"%\"", "account:'", "filename:%", "filename:_", "cc:%", "bcc:\\", "subject:\"", "\\", "\u{0}", "%", "_",
        "(((((", ")))))", "{{{{", "}}}}", "-----", "OR OR OR", "\"\"\"\"", "label:", "in:' OR '1'='1",
        String(repeating: "a", count: 10_000), String(repeating: "(", count: 500) + "x" + String(repeating: ")", count: 500),
    ]
    for text in hostile {
        let hits = try f.search.searchHits(text, options: f.options())
        #expect(hits.count < 12, "\(text.prefix(30))")
    }
    #expect(try f.store.database.reader.read { db in try MailThread.fetchCount(db) } == 11)
    #expect(try f.ids("filename:%") == [])
    #expect(try f.ids("cc:%") == [])
    #expect(try f.ids("project:%") == [])
}

@Test func randomTextNeverThrows() throws {
    let f = try makeFixture()
    var generator = SystemRandomNumberGenerator()
    let alphabet = Array("abc tacos XYZ019:\"()-{}*'\\@._ OR AND from:to:cc:is:has:in:label:before:larger:category:project:account: \n🙂é%_[]|^$?+")
    for _ in 0..<1_500 {
        let length = Int.random(in: 0...40, using: &generator)
        let text = String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
        _ = try f.search.searchHits(text, options: f.options())
        _ = try f.search.searchHits(text, options: f.options(sort: .relevance))
    }
}

// MARK: - Every route gives the same answer

/// The planner picks a route by cost; all of them must agree on the result.
@Test func everyRouteReturnsTheSameThreads() throws {
    let f = try makeFixture()
    let queries = [
        "tacos", "roadmap", "from:maya", "to:me", "in:inbox", "is:unread", "has:attachment", "larger:1M", "filename:pdf",
        "is:snoozed", "is:needsreply", "category:receipt", "project:lumen", "label:work", "before:2026/10/10 lisbon",
        "in:inbox tacos", "from:ben -is:starred", "is:read from:ben", "cc:carol", "tacos (gate OR roadmap)", "-tacos",
        "after:2026/10/01 in:inbox", "account:home lisbon", "category:people is:starred",
    ]
    for text in queries {
        let routes = try f.store.database.reader.read { db -> [(String, [String])] in
            let options = f.options()
            guard let compiled = try SearchCompiler(db, options: options).compile(SearchQuery(text)) else { return [] }
            let executor = SearchExecutor(db: db, compiled: compiled, limit: 50)
            func ids(_ plan: SearchExecutor.Plan) throws -> [String] { try executor.run(plan).map(\.key.threadId) }
            var routes: [(String, [String])] = [("walk", try ids(.threadWalk))]
            routes.append(("chosen \(try executor.choosePlan())", try ids(try executor.choosePlan())))
            if compiled.fts != nil { routes.append(("fts", try ids(.ftsFirst))) }
            for driver in compiled.drivers {
                switch driver {
                case .label(let id): routes.append(("label \(id)", try ids(.labelWalk(id))))
                case .set(let fragment): routes.append(("set", try ids(.set(fragment))))
                }
            }
            return routes
        }
        let expected = try #require(routes.first, "\(text)").1
        for (name, ids) in routes { #expect(ids == expected, "\(text) via \(name)") }
    }
}

@Test func limitsCutTheListNewestFirst() throws {
    let f = try makeFixture()
    let hits = try f.search.searchHits("in:inbox", options: SearchOptions(limit: 3, now: now, timeZone: utc))
    #expect(hits.map(\.row.thread.id) == ["t3", "t1", "t2"])
    #expect(try f.search.search("tacos", limit: 1).map(\.thread.id) == ["t3"])
}

// MARK: - Hits

@Test func hitsNameTheMatchingMessage() throws {
    let f = try makeFixture()
    let hits = try f.search.searchHits("lisbon", options: f.options())
    #expect(hits.map(\.row.thread.id) == ["t4", "t5"])
    #expect(hits[1].matchedMessageId == "m5b")           // newest message of the thread that matches
    #expect(hits[1].matchedAt == ago(29))
    #expect(try f.search.searchHits("from:me lisbon", options: f.options()).first?.matchedMessageId == "m5a")
    #expect(try f.search.searchHits("has:attachment", options: f.options()).first?.matchedMessageId == "m1")
}

@Test func hitsHighlightTheMatchedWordsInTheExcerptAndSubject() throws {
    let f = try makeFixture()
    let hit = try #require(try f.search.searchHits("roadmap", options: f.options()).first { $0.row.thread.id == "t1" })
    #expect(hit.snippet.contains("roadmap"))
    let marked = hit.highlights.map { (hit.snippet as NSString).substring(with: $0) }
    #expect(marked == ["roadmap"])
    #expect(hit.snippetHighlightRanges.map { String(hit.snippet[$0]) } == ["roadmap"])
    #expect(hit.subjectHighlights.map { (hit.row.thread.subject as NSString).substring(with: $0) } == ["roadmap"])
}

@Test func hitHighlightsFollowPrefixesAndSkipMissedFields() throws {
    let f = try makeFixture()
    let hit = try #require(try f.search.searchHits("roadm", options: f.options()).first { $0.row.thread.id == "t1" })
    #expect(hit.highlights.map { (hit.snippet as NSString).substring(with: $0) } == ["roadmap"])

    // The match is only in the subject: the excerpt falls back to the message's own snippet, unmarked.
    let subjectOnly = try #require(try f.search.searchHits("subject:invoice", options: f.options()).first)
    #expect(subjectOnly.snippet == "Your receipt for the amount of $42 is attached")
    #expect(subjectOnly.subjectHighlights.map { (subjectOnly.row.thread.subject as NSString).substring(with: $0) } == ["Invoice"])
}

@Test func hitsForThreadLevelQueriesHaveNoMatchedMessage() throws {
    let f = try makeFixture()
    let hit = try #require(try f.search.searchHits("is:unread", options: f.options()).first)
    #expect(hit.matchedMessageId == nil)
    #expect(hit.snippet == hit.row.thread.snippet)
    #expect(hit.highlights.isEmpty)
}

@Test func theRowsAPIMatchesTheHitsAPI() throws {
    let f = try makeFixture()
    #expect(try f.search.search("lisbon").map(\.id) == (try f.search.searchHits("lisbon", options: f.options()).map(\.id)))
}

// MARK: - Relevance

@Test func relevanceRanksSubjectMatchesAboveBodyMatches() throws {
    let store = MailStore(try AppDatabase.inMemory())
    try store.upsertAccount(acme)
    try store.upsertMessages([
        message(acme, "m1", thread: "body", daysAgo: 1, from: ("A", "a@x.com"), subject: "Hello",
                body: "the budget is attached", labels: ["INBOX"]),
        message(acme, "m2", thread: "subject", daysAgo: 30, from: ("B", "b@x.com"), subject: "Budget plan",
                body: "see attached", labels: ["INBOX"]),
        message(acme, "m3", thread: "other", daysAgo: 2, from: ("C", "c@x.com"), subject: "Lunch", body: "tacos", labels: ["INBOX"]),
    ])
    let search = SearchService(store.database)
    let newest = try search.searchHits("budget", options: SearchOptions(now: now)).map(\.row.thread.id)
    let ranked = try search.searchHits("budget", options: SearchOptions(sort: .relevance, now: now)).map(\.row.thread.id)
    #expect(newest == ["body", "subject"])
    #expect(ranked == ["subject", "body"])
    #expect(try search.searchHits("is:unread", options: SearchOptions(sort: .relevance, now: now)).isEmpty)
}

@Test func relevanceStillHonoursOtherConditions() throws {
    let f = try makeFixture()
    let hits = try f.search.searchHits("tacos -gate", options: f.options(sort: .relevance))
    #expect(hits.map(\.row.thread.id) == ["t10"])
    #expect(try f.ids("tacos", account: home.id, sort: .relevance) == [])
}

@Test func relevanceFindsTheSameThreadsAsNewest() throws {
    let f = try makeFixture()
    let queries = [
        "tacos", "roadmap", "r", "from:maya", "lisbon OR invoice", "tacos -gate", "in:inbox tacos", "subject:lisbon",
        "to:hotel", "cc:carol", "has:attachment roadmap", "label:work invoice", "tacos (gate OR roadmap)", "account:home lisbon",
    ]
    for text in queries {
        let newest = try f.ids(text, sort: .newest)
        let ranked = try f.ids(text, sort: .relevance)
        #expect(Set(ranked) == Set(newest) && ranked.count == newest.count, "\(text): \(ranked) vs \(newest)")
    }
    #expect(try f.ids("-tacos", sort: .relevance) == (try f.ids("-tacos", sort: .newest)))   // nothing to rank: falls back to newest
}

@Test func relevanceRespectsTheLimitAndNamesTheBestMessage() throws {
    let f = try makeFixture()
    let hits = try f.search.searchHits("lisbon", options: SearchOptions(limit: 1, sort: .relevance, now: now, timeZone: utc))
    #expect(hits.count == 1)
    #expect(hits.first?.matchedMessageId != nil)
}
