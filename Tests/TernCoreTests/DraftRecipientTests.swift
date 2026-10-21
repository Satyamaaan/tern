import Foundation
import GRDB
import Testing
@testable import TernCore

@Test func parsesPastedAddressLists() {
    let people = RecipientParser.parse(#"Maya Chen <maya@lumen.io>, "Ng, Jonas" <jonas@x.dev>; sam@y.co"#
        + "\n<bare@z.org>, mailto:m@n.io, (paren@p.io).")
    #expect(people == [
        Participant(name: "Maya Chen", email: "maya@lumen.io"),
        Participant(name: "Ng, Jonas", email: "jonas@x.dev"),
        Participant(email: "sam@y.co"),
        Participant(email: "bare@z.org"),
        Participant(email: "m@n.io"),
        Participant(email: "paren@p.io"),
    ])
}

@Test func splitsTypedInputAtSeparators() {
    #expect(RecipientParser.splitCompleted("maya@lumen.io, jo") == (["maya@lumen.io"], "jo"))
    #expect(RecipientParser.splitCompleted(#""Ng, Jo"#) == ([], #""Ng, Jo"#))
    #expect(RecipientParser.splitCompleted("a@b.co c@d.co;") == (["a@b.co", "c@d.co"], ""))
    #expect(RecipientParser.splitCompleted("Maya Chen") == ([], "Maya Chen"))
    #expect(RecipientParser.parse("a@b.co c@d.co") == [Participant(email: "a@b.co"), Participant(email: "c@d.co")])
    #expect(RecipientParser.parse("Maya Chen maya@lumen.io") == [Participant(name: "Maya Chen", email: "maya@lumen.io")])
}

@Test func validatesAddresses() {
    for good in ["a@b.co", "first.last+tag@sub.domain.dev", "x_y@a-b.io", "jürgen@exämple.de"] {
        #expect(RecipientParser.isValidEmail(good), "\(good)")
    }
    for bad in ["", "a@", "@b.co", "a@b", "a@b.c", "a b@c.de", "a@@b.co", "a@b..co", "a.@b.co", "a@-b.co", "a@b.12"] {
        #expect(!RecipientParser.isValidEmail(bad), "\(bad)")
    }
}

@Test func formatsAndQuotesNames() {
    #expect(RecipientParser.format(Participant(name: "Maya Chen", email: "m@l.io")) == "Maya Chen <m@l.io>")
    #expect(RecipientParser.format(Participant(name: "Ng, Jonas", email: "j@x.dev")) == #""Ng, Jonas" <j@x.dev>"#)
    #expect(RecipientParser.format(Participant(email: "j@x.dev")) == "j@x.dev")
    let round = RecipientParser.parse(RecipientParser.format(Participant(name: #"Al "the" Pal"#, email: "al@p.io")))
    #expect(round == [Participant(name: #"Al "the" Pal"#, email: "al@p.io")])
}

private func contactsStore() throws -> DraftStore {
    let database = try AppDatabase.inMemory()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    try database.writer.write { db in
        try Account(email: "me@example.com").insert(db)
        let day: TimeInterval = 86_400
        for contact in [
            Contact(id: "maya@lumen.io", name: "Maya Chen", sentCount: 10, receivedCount: 12, lastContacted: now.addingTimeInterval(-day)),
            Contact(id: "max@lumen.io", name: "Max Okafor", sentCount: 0, receivedCount: 3, lastContacted: now.addingTimeInterval(-300 * day)),
            Contact(id: "jonas.mayer@kite.dev", name: "Jonas Mayer", sentCount: 2, receivedCount: 1, lastContacted: now.addingTimeInterval(-2 * day)),
            Contact(id: "noreply@lumen.io", name: "Lumen", sentCount: 0, receivedCount: 400, lastContacted: now),
            Contact(id: "me@example.com", name: "Me", sentCount: 50, receivedCount: 50, lastContacted: now),
            Contact(id: "under_score@x.io", name: "", sentCount: 1, receivedCount: 0, lastContacted: now),
        ] { try contact.insert(db) }
    }
    return DraftStore(database, filesDirectory: FileManager.default.temporaryDirectory)
}

@Test func suggestsByNameWordsAndAddressParts() throws {
    let store = try contactsStore()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(try store.suggestRecipients(prefix: "ma", now: now).map(\.email) == ["maya@lumen.io", "jonas.mayer@kite.dev", "max@lumen.io"])
    #expect(try store.suggestRecipients(prefix: "may", now: now).map(\.email) == ["maya@lumen.io", "jonas.mayer@kite.dev"])
    #expect(try store.suggestRecipients(prefix: "lumen", now: now).map(\.email) == ["maya@lumen.io", "max@lumen.io"])
    #expect(try store.suggestRecipients(prefix: "Chen", now: now).map(\.name) == ["Maya Chen"])
    #expect(try store.suggestRecipients(prefix: "me", now: now).isEmpty)
    #expect(try store.suggestRecipients(prefix: "under_", now: now).map(\.email) == ["under_score@x.io"])
    #expect(try store.suggestRecipients(prefix: "u_", now: now).isEmpty)
    #expect(try store.suggestRecipients(prefix: "ma", excluding: ["MAYA@lumen.io"], now: now).map(\.email) == ["jonas.mayer@kite.dev", "max@lumen.io"])
    #expect(try store.suggestRecipients(prefix: "noreply", now: now).map(\.email) == ["noreply@lumen.io"])
}

@Test func narrowingKeepsWhatTheQueryWouldFind() throws {
    let store = try contactsStore()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let shown = try store.suggestRecipients(prefix: "m", now: now)
    for prefix in ["ma", "may", "mayer", "max", "Chen", "lumen", "mx", "no"] {
        let found = try store.suggestRecipients(prefix: prefix, now: now)
        #expect(shown.filter { DraftStore.suggestion($0, fits: prefix) } == shown.filter(found.contains), "\(prefix)")
    }
    #expect(!DraftStore.suggestion(Participant(name: "Lumen", email: "noreply@lumen.io"), fits: "lumen"))
    #expect(DraftStore.suggestion(Participant(name: "Lumen", email: "noreply@lumen.io"), fits: "noreply"))
    #expect(!DraftStore.suggestion(Participant(name: "Maya", email: "maya@lumen.io"), fits: " "))
}

@Test func emptyPrefixSuggestsRecentRecipients() throws {
    let store = try contactsStore()
    let account = "me@example.com"
    try store.database.writer.write { db in
        try MailStore.upsertMessages(db, [
            MailMessage(accountId: account, id: "s1", threadId: "t1", date: Date(timeIntervalSince1970: 100),
                        fromEmail: account, toList: [Participant(name: "Old", email: "old@x.io")], labelIds: ["SENT"]),
            MailMessage(accountId: account, id: "s2", threadId: "t2", date: Date(timeIntervalSince1970: 200),
                        fromEmail: account, toList: [Participant(name: "New", email: "new@x.io")],
                        ccList: [Participant(email: "OLD@x.io"), Participant(email: account)], labelIds: ["SENT"]),
            MailMessage(accountId: account, id: "r1", threadId: "t3", date: Date(timeIntervalSince1970: 300),
                        fromEmail: "inbound@x.io", toList: [Participant(email: account)], labelIds: ["INBOX"]),
        ])
    }
    #expect(try store.suggestRecipients(prefix: " ").map(\.email) == ["new@x.io", "OLD@x.io"])
    #expect(try store.recentRecipients(limit: 1).map(\.name) == ["New"])
}
