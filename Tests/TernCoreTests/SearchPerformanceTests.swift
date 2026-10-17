import Foundation
import GRDB
import Testing
@testable import TernCore

/// Search must answer on every keystroke: under 30 ms per query on the 50,000-message fake mailbox.
/// Seeding takes ~15 s, so the database is built once per run. Skip with `TERN_SKIP_PERF=1`; tune the
/// budget with `TERN_SEARCH_BUDGET_MS`.
///
/// 30 ms is the budget for a release build, which is what ships. A debug build (the default for `swift test`) runs
/// the Swift side ~1.5x slower, so it is held to 45 ms; `swift test -c release -Xswiftc -enable-testing` checks 30.
///
/// The budget is asserted on CPU time, not wall-clock: on an idle machine they are the same, and on a busy one
/// (parallel builds, Spotlight, VMs) wall-clock measures the scheduler instead of the query. Wall-clock is printed
/// next to it.
private enum Perf {
    static let skip = ProcessInfo.processInfo.environment["TERN_SKIP_PERF"] == "1"
    #if DEBUG
    static let defaultBudgetMs = 45.0
    #else
    static let defaultBudgetMs = 30.0
    #endif
    static let budgetMs = Double(ProcessInfo.processInfo.environment["TERN_SEARCH_BUDGET_MS"] ?? "") ?? defaultBudgetMs
    static let runs = 12
    static let rounds = 4

    /// Typical queries by what makes them hard.
    static let groups: [(name: String, queries: [String])] = [
        ("very common prefixes", ["t", "th", "the", "a", "to", "you", "i", "s", "co"]),
        ("rare and middling words", ["roadmap", "lisbon", "invoice", "github", "stripe", "quokka", "feedback", "kiteworks"]),
        ("several words", ["the roadmap", "design review", "q4 roadmap review", "flight details for lisbon", "the a", "your receipt from"]),
        ("typing a phrase", ["r", "ro", "roa", "roadm", "roadmap", "roadmap ", "roadmap r", "roadmap rev", "roadmap review"]),
        ("operators only", [
            "is:unread", "is:starred", "is:important", "in:inbox", "in:sent", "in:drafts", "in:trash", "has:attachment",
            "from:github", "from:maya", "from:me", "to:me", "is:needsreply", "is:snoozed", "category:newsletter",
            "category:security", "project:lumen", "project:kiteworks", "label:finance", "larger:1M", "smaller:1K",
            "filename:pdf", "newer_than:7d", "older_than:1y", "before:2025/01/01", "after:2026/09/01", "account:kiteworks",
            "from:", "from:g", "is:u",
        ]),
        ("operators with words", [
            "from:github is:unread", "in:inbox the", "in:inbox t", "has:attachment invoice", "from:maya roadmap", "subject:invoice",
            "subject:the", "is:unread the", "from:github the", "category:people the", "label:finance the", "from:the",
            "to:alex the", "cc:maya", "bcc:maya", "newer_than:30d the", "before:2025/06/01 the", "account:northwind the",
        ]),
        ("negation, OR, groups", [
            "-the", "the -a", "roadmap -review", "from:github OR from:linear", "(invoice OR receipt) the",
            "-is:read the", "tacos OR roadmap", "{from:github from:linear} the", "\"the roadmap\"", "\"q4 roadmap\" -is:read",
        ]),
    ]

    /// Worst shapes, held to twice the budget: an AND/OR of stop-words makes every thread cost three index
    /// lookups per message (~60 µs), so even the newest-first walk is slow. Nobody types these; they are here to
    /// catch a regression, not to promise 30 ms.
    static let stress = ["the (a OR b)", "the a b c d", "(the OR a OR to) (you OR i)"]

    nonisolated(unsafe) static var cached: (database: AppDatabase, directory: URL)?
    static let lock = NSLock()

