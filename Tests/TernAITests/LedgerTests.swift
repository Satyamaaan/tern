import Foundation
import GRDB
import Testing
@testable import TernAI
import TernCore

private func ledgerAnswer(_ request: AIRequest, direction: String = "owe", quote: String = "I'll send the revised deck by Thursday.", deliverable: String = "Send revised deck", messageRef: String = "t1.m1", counterparty: String = "ethan.brooks@gmail.com", due: String = "2027-01-21", confidence: String = "high") -> String {
    let refs = request.input.components(separatedBy: "\n").filter { $0.hasPrefix("<thread ref=") }.compactMap { $0.split(separator: "\"").dropFirst().first.map(String.init) }
    let threads: [[String: Any]] = refs.map { ref in
        ["threadRef": ref, "items": [["direction": direction, "counterparty": counterparty, "deliverable": deliverable,
            "dueDate": due, "dueText": "Thursday", "messageRef": messageRef == "t1.m1" ? "\(ref).m1" : messageRef,
            "quote": quote, "confidence": confidence, "existingRef": NSNull()]], "updates": []]
    }
    return String(data: try! JSONSerialization.data(withJSONObject: ["threads": threads]), encoding: .utf8)!
}

private func promises(_ count: Int = 1) throws -> AppDatabase {
    try makeDatabase((0..<count).map { TestMail(id: "m\($0)", thread: "t\($0)", from: me.email, to: "ethan.brooks@gmail.com", body: "I'll send the revised deck by Thursday.", daysAgo: 4) })
}

struct LedgerTests {
    @Test func strictSchemaAndUntrustedMail() throws {
        let db = try promises()
        let threads = try db.reader.read { try PromptData.threads($0, keys: [ThreadKey(accountId: me.id, threadId: "t0")], messages: 4, characters: 700) }
        let request = Prompts.ledger(threads, open: [:], owner: [me.email], today: testNow)
        #expect(!request.instructions.contains("revised deck"))
        #expect(request.input.contains("ref=\"t1.m1\""))
        #expect(threads[0].messages[0].id == "m0")
        #expect(request.isBackground)
        func walk(_ node: Any) throws {
            if let object = node as? [String: Any] {
                if object["type"] as? String == "object" {
                    #expect(object["additionalProperties"] as? Bool == false)
                    let properties = try #require(object["properties"] as? [String: Any])
                    #expect(Set(object["required"] as? [String] ?? []) == Set(properties.keys))
                }
                for value in object.values { try walk(value) }
            } else if let array = node as? [Any] { for value in array { try walk(value) } }
        }
        try walk(JSONSerialization.jsonObject(with: Data(Prompts.ledgerSchema.utf8)))
    }

    @Test(arguments: ["ref", "quote", "counterparty", "direction", "url", "own"])
    func invalidEvidenceIsDropped(_ defect: String) async throws {
        let db = try promises()
        let provider = FakeProvider { request, _ in
            ledgerAnswer(request, direction: defect == "direction" ? "waiting" : "owe",
                quote: defect == "quote" ? "I'll send the secret invoice tomorrow." : "I'll send the revised deck by Thursday.",
                deliverable: defect == "url" ? "Send https://example.com" : "Send revised deck",
                messageRef: defect == "ref" ? "t99.m1" : "t1.m1",
                counterparty: defect == "counterparty" ? "outsider@example.com" : defect == "own" ? me.email : "ethan.brooks@gmail.com")
        }
        let queue = LedgerQueue(database: db, providers: AIProviders([provider]), now: { testNow })
        _ = try await queue.processBatch()
        #expect(try await db.reader.read { try Commitment.filter(Column("origin") != "rule").fetchCount($0) } == 0)
        #expect(try await db.reader.read { try LedgerScan.fetchCount($0) } == 1)
    }

    @Test func dateBoundsAndMedium() async throws {
        let db = try promises()
        let provider = FakeProvider { request, _ in ledgerAnswer(request, due: "2099-01-01", confidence: "medium") }
        _ = try await LedgerQueue(database: db, providers: AIProviders([provider]), now: { testNow }).processBatch()
        let item = try #require(await db.reader.read { try Commitment.fetchOne($0) })
        #expect(item.dueAt == nil)
        #expect(item.dueText == "Thursday")
        #expect(item.confidence == 1)
        #expect(try MailStore(db).threadRows(in: Mailbox(.iOwe)).isEmpty)
        try await db.writer.write { try Setting(key: "ledger.showMaybe", value: "true").upsert($0) }
        #expect(try MailStore(db).threadRows(in: Mailbox(.iOwe)).count == 1)
    }

    @Test func batchingDailyCapAndCueSkip() async throws {
        let db = try promises(14)
        try await db.writer.write { try Setting(key: "ledger.aiDailyCalls", value: "1").upsert($0) }
        let provider = FakeProvider(id: "groq") { request, _ in ledgerAnswer(request) }
        try await db.writer.write { try AISettings(enabled: true, provider: "groq").write($0) }
        let queue = LedgerQueue(database: db, providers: AIProviders([provider]), now: { testNow })
        #expect(try await queue.processBatch().sent == 6)
        #expect(try await queue.processBatch().sent == 0)
        #expect(provider.requests.count == 1)
        let skipDB = try makeDatabase([TestMail(id: "x", thread: "x", body: "Thanks, sounds good.")], settings: AISettings(enabled: true, provider: "groq"))
        let skipped = LedgerQueue(database: skipDB, providers: AIProviders([provider]), now: { testNow })
        _ = try await skipped.processBatch()
        #expect(provider.requests.count == 1)
        #expect(try await skipDB.reader.read { try LedgerScan.fetchOne($0)?.origin } == "cue-skip")
        #expect(LedgerQueue.batchSize(for: "claude") == 6)
        #expect(LedgerQueue.batchSize(for: "codex") == 10)
    }

