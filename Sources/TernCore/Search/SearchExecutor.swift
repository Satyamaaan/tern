import Foundation
import GRDB

/// Runs a compiled search. The same result can be reached by very different routes, and which one is fast
/// depends on how common the words are:
///
/// - a **rare** word: ask the full-text index for the few matching messages, then sort their threads;
/// - a **common** word (`the`, `t`): walk threads newest first, checking each against the index, and stop as
///   soon as the page is full, which takes a few hundred rows;
/// - a **small table** (snoozed, needs reply, one category, big messages): start from it.
///
/// SQLite cannot tell these apart (it has no statistics for the full-text index), so the executor counts the
/// candidates of each route with a cap and picks the cheapest.
struct SearchExecutor {
    let db: Database
    let compiled: CompiledSearch

    enum Plan {
        case ftsFirst
        case set(SQLFragment)
        case labelWalk(String)
        case threadWalk
    }

    /// Candidate sets bigger than this are walked instead of sorted.
    static let setCap = 3_000

    // MARK: Planning

    func choosePlan() throws -> Plan {
        var best: (plan: Plan, cost: Double)?
        func consider(_ plan: Plan, cost: Double) {
            if best == nil || cost < best!.cost { best = (plan, cost) }
        }

        let ftsCap = try ftsCap()
        if let fts = compiled.fts {
            let count = try countFTS(fts, cap: ftsCap)
            if count <= ftsCap { consider(.ftsFirst, cost: Double(count) * 1.5) }
        }
        for case .set(let fragment) in compiled.drivers {
            let count = try countSet(fragment, cap: Self.setCap)
            if count <= Self.setCap {
                consider(.set(fragment), cost: Double(count) * (compiled.hasMessageConditions ? 20 : 3))
            }
        }
        if let best { return best.plan }

        let labels: [String] = compiled.drivers.compactMap { if case .label(let id) = $0 { id } else { nil } }
        if labels.count > 1 {
            let counted = try labels.map { (id: $0, count: try countLabel($0)) }
            return .labelWalk(counted.min { $0.count < $1.count }!.id)
        }
        if let id = labels.first { return .labelWalk(id) }
        return .threadWalk
    }

    /// How many full-text matches are cheap enough to sort. Grows with the mailbox (the walk it competes with
    /// gets slower as matches get rarer), but never so far that sorting alone blows the keystroke budget.
    private func ftsCap() throws -> Int {
        let messages = try Int.fetchOne(db, sql: "SELECT coalesce(max(seq), 0) FROM message") ?? 0
        return max(3_000, min(30_000, Int(Double(messages).squareRoot() * 28)))
    }

