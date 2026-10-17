import Foundation
import GRDB
import Testing
@testable import TernCore

private let work = Account(email: "alex@northwind.studio", displayName: "Northwind")
private let home = Account(email: "alex.morgan@gmail.com", displayName: "Personal", sortOrder: 1)

private func message(_ id: String, thread: String, account: Account = work, from: String, to: [String] = [],
                     subject: String, body: String = "", labels: [String] = [SystemLabel.inbox]) -> MailMessage {
    MailMessage(
        accountId: account.id, id: id, threadId: thread, date: Date(timeIntervalSince1970: 1_000),
        fromEmail: from, toList: (to.isEmpty ? [account.email] : to).map { Participant(email: $0) },
        subject: subject, snippet: body, bodyText: body, bodyState: .full, labelIds: labels,
        isFromMe: from == account.email)
}

private func makeStore() throws -> MailStore {
    let store = MailStore(try AppDatabase.inMemory())
    try store.upsertAccount(work)
    try store.upsertAccount(home)
    try store.replaceLabels(accountId: work.id, with: [MailLabel(accountId: work.id, id: "Label_7", name: "Clients")])
    try store.replaceLabels(accountId: home.id, with: [MailLabel(accountId: home.id, id: "Label_2", name: "Travel")])
    try store.upsertMessages([
        message("m1", thread: "acme", from: "sofia@mail.acme.com", subject: "Kickoff notes"),
        message("m2", thread: "lisbon", account: home, from: "tap@flytap.com", subject: "Your Lisbon flight", labels: ["INBOX", "Label_2"]),
        message("m3", thread: "client", from: "grace@brightpath.co", subject: "Brief", labels: ["INBOX", "Label_7"]),
        message("m4", thread: "outbound", from: work.email, to: ["omar@harbor.dev"], subject: "Proposal", body: "The zeppelin budget"),
        message("m5", thread: "redesign", from: "tom@brightpath.co", subject: "The Lúmen Redesign"),
    ])
    return store
}

private func links(_ store: MailStore, _ projectId: String) throws -> [String: ThreadProject.Source] {
    try store.database.reader.read { db in
        Dictionary(uniqueKeysWithValues: try ThreadProject.filter(Column("projectId") == projectId).fetchAll(db).map { ($0.threadId, $0.source) })
    }
}

@Test func rulesMatchByEveryField() throws {
    let store = try makeStore()
    let projects = ProjectStore(store.database)
    let cases: [(ProjectRule.Field, String, Set<String>)] = [
        (.fromDomain, "acme.com", ["acme"]),
        (.from, "Grace@Brightpath.co", ["client"]),
        (.to, "harbor.dev", ["outbound"]),
        (.to, "omar@harbor.dev", ["outbound"]),
        (.subjectContains, "lumen", ["redesign"]),
        (.label, "Clients", ["client"]),
        (.label, "Label_2", ["lisbon"]),
        (.account, "Personal", ["lisbon"]),
        (.account, "alex.morgan@gmail.com", ["lisbon"]),
        (.query, "zeppelin budget", ["outbound"]),
        (.label, "No such label", []),
    ]
    for (field, value, expected) in cases {
        let project = try projects.create(name: "\(field) \(value)")
        try projects.addRule(projectId: project.id, field: field, value: value)
        #expect(Set(try links(store, project.id).keys) == expected, "\(field) \(value)")
    }
}

