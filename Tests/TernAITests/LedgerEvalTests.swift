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
                // Evaluate AI extraction independently from the rule reply detector.
                try db.execute(sql: "DELETE FROM commitment")
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
        let queue = LedgerQueue(database: database, providers: AIProviders([provider]), now: { now })
        let started = Date()
        for _ in 0..<40 {
            if try await queue.processBatch().sent == 0 { break }
        }
        let items = try await database.reader.read { try Commitment.filter(Column("origin") != "rule" && Column("confidence") == 2 && Column("surfaced") == true).fetchAll($0) }
        let expected = gold.filter { $0.direction != nil }
        let matched = items.filter { item in
            expected.contains { target in
                target.thread == ThreadKey(accountId: item.accountId, threadId: item.threadId) && target.direction == item.direction
                    && target.counterparty == item.counterpartyEmail
                    && target.deliverableKeywords.allSatisfy { item.deliverable.lowercased().contains($0) }
                    && item.sourceMessageId == target.thread.threadId + "-m\(target.sourceIndex)"
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
    }
}
