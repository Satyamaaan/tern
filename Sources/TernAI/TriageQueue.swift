import Foundation
import GRDB
import TernCore

/// Refines triage in the background with the user's AI CLI. It picks threads from the last 30 days
/// whose `ThreadAI` row is missing, rule-sourced as people/other, or older than the thread, sends them
/// in batches, and writes the verdicts with `source` set to the provider id.
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

    public struct Status: Hashable, Sendable {
        public var state: State
        /// Threads classified by AI since `start()`.
        public var classified: Int
        public var lastError: String?
    }

    public struct BatchResult: Hashable, Sendable {
        /// Threads picked for this batch (0 when nothing is left).
        public var sent: Int
        /// Threads that got a verdict written.
        public var classified: Int
    }

    public let database: AppDatabase
    public let providers: AIProviders
    public let batchSize: Int
    /// Only threads whose last message is newer than this many seconds are sent.
    public let window: TimeInterval
    private let debounce: Duration
    private let now: @Sendable () -> Date

    private var status = Status(state: .idle, classified: 0, lastError: nil)
    private var listeners: [UUID: AsyncStream<Status>.Continuation] = [:]
    /// Message count each thread had when last sent, so a thread the model skipped isn't resent
    /// until it changes.
    private var attempted: [ThreadKey: Int] = [:]
    private var resumeAt: Date?
    private var backoff: TimeInterval = 300
    private var passRunning = false
    private var observers: [AnyDatabaseCancellable] = []
    private var loop: Task<Void, Never>?
    private var wake: Task<Void, Never>?
    private var pokes: AsyncStream<Void>.Continuation?

    public init(
        database: AppDatabase, providers: AIProviders = .shared, batchSize: Int = 15,
        window: TimeInterval = 30 * 86_400, debounce: Duration = .seconds(2),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.providers = providers
        self.batchSize = max(1, batchSize)
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
        let debounce = debounce
        loop = Task { [weak self] in
            for await _ in stream {
                try? await Task.sleep(for: debounce)
                guard let self, !Task.isCancelled else { return }
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
    }

    /// Asks for a pass soon, e.g. after the user signs in to the CLI.
    public func poke() {
        if case .unavailable = status.state { resumeAt = nil }
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

    /// Sends batches until nothing is left or the provider can't continue.
    public func runPass() async {
        guard !passRunning else { return }
        if let resumeAt, resumeAt > now() { return }
        resumeAt = nil
        passRunning = true
        defer { passRunning = false }

        while !Task.isCancelled {
            do {
                let result = try await processBatch()
                if result.sent == 0 { break }
                backoff = 300
            } catch AIError.disabled {
                setState(.off)
                return
            } catch let error as AIError {
                status.lastError = error.localizedDescription
                switch error {
                case .invalidOutput:
                    continue
                case .notInstalled, .notSignedIn:
                    pause(for: 600, state: .unavailable(error.localizedDescription))
                case .rateLimited:
                    pause(for: backoff, state: nil, reason: error.localizedDescription)
                    backoff = min(backoff * 2, 3_600)
                case .timedOut, .failed, .disabled:
                    pause(for: 120, state: nil, reason: error.localizedDescription)
                }
                return
            } catch is CancellationError {
                return
            } catch {
                status.lastError = error.localizedDescription
                pause(for: 120, state: nil, reason: error.localizedDescription)
                return
            }
        }
        setState(.idle)
    }

    /// Classifies one batch. Throws `AIError.disabled` when AI is off.
    @discardableResult
    public func processBatch() async throws -> BatchResult {
        let settings = try await database.reader.read { db in try AISettings.read(db) }
        guard settings.enabled else { throw AIError.disabled }
        let provider = try await providers.resolve(settings)

        let since = now().addingTimeInterval(-window)
        let attempted = attempted
        let batchSize = batchSize
        let batch = try await database.reader.read { db -> Batch in
            let fresh = try Self.candidates(db, since: since, limit: 500)
                .filter { attempted[$0.key] != $0.messageCount }
                .prefix(batchSize)
            let threads = try PromptData.threads(db, keys: fresh.map(\.key), messages: 2, characters: 600)
            let owner = try String.fetchAll(db, sql: "SELECT email FROM account ORDER BY sortOrder, email")
            let projects = settings.autoProjects ? try Project.order(Column("sortOrder"), Column("name")).fetchAll(db) : nil
            return Batch(picked: Array(fresh), threads: threads, owner: owner, projects: projects)
        }
        for candidate in batch.picked { self.attempted[candidate.key] = candidate.messageCount }
        guard !batch.threads.isEmpty else { return BatchResult(sent: batch.picked.count, classified: 0) }

        setState(.working)
        let refs = batch.threads.indices.map { String($0 + 1) }
        var request = Prompts.triage(batch.threads, refs: refs, owner: batch.owner, projects: batch.projects, today: now())
        request.model = settings.model(for: provider)
        let verdicts = try await ask(provider, request, refs: Set(refs), projects: batch.projects ?? [])
        let threadsByRef = Dictionary(uniqueKeysWithValues: zip(refs, batch.threads))
        let classifiedAt = now()
        let written = try await database.writer.write { db in
            try Self.write(db, verdicts, threads: threadsByRef, source: provider.id, autoProjects: settings.autoProjects, at: classifiedAt)
        }
        status.classified += written
        aiLog.info("triage: \(written) of \(batch.threads.count) threads classified by \(provider.id, privacy: .public)")
        return BatchResult(sent: batch.picked.count, classified: written)
    }

    // MARK: Steps

    struct Candidate: Hashable, Sendable {
        var key: ThreadKey
        var messageCount: Int
    }

    private struct Batch: Sendable {
        var picked: [Candidate]
        var threads: [PromptThread]
        var owner: [String]
        var projects: [Project]?
    }

    /// Threads that need an AI verdict, inbox first, newest first.
    static func candidates(_ db: Database, since: Date, limit: Int) throws -> [Candidate] {
        try Row.fetchAll(db, sql: """
            SELECT t.accountId, t.id, t.messageCount FROM thread t
            LEFT JOIN thread_ai ai ON ai.accountId = t.accountId AND ai.threadId = t.id
            WHERE t.lastDate >= ? AND t.lastInboundDate IS NOT NULL
              AND (ai.threadId IS NULL OR ai.messageCount < t.messageCount
                   OR (ai.source = 'rules' AND ai.category IN ('people', 'other')))
              AND NOT EXISTS (SELECT 1 FROM thread_label x WHERE x.accountId = t.accountId AND x.threadId = t.id
                AND x.labelId IN ('TRASH', 'SPAM'))
            ORDER BY EXISTS (SELECT 1 FROM thread_label i WHERE i.accountId = t.accountId AND i.threadId = t.id
                AND i.labelId = 'INBOX') DESC, t.lastDate DESC
            LIMIT ?
            """, arguments: [since.timeIntervalSince1970, limit]
        ).map { Candidate(key: ThreadKey(accountId: $0[0], threadId: $0[1]), messageCount: $0[2]) }
    }

    /// Asks once, and once more when the answer can't be read.
    private func ask(_ provider: any AIProvider, _ request: AIRequest, refs: Set<String>, projects: [Project]) async throws -> [TriageVerdict] {
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

    private func settingsChanged() {
        resumeAt = nil
        backoff = 300
        pokes?.yield()
    }

    private func setState(_ state: State) {
        status.state = state
        for listener in listeners.values { listener.yield(status) }
    }

    private func removeListener(_ id: UUID) {
        listeners[id] = nil
    }
}