@Test func applyFollowsThreadChangesAndKeepsManualRows() throws {
    let store = try makeStore()
    let projects = ProjectStore(store.database)
    let acme = try projects.create(name: "Acme")
    try projects.addRule(projectId: acme.id, field: .subjectContains, value: "kickoff")
    try projects.assign([ThreadKey(accountId: work.id, threadId: "client")], to: acme.id)
    #expect(try links(store, acme.id) == ["acme": .rule, "client": .manual])

    // A new thread arrives; sync applies rules to the threads it touched.
    try store.upsertMessages([message("m6", thread: "late", from: "x@y.com", subject: "Kickoff follow-up")])
    let changes = try store.database.writer.write { db in
        try ProjectRules.apply(db, keys: [ThreadKey(accountId: work.id, threadId: "late"), ThreadKey(accountId: work.id, threadId: "client")])
    }
    #expect(changes == ProjectRules.Changes(added: 1, removed: 0))
    #expect(try links(store, acme.id) == ["acme": .rule, "client": .manual, "late": .rule])

    // An AI suggestion becomes a rule row once a rule matches it.
    try store.database.writer.write { db in
        try ThreadProject(accountId: work.id, threadId: "redesign", projectId: acme.id, source: .ai).insert(db)
    }
    let rule = try projects.addRule(projectId: acme.id, field: .from, value: "tom@brightpath.co")
    #expect(try links(store, acme.id)["redesign"] == .rule)

    // Removing rules drops their rows but never manual ones.
    try projects.removeRule(id: try #require(rule.id))
    for remaining in try projects.rules(projectId: acme.id) { try projects.removeRule(id: try #require(remaining.id)) }
    #expect(try links(store, acme.id) == ["client": .manual])
}

@Test func updatingARuleRecomputes() throws {
    let store = try makeStore()
    let projects = ProjectStore(store.database)
    let project = try projects.create(name: "Clients")
    var rule = try projects.addRule(projectId: project.id, field: .fromDomain, value: "acme.com")
    #expect(Set(try links(store, project.id).keys) == ["acme"])
    rule.value = "brightpath.co"
    try projects.updateRule(rule)
    #expect(Set(try links(store, project.id).keys) == ["client", "redesign"])
    #expect(try store.database.reader.read { db in try ProjectRules.matchingProjects(db, key: ThreadKey(accountId: work.id, threadId: "client")) } == [project.id])
}

@Test func projectCrud() throws {
    let store = try makeStore()
    let projects = ProjectStore(store.database)
    let a = try projects.create(name: "A")
    let b = try projects.create(name: "B", colorIndex: 2, icon: "star")
    let c = try projects.create(name: "C")
    #expect([a.sortOrder, b.sortOrder, c.sortOrder] as [Int] == [0, 1, 2])

    try projects.rename(a.id, to: "Alpha")
    try projects.recolor(a.id, colorIndex: 5)
    try projects.setIcon(a.id, icon: "🚀")
    try projects.reorder([c.id, a.id])
    #expect(try store.projects().map(\.name) == ["C", "Alpha", "B"])
    let alpha = try #require(try store.projects().first { $0.id == a.id })
    #expect(alpha.colorIndex == 5 && alpha.icon == "🚀")

    try projects.addRule(projectId: a.id, field: .fromDomain, value: "acme.com")
    try projects.assign([ThreadKey(accountId: work.id, threadId: "client")], to: a.id)
    try store.database.writer.write { db in
        try ThreadProject(accountId: home.id, threadId: "lisbon", projectId: b.id, source: .ai).insert(db)
    }
    try projects.removeAIAssignments()
    #expect(try links(store, b.id).isEmpty)

    try projects.unassign([ThreadKey(accountId: work.id, threadId: "client")], from: a.id)
    #expect(try links(store, a.id) == ["acme": .rule])
    try projects.delete(a.id)
    #expect(try store.database.reader.read { db in try ThreadProject.fetchCount(db) + ProjectRule.fetchCount(db) } == 0)
}

@Test func fakeMailboxRecomputeMatchesGenerator() throws {
    let database = try AppDatabase.inMemory()
    try FakeMailbox.populate(database, options: .init(messages: 3_000))
    let before = try database.reader.read { db in Set(try ThreadProject.fetchAll(db)) }
    let started = Date()
    let changes = try database.writer.write { db in
        try db.execute(sql: "DELETE FROM thread_project")
        return try ProjectRules.recomputeAll(db)
    }
    #expect(Date().timeIntervalSince(started) < 2)
    #expect(changes.added == before.count)
    #expect(try database.reader.read { db in Set(try ThreadProject.fetchAll(db)) } == before)
}
