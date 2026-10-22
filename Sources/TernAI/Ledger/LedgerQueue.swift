import Foundation
import GRDB
import TernCore

/// Low-priority extraction of explicit commitments. Mail screens continue to read SQLite only.
public actor LedgerQueue {
    public struct BatchResult: Sendable {
        public var sent: Int
        public var extracted: Int
    }
    public let database: AppDatabase
    public let providers: AIProviders
    private let now: @Sendable () -> Date
    private let triageIdle: @Sendable () async -> Bool
    private let debounce: Duration
    private var observers: [AnyDatabaseCancellable] = []
    private var loop: Task<Void, Never>?
    private var call: Task<String, Error>?
    private var wake: Task<Void, Never>?
    private var debounceWait: Task<Void, Never>?
    private var pokes: AsyncStream<Void>.Continuation?
    private var screen: [ThreadKey] = []
    private var generation = 0
    private var known: AISettings?
    private var ledgerKnown: LedgerSettings?
    private var retry: [[ThreadKey]] = []
    private struct Failure {
        var messageCount: Int
        var count = 0
        var alone = 0
    }
    private var failed: [ThreadKey: Failure] = [:]
    private var blocked: [ThreadKey: Int] = [:]
    private var running = false
    private var resumeAt: Date?
    private var backoff = 300.0

    public init(database: AppDatabase, providers: AIProviders = .shared, debounce: Duration = .seconds(5),
                now: @escaping @Sendable () -> Date = { Date() }, triageIdle: @escaping @Sendable () async -> Bool = { true }) {
        self.database = database; self.providers = providers; self.debounce = debounce
        self.now = now; self.triageIdle = triageIdle
    }

    public static func batchSize(for provider: String) -> Int { provider == "codex" ? 10 : 6 }

    public func start() {
        guard loop == nil else { return }
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pokes = continuation
        observers = [DatabaseRegionObservation(tracking: Table("thread")).start(in: database.writer, onError: { _ in }, onChange: { _ in continuation.yield() }),
            DatabaseRegionObservation(tracking: Table("setting")).start(in: database.writer, onError: { _ in }, onChange: { [weak self] _ in Task { await self?.settingsChanged() } })]
        continuation.yield()
        loop = Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                await self.runPass()
                if Task.isCancelled { return }
            }
        }
    }

    public func stop() {
        observers.forEach { $0.cancel() }; observers = []
        pokes?.finish(); pokes = nil; loop?.cancel(); loop = nil; call?.cancel(); wake?.cancel(); debounceWait?.cancel()
    }
    public func poke() { pokes?.yield() }
    /// Releases an in-flight provider slot as soon as triage needs it.
    public func yieldToTriage() {
        guard call != nil else { return }
        generation += 1
        call?.cancel()
    }
    public func prioritize(_ keys: [ThreadKey]) { screen = Array(Set(keys.prefix(60))) }

    private func settingsChanged() async {
        guard let values = try? await database.reader.read({ db in (try AISettings.read(db), try LedgerSettings.load(db)) }) else { return }
        let changed = known == nil || known != values.0 || ledgerKnown.map { !Self.sameExtractionSettings($0, values.1) } == true
        if known != nil && (known != values.0 || ledgerKnown.map { !Self.sameExtractionSettings($0, values.1) } == true) {
            generation += 1; call?.cancel(); wake?.cancel(); debounceWait?.cancel(); resumeAt = nil; backoff = 300
            blocked = [:]; failed = [:]; retry = []
        }
        known = values.0; ledgerKnown = values.1
        if changed { pokes?.yield() }
    }

    private static func sameExtractionSettings(_ a: LedgerSettings, _ b: LedgerSettings) -> Bool {
        a.enabled == b.enabled && a.ai == b.ai && a.backfillDays == b.backfillDays
    }

    private func runPass() async {
        let wait = Task { [debounce] in _ = try? await Task.sleep(for: debounce) }
        debounceWait = wait
        await wait.value
        debounceWait = nil
        guard !Task.isCancelled else { return }
        do {
            while !Task.isCancelled {
                if !(await triageIdle()) {
                    // Never occupy a provider slot while triage has visible rows or a backlog in flight.
                    try await Task.sleep(for: .seconds(5)); continue
                }
                let result = try await processBatch()
                if result.sent == 0 { break }
                await Task.yield()
            }
        } catch {
            if Task.isCancelled { return }
            let delay: Double
            if case AIError.rateLimited = error { delay = backoff; backoff = min(3_600, backoff * 2) }
            else if error is CancellationError { delay = 0 }
            else { delay = 120 }
            resumeAt = now().addingTimeInterval(delay)
            aiLog.error("ledger: extraction paused (no mail logged)")
            scheduleWake(after: delay)
        }
    }

    /// Processes one bounded call, also used by the deterministic tests and gated evaluation.
    @discardableResult
    public func processBatch() async throws -> BatchResult {
        guard !running else { return BatchResult(sent: 0, extracted: 0) }
        running = true
        defer { running = false; call = nil }
        if let resumeAt, resumeAt > now() { return BatchResult(sent: 0, extracted: 0) }
        guard await triageIdle() else { return BatchResult(sent: 0, extracted: 0) }
        let settings = try await database.reader.read { try AISettings.read($0) }
        let preferences = try await database.reader.read { try LedgerSettings.load($0) }
        guard preferences.enabled && preferences.ai, await providers.isEnabled(settings) else { return BatchResult(sent: 0, extracted: 0) }
        let provider = try await providers.resolve(settings)
        known = settings; ledgerKnown = preferences
        let stamp = now()
        let generation = generation
        let screen = screen; let blocked = blocked
        let retryKeys = retry.isEmpty ? nil : retry.removeFirst()
        let size = Self.batchSize(for: provider.id)
        let visible = screen.isEmpty ? "(NULL,NULL)" : screen.map { _ in "(?,?)" }.joined(separator: ",")
        var queryArguments = StatementArguments(screen.flatMap { [$0.accountId, $0.threadId] })
        _ = queryArguments.append(contentsOf: [stamp.addingTimeInterval(-Double(preferences.backfillDays) * 86_400).timeIntervalSince1970, Prompts.ledgerVersion])
        let candidateArguments = queryArguments
        var threads = try await database.reader.read { db -> [PromptThread] in
            let rows = try Row.fetchAll(db, sql: """
                WITH visible(accountId,threadId) AS (VALUES \(visible))
                SELECT t.accountId,t.id,t.messageCount FROM thread t
                LEFT JOIN visible v ON v.accountId=t.accountId AND v.threadId=t.id
                LEFT JOIN ledger_scan s ON s.accountId=t.accountId AND s.threadId=t.id
                LEFT JOIN thread_ai ai ON ai.accountId=t.accountId AND ai.threadId=t.id
                WHERE t.lastDate>=? AND (s.threadId IS NULL OR s.messageCount<t.messageCount OR s.promptVersion<?)
                  AND (ai.category IS NULL OR ai.category IN ('people','other'))
                  AND NOT EXISTS (SELECT 1 FROM thread_label x WHERE x.accountId=t.accountId AND x.threadId=t.id
                    AND (x.labelId IN ('TRASH','SPAM','TERN_PENDING_MUTED') OR x.labelId=(SELECT value FROM setting WHERE key='mute.label.' || t.accountId)))
                ORDER BY v.threadId IS NOT NULL DESC,
                  t.lastDate DESC,t.id,t.accountId LIMIT 2000
                """, arguments: candidateArguments)
            var keys = rows.filter { blocked[ThreadKey(accountId: $0[0], threadId: $0[1])] != ($0[2] as Int) }.map { ThreadKey(accountId: $0[0], threadId: $0[1]) }
            if let retryKeys { keys = retryKeys.filter { keys.contains($0) } }
            return try PromptData.threads(db, keys: Array(keys.prefix(size)), messages: 4, characters: 700)
        }
        var resolving: [Commitment] = []
        if threads.isEmpty {
            resolving = try await database.reader.read { db in
                try Commitment.fetchAll(db, sql: """
                    SELECT c.* FROM commitment c JOIN thread t ON t.accountId=c.accountId AND t.id=c.threadId
                    WHERE c.state='open' AND c.stateSource!='user' AND c.kind!='reply'
                      AND c.hintMessageId IS NOT NULL AND c.checkedCount<t.messageCount
                      AND NOT EXISTS (SELECT 1 FROM message m WHERE m.accountId=c.accountId AND m.threadId=c.threadId AND m.listUnsubscribe IS NOT NULL)
                      AND NOT EXISTS (SELECT 1 FROM thread_label x WHERE x.accountId=c.accountId AND x.threadId=c.threadId
                        AND (x.labelId IN ('TRASH','SPAM','TERN_PENDING_MUTED') OR x.labelId=(SELECT value FROM setting WHERE key='mute.label.' || c.accountId)))
                    ORDER BY c.updatedAt LIMIT 6
                    """)
            }
            let keys = Array(Set(resolving.map { ThreadKey(accountId: $0.accountId, threadId: $0.threadId) }))
            threads = try await database.reader.read { db in
                var values = try PromptData.threads(db, keys: keys, messages: 12, characters: 2000)
                for i in values.indices {
                    for j in values[i].messages.indices {
                        let names = try String.fetchAll(db, sql: "SELECT filename FROM attachment WHERE accountId=? AND messageId=? AND isInline=0", arguments: [values[i].key.accountId, values[i].messages[j].id])
                        if !names.isEmpty { values[i].messages[j].text += "\nAttachments: " + names.joined(separator: ", ") }
                    }
                }
                return values
            }
        }
        guard !threads.isEmpty else { return BatchResult(sent: 0, extracted: 0) }
        let inspectedThreads = threads
        let open = try await database.reader.read { db in
            try Dictionary(uniqueKeysWithValues: inspectedThreads.map { thread in
                (thread.key, try Commitment.filter(Column("accountId") == thread.key.accountId && Column("threadId") == thread.key.threadId && Column("state") == "open").fetchAll(db))
            })
        }
        let resolutionItems = resolving
        let candidateThreads = threads
        let picked = try await database.writer.write { db -> [PromptThread] in
            guard try AISettings.read(db) == settings, Self.sameExtractionSettings(try LedgerSettings.load(db), preferences) else { throw CancellationError() }
            var picked: [PromptThread] = []
            for thread in candidateThreads {
                let cue = thread.messages.contains { CommitmentCues.contains($0.text) }
                let hasList = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM message WHERE accountId=? AND threadId=? AND listUnsubscribe IS NOT NULL LIMIT 1)", arguments: [thread.key.accountId, thread.key.threadId]) ?? false
                let hasOpen = (open[thread.key] ?? []).contains { $0.origin != "rule" }
                if !hasList && (cue || hasOpen || !resolutionItems.isEmpty) { picked.append(thread) }
                else { try Ledger.recordScan(db, key: thread.key, messageCount: thread.messageCount, promptVersion: Prompts.ledgerVersion, origin: "cue-skip", now: stamp) }
            }
            return picked
        }
        guard !picked.isEmpty else { return BatchResult(sent: threads.count, extracted: 0) }
        let day = Self.day(stamp)
        let reserved = try await database.writer.write { db -> Bool in
            guard try AISettings.read(db) == settings, Self.sameExtractionSettings(try LedgerSettings.load(db), preferences) else { return false }
            let saved = try Setting.fetchOne(db, key: "ledger.ai.day")?.value ?? ""
            let parts = saved.split(separator: ":")
            let count = parts.first.map(String.init) == day ? Int(parts.last ?? "0") ?? 0 : 0
            guard count < preferences.aiDailyCalls else { return false }
            try Setting(key: "ledger.ai.day", value: "\(day):\(count + 1)").upsert(db)
            return true
        }
        guard reserved else {
            let stillCurrent = try await database.reader.read { db in try AISettings.read(db) == settings && Self.sameExtractionSettings(try LedgerSettings.load(db), preferences) }
            guard stillCurrent else { throw CancellationError() }
            let calendar = Calendar.current
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: stamp))!
            resumeAt = tomorrow
            scheduleWake(after: tomorrow.timeIntervalSince(stamp))
            return BatchResult(sent: 0, extracted: 0)
        }
        let owner = try await database.reader.read { try String.fetchAll($0, sql: "SELECT email FROM account") }
        var request = resolutionItems.isEmpty ? Prompts.ledger(picked, open: open, owner: owner, today: stamp) : LedgerResolution.request(picked, items: resolutionItems)
        request.model = settings.model(for: provider)
        let task = Task { try await provider.complete(request) }
        call = task
        do {
            let text = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard generation == self.generation, !Task.isCancelled else { throw CancellationError() }
            if !resolutionItems.isEmpty {
                let count = try await database.writer.write { db in
                    guard try AISettings.read(db) == settings, Self.sameExtractionSettings(try LedgerSettings.load(db), preferences) else { throw CancellationError() }
                    guard let count = try LedgerResolution.apply(text, db: db, threads: picked, items: resolutionItems, now: stamp) else { throw AIError.invalidOutput("Invalid resolution answer") }
                    return count
                }
                return BatchResult(sent: picked.count, extracted: count)
            }
            guard let verdicts = try await database.reader.read({ db in
                try LedgerVerdict.parse(text, db: db, threads: picked, open: open)
            }) else { throw AIError.invalidOutput("Invalid ledger answer") }
            let missing = picked.filter { thread in !verdicts.contains { $0.thread.key == thread.key } }
            for thread in missing {
                var failure = failed[thread.key].flatMap { $0.messageCount == thread.messageCount ? $0 : nil } ?? Failure(messageCount: thread.messageCount)
                failure.count += 1
                if picked.count == 1 { failure.alone += 1 }
                failed[thread.key] = failure
                if failure.count >= 10 || failure.alone >= 2 { self.blocked[thread.key] = thread.messageCount }
                else { retry.append([thread.key]) }
            }
            let count = try await database.writer.write { db -> Int in
                guard try AISettings.read(db) == settings, Self.sameExtractionSettings(try LedgerSettings.load(db), preferences) else { throw CancellationError() }
                for verdict in verdicts {
                    try Ledger.applyExtraction(db, key: verdict.thread.key, items: verdict.items, messageCount: verdict.thread.messageCount,
                        promptVersion: Prompts.ledgerVersion, origin: provider.id, now: stamp)
                    for update in verdict.updates {
                        try Ledger.applyResolutionHint(db, id: update.id, messageId: update.messageId, at: update.date,
                            note: update.note, newDueAt: update.due, now: stamp)
                    }
                }
                return verdicts.reduce(0) { $0 + $1.items.count }
            }
            backoff = 300
            return BatchResult(sent: threads.count, extracted: count)
        } catch {
            let cancelled = error is CancellationError || task.isCancelled || generation != self.generation || Task.isCancelled
            // Refund interruptions and provider failures. Invalid output consumed a useful call and remains charged.
            let invalid: Bool
            if case AIError.invalidOutput = error { invalid = true } else { invalid = false }
            if cancelled || !invalid {
                try await database.writer.write { db in
                    guard let saved = try Setting.fetchOne(db, key: "ledger.ai.day"), saved.value.hasPrefix(day + ":") else { return }
                    let count = Int(saved.value.split(separator: ":").last ?? "0") ?? 0
                    try Setting(key: "ledger.ai.day", value: "\(day):\(max(0, count - 1))").upsert(db)
                }
            }
            if cancelled { throw CancellationError() }
            if !(error is CancellationError), case AIError.rateLimited = error { throw error }
            if !(error is CancellationError) {
                let keys = picked.map(\.key)
                for thread in picked {
                    var failure = failed[thread.key].flatMap { $0.messageCount == thread.messageCount ? $0 : nil } ?? Failure(messageCount: thread.messageCount)
                    failure.count += 1
                    if keys.count == 1 { failure.alone += 1 }
                    failed[thread.key] = failure
                    if failure.count >= 10 || failure.alone >= 2 { self.blocked[thread.key] = thread.messageCount }
                }
                if keys.count > 1 { let half = (keys.count + 1) / 2; retry += [Array(keys.prefix(half)), Array(keys.dropFirst(half))] }
                else if let key = keys.first, self.blocked[key] == nil { retry.append(keys) }
            }
            throw error
        }
    }

    private func scheduleWake(after seconds: TimeInterval) {
        wake?.cancel()
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, seconds)))
            guard !Task.isCancelled else { return }
            await self?.poke()
        }
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
