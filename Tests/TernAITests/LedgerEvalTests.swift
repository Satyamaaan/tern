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
        let source = directory.appendingPathComponent("gold.sqlite")
        let copy = directory.appendingPathComponent("evaluated.sqlite")
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
        try FileManager.default.copyItem(at: source, to: copy)
        let database = try AppDatabase.open(at: copy)
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
        for _ in 0..<40 {
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
        let scans = try await database.reader.read { try LedgerScan.fetchAll($0) }
        let skipped = Set(scans.filter { $0.origin == "cue-skip" }.map { ThreadKey(accountId: $0.accountId, threadId: $0.threadId) })
        let prefilter = Double(expected.filter { !skipped.contains($0.thread) }.count) / Double(expected.count)
        let calls = try await database.reader.read { try Setting.fetchOne($0, key: "ledger.ai.day")?.value ?? "" }
        try JSONEncoder().encode(gold).write(to: directory.appendingPathComponent("gold.json"))
        print("LEDGER EVAL precision=\(precision) recall=\(recall) prefilterRecall=\(prefilter) calls=\(calls) latency=\(Date().timeIntervalSince(started))s surfaced=\(items.count) matched=\(matched.count) expected=\(expected.count) artifacts=\(directory.path)")
        #expect(precision >= 0.95)
        #expect(recall >= 0.7)
        #expect(prefilter >= 0.9)
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
