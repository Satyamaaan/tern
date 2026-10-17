import Foundation
import GRDB
import Testing
import TernCore
@testable import TernSync

// Rule triage and project rules run inside every sync write.

extension Harness {
    func triage(_ threadId: String) throws -> ThreadAI? {
        try store.database.reader.read { db in try ThreadAI.fetchOne(db, key: ["accountId": testEmail, "threadId": threadId]) }
    }

    func projects(_ threadId: String) throws -> Set<String> {
        Set(try store.database.reader.read { db in
            try ThreadProject.filter(Column("accountId") == testEmail && Column("threadId") == threadId).fetchAll(db).map(\.projectId)
        })
    }

    func addProject(_ name: String, rule field: ProjectRule.Field, _ value: String) throws -> Project {
        let project = Project(name: name)
        try store.database.writer.write { db in
            try project.insert(db)
            var rule = ProjectRule(projectId: project.id, field: field, value: value)
            try rule.insert(db)
        }
        return project
    }
}

@Test func everySyncedThreadIsSortedAndJoinsItsProjects() async throws {
    let h = try Harness()
    let acme = try h.addProject("Acme", rule: .fromDomain, "acme.io")
    let person = await h.fake.deliver(FakeEmail(from: "Jo Park <jo@gmail.com>", subject: "Dinner", text: "Free tonight?",
                                                date: testNow.addingTimeInterval(-3600)))
    let bot = await h.fake.deliver(FakeEmail(from: "GitHub <notifications@github.com>", subject: "[tern] PR merged",
                                             text: "Merged #12", date: testNow.addingTimeInterval(-1800)))
    let client = await h.fake.deliver(FakeEmail(from: "Bob <bob@acme.io>", subject: "Contract", text: "Draft attached",
                                                date: testNow.addingTimeInterval(-600)))
    try await h.sync.initialSync()

    #expect(try h.triage(person.threadId)?.category == .people)
    #expect(try h.triage(bot.threadId)?.category == .notification)
    #expect(try h.triage(client.threadId) != nil)
    #expect(try h.projects(client.threadId) == [acme.id])
    #expect(try h.projects(person.threadId).isEmpty)

    // New mail through history is sorted in the same write that stores it.
    let followUp = await h.fake.deliver(FakeEmail(from: "Bob <bob@acme.io>", subject: "Invoice", text: "Due Friday",
                                                  date: testNow))
    try await h.sync.pollHistory()
    #expect(try h.triage(followUp.threadId) != nil)
    #expect(try h.projects(followUp.threadId) == [acme.id])
}

@Test func labelChangesAndDeletionsReachRulesToo() async throws {
    let h = try Harness()
    let label = try await h.fake.createLabel(name: "Clients")
    let flagged = try h.addProject("Flagged", rule: .label, "Clients")
    let message = await h.fake.deliver(FakeEmail(subject: "Hello", date: testNow.addingTimeInterval(-60)))
    try await h.sync.initialSync()
    #expect(try h.projects(message.threadId).isEmpty)

    // Labelled on the phone: history brings the label, the project rule follows.
    await h.fake.remoteModify([message.id], add: [label.id])
    try await h.sync.pollHistory()
    #expect(try h.projects(message.threadId) == [flagged.id])
    await h.fake.remoteModify([message.id], remove: [label.id])
    try await h.sync.pollHistory()
    #expect(try h.projects(message.threadId).isEmpty)

    // Deleted for good: the thread's triage row goes with it.
    #expect(try h.triage(message.threadId) != nil)
    await h.fake.remoteDelete([message.id])
    try await h.sync.pollHistory()
    #expect(try h.triage(message.threadId) == nil)
}

@Test func theFirstFillLearnsWhoTheUserWritesTo() async throws {
    let h = try Harness()
    // Bob writes from a company domain; on its own that doesn't look like a person.
    let bob = await h.fake.deliver(FakeEmail(from: "Bob Stone <bob@stone.studio>", subject: "Quick question",
                                             text: "Can you look at this?", date: testNow.addingTimeInterval(-3600)))
    // Last week the user wrote to Bob (another conversation).
    await h.fake.deliver(FakeEmail(from: "Me <\(testEmail)>", to: ["bob@stone.studio"], subject: "Intro",
                                   text: "Nice to meet you", date: testNow.addingTimeInterval(-7 * 86_400), labels: [SystemLabel.sent]))
    try await h.sync.initialSync()

    let contact = try await h.store.database.reader.read { db in try Contact.fetchOne(db, key: "bob@stone.studio") }
    #expect(contact?.sentCount == 1)
    #expect(try h.triage(bob.threadId)?.category == .people, "sorted again once the address book knew Bob")
}

@MainActor
@Test func dailyUpkeepExpiresNeedsReply() async throws {
    let store = try MailStore(AppDatabase.inMemory())
    let clock = EngineTestClock()
    try await store.database.writer.write { db in
        try Account(email: testEmail).insert(db)
        try MailStore.upsertMessages(db, [MailMessage(accountId: testEmail, id: "m1", threadId: "t1",
                                                      date: testNow.addingTimeInterval(-20 * 86_400), fromEmail: "jo@gmail.com",
                                                      subject: "Ping", labelIds: [SystemLabel.inbox])])
        try ThreadAI(accountId: testEmail, threadId: "t1", category: .people, needsReply: true, messageCount: 1).insert(db)
    }
    let coordinator = SyncCoordinator(store: store, accounts: [], apiProvider: { _ in FakeGmail(email: testEmail) },
                                      encodeDraft: testEncoder, configuration: .test(), clock: clock)
    await coordinator.runDailyUpkeep()
    let row = try await store.database.reader.read { db in try ThreadAI.fetchOne(db, key: ["accountId": testEmail, "threadId": "t1"]) }
    #expect(row?.needsReply == false)
}

@Test func labellingInTernAppliesLabelProjectRules() async throws {
    let h = try Harness()
    let label = try await h.fake.createLabel(name: "Clients")
    let clients = try h.addProject("Clients", rule: .label, "Clients")
    let message = await h.fake.deliver(FakeEmail(subject: "Proposal", date: testNow.addingTimeInterval(-60)))
    try await h.sync.initialSync()
    let key = h.thread(message.threadId)

    let token = try h.store.perform(.addLabel(label.id), on: [key])
    #expect(try h.projects(message.threadId) == [clients.id], "at once, not after Gmail echoes it")
    try h.store.undo(token)
    #expect(try h.projects(message.threadId).isEmpty)
}