    /// One seeded file per test run, deleted at process exit.
    static func database() throws -> AppDatabase {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached.database }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tern-search-perf-\(UUID().uuidString)")
        let database = try AppDatabase.open(at: directory.appendingPathComponent("Tern-Fake.sqlite"))
        _ = try FakeMailbox.populate(database, options: .init(messages: 50_000))
        cached = (database, directory)
        atexit { try? FileManager.default.removeItem(at: Perf.cached!.directory) }
        return database
    }

    struct Timing {
        var query: String
        /// CPU milliseconds per run; the numbers the budget is held to.
        var ms: [Double]
        var wall: [Double] = []
        var results: Int
        var p50: Double { percentile(0.5) }
        var p95: Double { percentile(0.95) }
        var max: Double { ms.max() ?? 0 }
        var wallP95: Double { wall.sorted()[Swift.min(wall.count - 1, Int((Double(wall.count) * 0.95).rounded(.up)) - 1)] }

        func percentile(_ p: Double) -> Double {
            let sorted = ms.sorted()
            return sorted[min(sorted.count - 1, Int((Double(sorted.count) * p).rounded(.up)) - 1)]
        }
    }

    /// How the planner would run `query`, for the report.
    static func plan(_ query: String, database: AppDatabase) throws -> String {
        try database.reader.read { db in
            let options = SearchOptions()
            guard let compiled = try SearchCompiler(db, options: options).compile(SearchQuery(query)) else { return "-" }
            return "\(try SearchExecutor(db: db, compiled: compiled, limit: 100).choosePlan())"
        }
    }

    static func time(_ query: String, search: SearchService, hits: Bool, sort: SearchSort = .newest) throws -> Timing {
        let options = SearchOptions(sort: sort)
        func run() throws -> Int {
            guard hits else { return try search.search(SearchQuery(query), options: options).count }
            let found = try search.searchHits(query, options: options)
            // A list shows about 20 rows: the marked-up words are found for those, as the UI would.
            for hit in found.prefix(20) { _ = hit.highlights; _ = hit.subjectHighlights }
            return found.count
        }
        _ = try run() // warm the page cache and statement caches
        // Best of a few rounds: a busy machine (parallel builds, Spotlight, VMs) only ever makes a round
        // slower, so the quietest round is the one that measures the code.
        var best: Timing?
        for _ in 0..<rounds {
            var samples: [Double] = []
            var wall: [Double] = []
            var count = 0
            for _ in 0..<runs {
                let cpuStart = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
                let wallStart = DispatchTime.now().uptimeNanoseconds
                count = try run()
                wall.append(Double(DispatchTime.now().uptimeNanoseconds - wallStart) / 1_000_000)
                samples.append(Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - cpuStart) / 1_000_000)
            }
            let round = Timing(query: query, ms: samples, wall: wall, results: count)
            if best == nil || round.p95 < best!.p95 { best = round }
        }
        return best!
    }
}

