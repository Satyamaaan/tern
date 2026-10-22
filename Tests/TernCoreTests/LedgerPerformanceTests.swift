import Foundation
import GRDB
import Testing
@testable import TernCore

struct LedgerPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_SKIP_PERF"] != "1"))
    func rebuildAndCountsOn50k() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tern-ledger-perf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.open(at: directory.appendingPathComponent("mail.sqlite"))
        let now = Date()
        try FakeMailbox.populate(database, options: .init(messages: 50_000, now: now, ledgerGold: 160))
        try database.writer.write { try Commitment.deleteAll($0) }
        let candidates = try database.reader.read { try Ledger.waitingCandidates($0, now: now).count }
        let started = Date()
        try Ledger.rebuildWaiting(in: database, now: now)
        let rebuildMs = Date().timeIntervalSince(started) * 1000
        let countsStart = Date()
        let count = try database.reader.read { try MailStore.fetchLedgerCount($0, accountId: nil) }
        let countsMs = Date().timeIntervalSince(countsStart) * 1000
        print(String(format: "Ledger 50k: %d candidates, rebuild %.2f ms, count %d in %.2f ms", candidates, rebuildMs, count, countsMs))
        #expect(count > 0)
        #expect(rebuildMs < 150)
        #expect(countsMs < 30)
        let plan = try database.reader.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT accountId,threadId FROM commitment WHERE direction='waitingOn' AND state='open' AND surfaced=1").map { $0.description }.joined()
        }
        #expect(plan.contains("commitment_list"))
    }
}