    @Test func settingsFlipDropsAnswer() async throws {
        let db = try promises()
        let latch = Latch()
        let provider = FakeProvider { request, _ in await latch.wait(); return ledgerAnswer(request) }
        let queue = LedgerQueue(database: db, providers: AIProviders([provider]), now: { testNow })
        let task = Task { try await queue.processBatch() }
        for _ in 0..<100 where provider.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await db.writer.write { try Setting(key: "ledger.ai", value: "false").upsert($0) }
        await latch.release()
        do { _ = try await task.value; Issue.record("Stale response was accepted") } catch is CancellationError {} catch { throw error }
        #expect(try await db.reader.read { try Commitment.fetchCount($0) } == 0)
    }

    @Test func failedBatchHalvesAndPriorityDefers() async throws {
        let db = try promises(6)
        let provider = FakeProvider(id: "groq") { request, index in
            if index == 1 { throw AIError.invalidOutput("synthetic") }
            return ledgerAnswer(request)
        }
        try await db.writer.write { try AISettings(enabled: true, provider: "groq").write($0) }
        let queue = LedgerQueue(database: db, providers: AIProviders([provider]), now: { testNow })
        do { _ = try await queue.processBatch() } catch {}
        #expect(try await queue.processBatch().sent == 3)
        #expect(try await queue.processBatch().sent == 3)
        let deferred = LedgerQueue(database: try promises(), providers: AIProviders([provider]), now: { testNow }, triageIdle: { false })
        #expect(try await deferred.processBatch().sent == 0)
        #expect(provider.requests.count == 3)
    }

    @Test func dueDateParserAndCues() {
        #expect(LedgerVerdict.date("2027-02-30", source: testNow) == nil)
        #expect(LedgerVerdict.date("2000-01-01", source: testNow) == nil)
        #expect(CommitmentCues.contains("I'll send the deck tomorrow"))
        #expect(CommitmentCues.contains("Please share the document"))
        #expect(!CommitmentCues.contains("Thanks!\n\nOn Monday Alex wrote:\n> I'll send the deck"))
    }
    @Test func resolutionEvidenceIsOnlyAHint() async throws {
        let db = try promises()
        let provider = FakeProvider { request, index in
            if index == 1 { return ledgerAnswer(request) }
            return #"{"threads":[{"threadRef":"t1","items":[],"updates":[{"ref":"c1","status":"fulfilled","resolvedByRef":"t1.m2","quote":"Here is the revised deck.","newDueDate":null}]}]}"#
        }
        let queue = LedgerQueue(database: db, providers: AIProviders([provider]), now: { testNow })
        _ = try await queue.processBatch()
        try MailStore(db).upsertMessages([MailMessage(accountId: me.id, id: "delivery", threadId: "t0", date: testNow,
            fromEmail: me.email, toList: [Participant(email: "ethan.brooks@gmail.com")], subject: "Hello",
            snippet: "Here is the revised deck.", bodyText: "Here is the revised deck.", labelIds: [SystemLabel.sent], isFromMe: true)])
        _ = try await queue.processBatch()
        let item = try #require(await db.reader.read { try Commitment.fetchOne($0) })
        #expect(item.state == .open)
        #expect(item.hintMessageId == "delivery")
        #expect(item.resolutionNote?.hasPrefix("fulfilled:") == true)
    }

    @Test func settingsObservationInterruptsProvider() async throws {
        let db = try promises()
        let cancelled = TestState()
        let provider = FakeProvider { _, _ in
            do { try await Task.sleep(for: .seconds(20)) }
            catch { cancelled.isOn = true; throw error }
            return "{}"
        }
        let queue = LedgerQueue(database: db, providers: AIProviders([provider]), debounce: .zero, now: { testNow })
        await queue.start()
        for _ in 0..<200 where provider.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(provider.requests.count == 1)
        try await db.writer.write { try AISettings(enabled: false, provider: "codex").write($0) }
        // A second direct batch can run only after the observed setting cancelled the sleeping call.
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await db.reader.read { try Commitment.fetchCount($0) } == 0)
        #expect(cancelled.isOn)
        await queue.stop()
    }

    @Test func aBatchedFailureDoesNotCountAsASoloFailure() async throws {
        let db = try promises(2)
        try await db.writer.write { try AISettings(enabled: true, provider: "groq").write($0) }
        let provider = FakeProvider(id: "groq") { request, index in
            if index <= 2 { throw AIError.invalidOutput("synthetic") }
            return ledgerAnswer(request)
        }
        let queue = LedgerQueue(database: db, providers: AIProviders([provider]), now: { testNow })
        for _ in 0..<2 { do { _ = try await queue.processBatch() } catch {} }
        #expect(try await queue.processBatch().sent == 1)
        #expect(try await queue.processBatch().sent == 1)
        #expect(provider.requests.count == 4)
    }

}
