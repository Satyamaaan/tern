import Foundation
import GRDB
import Testing
@testable import TernCore

private let acme = Account(email: "alex@acme.com", displayName: "Acme", sortOrder: 0)
private let home = Account(email: "alex@home.net", displayName: "Home", sortOrder: 1)

private func mail(_ account: Account, _ id: String, from: (String, String), to: [(String, String)] = [], days: Double, sent: Bool = false) -> MailMessage {
    MailMessage(
        accountId: account.id, id: id, threadId: id, date: Date(timeIntervalSince1970: 1_790_000_000 - days * 86_400),
        fromName: from.0, fromEmail: from.1, toList: to.isEmpty ? [Participant(email: account.email)] : to.map { Participant(name: $0.0, email: $0.1) },
        subject: "Subject \(id)", snippet: "Body", bodyText: "Body", bodyState: .full, labelIds: sent ? ["SENT"] : ["INBOX"], isFromMe: sent)
}

private func makeSearch() throws -> SearchService {
    let store = MailStore(try AppDatabase.inMemory())
    try store.upsertAccount(acme)
    try store.upsertAccount(home)
    try store.replaceLabels(accountId: acme.id, with: [
        MailLabel(accountId: acme.id, id: "INBOX", name: "Inbox", type: "system"),
        MailLabel(accountId: acme.id, id: "Label_1", name: "Finance"),
        MailLabel(accountId: acme.id, id: "Label_2", name: "Client Work"),
        MailLabel(accountId: acme.id, id: "Label_3", name: "Hidden one", hidden: true),
    ])
    try store.replaceLabels(accountId: home.id, with: [
        MailLabel(accountId: home.id, id: "Label_9", name: "finance"),
        MailLabel(accountId: home.id, id: "Label_8", name: "Travel"),
    ])
    try store.upsertMessages([
        mail(acme, "a1", from: ("Maya Chen", "maya@northwind.studio"), days: 1),
        mail(acme, "a2", from: ("Maya Chen", "maya@northwind.studio"), days: 2),
        mail(acme, "a3", from: ("Mark Twain", "mark@books.org"), days: 3),
        mail(acme, "a4", from: ("Alex", acme.email), to: [("Maya Chen", "maya@northwind.studio"), ("Marco Polo", "marco@silk.road")], days: 4, sent: true),
        mail(acme, "a5", from: ("Alex", acme.email), to: [("Marco Polo", "marco@silk.road")], days: 5, sent: true),
        mail(acme, "a6", from: ("Alex", acme.email), to: [("Marco Polo", "marco@silk.road")], days: 6, sent: true),
        mail(home, "h1", from: ("Ben Turner", "ben@turner.law"), days: 7),
        mail(home, "h2", from: ("", "noreply@github.com"), days: 8),
    ])
    try store.database.writer.write { db in
        try Project(id: "p1", name: "Lumen redesign", sortOrder: 0).insert(db)
        try Project(id: "p2", name: "Home & travel", sortOrder: 1).insert(db)
    }
    try store.rebuildContacts()
    return SearchService(store.database)
}

@Test func contactsCompleteFromAndTo() throws {
    let search = try makeSearch()
    let from = try search.suggestions(for: "from:ma")
    #expect(from.map(\.kind).allSatisfy { $0 == .contact })
    #expect(Set(from.map(\.detail)) == ["maya@northwind.studio", "mark@books.org", "marco@silk.road"])
    #expect(from.first?.title == "Maya Chen")                           // writes to you most
    #expect(from.first?.completion == "from:maya@northwind.studio ")
    #expect(from.first?.runsImmediately == false)

    let to = try search.suggestions(for: "to:ma")
    #expect(to.first?.detail == "marco@silk.road")                     // you write to him most
    #expect(to.first?.completion == "to:marco@silk.road ")

    #expect(try search.suggestions(for: "from:chen").first?.detail == "maya@northwind.studio")   // any word of the name
    #expect(try search.suggestions(for: "from:turner.law").first?.title == "Ben Turner")         // the domain
    #expect(try search.suggestions(for: "from:github").first?.title == "noreply@github.com")      // no name: the address
    #expect(try search.suggestions(for: "from:zzz").isEmpty)
    #expect(try search.suggestions(for: "from:").count > 3)                                      // nothing typed yet: the usual people
}

@Test func suggestionsKeepEarlierTextAndNegation() throws {
    let search = try makeSearch()
    #expect(try search.suggestions(for: "invoice from:ben").first?.completion == "invoice from:ben@turner.law ")
    #expect(try search.suggestions(for: "invoice -from:ben").first?.completion == "invoice -from:ben@turner.law ")
    #expect(try search.suggestions(for: "(from:ben OR from:ma").first?.completion.hasPrefix("(from:ben OR from:ma") == true)
}

@Test func labelsCompleteByNameOnce() throws {
    let search = try makeSearch()
    let finance = try search.suggestions(for: "label:fin")
    #expect(finance.map(\.title) == ["Finance"])              // one row although two accounts have it
    #expect(finance.first?.completion == "label:Finance ")
    #expect(try search.suggestions(for: "label:client").first?.completion == "label:\"Client Work\" ")
    #expect(try search.suggestions(for: "label:client-w").first?.title == "Client Work")
    let all = try search.suggestions(for: "label:").map(\.title)
    #expect(all.contains("Finance") && all.contains("Travel") && all.contains("Client Work"))
    #expect(!all.contains("Inbox"))                            // system labels have operators of their own
    #expect(!all.contains("Hidden one"))
}