    private func countFTS(_ expression: String, cap: Int) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT count(*) FROM (SELECT 1 FROM message_fts WHERE message_fts MATCH ? LIMIT ?)",
                         arguments: [expression, cap + 1]) ?? 0
    }

    private func countSet(_ fragment: SQLFragment, cap: Int) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT count(*) FROM (\(fragment.sql) LIMIT \(cap + 1))",
                         arguments: StatementArguments(fragment.arguments)) ?? 0
    }

    private func countLabel(_ id: String) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT count(*) FROM (SELECT 1 FROM thread_label WHERE labelId = ? LIMIT 50000)",
                         arguments: [id]) ?? 0
    }

    // MARK: Newest first

    /// Thread keys, most recently active first.
    func threadKeys(plan: Plan, limit: Int) throws -> [ThreadKey] {
        var sql = ""
        var arguments: [DatabaseValue] = []
        func add(_ text: String) { sql += text }
        func add(_ fragment: SQLFragment) { sql += fragment.sql; arguments += fragment.arguments }

        let threadFilter = SQLFragment.all(compiled.threadConds)

        switch plan {
        case .ftsFirst:
            add("""
                SELECT t.accountId, t.id FROM (
                  SELECT m.accountId AS a, m.threadId AS i FROM message_fts f CROSS JOIN message m ON m.seq = f.rowid
                  WHERE message_fts MATCH ? AND\u{20}
                """)
            arguments.append(compiled.fts!.databaseValue)
            add(SQLFragment.all(compiled.messageConds))
            add("""

                  GROUP BY m.accountId, m.threadId) h
                CROSS JOIN thread t ON t.accountId = h.a AND t.id = h.i
                WHERE\u{20}
                """)
            add(threadFilter)

        case .set(let fragment):
            add("SELECT t.accountId, t.id FROM (")
            add(fragment)
            add(") s CROSS JOIN thread t ON t.accountId = s.a AND t.id = s.i WHERE ")
            add(threadFilter)
            add(" AND ")
            add(messageExists)

        case .labelWalk(let id):
            let singleAccount = compiled.accountIds?.count == 1 ? compiled.accountIds?.first : nil
            let index = singleAccount == nil ? "thread_label_unified" : "thread_label_account"
            add("""
                SELECT t.accountId, t.id FROM thread_label tl INDEXED BY \(index)
                CROSS JOIN thread t ON t.accountId = tl.accountId AND t.id = tl.threadId
                WHERE tl.labelId = ?
                """)
            arguments.append(id.databaseValue)
            if let singleAccount {
                add(" AND tl.accountId = ?")
                arguments.append(singleAccount.databaseValue)
            }
            if let min = compiled.lastDateMin { add(" AND tl.lastDate >= ?"); arguments.append(min.databaseValue) }
            if let max = compiled.lastDateMax { add(" AND tl.lastDate < ?"); arguments.append(max.databaseValue) }
            add(" AND ")
            add(threadFilter)
            add(" AND ")
            add(messageExists)
            add(" ORDER BY tl.lastDate DESC LIMIT ?")
            arguments.append(limit.databaseValue)
            return try keys(sql, arguments)

        case .threadWalk:
            add("SELECT t.accountId, t.id FROM thread t INDEXED BY thread_by_date WHERE ")
            add(threadFilter)
            add(" AND ")
            add(messageExists)
        }

        add(" ORDER BY t.lastDate DESC LIMIT ?")
        arguments.append(limit.databaseValue)
        return try keys(sql, arguments)
    }

    /// True when some message of thread `t` satisfies the message-level conditions.
    private var messageExists: SQLFragment {
        var conditions = compiled.messageConds
        if let fts = compiled.fts { conditions.append(Self.probe(fts)) }
        let all = SQLFragment.all(conditions)
        if all.isAlways { return .always }
        return SQLFragment(
            "EXISTS (SELECT 1 FROM message m WHERE m.accountId = t.accountId AND m.threadId = t.id AND \(all.sql))",
            all.arguments.map { $0 as any DatabaseValueConvertible })
    }

    static func probe(_ expression: String) -> SQLFragment {
        SQLFragment("EXISTS (SELECT 1 FROM message_fts WHERE message_fts MATCH ? AND rowid = m.seq)", [expression])
    }

    private func keys(_ sql: String, _ arguments: [DatabaseValue]) throws -> [ThreadKey] {
        try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map {
            ThreadKey(accountId: $0[0], threadId: $0[1])
        }
    }

    // MARK: Relevance

    /// Weights per column: subject, sender, recipients, snippet, body.
    private static let bm25 = "bm25(message_fts, 10.0, 4.0, 2.0, 1.0, 1.0)"
    /// How many of the newest matches get ranked when a word is too common to rank them all.
    static let rankedPool = 800

    /// Thread keys, best match first. Exact when the words are rare; for very common words it ranks the newest
    /// `rankedPool` matching messages.
    func rankedThreadKeys(limit: Int) throws -> [ThreadKey] {
        guard let fts = compiled.fts else { return try threadKeys(plan: try choosePlan(), limit: limit) }

        let cap = try ftsCap()
        if try countFTS(fts, cap: cap) <= cap {
            // bm25() cannot be aggregated, so rank messages and keep each thread's best one.
            let messageFilter = SQLFragment.all(compiled.messageConds)
            let threadFilter = SQLFragment.all(compiled.threadConds)
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT m.accountId, m.threadId FROM message_fts f CROSS JOIN message m ON m.seq = f.rowid
                CROSS JOIN thread t ON t.accountId = m.accountId AND t.id = m.threadId
                WHERE message_fts MATCH ? AND \(messageFilter.sql) AND \(threadFilter.sql)
                ORDER BY \(Self.bm25), t.lastDate DESC
                """, arguments: StatementArguments([fts.databaseValue] + messageFilter.arguments + threadFilter.arguments))
            var seen = Set<ThreadKey>()
            var ordered: [ThreadKey] = []
            while ordered.count < limit, let row = try cursor.next() {
                let key = ThreadKey(accountId: row[0], threadId: row[1])
                if seen.insert(key).inserted { ordered.append(key) }
            }
            return ordered
        }

        // Too common to rank everything: newest matching messages first, then score those.
        let messageFilter = SQLFragment.all(compiled.messageConds + [Self.probe(fts)])
        let threadFilter = SQLFragment.all(compiled.threadConds)
        let candidates = try Row.fetchAll(db, sql: """
            SELECT m.seq, m.accountId, m.threadId FROM message m INDEXED BY message_by_date
            WHERE \(messageFilter.sql)
              AND EXISTS (SELECT 1 FROM thread t WHERE t.accountId = m.accountId AND t.id = m.threadId AND \(threadFilter.sql))
            ORDER BY m.date DESC LIMIT \(Self.rankedPool)
            """, arguments: StatementArguments(messageFilter.arguments + threadFilter.arguments))
        guard !candidates.isEmpty else { return [] }

        var order: [ThreadKey] = []
        var bySeq: [Int64: ThreadKey] = [:]
        for row in candidates {
            let key = ThreadKey(accountId: row[1], threadId: row[2])
            bySeq[row[0]] = key
            if !order.contains(key) { order.append(key) }
        }
        let list = bySeq.keys.map(String.init).joined(separator: ",")
        var scores: [ThreadKey: Double] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT rowid, \(Self.bm25) FROM message_fts WHERE message_fts MATCH ? AND rowid IN (\(list))
            """, arguments: [fts]) {
            guard let key = bySeq[row[0]] else { continue }
            let score: Double = row[1]
            scores[key] = min(scores[key] ?? .infinity, score)
        }
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return Array(order.sorted {
            let (a, b) = (scores[$0] ?? .infinity, scores[$1] ?? .infinity)
            return a != b ? a < b : position[$0]! < position[$1]!
        }.prefix(limit))
    }
}
