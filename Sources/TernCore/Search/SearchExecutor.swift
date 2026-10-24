import Foundation
import GRDB

/// Runs a compiled search. The same answer can be reached by very different routes, and which one is fast
/// depends on how common the words are:
///
/// - a **rare** word: ask the full-text index for the few matching messages, then sort their threads;
/// - a **common** word (`the`, `t`): walk threads newest first, checking each against the index, and stop as
///   soon as the page is full, which takes a few hundred rows;
/// - a **small table** (snoozed, needs reply, one category, big messages): start from it.
///
/// SQLite has no statistics for the full-text index, so it cannot tell these apart. The executor counts each
/// route's candidates with a cap, estimates what each route would cost, and runs the cheapest.
struct SearchExecutor {
    let db: Database
    let compiled: CompiledSearch
    let limit: Int

    /// A matching thread, and the newest message of it that matched (when the route found it for free).
    struct Found {
        var key: ThreadKey
        var messageSeq: Int64?
    }

    enum Plan: CustomStringConvertible {
        case ftsFirst
        case set(SQLFragment)
        case labelWalk(String)
        case threadWalk

        var description: String {
            switch self {
            case .ftsFirst: "full-text first"
            case .set: "small set first"
            case .labelWalk(let id): "walk label \(id)"
            case .threadWalk: "walk threads"
            }
        }
    }

    /// Most full-text matches worth sorting (~1 µs each).
    static let ftsCap = 30_000
    /// Candidate sets bigger than this are walked instead of sorted.
    static let setCap = 3_000
    /// Up to this many full-text matches, sorting them is always cheaper than any walk.
    static let obviousFTS = 1_500

    // MARK: Planning

    /// What the planner believed about a route; exposed for tests and tuning.
    struct Estimate {
        var plan: Plan
        var microseconds: Double
    }

    func choosePlan() throws -> Plan {
        try estimates().min { $0.microseconds < $1.microseconds }!.plan
    }

    func estimates() throws -> [Estimate] {
        let ftsCount = try compiled.fts.map(countFTS)
        if let ftsCount, ftsCount <= Self.obviousFTS { return [Estimate(plan: .ftsFirst, microseconds: 1.0 * Double(ftsCount))] }

        let threads = Double(max(1, try Int.fetchOne(db, sql: "SELECT coalesce(max(rowid), 0) FROM thread") ?? 0))
        let wanted = Double(limit)

        // Share of threads each source lets through, taking the sources as independent.
        var sets: [(fragment: SQLFragment, count: Int)] = []
        var labels: [(id: String, count: Int)] = []
        var share = 1.0
        if let count = ftsCount {
            // Matches cluster in threads (replies repeat the subject), so threads < matches; sample the ratio.
            share *= min(1, Double(min(count, Self.ftsCap)) * (try distinctThreadRatio()) / threads)
        }
        for driver in compiled.drivers {
            switch driver {
            case .set(let fragment):
                let count = try countSet(fragment)
                sets.append((fragment, count))
                share *= Double(max(1, count)) / threads
            case .label(let id):
                let count = try countLabel(id)
                labels.append((id, count))
                share *= Double(max(1, count)) / threads
            }
        }
        share = min(1, max(share, 1e-4))

        // Microseconds to test one thread: its row and label checks (~1.5), then its messages against the index
        // (an exact word or a prefix of up to three letters costs ~17; a longer prefix ~250).
        let check = 1.5 + (compiled.hasMessageConditions ? 1.2 * max(compiled.probeCost, 3) : 0)
        /// Threads a walk over `rows` driver rows looks at before `limit` pass.
        func walked(_ rows: Double) -> Double {
            min(rows, wanted / min(1, share * threads / max(rows, 1)))
        }

        var all = [Estimate(plan: .threadWalk, microseconds: walked(threads) * check)]
        if let count = ftsCount, count <= Self.ftsCap {
            all.append(Estimate(plan: .ftsFirst, microseconds: 40 + 1.0 * Double(count)))
        }
        for set in sets where set.count <= Self.setCap {
            let rows = Double(set.count)
            all.append(Estimate(plan: .set(set.fragment), microseconds: 40 + 2 * rows + walked(rows) * check))
        }
        for label in labels {
            all.append(Estimate(plan: .labelWalk(label.id), microseconds: 40 + walked(Double(label.count)) * check))
        }
        return all
    }

    /// Distinct threads per matching message, from the first few hundred matches.
    private func distinctThreadRatio() throws -> Double {
        guard let fts = compiled.fts else { return 1 }
        let row = try Row.fetchOne(db, sql: """
            SELECT count(*), count(DISTINCT m.accountId || m.threadId) FROM (
              SELECT rowid FROM message_fts WHERE message_fts MATCH ? LIMIT 400) f
            JOIN message m ON m.seq = f.rowid
            """, arguments: [fts])
        let matches: Int = row?[0] ?? 0
        let distinct: Int = row?[1] ?? 0
        return matches > 0 ? max(0.05, Double(distinct) / Double(matches)) : 1
    }