@Test func projectsCategoriesAccountsAndFlags() throws {
    let search = try makeSearch()
    #expect(try search.suggestions(for: "project:lu").first?.completion == "project:\"Lumen redesign\" ")
    #expect(try search.suggestions(for: "project:home").first?.completion == "project:\"Home & travel\" ")
    #expect(try search.suggestions(for: "project:").map(\.title) == ["Lumen redesign", "Home & travel"])

    #expect(try search.suggestions(for: "category:n").map(\.title) == ["Notification", "Newsletter"])
    #expect(try search.suggestions(for: "category:").count == MailCategory.allCases.count)
    #expect(try search.suggestions(for: "category:rec").first?.completion == "category:receipt ")

    let accounts = try search.suggestions(for: "account:")
    #expect(accounts.map(\.title) == ["Acme", "Home"])
    #expect(accounts.first?.detail == "alex@acme.com")
    #expect(try search.suggestions(for: "account:ho").first?.completion == "account:alex@home.net ")

    #expect(try search.suggestions(for: "is:un").map(\.title) == ["is:unread"])
    #expect(try search.suggestions(for: "in:t").map(\.title) == ["in:trash"])
    #expect(try search.suggestions(for: "has:").map(\.title) == ["has:attachment"])
}

@Test func operatorsCompleteFromAPlainWord() throws {
    let search = try makeSearch()
    let hints = try search.suggestions(for: "fro")
    #expect(hints.first?.kind == .operator)
    #expect(hints.first?.completion == "from:")
    #expect(try search.suggestions(for: "tacos is:s").map(\.completion).first == "tacos is:starred ")
    #expect(try search.suggestions(for: "tacos hi").isEmpty)
    #expect(try search.suggestions(for: "tacos in").map(\.title).contains("in:inbox"))
    #expect(try search.suggestions(for: "xyz").isEmpty)
}

@Test func limitIsHonoured() throws {
    let search = try makeSearch()
    #expect(try search.suggestions(for: "from:", limit: 2).count == 2)
    #expect(try search.suggestions(for: "is:", limit: 3).count == 3)
}

@Test func recentSearchesAreKeptNewestFirstWithoutDuplicates() throws {
    let search = try makeSearch()
    #expect(try search.recentSearches().isEmpty)
    #expect(try search.suggestions(for: "").isEmpty)

    try search.recordRecentSearch("from:maya invoice")
    try search.recordRecentSearch("  tacos  ")
    try search.recordRecentSearch("FROM:MAYA invoice")
    #expect(try search.recentSearches() == ["FROM:MAYA invoice", "tacos"])
    try search.recordRecentSearch("")
    try search.recordRecentSearch("   ")
    try search.recordRecentSearch("&&&")
    #expect(try search.recentSearches().count == 2)

    let none = try search.suggestions(for: "")
    #expect(none.map(\.title) == ["FROM:MAYA invoice", "tacos"])
    #expect(none.allSatisfy { $0.kind == .recent && $0.runsImmediately })
    #expect(try search.suggestions(for: "   ").count == 2)

    #expect(try search.suggestions(for: "ta").first?.completion == "tacos")
    #expect(try search.suggestions(for: "tacos").allSatisfy { $0.completion != "tacos" })   // already typed in full
    #expect(try search.suggestions(for: "from:m", limit: 8).first?.kind == .contact)
}

@Test func onlyTheLastTwentyRecentSearchesSurvive() throws {
    let search = try makeSearch()
    for number in 1...30 { try search.recordRecentSearch("search \(number)") }
    let recent = try search.recentSearches()
    #expect(recent.count == 20)
    #expect(recent.first == "search 30")
    #expect(recent.last == "search 11")
    try search.removeRecentSearch("SEARCH 30")
    #expect(try search.recentSearches().first == "search 29")
    try search.clearRecentSearches()
    #expect(try search.recentSearches().isEmpty)
}

@Test func recentSearchesSurviveInTheSettingTable() throws {
    let search = try makeSearch()
    try search.recordRecentSearch("lisbon")
    let stored = try MailStore(search.database).setting("search.recent")
    #expect(stored == "[\"lisbon\"]")
}

@Test func splittingTheLastWord() {
    func split(_ text: String) -> (String, String?, String, Bool) {
        let (head, word) = SearchService.splitLastWord(text)
        return (head, word.op, word.text, word.quoted)
    }
    #expect(split("") == ("", nil, "", false))
    #expect(split("abc") == ("", nil, "abc", false))
    #expect(split("abc de") == ("abc ", nil, "de", false))
    #expect(split("abc ") == ("abc ", nil, "", false))
    #expect(split("from:ma") == ("", "from", "ma", false))
    #expect(split("x from:") == ("x ", "from", "", false))
    #expect(split("x -from:ma") == ("x -", "from", "ma", false))
    #expect(split("label:\"Client W") == ("", "label", "Client W", true))
    #expect(split("subject:\"a b\" label:fi") == ("subject:\"a b\" ", "label", "fi", false))
    #expect(split("\"a b") == ("", nil, "a b", false))
    #expect(split("(from:ma") == ("(", "from", "ma", false))
    #expect(split("foo:bar") == ("", nil, "foo:bar", false))
}