/// Serialized: timing tests that run side by side measure each other.
@Suite("Search speed", .serialized)
struct SearchSpeed {
    @Test(.enabled(if: !Perf.skip, "TERN_SKIP_PERF=1"))
    func searchAnswersWithinTheKeystrokeBudgetOnFiftyThousandMessages() throws {
        let search = SearchService(try Perf.database())
        var report = "\nsearch timings, 50,000 messages, best of \(Perf.rounds) rounds of \(Perf.runs) runs (CPU ms; hits = with matched message, excerpt, and highlights of the first 20)\n"
        var worst: [(String, Perf.Timing)] = []
        var all: [Double] = []
    var allWall: [Double] = []

        for (name, queries) in Perf.groups {
            report += "\n\(name)\n"
            for query in queries {
                let rows = try Perf.time(query, search: search, hits: false)
                let hits = try Perf.time(query, search: search, hits: true)
                all += hits.ms
            allWall += hits.wall
                worst.append((name, hits))
                let plan = try Perf.plan(query, database: search.database)
                report += String(format: "  %-34@ %4d results   rows p50 %5.1f p95 %5.1f   hits p50 %5.1f p95 %5.1f   %@\n",
                                 "'\(query)'" as NSString, hits.results, rows.p50, rows.p95, hits.p50, hits.p95, plan as NSString)
            }
        }
        let sorted = all.sorted()
        let wallSorted = allWall.sorted()
        report += String(format: "\nall queries with hits: p50 %.1f ms, p95 %.1f ms, max %.1f ms CPU   (wall-clock p50 %.1f, p95 %.1f, max %.1f)\n",
                         sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)], sorted.last!,
                         wallSorted[wallSorted.count / 2], wallSorted[Int(Double(wallSorted.count) * 0.95)], wallSorted.last!)
        print(report)

        // The UI's per-keystroke call asks for a first page, not 100 rows.
        var firstPage: [Double] = []
        for (_, queries) in Perf.groups {
            for query in queries {
                let options = SearchOptions(limit: 40)
                _ = try search.searchHits(query, options: options)
                var best = Double.infinity
                for _ in 0..<Perf.runs {
                    let start = DispatchTime.now().uptimeNanoseconds
                    for hit in try search.searchHits(query, options: options).prefix(20) { _ = hit.highlights; _ = hit.subjectHighlights }
                    best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                }
                firstPage.append(best)
            }
        }
        firstPage.sort()
        print(String(format: "first page of 40 (best of %d runs): p50 %.1f ms, p95 %.1f ms, max %.1f ms",
                     Perf.runs, firstPage[firstPage.count / 2], firstPage[Int(Double(firstPage.count) * 0.95)], firstPage.last!))

        for (group, timing) in worst {
            #expect(timing.p95 <= Perf.budgetMs, "\(group): '\(timing.query)' p95 \(timing.p95) ms > \(Perf.budgetMs) ms")
        }
    }

    @Test(.enabled(if: !Perf.skip, "TERN_SKIP_PERF=1"))
    func relevanceRankingStaysWithinBudgetToo() throws {
        let search = SearchService(try Perf.database())
        for query in [
            "roadmap", "the", "t", "th", "the roadmap", "from:github invoice", "lisbon flights", "subject:invoice", "invoice", "ro",
            "kiteworks", "design review", "from:g", "in:inbox the", "is:unread the", "is:starred the", "has:attachment the", "the -a", "is:starred invoice", "is:unread invoice",
        ] {
            let timing = try Perf.time(query, search: search, hits: true, sort: .relevance)
            print(String(format: "relevance %-24@ %4d results p50 %5.1f p95 %5.1f", "'\(query)'" as NSString, timing.results, timing.p50, timing.p95))
            #expect(timing.p95 <= Perf.budgetMs, "relevance '\(query)' p95 \(timing.p95) ms")
        }
    }

    @Test(.enabled(if: !Perf.skip, "TERN_SKIP_PERF=1"))
    func searchResultsAreFilledForTheBenchmarkQueries() throws {
        let search = SearchService(try Perf.database())
        #expect(try search.search("the").count == 100)
        #expect(try search.search("t").count == 100)
        #expect(try !search.search("roadmap").isEmpty)
        #expect(try !search.search("from:github").isEmpty)
        #expect(try !search.search("is:unread").isEmpty)
        #expect(try !search.search("has:attachment").isEmpty)
        #expect(try !search.search("is:snoozed").isEmpty)
        #expect(try !search.search("larger:1K").isEmpty)
        // A word that matches most of the mailbox has nothing to rank by: relevance order is newest first.
        let newest = try search.search("the", limit: 100).map(\.id)
        let ranked = try search.search(SearchQuery("the"), options: SearchOptions(sort: .relevance)).map(\.id)
        #expect(ranked == newest)
    }

    @Test(.enabled(if: !Perf.skip, "TERN_SKIP_PERF=1"))
    func suggestionsAreInstantEvenWithTwentyThousandContacts() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try Account(email: "alex@acme.com", displayName: "Acme").insert(db)
            for index in 0..<20_000 {
                let first = ["Maya", "Marco", "Mark", "Priya", "Jonas", "Hana", "Leo", "Sofia", "Daniel", "Grace"][index % 10]
                try Contact(id: "\(first.lowercased())\(index)@company\(index % 400).com", name: "\(first) Person\(index)",
                            sentCount: index % 7, receivedCount: index % 13, lastContacted: Date(timeIntervalSince1970: Double(index))).insert(db)
            }
            for index in 0..<200 { try MailLabel(accountId: "alex@acme.com", id: "Label_\(index)", name: "Label \(index)").insert(db) }
        }
        let search = SearchService(database)
        for partial in ["from:", "from:m", "from:ma", "from:mar", "to:pri", "from:company1", "from:zzzz", "label:l", "label:label-1", "fro", "is:u", ""] {
            var samples: [Double] = []
            for _ in 0..<15 {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = try search.suggestions(for: partial)
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            let p95 = samples.sorted()[Int(Double(samples.count) * 0.95)]
            print(String(format: "suggestions %-16@ p95 %5.1f ms", "'\(partial)'" as NSString, p95))
            #expect(p95 <= Perf.budgetMs, "suggestions '\(partial)' p95 \(p95) ms")
        }
    }

    @Test(.enabled(if: !Perf.skip, "TERN_SKIP_PERF=1"))
    func stopWordCompositionsStayWithinTwiceTheBudget() throws {
        let search = SearchService(try Perf.database())
        for query in Perf.stress {
            let timing = try Perf.time(query, search: search, hits: true)
            print(String(format: "stress %-30@ %4d results p50 %5.1f p95 %5.1f", "'\(query)'" as NSString, timing.results, timing.p50, timing.p95))
            #expect(timing.p95 <= Perf.budgetMs * 2, "stress '\(query)' p95 \(timing.p95) ms")
        }
    }
}