    /// Full-text matches, up to one more than the cap.
    func countFTS(_ expression: String) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT count(*) FROM (SELECT 1 FROM message_fts WHERE message_fts MATCH ? LIMIT ?)",
                         arguments: [expression, Self.ftsCap + 1]) ?? 0
    }

    private func countSet(_ fragment: SQLFragment, limit: Int = SearchExecutor.setCap + 1) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT count(*) FROM (\(fragment.sql) LIMIT \(limit))",
                         arguments: StatementArguments(fragment.arguments)) ?? 0
    }

    private func countLabel(_ id: String, limit: Int = 100_000) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT count(*) FROM (SELECT 1 FROM thread_label WHERE labelId = ? LIMIT \(limit))",
                         arguments: [id]) ?? 0
    }

    // MARK: Newest first

    /// Matching threads, most recently active first. With `resolveMatches`, also the newest matching message of
    /// each (the walks look it up for the returned threads only).
    func run(_ plan: Plan, resolveMatches: Bool = true) throws -> [Found] {
        var sql = SQLBuilder()
        let threadFilter = SQLFragment.all(compiled.threadConds)
        let newestMatch = resolveMatches && compiled.hasMessageConditions

        switch plan {
        case .ftsFirst:
            // max(m.date) makes the bare column come from each thread's newest matching message.
            sql.add("""
                SELECT t.accountId, t.id, h.mseq FROM (
                  SELECT m.accountId AS a, m.threadId AS i, m.seq AS mseq, max(m.date) AS mdate
                  FROM message_fts f CROSS JOIN message m ON m.seq = f.rowid
                  WHERE message_fts MATCH ?
                """, compiled.fts!)
            sql.add(" AND ", SQLFragment.all(compiled.messageConds))
            sql.add("""
                 GROUP BY m.accountId, m.threadId) h
                CROSS JOIN thread t ON t.accountId = h.a AND t.id = h.i
                WHERE\u{20}
                """, threadFilter)
            sql.add(" ORDER BY t.lastDate DESC LIMIT ?", limit)

        case .set(let fragment):
            // Sort the small set first, then test messages lazily on the way out: only as many rows as it
            // takes to fill the page are ever checked.
            sql.add("SELECT o.accountId, o.id")
            if newestMatch { sql.add(", ", newestMatchColumn(on: "o")) }
            sql.add(" FROM (SELECT t.accountId, t.id FROM (")
            sql.add(fragment)
            sql.add(") s CROSS JOIN thread t ON t.accountId = s.a AND t.id = s.i WHERE ", threadFilter)
            sql.add(" ORDER BY t.lastDate DESC LIMIT 1000000) o WHERE ", messageExists(on: "o"))
            sql.add(" LIMIT ?", limit)

        case .labelWalk(let id):
            let singleAccount = compiled.accountIds?.count == 1 ? compiled.accountIds?.first : nil
            let index = singleAccount == nil ? "thread_label_unified" : "thread_label_account"
            sql.add("SELECT t.accountId, t.id")
            if newestMatch { sql.add(", ", newestMatchColumn(on: "t")) }
            sql.add("""
                 FROM thread_label tl INDEXED BY \(index)
                CROSS JOIN thread t ON t.accountId = tl.accountId AND t.id = tl.threadId
                WHERE tl.labelId = ?
                """, id)
            if let singleAccount { sql.add(" AND tl.accountId = ?", singleAccount) }
            if let min = compiled.lastDateMin { sql.add(" AND tl.lastDate >= ?", min) }
            if let max = compiled.lastDateMax { sql.add(" AND tl.lastDate < ?", max) }
            sql.add(" AND ", threadFilter)
            sql.add(" AND ", messageExists(on: "t"))
            sql.add(" ORDER BY tl.lastDate DESC LIMIT ?", limit)

        case .threadWalk:
            let index = compiled.accountIds?.count == 1 ? "thread_by_account_date" : "thread_by_date"
            sql.add("SELECT t.accountId, t.id")
            if newestMatch { sql.add(", ", newestMatchColumn(on: "t")) }
            sql.add(" FROM thread t INDEXED BY \(index) WHERE ", threadFilter)
            sql.add(" AND ", messageExists(on: "t"))
            sql.add(" ORDER BY t.lastDate DESC LIMIT ?", limit)
        }

        return try sql.rows(db).map {
            Found(key: ThreadKey(accountId: $0[0], threadId: $0[1]), messageSeq: $0.count > 2 ? $0[2] : nil)
        }
    }

    /// Every message-level condition (words included) as one test on message `m`.
    private var messageConditions: SQLFragment {
        SQLFragment.all(compiled.messageConds + (compiled.fts.map { [Self.probe($0)] } ?? []))
    }

    /// True when some message of the thread aliased `thread` satisfies every message-level condition.
    private func messageExists(on thread: String) -> SQLFragment {
        let all = messageConditions
        if all.isAlways { return .always }
        return SQLFragment(
            "EXISTS (SELECT 1 FROM message m WHERE m.accountId = \(thread).accountId AND m.threadId = \(thread).id AND \(all.sql))",
            all.arguments.map { $0 as any DatabaseValueConvertible })
    }

    /// `seq` of the newest message of the thread aliased `thread` that satisfies every message-level
    /// condition. Evaluated only for the rows that are returned.
    private func newestMatchColumn(on thread: String) -> SQLFragment {
        let all = messageConditions
        return SQLFragment("""
            (SELECT m.seq FROM message m WHERE m.accountId = \(thread).accountId AND m.threadId = \(thread).id \
            AND \(all.sql) ORDER BY m.date DESC LIMIT 1)
            """, all.arguments.map { $0 as any DatabaseValueConvertible })
    }

    static func probe(_ expression: String) -> SQLFragment {
        SQLFragment("EXISTS (SELECT 1 FROM message_fts WHERE message_fts MATCH ? AND rowid = m.seq)", [expression])
    }

    // MARK: Relevance

    /// Weights per column: subject, sender, recipients, snippet, body.
    private static let bm25 = "bm25(message_fts, 10.0, 4.0, 2.0, 1.0, 1.0)"

    /// Most full-text matches worth ranking. A word that matches more than this (40% of a 50,000-message
    /// mailbox: `the`, `t`, `th`) tells nothing apart by score, and scoring them all would cost over 20 ms.
    static let rankCap = 20_000

    /// Matching threads, best match first, each with its best-scoring message. Filter before ranking when
    /// a label or small set narrows the mailbox. Otherwise start with a bounded ranked prefix, and filter
    /// before ranking only if that leaves the page short.
    /// Words that match almost everything are returned newest first instead.
    func runRanked() throws -> [Found] {
        guard let fts = compiled.fts else { return try run(try choosePlan()) }
        let matches = try Int.fetchOne(db, sql: "SELECT count(*) FROM (SELECT 1 FROM message_fts WHERE message_fts MATCH ? LIMIT ?)",
                                       arguments: [fts, Self.rankCap + 1]) ?? 0
        if matches > Self.rankCap { return try run(try choosePlan()) }
        let firstPool = 4_000
        if matches > firstPool {
            for driver in compiled.drivers {
                let count = switch driver {
                case .label(let id): try countLabel(id, limit: firstPool + 1)
                case .set(let fragment): try countSet(fragment, limit: firstPool + 1)
                }
                if count <= firstPool { return try ranked(fts, pool: nil) }
            }
        }
        let ordered = try ranked(fts, pool: firstPool)
        return ordered.count >= limit || matches <= firstPool ? ordered : try ranked(fts, pool: nil)
    }

    private func ranked(_ fts: String, pool: Int?) throws -> [Found] {
        var sql = SQLBuilder()
        if let pool {
            // LIMIT preserves the prefix's order and bounds its sort before the row lookups.
            sql.add("""
                SELECT m.accountId, m.threadId, m.seq FROM (
                  SELECT rowid AS r, \(Self.bm25) AS score FROM message_fts WHERE message_fts MATCH ?
                  ORDER BY score, rowid DESC LIMIT \(pool)) c
                CROSS JOIN message m ON m.seq = c.r
                CROSS JOIN thread t ON t.accountId = m.accountId AND t.id = m.threadId
                WHERE\u{20}
                """, fts)
        } else {
            sql.add("""
                SELECT m.accountId, m.threadId, m.seq FROM message_fts f
                CROSS JOIN message m ON m.seq = f.rowid
                CROSS JOIN thread t ON t.accountId = m.accountId AND t.id = m.threadId
                WHERE message_fts MATCH ? AND\u{20}
                """, fts)
        }
        sql.add(SQLFragment.all(compiled.messageConds + compiled.threadConds))
        if pool == nil { sql.add(" ORDER BY \(Self.bm25), f.rowid DESC") }
        let cursor = try Row.fetchCursor(db, sql: sql.sql, arguments: StatementArguments(sql.arguments))
        var seen = Set<ThreadKey>()
        var ordered: [Found] = []
        while ordered.count < limit, let row = try cursor.next() {
            let key = ThreadKey(accountId: row[0], threadId: row[1])
            if seen.insert(key).inserted { ordered.append(Found(key: key, messageSeq: row[2])) }
        }
        return ordered
    }
}

/// Collects SQL text and its arguments in order.
private struct SQLBuilder {
    var sql = ""
    var arguments: [DatabaseValue] = []

    mutating func add(_ text: String) {
        sql += text
    }

    mutating func add(_ text: String, _ value: any DatabaseValueConvertible) {
        sql += text
        arguments.append(value.databaseValue)
    }

    mutating func add(_ text: String, _ fragment: SQLFragment) {
        sql += text + fragment.sql
        arguments += fragment.arguments
    }

    mutating func add(_ fragment: SQLFragment) {
        sql += fragment.sql
        arguments += fragment.arguments
    }

    func rows(_ db: Database) throws -> [Row] {
        try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
    }
}
