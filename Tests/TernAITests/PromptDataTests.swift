import Foundation
import GRDB
import Testing
@testable import TernAI
import TernCore

private func mail(_ id: String, thread: String, hoursAgo: Double, draft: Bool = false) -> MailMessage {
    MailMessage(
        accountId: me.id, id: id, threadId: thread, date: testNow.addingTimeInterval(-hoursAgo * 3_600),
        fromName: "Ethan Brooks", fromEmail: "ethan.brooks@gmail.com", toList: [Participant(email: me.email)],
        subject: "Plans", snippet: "Note \(id)", bodyText: "Note \(id)", bodyState: .full,
        labelIds: draft ? [SystemLabel.draft] : [SystemLabel.inbox])
}

private func mailbox() throws -> AppDatabase {
    let database = try makeDatabase([])
    try MailStore(database).upsertMessages([
        mail("a1", thread: "a", hoursAgo: 50), mail("a2", thread: "a", hoursAgo: 40), mail("a3", thread: "a", hoursAgo: 30),
        mail("a4", thread: "a", hoursAgo: 20), mail("a5", thread: "a", hoursAgo: 1, draft: true),
        mail("b1", thread: "b", hoursAgo: 10),
        mail("c1", thread: "c", hoursAgo: 5, draft: true),
    ])
    return database
}

private func key(_ thread: String) -> ThreadKey { ThreadKey(accountId: me.id, threadId: thread) }

@Test func promptThreadsKeepTheLatestMessagesOldestFirstWithoutDrafts() throws {
    let database = try mailbox()
    let threads = try database.reader.read { db in
        try PromptData.threads(db, keys: [key("b"), key("a"), key("c"), key("missing"), key("a")], messages: 2, characters: 200)
    }
    #expect(threads.map(\.key.threadId) == ["b", "a", "a"])
    #expect(threads[0].messages.map(\.text) == ["Note b1"])
    #expect(threads[1].messages.map(\.text) == ["Note a3", "Note a4"])
    #expect(threads[1].messageCount == 4)
}

@Test func promptThreadsWithAZeroLimitHaveNothingToPrompt() throws {
    let database = try mailbox()
    #expect(try database.reader.read { db in try PromptData.threads(db, keys: [key("a")], messages: 0, characters: 200) }.isEmpty)
}

@Test func promptMessageCountMatchesWhatThreadsReturn() throws {
    let database = try mailbox()
    let counts = try database.reader.read { db in
        try ["a", "b", "c", "missing"].map { try PromptData.messageCount(db, key: key($0)) }
    }
    #expect(counts == [4, 1, nil, nil])
}

@Test func cachedSummaryStillFailsOnceTheThreadIsGone() async throws {
    let database = try mailbox()
    let provider = FakeProvider(id: "codex") { _, _ in #"{"bullets":["Ethan wants to plan."]}"# }
    let assistant = MailAssistant(database: database, providers: AIProviders([provider]), now: { testNow })
    #expect(try await assistant.summarize(thread: key("a")) == ["Ethan wants to plan."])
    #expect(try await assistant.summarize(thread: key("a")) == ["Ethan wants to plan."])
    #expect(provider.requests.count == 1)

    try await database.writer.write { db in
        try db.execute(sql: "DELETE FROM message WHERE threadId = 'a'")
        try db.execute(sql: "DELETE FROM thread WHERE id = 'a'")
    }
    await #expect(throws: AIError.self) { try await assistant.summarize(thread: key("a")) }
}
