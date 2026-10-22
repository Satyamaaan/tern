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
    private var failed: [ThreadKey: Int] = [:]
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
    public func prioritize(_ keys: [ThreadKey]) { screen = Array(keys.prefix(60)) }

    private func settingsChanged() async {
        guard let values = try? await database.reader.read({ db in (try AISettings.read(db), try LedgerSettings.load(db)) }) else { return }
        if known != nil && (known != values.0 || ledgerKnown != values.1) {
            generation += 1; call?.cancel(); wake?.cancel(); debounceWait?.cancel(); resumeAt = nil; backoff = 300
            blocked = [:]; failed = [:]; retry = []
        }
        known = values.0; ledgerKnown = values.1
        pokes?.yield()
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
        let screenJSON = String(data: try JSONSerialization.data(withJSONObject: screen.map { [$0.accountId, $0.threadId] }), encoding: .utf8)!
        let threads = try await database.reader.read { db -> [PromptThread] in
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.accountId,t.id,t.messageCount FROM thread t
                LEFT JOIN ledger_scan s ON s.accountId=t.accountId AND s.threadId=t.id
                LEFT JOIN thread_ai ai ON ai.accountId=t.accountId AND ai.threadId=t.id
                WHERE t.lastDate>=? AND (s.threadId IS NULL OR s.messageCount<t.messageCount OR s.promptVersion<?)
                  AND (ai.category IS NULL OR ai.category IN ('people','other'))
                  AND NOT EXISTS (SELECT 1 FROM thread_label x WHERE x.accountId=t.accountId AND x.threadId=t.id
                    AND (x.labelId IN ('TRASH','SPAM','TERN_PENDING_MUTED') OR x.labelId=(SELECT value FROM setting WHERE key='mute.label.' || t.accountId)))
                ORDER BY EXISTS (SELECT 1 FROM json_each(?) visible
                  WHERE json_extract(visible.value,'$[0]')=t.accountId AND json_extract(visible.value,'$[1]')=t.id) DESC,
                  t.lastDate DESC LIMIT 2000
                """, arguments: [stamp.addingTimeInterval(-Double(preferences.backfillDays) * 86_400).timeIntervalSince1970, Prompts.ledgerVersion, screenJSON])
            let order = Dictionary(screen.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
            var keys = rows.filter { blocked[ThreadKey(accountId: $0[0], threadId: $0[1])] != ($0[2] as Int) }.map { ThreadKey(accountId: $0[0], threadId: $0[1]) }
            if let retryKeys { keys = retryKeys.filter { keys.contains($0) } }
            else { keys.sort { order[$0, default: Int.max] < order[$1, default: Int.max] } }
            return try PromptData.threads(db, keys: Array(keys.prefix(size)), messages: 4, characters: 700)
        }
        guard !threads.isEmpty else { return BatchResult(sent: 0, extracted: 0) }
        let open = try await database.reader.read { db in
            try Dictionary(uniqueKeysWithValues: threads.map { thread in
                (thread.key, try Commitment.filter(Column("accountId") == thread.key.accountId && Column("threadId") == thread.key.threadId && Column("state") == "open").fetchAll(db))
            })
        }
        let picked = try await database.writer.write { db -> [PromptThread] in
            guard try AISettings.read(db) == settings, try LedgerSettings.load(db) == preferences else { throw CancellationError() }
            var picked: [PromptThread] = []
            for thread in threads {
                let scan = try LedgerScan.fetchOne(db, key: ["accountId": thread.key.accountId, "threadId": thread.key.threadId])
                // Message counts, not wall-clock scan time, identify arrivals even after a historical sync.
                let oldCount = (scan?.promptVersion ?? 0) < Prompts.ledgerVersion ? 0 : scan?.messageCount ?? 0
                let newMessages = try MailMessage.filter(Column("accountId") == thread.key.accountId && Column("threadId") == thread.key.threadId && Column("isDraft") == false)
                    .order(Column("date"), Column("seq")).limit(-1, offset: oldCount).fetchAll(db)
                let hasList = newMessages.contains { $0.listUnsubscribe != nil }
                let cue = newMessages.contains { CommitmentCues.contains($0.bodyText ?? $0.snippet) }
                let hasOpen = (open[thread.key] ?? []).contains { $0.origin != "rule" }
                if !hasList && (cue || hasOpen) { picked.append(thread) }
                else { try Ledger.recordScan(db, key: thread.key, messageCount: thread.messageCount, promptVersion: Prompts.ledgerVersion, origin: "cue-skip", now: stamp) }
            }
            return picked
        }
        guard !picked.isEmpty else { return BatchResult(sent: threads.count, extracted: 0) }
        let day = Self.day(stamp)
        let reserved = try await database.writer.write { db -> Bool in
            guard try AISettings.read(db) == settings, try LedgerSettings.load(db) == preferences else { return false }
            let saved = try Setting.fetchOne(db, key: "ledger.ai.day")?.value ?? ""
            let parts = saved.split(separator: ":")
            let count = parts.first.map(String.init) == day ? Int(parts.last ?? "0") ?? 0 : 0
            guard count < preferences.aiDailyCalls else { return false }
            try Setting(key: "ledger.ai.day", value: "\(day):\(count + 1)").upsert(db)
            return true
        }
        guard reserved else {
            let stillCurrent = try await database.reader.read { db in try AISettings.read(db) == settings && LedgerSettings.load(db) == preferences }
            guard stillCurrent else { throw CancellationError() }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: stamp))!
            resumeAt = tomorrow
            scheduleWake(after: tomorrow.timeIntervalSince(stamp))
            return BatchResult(sent: 0, extracted: 0)
        }
        let owner = try await database.reader.read { try String.fetchAll($0, sql: "SELECT email FROM account") }
        var request = Prompts.ledger(picked, open: open, owner: owner, today: stamp)
        request.model = settings.model(for: provider)
        let task = Task { try await provider.complete(request) }
        call = task
        do {
            let text = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard generation == self.generation, !Task.isCancelled else { throw CancellationError() }
            let count = try await database.writer.write { db -> Int in
                guard try AISettings.read(db) == settings, try LedgerSettings.load(db) == preferences else { throw CancellationError() }
                guard let verdicts = try LedgerVerdict.parse(text, db: db, threads: picked, open: open), verdicts.count == picked.count else { throw AIError.invalidOutput("Incomplete ledger answer") }
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
            if !(error is CancellationError), case AIError.rateLimited = error { throw error }
            if !(error is CancellationError) {
                let keys = picked.map(\.key)
                for thread in picked {
                    failed[thread.key, default: 0] += 1
                    if failed[thread.key, default: 0] >= 10 || keys.count == 1 && failed[thread.key, default: 0] >= 2 { self.blocked[thread.key] = thread.messageCount }
                }
                if keys.count > 1 { let half = (keys.count + 1) / 2; retry += [Array(keys.prefix(half)), Array(keys.dropFirst(half))] }
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
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
