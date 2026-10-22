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
        let refreshKeys = try database.reader.read { db in
            try Row.fetchAll(db, sql: "SELECT accountId,id FROM thread ORDER BY lastDate DESC LIMIT 100").map {
                ThreadKey(accountId: $0[0], threadId: $0[1])
            }
        }
        let refreshStart = Date()
        try database.writer.write { try Ledger.refresh($0, keys: refreshKeys, now: now) }
        let refreshMs = Date().timeIntervalSince(refreshStart) * 1000
        print(String(format: "Ledger 50k sync refresh: %d touched threads in %.2f ms", refreshKeys.count, refreshMs))
        let countsStart = Date()
        let count = try database.reader.read { try MailStore.fetchLedgerCount($0, accountId: nil) }
        let countsMs = Date().timeIntervalSince(countsStart) * 1000
        print(String(format: "Ledger 50k: %d candidates, rebuild %.2f ms, count %d in %.2f ms", candidates, rebuildMs, count, countsMs))
        #expect(count > 0)
        #expect(rebuildMs < 150)
        #expect(countsMs < 30)
        let detailKeys = try database.reader.read { db in
            try Row.fetchAll(db, sql: "SELECT DISTINCT accountId,threadId FROM commitment LIMIT 100").map { ThreadKey(accountId: $0[0], threadId: $0[1]) }
        }
        var timings: [Double] = []
        for key in detailKeys {
            let start = Date()
            let detail = try MailStore(database).threadDetail(key)
            timings.append(Date().timeIntervalSince(start) * 1000)
            #expect(detail?.commitments.isEmpty == false)
        }
        print(String(format: "Ledger 50k threadDetail with commitments: %d reads, max %.2f ms, mean %.2f ms", timings.count, timings.max() ?? 0, timings.reduce(0,+) / Double(max(1, timings.count))))
        #expect((timings.max() ?? 0) < 50)
        let plan = try database.reader.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT accountId,threadId FROM commitment WHERE direction='waitingOn' AND state='open' AND surfaced=1").map { $0.description }.joined()
        }
        #expect(plan.contains("commitment_list"))
    }
}
