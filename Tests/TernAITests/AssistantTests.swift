import Foundation
import GRDB
import Testing
@testable import TernAI
import TernCore

private let thread = ThreadKey(accountId: me.id, threadId: "t1")

private func conversation() throws -> AppDatabase {
    let database = try makeDatabase([
        TestMail(id: "m1", thread: "t1", subject: "Offsite", body: "Should we book the cabin for March?", daysAgo: 3),
        TestMail(id: "m2", thread: "t1", from: me.email, to: "ethan.brooks@gmail.com", subject: "Re: Offsite",
                 body: "Hey Ethan — love it. Let me check dates.\n\nCheers,\nAlex", daysAgo: 2),
        TestMail(id: "m3", thread: "t1", subject: "Re: Offsite", body: "Any update? The cabin fills up fast.", daysAgo: 1),
        TestMail(id: "x1", thread: "t9", from: me.email, to: "ethan.brooks@gmail.com", subject: "Lunch",
                 body: "Hey Ethan — lunch Friday?\n\nCheers,\nAlex", daysAgo: 20),
    ], settings: AISettings(enabled: true, provider: "claude", model: "sonnet"))
    try database.writer.write { db in
        try MailLabel(accountId: me.id, id: "Label_1", name: "Clients").insert(db)
        try Project(id: "p1", name: "Lumen redesign").insert(db)
    }
    return database
}

@Test func summariesAreCachedUntilTheThreadGrows() async throws {
    let database = try conversation()
    let provider = FakeProvider(id: "claude") { _, index in
        #"{"bullets":["- Ethan proposes booking the cabin for March.","Waiting on your dates (\#(index))",""]}"#
    }
    let assistant = MailAssistant(database: database, providers: AIProviders([provider]), now: { testNow })
    let bullets = try await assistant.summarize(thread: thread)
    #expect(bullets == ["Ethan proposes booking the cabin for March.", "Waiting on your dates (1)"])
    #expect(try await assistant.summarize(thread: thread) == bullets)
    #expect(provider.requests.count == 1)
    #expect(provider.requests[0].model == "sonnet")
    #expect(provider.requests[0].input.contains("Should we book the cabin"))

    try MailStore(database).upsertMessages([MailMessage(
        accountId: me.id, id: "m4", threadId: "t1", date: testNow, fromName: "Ethan", fromEmail: "ethan.brooks@gmail.com",
        toList: [Participant(email: me.email)], subject: "Re: Offsite", snippet: "Booked!", bodyText: "Booked!",
        bodyState: .full, labelIds: [SystemLabel.inbox])])
    #expect(try await assistant.summarize(thread: thread).last == "Waiting on your dates (2)")
}

@Test func replySuggestionsAreShortAndUseOwnVoice() async throws {
    let database = try conversation()
    let provider = FakeProvider(id: "claude") { _, _ in
        #"{"replies":["Yes — book it, March works great for the whole team and me too honestly","Not yet, checking dates","Which weekend?","extra"]}"#
    }
    let assistant = MailAssistant(database: database, providers: AIProviders([provider]))
    let replies = try await assistant.suggestReplies(thread: thread)
    #expect(replies.count == 3)
    #expect(replies.allSatisfy { $0.split(separator: " ").count <= 12 })
    #expect(replies[1] == "Not yet, checking dates")
    let input = try #require(provider.requests.first?.input)
    #expect(input.contains("<sample>\nHey Ethan — love it."))
}

@Test func draftReplyIsHTMLInTheOwnersVoice() async throws {
    let database = try conversation()
    let provider = FakeProvider(id: "claude") { _, _ in
        #"{"body":"Hey Ethan — yes, book it for the 14th.\n\nCheers,\nAlex <3"}"#
    }
    let assistant = MailAssistant(database: database, providers: AIProviders([provider]))
    let html = try await assistant.draftReply(thread: thread, instruction: "say yes, the 14th")
    #expect(html == "<div dir=\"ltr\"><div>Hey Ethan — yes, book it for the 14th.</div><div><br></div><div>Cheers,</div><div>Alex &lt;3</div></div>")

    let request = try #require(provider.requests.first)
    #expect(request.effort == .careful)
    #expect(request.input.contains("Owner's instruction: say yes, the 14th"))
    #expect(request.input.contains("Owner's name: Alex Morgan"))
    // Own messages from this thread first, then other mail to the same person.
    let samples = request.input.components(separatedBy: "<sample>").dropFirst().map { $0.components(separatedBy: "</sample>")[0] }
    #expect(samples.count == 2)
    #expect(samples[0].contains("Let me check dates") && samples[1].contains("lunch Friday"))
    #expect(!request.instructions.contains("14th") && !request.instructions.contains("cabin"))
}

@Test func naturalLanguageBecomesSearchQuery() async throws {
    let database = try conversation()
    let provider = FakeProvider(id: "claude") { _, _ in "```json\n{\"query\": \"from:ethan has:attachment\\nnewer_than:1m\"}\n```" }
    let assistant = MailAssistant(database: database, providers: AIProviders([provider]), now: { testNow })
    #expect(try await assistant.naturalLanguageToQuery("attachments ethan sent me this month") == "from:ethan has:attachment newer_than:1m")
    let request = try #require(provider.requests.first)
    #expect(request.input.contains("Accounts: \(me.email)"))
    #expect(request.input.contains("Labels: Clients"))
    #expect(request.input.contains("Projects: Lumen redesign"))
    #expect(request.input.contains("Today: 2027-01-15"))
    #expect(request.instructions.contains("newer_than:") && request.instructions.contains("category:"))
}

@Test func assistantRespectsTheMasterSwitch() async throws {
    let database = try makeDatabase([TestMail(id: "a", thread: "t1")], settings: AISettings(enabled: false))
    let provider = FakeProvider { _, _ in "{}" }
    let assistant = MailAssistant(database: database, providers: AIProviders([provider]))
    await #expect(throws: AIError.disabled) { try await assistant.summarize(thread: thread) }
    await #expect(throws: AIError.disabled) { try await assistant.naturalLanguageToQuery("x") }
    #expect(provider.requests.isEmpty)
}
