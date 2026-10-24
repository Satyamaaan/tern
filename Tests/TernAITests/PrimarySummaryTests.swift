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
            TestMail(id: "boundary", thread: "boundary", daysAgo: 30, labels: []),
            TestMail(id: "tooOld", thread: "tooOld", daysAgo: 40, labels: []),
            TestMail(id: "promo", thread: "promo", daysAgo: 0, labels: [SystemLabel.inbox, SystemLabel.categoryPromotions]),
            TestMail(id: "trash", thread: "trash", daysAgo: 0, labels: [SystemLabel.inbox, SystemLabel.trash]),
            TestMail(id: "spam", thread: "spam", daysAgo: 0, labels: [SystemLabel.inbox, SystemLabel.spam]),
            TestMail(id: "draft", thread: "draft", daysAgo: 0, labels: [SystemLabel.inbox, "DRAFT"]),
            TestMail(id: "pendingMute", thread: "pendingMute", daysAgo: 0, labels: [SystemLabel.inbox, "TERN_PENDING_MUTED"]),
            TestMail(id: "muted", thread: "muted", daysAgo: 0, labels: [SystemLabel.inbox, "CustomMute"]),
            TestMail(id: "bulk", thread: "bulk", daysAgo: 0)
        ])
        try db.writer.write {
            try $0.execute(sql: "UPDATE message SET listUnsubscribe='synthetic' WHERE id='bulk'")
            try Setting(key: "mute.label.\(me.id)", value: "CustomMute").upsert($0)
        }
        let keys = try db.reader.read { try PrimarySummaryQueue.candidates($0, now: testNow, limit: 20) }
        #expect(keys.map(\.threadId) == ["new", "archive", "boundary", "old"])
        try db.reader.read { db in
            for id in ["new", "archive", "boundary", "old", "tooOld", "promo", "trash", "spam", "draft", "pendingMute", "muted", "bulk"] {
                let key = ThreadKey(accountId: me.id, threadId: id)
                let actual = try PrimarySummaryQueue.candidates(db, now: testNow, key: key)
                let expected = ["new", "archive", "boundary", "old"].contains(id) ? [key] : []
                #expect(actual == expected)
            }
        }
    }

    @Test func candidateLabelProbesUseTheWholePrimaryKey() throws {
        let database = try makeDatabase([])
        try database.writer.write { db in
            try Setting(key: "mute.label." + me.id, value: "muted").upsert(db)
            var sql: String?
            db.trace(options: .statement) { event in
                if case .statement(let statement) = event, statement.sql.contains("SELECT t.accountId,t.id") {
                    sql = statement.sql
                }
            }
            _ = try PrimarySummaryQueue.candidates(db, now: testNow)
            db.trace(options: .statement, nil)
            let query = try #require(sql)
            let arguments = StatementArguments(Array(repeating: "x", count: query.filter { $0 == "?" }.count))
            let plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(query)", arguments: arguments)
                .map { $0["detail"] as String }
            let probes = plan.filter { $0.contains("SEARCH x ") }
            #expect(!probes.isEmpty, "\(plan)")
            #expect(probes.allSatisfy { $0.contains("accountId=? AND labelId=? AND threadId=?") }, "\(probes)")
        }
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

    @Test func discoveryDoesNotBlockMailWrites() async throws {
        let gate = SummaryDiscoveryGate()
        let (db, directory) = try pooledDatabase(gate: gate)
        defer { gate.release(); try? FileManager.default.removeItem(at: directory) }
        let provider = FakeProvider { _, _ in #"{"bullets":["Hello"]}"# }
        let providers = AIProviders([provider])
        let queue = PrimarySummaryQueue(database: db, assistant: MailAssistant(database: db, providers: providers),
                                        providers: providers, now: { testNow })
        let work = Task { try await queue.processNext() }
        for _ in 0..<200 where !gate.entered { try await Task.sleep(for: .milliseconds(10)) }
        try #require(gate.entered)

        let written = TestState()
        let write = Task {
            try await db.writer.write { try Setting(key: "test.foreground", value: "saved").upsert($0) }
            written.isOn = true
        }
        for _ in 0..<200 where !written.isOn { try await Task.sleep(for: .milliseconds(10)) }
        #expect(written.isOn, "An unrelated write must finish while summary discovery is paused")
        gate.release()
        try await write.value
        #expect(try await work.value)
    }

    @Test(arguments: ["ai.autoPrimarySummaries", "ai.summary.day", "ai.enabled", "muted"])
    func claimRechecksChangesAfterDiscovery(_ change: String) async throws {
        let gate = SummaryDiscoveryGate()
        let (db, directory) = try pooledDatabase(gate: gate)
        defer { gate.release(); try? FileManager.default.removeItem(at: directory) }
        let provider = FakeProvider { _, _ in #"{"bullets":["Hello"]}"# }
        let providers = AIProviders([provider])
        let queue = PrimarySummaryQueue(database: db, assistant: MailAssistant(database: db, providers: providers),
                                        providers: providers, dailyLimit: 1, now: { testNow })
        let work = Task { try await queue.processNext() }
        for _ in 0..<200 where !gate.entered { try await Task.sleep(for: .milliseconds(10)) }
        try #require(gate.entered)
        try await db.writer.write { db in
            switch change {
            case "ai.summary.day":
                try Setting(key: change, value: "\(LedgerQueue.day(testNow)):1").upsert(db)
            case "muted":
                try Setting(key: "mute.label.\(me.id)", value: "CustomMute").upsert(db)
                try MailStore.setLabels(db, accountId: me.id, ["m": [SystemLabel.inbox, "CustomMute"]])
            default:
                try Setting(key: change, value: "false").upsert(db)
            }
        }
        gate.release()
        #expect(try await work.value == false)
        #expect(provider.requests.isEmpty)
        let allowance = try await db.reader.read { try Setting.fetchOne($0, key: "ai.summary.day")?.value }
        #expect(allowance == (change == "ai.summary.day" ? "\(LedgerQueue.day(testNow)):1" : nil))
    }

    @Test(arguments: ["foreground", "stop", "caller"])
    func discoveryCanBeCancelledBeforeReservingAllowance(_ cancellation: String) async throws {
        let gate = SummaryDiscoveryGate()
        let (db, directory) = try pooledDatabase(gate: gate)
        defer { gate.release(); try? FileManager.default.removeItem(at: directory) }
        let provider = FakeProvider { _, _ in #"{"bullets":["Hello"]}"# }
        let providers = AIProviders([provider])
        let queue = PrimarySummaryQueue(database: db, assistant: MailAssistant(database: db, providers: providers),
                                        providers: providers, now: { testNow })
        let work = Task { try await queue.processNext() }
        for _ in 0..<200 where !gate.entered { try await Task.sleep(for: .milliseconds(10)) }
        try #require(gate.entered)
        switch cancellation {
        case "foreground": await queue.yieldToForeground()
        case "stop": await queue.stop()
        default: work.cancel()
        }
        gate.release()
        do { _ = try await work.value; Issue.record("Cancelled discovery was accepted") }
        catch is CancellationError { }
        #expect(provider.requests.isEmpty)
        #expect(try await db.reader.read { try Setting.fetchOne($0, key: "ai.summary.day") } == nil)
    }

    private func pooledDatabase(gate: SummaryDiscoveryGate) throws -> (AppDatabase, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tern-summary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            db.trace(options: .profile) { event in
                if case .profile(let statement, _) = event, statement.sql.contains("LEFT JOIN thread_summary sm") {
                    gate.pause()
                }
            }
        }
        let database = try AppDatabase(DatabasePool(path: directory.appendingPathComponent("mail.sqlite").path, configuration: config))
        let store = MailStore(database)
        try store.upsertAccount(me)
        try store.upsertMessages([MailMessage(accountId: me.id, id: "m", threadId: "t", date: testNow,
            fromEmail: "person@example.com", subject: "Hello", bodyText: "Hello", labelIds: [SystemLabel.inbox])])
        try database.writer.write { try AISettings(enabled: true, provider: "codex").write($0) }
        return (database, directory)
    }

    @Test func extractionCuesIncludeQuestionsAndPoliteRequests() {
        #expect(CommitmentCues.contains("Would Thursday work?"))
        #expect(CommitmentCues.contains("Please confirm the revised schedule."))
        #expect(!CommitmentCues.contains("Thanks, sounds good."))
        #expect(!CommitmentCues.contains("Thanks\n> Can you send the deck?"))
    }
}

/// Holds the first discovery after SQL selection, before its transaction returns to the queue.
private final class SummaryDiscoveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private let resume = DispatchSemaphore(value: 0)
    private var paused = false

    var entered: Bool { lock.withLock { paused } }

    func pause() {
        let first = lock.withLock { () -> Bool in
            guard !paused else { return false }
            paused = true
            return true
        }
        if first { _ = resume.wait(timeout: .now() + 10) }
    }

    func release() { resume.signal() }
}
