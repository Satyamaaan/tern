import Foundation
import GRDB
import TernCore

/// Refines triage in the background with the user's AI CLI. It picks threads from the last 30 days
/// whose `ThreadAI` row is missing, rule-sourced as people/other, or older than the thread — the threads
/// on screen first (`prioritize`), then the inbox, newest first — sends them in batches, up to
/// `concurrency` CLI calls at once, and writes the verdicts with `source` set to the provider id.
///
/// Call `start()` once at launch. It watches the `thread` and `setting` tables, so new mail and
/// settings changes trigger a pass; nothing is sent while `ai.enabled` is off.
public actor TriageQueue {
    public enum State: Hashable, Sendable {
        /// `ai.enabled` is off.
        case off
        case idle
        case working
        /// Paused after a usage limit or a failure; resumes on its own at `until`.
        case waiting(until: Date, reason: String)
        /// The CLI isn't installed or signed in. Retried after a while and on any settings change.
        case unavailable(String)
    }

    /// How far the running pass got, for "Sorting 120 of 800".
    public struct Progress: Hashable, Sendable {
        /// Threads the pass has finished with.
        public var done: Int
        /// Threads the pass has found to sort, `done` included. Grows when mail arrives meanwhile.
        public var total: Int

        public init(done: Int, total: Int) {
            self.done = done
            self.total = total
        }
    }

    public struct Status: Hashable, Sendable {
        public var state: State
        /// Threads classified by AI since `start()`.
        public var classified: Int
        public var lastError: String?
        /// Set while a pass is working.
        public var progress: Progress?

        public init(state: State, classified: Int = 0, lastError: String? = nil, progress: Progress? = nil) {
            self.state = state
            self.classified = classified
            self.lastError = lastError
            self.progress = progress
        }
    }

    public struct BatchResult: Hashable, Sendable {
        /// Threads picked for this batch (0 when nothing is left).
        public var sent: Int
        /// Threads that got a verdict written.
        public var classified: Int
    }

    /// Threads per CLI call for a provider. Codex spends about 4 s and 4k tokens of its own on every
    /// call, so bigger batches pay off; Claude's time grows with each thread's answer, so smaller
    /// batches cost it little and come back sooner.
    public static func batchSize(for provider: String) -> Int {
        provider == "codex" ? 30 : 15
    }

    /// Threads on screen are split across the free calls so they come back sooner, but no call gets
    /// fewer than this many (each call has a fixed cost).
    static let minimumScreenBatch = 5
    /// At most this many threads are remembered from `prioritize`.
    static let screenLimit = 60
    /// A thread whose call fails this many times with it alone waits until it changes.
    static let failuresAlone = 2
    /// So does any thread after this many failed calls, however it was batched.
    static let failureLimit = 10
    /// Candidates read per pick: enough to count what is left for the progress line.
    static let scanLimit = 2_000
    /// The latest messages of a thread a prompt shows, and how much of each.
    static let messagesPerThread = 2
    static let charactersPerMessage = 600

    public let database: AppDatabase
    public let providers: AIProviders
    /// Threads per call; nil uses `batchSize(for:)` of the provider in use.
    public let batchSize: Int?
    /// CLI calls a pass runs at once, at most.
    public let concurrency: Int
    /// Only threads whose last message is newer than this many seconds are sent.
    public let window: TimeInterval
    private let debounce: Duration
    private let now: @Sendable () -> Date

    private var status = Status(state: .idle, classified: 0, lastError: nil, progress: nil)
    private var listeners: [UUID: AsyncStream<Status>.Continuation] = [:]
    /// Message count each thread had when last sent, so a thread the model skipped isn't resent
    /// until it changes.
    private var attempted: [ThreadKey: Int] = [:]
    /// Threads in a batch that is being answered.
    private var inFlight: Set<ThreadKey> = []
    /// Threads whose call failed (a time-out, a CLI error, an unreadable answer), with the message count they
    /// had. They go out again only through `retries`, in halves of the batch that failed, so one thread that
    /// breaks a call can't hold the others back.
    private var failures: [ThreadKey: Failure] = [:]
    /// Halves of failed batches, sent after the threads on screen and before the rest.
    private var retries: [[ThreadKey]] = []
    /// Bumped when the AI settings change: calls picked before are cancelled and their answers dropped.
    private(set) var generation = 0
    /// The AI settings the queue last saw.
    private var knownSettings: AISettings?
    /// Interrupts the running pass when the settings change.
    private var interrupt: AsyncStream<Void>.Continuation?
    /// Threads the running pass has finished with: written, or set aside until they change.
    private var passSettled = 0
    /// Threads on screen, sent before the rest.
    private var screen: [ThreadKey] = []
    private var resumeAt: Date?
    private var backoff: TimeInterval = 300
    /// Calls a pass may run at once right now: one after a usage limit, then one more per answer,
    /// up to `concurrency`.
    private var allowed: Int
    private var passRunning = false
    /// A pass was asked for while one ran; it runs again when it ends.
    private var passRequested = false
    /// The next pass skips the debounce (threads on screen are waiting).
    private var urgent = false
    /// The debounce before the next pass; cancelled when threads on screen are waiting.
    private var debounceWait: Task<Void, Never>?
    private var observers: [AnyDatabaseCancellable] = []
    private var loop: Task<Void, Never>?
    private var wake: Task<Void, Never>?
    private var pokes: AsyncStream<Void>.Continuation?

    public init(
        database: AppDatabase, providers: AIProviders = .shared, batchSize: Int? = nil, concurrency: Int = 3,
        window: TimeInterval = 30 * 86_400, debounce: Duration = .seconds(2),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.providers = providers
        self.batchSize = batchSize.map { max(1, $0) }
        self.concurrency = max(1, concurrency)
        self.allowed = max(1, concurrency)
        self.window = window
        self.debounce = debounce
        self.now = now
    }

    // MARK: Lifecycle

    /// Starts watching the database and runs a first pass.
    public func start() {
        guard loop == nil else { return }
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pokes = continuation
        observers = [
            DatabaseRegionObservation(tracking: Table("thread")).start(
                in: database.writer, onError: { _ in }, onChange: { _ in continuation.yield() }),
            DatabaseRegionObservation(tracking: Table("setting")).start(
                in: database.writer, onError: { _ in }, onChange: { [weak self] _ in
                    Task { await self?.settingsChanged() }
                }),
        ]
        continuation.yield()
        loop = Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                await self.waitOutDebounce()
                guard !Task.isCancelled else { return }
                await self.runPass()
            }
        }
    }

    public func stop() {
        observers.forEach { $0.cancel() }
        observers = []
        pokes?.finish()
        pokes = nil
        loop?.cancel()
        loop = nil
        wake?.cancel()
        wake = nil
        debounceWait?.cancel()
    }

    /// Asks for a pass soon, e.g. after the user signs in to the CLI.
    public func poke() {
        if case .unavailable = status.state { resumeAt = nil }
        pokes?.yield()
    }

    /// Sorts these threads before the rest: the rows on screen and the open thread. Each call replaces
    /// the last one. Threads that don't need AI (or are older than `window`) are skipped. A pass starts
    /// at once, without the usual debounce, unless the queue is waiting out a usage limit.
    public func prioritize(_ keys: [ThreadKey]) {
        var seen = Set<ThreadKey>()
        let keys = Array(keys.filter { seen.insert($0).inserted }.prefix(Self.screenLimit))
        guard keys != screen else { return }
        screen = keys
        guard !keys.isEmpty else { return }
        urgent = true
        debounceWait?.cancel()
        pokes?.yield()
    }

    public var currentStatus: Status { status }

    /// The current status, then every change.
    public func statusUpdates() -> AsyncStream<Status> {
        let (stream, continuation) = AsyncStream<Status>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        listeners[id] = continuation
        continuation.yield(status)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeListener(id) } }
        return stream
    }

    // MARK: Passes

    /// Sends batches, several at once, until nothing is left or the provider can't continue.
    public func runPass() async {
        guard !passRunning else {
            passRequested = true
            return
        }
        passRunning = true
        defer { passRunning = false }
        repeat {
            passRequested = false
            if let resumeAt, resumeAt > now() { return }
            resumeAt = nil
            guard await pass() else { return }
        } while passRequested && !Task.isCancelled
    }

    /// One pass. Returns false when it stopped early (AI off, a failure, cancellation). A settings change
    /// cancels its calls and asks for a new pass with the new settings.
    private func pass() async -> Bool {
        passSettled = 0
        var stop: Error?
        let (signals, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        interrupt = signal
        await withTaskGroup(of: Event.self) { group in
            group.addTask {
                for await _ in signals { return .settingsChanged }
                return .ended
            }
            var running = 0
            while true {
                while stop == nil, running < min(allowed, concurrency), !Task.isCancelled {
                    do {
                        guard let job = try await nextJob(free: min(allowed, concurrency) - running) else { break }
                        running += 1
                        status.progress = Progress(done: passSettled, total: passSettled + job.remainingAfterPick)
                        setState(.working)
                        group.addTask { .answer(await job.run()) }
                    } catch {
                        stop = Self.worse(stop, error)
                    }
                }
                guard running > 0, let event = await group.next() else { break }
                switch event {
                case .settingsChanged:
                    // Kills the CLIs that run and drops the calls still waiting for a slot.
                    stop = SettingsChanged()
                    group.cancelAll()
                case .ended:
                    continue
                case .answer(let answer):
                    running -= 1
                    do {
                        try await finish(answer)
                    } catch AIError.invalidOutput(let message) {
                        // Its threads go out again in halves; the rest carry on.
                        status.lastError = message
                    } catch {
                        stop = Self.worse(stop, error)
                    }
                    if let progress = status.progress {
                        status.progress = Progress(done: passSettled, total: max(progress.total, passSettled + inFlight.count))
                        publish()
                    }
                }
            }
            signal.finish()
        }
        interrupt = nil
        status.progress = nil
        if stop is SettingsChanged {
            passRequested = true
            return true
        }
        guard let stop else {
            setState(.idle)
            return true
        }
        handle(stop)
        return false
    }

    /// Classifies one batch. Throws `AIError.disabled` when AI is off.
    @discardableResult
    public func processBatch() async throws -> BatchResult {
        guard let job = try await nextJob(free: 1) else { return BatchResult(sent: 0, classified: 0) }
        setState(.working)
        let written = try await finish(await job.run())
        return BatchResult(sent: job.picked.count, classified: written)
    }

    // MARK: Steps

    struct Candidate: Hashable, Sendable {
        var key: ThreadKey
        var messageCount: Int
    }

    struct Failure: Hashable, Sendable {
        var messageCount: Int
        /// Failed calls the thread was in.
        var count = 0
        /// Of those, calls with it alone.
        var alone = 0
    }

    /// The AI settings changed while a pass ran.
    private struct SettingsChanged: Error {}

    private enum Event: Sendable {
        case answer(Answer)
        case settingsChanged
        /// The pass's settings watcher stopped.
        case ended
    }

    /// One CLI call's worth of threads, claimed until its answer is handled.
    struct Job: Sendable {
        var queue: TriageQueue
        /// The settings it was picked under, and their generation.
        var settings: AISettings
        var generation: Int
        var provider: any AIProvider
        var request: AIRequest
        var picked: [Candidate]
        var threads: [PromptThread]
        var refs: [String]
        var projects: [Project]
        var autoProjects: Bool
        /// Threads still to send when this one was picked, its own included.
        var remainingAfterPick: Int

        func run() async -> Answer {
            let started = Date()
            // The settings may have changed while this call waited to start.
            guard await queue.isCurrent(generation) else {
                return Answer(job: self, verdicts: .failure(CancellationError()), seconds: 0)
            }
            do {
                let verdicts = try await TriageQueue.ask(provider, request, refs: Set(refs), projects: projects)
                return Answer(job: self, verdicts: .success(verdicts), seconds: Date().timeIntervalSince(started))
            } catch {
                return Answer(job: self, verdicts: .failure(error), seconds: Date().timeIntervalSince(started))
            }
        }
    }

    struct Answer: Sendable {
        var job: Job
        var verdicts: Result<[TriageVerdict], Error>
        var seconds: TimeInterval
    }

    private struct Pick: Sendable {
        enum Kind: Sendable { case screen, retry, backlog }

        var kind: Kind
        var picked: [Candidate]
        var remaining: Int
        var threads: [PromptThread]
        var owner: [String]
        var projects: [Project]?
    }

    /// The next batch: threads on screen first, split across `free` calls; then halves of failed batches;
    /// then the provider's batch size from the queue. Claims its threads; nil when nothing is left. Throws
    /// `SettingsChanged` when it finds new settings while a pass runs.
    private func nextJob(free: Int) async throws -> Job? {
        let settings = try await database.reader.read { db in try AISettings.read(db) }
        if observe(settings), interrupt != nil { throw SettingsChanged() }
        // A later change makes this job stale before it starts.
        let generation = generation
        guard settings.enabled else { throw AIError.disabled }
        let provider = try await providers.resolve(settings)
        let size = batchSize ?? Self.batchSize(for: provider.id)
        let since = now().addingTimeInterval(-window)
        let screen = screen

        while true {
            let skip = attempted
            let busy = inFlight
            let failing = failures
            let retry = retries.first ?? []
            let pick = try await database.reader.read { db -> Pick in
                let failed = { (candidate: Candidate) in failing[candidate.key]?.messageCount == candidate.messageCount }
                let open = { (candidate: Candidate) in
                    skip[candidate.key] != candidate.messageCount && !busy.contains(candidate.key) && !failed(candidate)
                }
                let all = try Self.candidates(db, since: since, limit: Self.scanLimit).filter(open)
                var kind = Pick.Kind.backlog
                var picked = Array(all.prefix(size))
                if !screen.isEmpty {
                    let order = Dictionary(screen.enumerated().map { ($1, $0) }) { first, _ in first }
                    let onScreen = try Self.candidates(db, since: since, limit: screen.count, keys: screen)
                        .filter(open).sorted { order[$0.key, default: 0] < order[$1.key, default: 0] }
                    if !onScreen.isEmpty {
                        let share = (onScreen.count + max(1, free) - 1) / max(1, free)
                        picked = Array(onScreen.prefix(min(size, max(Self.minimumScreenBatch, share))))
                        kind = .screen
                    }
                }
                if kind != .screen, !retry.isEmpty {
                    picked = try Self.candidates(db, since: since, limit: retry.count, keys: retry)
                        .filter { failed($0) && !busy.contains($0.key) && skip[$0.key] != $0.messageCount }
                    kind = .retry
                }
                let threads = try PromptData.threads(
                    db, keys: picked.map(\.key), messages: Self.messagesPerThread, characters: Self.charactersPerMessage)
                let owner = try String.fetchAll(db, sql: "SELECT email FROM account ORDER BY sortOrder, email")
                let projects = settings.autoProjects ? try Project.order(Column("sortOrder"), Column("name")).fetchAll(db) : nil
                return Pick(
                    kind: kind, picked: picked, remaining: max(all.count, picked.count) + failing.count,
                    threads: threads, owner: owner, projects: projects)
            }
            if pick.kind == .retry {
                // The half leaves the queue; its threads that changed or need no AI any more leave the failures.
                if let index = retries.firstIndex(of: retry) { retries.remove(at: index) }
                let kept = Set(pick.picked.map(\.key))
                for key in retry where !kept.contains(key) && !inFlight.contains(key) { failures[key] = nil }
            } else {
                // A failure recorded for an older version of a thread doesn't count any more.
                for candidate in pick.picked where failures[candidate.key] != nil { failures[candidate.key] = nil }
            }
            // Another pick may have claimed some of these while this one read.
            let picked = pick.picked.filter { !inFlight.contains($0.key) && attempted[$0.key] != $0.messageCount }
            guard !picked.isEmpty else {
                if pick.kind == .retry { continue }
                return nil
            }
            let keys = Set(picked.map(\.key))
            let threads = pick.threads.filter { keys.contains($0.key) }
            guard !threads.isEmpty else {
                // Nothing to show a model (no messages left); don't pick them again until they change.
                markSent(picked)
                continue
            }
            inFlight.formUnion(keys)

            let refs = threads.indices.map { String($0 + 1) }
            var request = Prompts.triage(threads, refs: refs, owner: pick.owner, projects: pick.projects, today: now())
            request.model = settings.model(for: provider)
            request.isBackground = true
            return Job(
                queue: self, settings: settings, generation: generation, provider: provider, request: request,
                picked: picked, threads: threads, refs: refs, projects: pick.projects ?? [],
                autoProjects: settings.autoProjects, remainingAfterPick: busy.count + pick.remaining)
        }
    }

    /// Writes an answer and releases its threads. Verdicts mark them sent. A failure of this call (a
    /// time-out, a CLI error, an unreadable answer) sends them again in halves, or sets a thread aside once it
    /// failed alone; any other failure (a usage limit, a sign-out) sends them again as they were. An answer
    /// from before a settings change is dropped. Rethrows the failure.
    @discardableResult
    private func finish(_ answer: Answer) async throws -> Int {
        let job = answer.job
        let keys = Set(job.picked.map(\.key))
        defer { inFlight.subtract(keys) }
        guard job.generation == generation else {
            release(job)
            return 0
        }
        let verdicts: [TriageVerdict]
        switch answer.verdicts {
        case .success(let value):
            verdicts = value
        case .failure(let error):
            switch error {
            case AIError.timedOut, AIError.failed: charge(job, unreadable: false)
            case AIError.invalidOutput: charge(job, unreadable: true)
            default: release(job)
            }
            throw error
        }
        let threadsByRef = Dictionary(uniqueKeysWithValues: zip(job.refs, job.threads))
        let classifiedAt = now()
        let source = job.provider.id
        let settings = job.settings
        let written = try await database.writer.write { db -> Int? in
            // AI was turned off, or the provider, model or projects setting changed, since the call went out.
            guard try AISettings.read(db) == settings else { return nil }
            return try Self.write(db, verdicts, threads: threadsByRef, source: source, autoProjects: settings.autoProjects, at: classifiedAt)
        }
        guard let written else {
            release(job)
            return 0
        }
        markSent(job.picked)
        status.classified += written
        allowed = min(concurrency, allowed + 1)
        backoff = 300
        aiLog.info("triage: \(written) of \(job.threads.count) threads classified by \(source, privacy: .public) in \(answer.seconds, format: .fixed(precision: 1))s")
        return written
    }

    /// The call itself failed: each thread counts a failure, and the batch goes out again in two halves. A
    /// thread that failed alone `failuresAlone` times (once, when the answer was unreadable after its retry),
    /// or `failureLimit` times in all, is set aside until it changes.
    private func charge(_ job: Job, unreadable: Bool) {
        let alone = job.picked.count == 1
        var again: [ThreadKey] = []
        for candidate in job.picked {
            var failure = failures[candidate.key].flatMap { $0.messageCount == candidate.messageCount ? $0 : nil }
                ?? Failure(messageCount: candidate.messageCount)
            failure.count += 1
            if alone { failure.alone += unreadable ? Self.failuresAlone : 1 }
            if failure.alone >= Self.failuresAlone || failure.count >= Self.failureLimit {
                failures[candidate.key] = nil
                markSent([candidate])
                aiLog.error("triage: a thread failed \(failure.count) calls; it waits until it changes")
            } else {
                failures[candidate.key] = failure
                again.append(candidate.key)
            }
        }
        guard !again.isEmpty else { return }
        let half = (again.count + 1) / 2
        retries.append(Array(again.prefix(half)))
        if again.count > half { retries.append(Array(again.dropFirst(half))) }
    }

    /// The call didn't count against its threads: they go out again, failed ones as the half they were.
    private func release(_ job: Job) {
        let pending = job.picked.map(\.key).filter { failures[$0] != nil }
        if !pending.isEmpty { retries.insert(pending, at: 0) }
    }

    /// These threads aren't sent again until they change.
    private func markSent(_ candidates: [Candidate]) {
        for candidate in candidates { attempted[candidate.key] = candidate.messageCount }
        passSettled += candidates.count
    }

    func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation
    }

    /// Threads that need an AI verdict, inbox first, newest first. `keys` limits it to those threads.
    static func candidates(_ db: Database, since: Date, limit: Int, keys: [ThreadKey]? = nil) throws -> [Candidate] {
        var arguments: StatementArguments = [since.timeIntervalSince1970]
        var only = ""
        if let keys {
            guard !keys.isEmpty else { return [] }
            only = "AND (t.accountId, t.id) IN (VALUES \(keys.map { _ in "(?, ?)" }.joined(separator: ", ")))"
            for key in keys { _ = arguments.append(contentsOf: [key.accountId, key.threadId]) }
        }
        _ = arguments.append(contentsOf: [limit])
        return try Row.fetchAll(db, sql: """
            SELECT t.accountId, t.id, t.messageCount FROM thread t
            LEFT JOIN thread_ai ai ON ai.accountId = t.accountId AND ai.threadId = t.id
            WHERE t.lastDate >= ? AND t.lastInboundDate IS NOT NULL \(only)
              AND (ai.threadId IS NULL OR ai.messageCount < t.messageCount
                   OR (ai.source = 'rules' AND ai.category IN ('people', 'other')))
              AND NOT EXISTS (SELECT 1 FROM thread_label x WHERE x.accountId = t.accountId AND x.threadId = t.id
                AND x.labelId IN ('TRASH', 'SPAM'))
            ORDER BY EXISTS (SELECT 1 FROM thread_label i WHERE i.accountId = t.accountId AND i.threadId = t.id
                AND i.labelId = 'INBOX') DESC, t.lastDate DESC
            LIMIT ?
            """, arguments: arguments
        ).map { Candidate(key: ThreadKey(accountId: $0[0], threadId: $0[1]), messageCount: $0[2]) }
    }

    /// Asks once, and once more when the answer can't be read.
    static func ask(_ provider: any AIProvider, _ request: AIRequest, refs: Set<String>, projects: [Project]) async throws -> [TriageVerdict] {
        for attempt in 1...2 {
            let answer = try await provider.complete(request)
            if let verdicts = TriageVerdict.parse(answer, refs: refs, projects: projects), !verdicts.isEmpty {
                return verdicts
            }
            aiLog.error("triage: unreadable answer from \(provider.id, privacy: .public) (attempt \(attempt))")
        }
        throw AIError.invalidOutput("The triage answer couldn't be read.")
    }

    static func write(
        _ db: Database, _ verdicts: [TriageVerdict], threads: [String: PromptThread], source: String,
        autoProjects: Bool, at date: Date
    ) throws -> Int {
        var written = 0
        for verdict in verdicts {
            guard let thread = threads[verdict.ref] else { continue }
            let key = thread.key
            guard try MailThread.exists(db, key: ["accountId": key.accountId, "id": key.threadId]) else { continue }
            // Sync may have added mail (and rules a newer row) while the model was thinking.
            if let existing = try ThreadAI.fetchOne(db, key: ["accountId": key.accountId, "threadId": key.threadId]),
               existing.messageCount > thread.messageCount {
                continue
            }
            let lastIsInbound = thread.messages.last.map { !$0.isFromMe } ?? false
            let canNeedReply = lastIsInbound && ![.newsletter, .promotion, .receipt].contains(verdict.category)
            try ThreadAI(
                accountId: key.accountId, threadId: key.threadId, category: verdict.category,
                needsReply: verdict.needsReply && canNeedReply, priority: verdict.priority, summary: verdict.summary,
                source: source, messageCount: thread.messageCount, classifiedAt: date
            ).upsert(db)
            if autoProjects { try assign(db, key, project: verdict.project) }
            written += 1
        }
        return written
    }

    /// AI suggestions only fill gaps: they never replace a rule or manual assignment, never undo a manual
    /// removal, and a thread keeps at most the latest suggestion.
    private static func assign(_ db: Database, _ key: ThreadKey, project: String?) throws {
        let current = try ThreadProject.filter(Column("accountId") == key.accountId && Column("threadId") == key.threadId).fetchAll(db)
        for link in current where link.source == .ai && link.projectId != project {
            try link.delete(db)
        }
        guard let project, !current.contains(where: { $0.projectId == project }), try Project.exists(db, key: project),
              try !ProjectRules.isExcluded(db, key, from: project) else { return }
        try ThreadProject(accountId: key.accountId, threadId: key.threadId, projectId: project, source: .ai).insert(db)
    }

    // MARK: State

    /// The more telling of two reasons to stop a pass: AI off, then no CLI, then a usage limit, then
    /// anything else.
    static func worse(_ current: Error?, _ new: Error) -> Error {
        func rank(_ error: Error) -> Int {
            switch error {
            case is SettingsChanged: 6
            case AIError.disabled: 5
            case AIError.notInstalled, AIError.notSignedIn: 4
            case AIError.rateLimited: 3
            case is CancellationError: 2
            default: 1
            }
        }
        guard let current else { return new }
        return rank(new) > rank(current) ? new : current
    }

    private func handle(_ error: Error) {
        switch error {
        case AIError.disabled:
            setState(.off)
        case is CancellationError:
            publish()
        case let error as AIError:
            status.lastError = error.localizedDescription
            switch error {
            case .notInstalled, .notSignedIn:
                pause(for: 600, state: .unavailable(error.localizedDescription))
            case .rateLimited:
                // Once per pass, however many calls hit the limit; the next pass starts with one call.
                pause(for: backoff, state: nil, reason: error.localizedDescription)
                backoff = min(backoff * 2, 3_600)
                allowed = 1
            case .timedOut, .failed, .invalidOutput, .disabled:
                pause(for: 120, state: nil, reason: error.localizedDescription)
            }
        default:
            status.lastError = error.localizedDescription
            pause(for: 120, state: nil, reason: error.localizedDescription)
        }
    }

    private func pause(for seconds: TimeInterval, state: State?, reason: String = "") {
        let until = now().addingTimeInterval(seconds)
        resumeAt = until
        setState(state ?? .waiting(until: until, reason: reason))
        wake?.cancel()
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.poke()
        }
    }

    /// Waits `debounce` before a pass, or not at all when threads on screen are waiting (`prioritize`
    /// cancels the wait).
    private func waitOutDebounce() async {
        if !urgent {
            let wait = Task { [debounce] in _ = try? await Task.sleep(for: debounce) }
            debounceWait = wait
            await wait.value
            debounceWait = nil
        }
        urgent = false
    }

    private func settingsChanged() async {
        guard let settings = try? await database.reader.read({ db in try AISettings.read(db) }) else { return }
        let firstSeen = knownSettings == nil
        guard observe(settings) || firstSeen else { return }
        resumeAt = nil
        backoff = 300
        allowed = concurrency
        pokes?.yield()
    }

    /// Notes the AI settings in force. When they changed from what the queue saw before, a new generation
    /// starts: the running pass is interrupted, which cancels its calls. Returns whether they changed.
    @discardableResult
    private func observe(_ settings: AISettings) -> Bool {
        defer { knownSettings = settings }
        guard let known = knownSettings, known != settings else { return false }
        generation += 1
        interrupt?.yield()
        return true
    }

    private func setState(_ state: State) {
        status.state = state
        publish()
    }

    private func publish() {
        for listener in listeners.values { listener.yield(status) }
    }

    private func removeListener(_ id: UUID) {
        listeners[id] = nil
    }
}
