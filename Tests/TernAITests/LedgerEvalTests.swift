import Foundation
import GRDB
import Testing
import Security
@testable import TernAI
import TernCore

struct LedgerEvalTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_EVAL_AI"] == "1"))
    func liveGroq() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tern-ledger-eval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("gold.sqlite")
        let now = Date()
        let gold: [FakeMailbox.LedgerAIGold]
        do {
            let generated = try AppDatabase.open(at: source)
            gold = try FakeMailbox.populateLedgerAIGold(generated, count: 72, now: now)
            try await generated.writer.write { db in
                try AISettings(enabled: true, provider: "groq").write(db)
                try Setting(key: "ledger.backfillDays", value: "30").upsert(db)
                try Setting(key: "ledger.aiDailyCalls", value: "1000").upsert(db)
            }
            try await generated.writer.writeWithoutTransaction { try $0.checkpoint(.truncate) }
        }
        let database = try AppDatabase.open(at: source)
        let provider = GroqProvider(key: {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "dev.tern.ai.groq", kSecAttrAccount as String: "default",
                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var value: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        })
        let queue = LedgerQueue(database: database, providers: AIProviders([LedgerEvalRecorder(base: provider, directory: directory)]), now: { now })
        let started = Date()
        let resolutionOnly = ProcessInfo.processInfo.environment["TERN_EVAL_RESOLUTION_ONLY"] == "1"
        for _ in 0..<(resolutionOnly ? 0 : 40) {
            if try await queue.processBatch().sent == 0 { break }
        }
        let items = try await database.reader.read { try Commitment.filter(Column("origin") != "rule" && Column("confidence") == 2 && Column("surfaced") == true).fetchAll($0) }
        let expected = gold.filter { $0.direction != nil }
        let matched = items.filter { item in
            expected.contains { target in
                guard target.thread == ThreadKey(accountId: item.accountId, threadId: item.threadId),
                      target.direction == item.direction, target.counterparty == item.counterpartyEmail else { return false }
                let alternatives = [target.deliverableKeywords] + (target.deliverableAlternatives ?? [])
                let deliverable = item.deliverable.lowercased()
                let wordsMatch = alternatives.contains { words in words.allSatisfy { deliverable.contains($0) } }
                let sources = [target.sourceIndex] + (target.sourceAlternatives ?? [])
                let sourceMatches = sources.contains { item.sourceMessageId == target.thread.threadId + "-m\($0)" }
                return wordsMatch && sourceMatches
            }
        }
        let recalled = Set(matched.map { ThreadKey(accountId: $0.accountId, threadId: $0.threadId) }).count
        let precision = Double(matched.count) / Double(max(1, items.count))
        let recall = Double(recalled) / Double(expected.count)
        if !resolutionOnly {
            for target in expected where !matched.contains(where: { $0.threadId == target.thread.threadId && $0.accountId == target.thread.accountId }) {
                print("LEDGER MISS id=\(target.thread.threadId) category=\(target.thread.threadId.split(separator: "-").last.flatMap { Int($0) }.map { $0 % 24 } ?? -1)")
            }
        }
        let scans = try await database.reader.read { try LedgerScan.fetchAll($0) }
        let skipped = Set(scans.filter { $0.origin == "cue-skip" }.map { ThreadKey(accountId: $0.accountId, threadId: $0.threadId) })
        let prefilter = Double(expected.filter { !skipped.contains($0.thread) }.count) / Double(expected.count)
        let calls = try await database.reader.read { try Setting.fetchOne($0, key: "ledger.ai.day")?.value ?? "" }
        try JSONEncoder().encode(gold).write(to: directory.appendingPathComponent("gold.json"))
        if !resolutionOnly { print("LEDGER EVAL precision=\(precision) recall=\(recall) prefilterRecall=\(prefilter) calls=\(calls) latency=\(Date().timeIntervalSince(started))s surfaced=\(items.count) matched=\(matched.count) expected=\(expected.count)") }
        var resolutionClosed = 0
        var resolutionCorrect = 0
        var resolutionExpected = 0
        let resolutionStart = Date()
        for index in LedgerResolutionTests.cases.indices {
            let (body, _, mine, attachment, expectedDone) = LedgerResolutionTests.cases[index]
            let (sample, threads, items) = try LedgerResolutionTests.fixture(body, mine: mine, attachment: attachment)
            let request = LedgerResolution.request(threads, items: items)
            let response = try await provider.complete(request)
            if let root = ModelJSON.parse(response) as? [String: Any], let values = root["items"] as? [[String: Any]] {
                for value in values { print("RESOLUTION VERDICT category=\(index) ref=\(value["ref"] as? String ?? "nil") status=\(value["status"] as? String ?? "nil") messageRef=\(value["resolvedByRef"] as? String ?? "nil") quoteLength=\((value["quote"] as? String)?.count ?? 0)") }
            }
            let closed = try await sample.writer.write { db in
                try LedgerResolution.apply(response, db: db, threads: threads, items: items, now: testNow) ?? 0
            }
            resolutionClosed += closed
            if expectedDone { resolutionExpected += 1; resolutionCorrect += closed }
            if expectedDone && closed == 0 { print("RESOLUTION MISS category=\(index)") }
            if !expectedDone && closed > 0 { print("RESOLUTION FALSE CLOSE category=\(index)") }
        }
        let resolutionPrecision = resolutionClosed == 0 ? 1 : Double(resolutionCorrect) / Double(resolutionClosed)
        let resolutionRecall = Double(resolutionCorrect) / Double(max(1, resolutionExpected))
        print("RESOLUTION EVAL precision=\(resolutionPrecision) recall=\(resolutionRecall) calls=\(LedgerResolutionTests.cases.count) latency=\(Date().timeIntervalSince(resolutionStart))s")
        #expect(resolutionPrecision >= 0.95)
        if !resolutionOnly {
            #expect(precision >= 0.95)
            #expect(recall >= 0.7)
            #expect(prefilter >= 0.9)
        }
    }
}

private actor LedgerEvalRecorder: AIProvider {
    nonisolated let id = "groq"
    nonisolated let displayName = "Groq eval"
    let base: GroqProvider
    let directory: URL
    var calls = 0
    init(base: GroqProvider, directory: URL) { self.base = base; self.directory = directory }
    func availability(refresh: Bool) async -> AIAvailability { await base.availability(refresh: refresh) }
    func models() async -> [String] { await base.models() }
    func complete(_ request: AIRequest) async throws -> String {
        calls += 1
        let index = calls
        let response = try await base.complete(request)
        // Only synthetic gold mail and model text. Credentials never enter these artifacts.
        let data = try JSONSerialization.data(withJSONObject: ["input": request.input, "response": response], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("call-\(index).json"))
        return response
    }
}
