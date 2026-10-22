import Foundation
import GRDB
import Testing
@testable import TernAI
import TernCore

struct PrimarySummaryTests {
    @Test func selectionUsesPrimaryNewestWindowAndBulkExclusion() throws {
        let db = try makeDatabase([
            TestMail(id: "old", thread: "old", daysAgo: 90),
            TestMail(id: "new", thread: "new", daysAgo: 1),
            TestMail(id: "archive", thread: "archive", daysAgo: 10, labels: []),
            TestMail(id: "tooOld", thread: "tooOld", daysAgo: 40, labels: []),
            TestMail(id: "promo", thread: "promo", daysAgo: 0, labels: [SystemLabel.inbox, SystemLabel.categoryPromotions]),
            TestMail(id: "bulk", thread: "bulk", daysAgo: 0)
        ])
        try db.writer.write { try $0.execute(sql: "UPDATE message SET listUnsubscribe='synthetic' WHERE id='bulk'") }
        let keys = try db.reader.read { try PrimarySummaryQueue.candidates($0, now: testNow, limit: 20) }
        #expect(keys.map(\.threadId) == ["new", "archive", "old"])
    }

    @Test func capPersistenceResummaryAndDisabled() async throws {
        let db = try makeDatabase([TestMail(id: "m", thread: "t")])
        let provider = FakeProvider { _, index in #"{"bullets":["Summary \#(index)"]}"# }
        let providers = AIProviders([provider])
        let assistant = MailAssistant(database: db, providers: providers)
        let queue = PrimarySummaryQueue(database: db, assistant: assistant, providers: providers, dailyLimit: 1, now: { testNow })
        #expect(try await queue.processNext())
        #expect(provider.requests.first?.isBackground == true)
        #expect(try MailStore(db).threadRows(in: .unifiedInbox).first?.summary == "Summary 1")
        let freshAssistant = MailAssistant(database: db, providers: providers)
        #expect(try await freshAssistant.summarize(thread: ThreadKey(accountId: me.id, threadId: "t")) == ["Summary 1"])
        #expect(provider.requests.count == 1)
        try MailStore(db).upsertMessages([MailMessage(accountId: me.id, id: "m2", threadId: "t", date: testNow, fromEmail: "person@example.com", subject: "Update", snippet: "New message", bodyText: "New message", labelIds: [SystemLabel.inbox])])
        #expect(try await db.reader.read { try PrimarySummaryQueue.candidates($0, now: testNow).count } == 1)
        #expect(try await queue.processNext() == false)
        let nextDay = PrimarySummaryQueue(database: db, assistant: assistant, providers: providers, now: { testNow.addingTimeInterval(86_400) })
        #expect(try await nextDay.processNext())
        #expect(provider.requests.count == 2)
        try await db.writer.write { try AISettings(enabled: false).write($0); try $0.execute(sql: "DELETE FROM thread_summary") }
        #expect(try await nextDay.processNext() == false)
        #expect(provider.requests.count == 2)
    }

    @Test func toggleAndTriagePreventCalls() async throws {
        let db = try makeDatabase([TestMail(id: "m", thread: "t")])
        let provider = FakeProvider { _, _ in #"{"bullets":["Hello"]}"# }
        let providers = AIProviders([provider])
        let assistant = MailAssistant(database: db, providers: providers)
        let queue = PrimarySummaryQueue(database: db, assistant: assistant, providers: providers, now: { testNow }, idle: { false })
        #expect(try await queue.processNext() == false)
        try await db.writer.write { try Setting(key: "ai.autoPrimarySummaries", value: "false").upsert($0) }
        let enabled = PrimarySummaryQueue(database: db, assistant: assistant, providers: providers, now: { testNow })
        #expect(try await enabled.processNext() == false)
        #expect(provider.requests.isEmpty)
    }

    @Test func ledgerRescansOldCueSkipsAndIncludesOlderPrimary() async throws {
        let db = try makeDatabase([TestMail(id: "m", thread: "t", body: "Please confirm the revised schedule.", daysAgo: 22,
            labels: [SystemLabel.inbox, SystemLabel.categoryPersonal])])
        try await db.writer.write { db in
            try ThreadAI(accountId: me.id, threadId: "t", category: .notification, needsReply: false,
                priority: 1, source: "rules", messageCount: 1, classifiedAt: testNow).upsert(db)
            try Ledger.recordScan(db, key: ThreadKey(accountId: me.id, threadId: "t"), messageCount: 1, promptVersion: 2, origin: "cue-skip", now: testNow)
        }
        let provider = FakeProvider { _, _ in "{\"items\":[]}" }
        let queue = LedgerQueue(database: db, providers: AIProviders([provider]), now: { testNow })
        _ = try? await queue.processBatch()
        #expect(provider.requests.count == 1)
        #expect(provider.requests.first?.input.contains("Please confirm") == true)
    }

    @Test func foregroundWorkCancelsAndRefundsBackgroundSummary() async throws {
        let db = try makeDatabase([TestMail(id: "m", thread: "t")])
        let latch = Latch()
        let provider = FakeProvider { _, _ in
            await latch.wait()
            if Task.isCancelled { throw URLError(.cancelled) }
            return "{\"bullets\":[\"A synthetic summary\"]}"
        }
        let providers = AIProviders([provider])
        let assistant = MailAssistant(database: db, providers: providers)
        let queue = PrimarySummaryQueue(database: db, assistant: assistant, providers: providers, dailyLimit: 1, now: { testNow })
        let work = Task { try await queue.processNext() }
        for _ in 0..<100 where provider.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(provider.requests.count == 1)
        await queue.yieldToForeground()
        await latch.release()
        do { _ = try await work.value; Issue.record("Cancelled summary was accepted") }
        catch is CancellationError { }
        #expect(try MailStore(db).threadRows(in: .unifiedInbox).first?.summary == nil)
        #expect(try await queue.processNext())
        #expect(provider.requests.count == 2)
    }

    @Test func extractionCuesIncludeQuestionsAndPoliteRequests() {
        #expect(CommitmentCues.contains("Would Thursday work?"))
        #expect(CommitmentCues.contains("Please confirm the revised schedule."))
        #expect(!CommitmentCues.contains("Thanks, sounds good."))
        #expect(!CommitmentCues.contains("Thanks\n> Can you send the deck?"))
    }
}
