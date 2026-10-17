import Foundation
import GRDB
import TernCore

/// Syncs one Gmail account into the local store: initial sync and resumable backfill, history
/// polling, the pending-op queue (labels, drafts, sending), body prefetch, attachments and server
/// search. `SyncCoordinator` owns one per account and calls `run()`; every step is also callable
/// on its own, which is how the tests drive it.
///
/// Network calls never happen inside a write transaction: each step fetches first, then writes.
public actor AccountSync {
    public nonisolated let accountId: String
    let store: MailStore
    var api: any GmailAPI
    let encodeDraft: @Sendable (Draft, Account) throws -> Data
    let configuration: SyncConfiguration
    let clock: any SyncClock
    private let statusSink: @Sendable (SyncStatusSnapshot) -> Void

    /// The last copy of the account row this actor read or wrote.
    var account: Account
    public private(set) var status: SyncStatusSnapshot
    /// From the profile, for backfill progress.
    var messagesTotal: Int?

    var isActive = true
    var paused = false
    var prepared = false
    var pollRequested = true
    var nextPollAt = Date.distantPast
    var nextLabelRefreshAt = Date.distantPast
    /// When the earliest deferred op becomes due.
    var nextOpAt: Date?
    var consecutiveFailures = 0
    /// Bumped whenever history changes are applied, so a fetch that overlapped one can tell.
    var historyGeneration = 0
    private var wakeRequested = false
    private var wakeContinuation: CheckedContinuation<Void, Never>?

    /// - Parameters:
    ///   - encodeDraft: Builds the RFC 822 message for a draft (the MIME builder lives in Google/).
    ///   - statusSink: Receives every status change; called on this actor.
    public init(account: Account, store: MailStore, api: any GmailAPI,
                encodeDraft: @escaping @Sendable (Draft, Account) throws -> Data,
                configuration: SyncConfiguration = SyncConfiguration(), clock: any SyncClock = SystemSyncClock(),
                statusSink: @escaping @Sendable (SyncStatusSnapshot) -> Void = { _ in }) {
        self.accountId = account.id
        self.store = store
        self.api = api
        self.encodeDraft = encodeDraft
        self.configuration = configuration
        self.clock = clock
        self.statusSink = statusSink
        self.account = account
        self.status = SyncStatusSnapshot(accountId: account.id, state: account.syncState,
                                         lastSyncAt: account.lastSyncAt, lastError: account.syncError)
    }

    // MARK: Controls

    /// Polls every 5 s while active, every 60 s otherwise. Becoming active polls at once.
    public func setActive(_ active: Bool) {
        isActive = active
        if active {
            pollRequested = true
            wake()
        } else {
            nextPollAt = min(nextPollAt, clock.now().addingTimeInterval(configuration.inactivePollInterval))
        }
    }

    /// Polls history now.
    public func syncNow() {
        pollRequested = true
        wake()
    }

    /// Drains queued ops now (call after `MailStore.perform`).
    public func kick() {
        wake()
    }

    /// After the account signs in again (`syncState == .needsAuth`), continues with a fresh client.
    public func resume(api: (any GmailAPI)? = nil) async {
        if let api { self.api = api }
        guard paused || account.syncState == .needsAuth else { return }
        paused = false
        _ = try? await updateAccount { $0.syncState = AccountSync.resumedState($0); $0.syncError = nil }
        publishAccount()
        pollRequested = true
        wake()
    }

    // MARK: Loop

    /// Runs until the task is cancelled.
    public func run() async {
        // A previous run may have been cancelled mid-op; recover its inflight ops before draining.
        prepared = false
        while !Task.isCancelled {
            if paused {
                // Kicks while paused don't count; only `resume` wakes a paused account.
                wakeRequested = false
                await waitForWake()
                continue
            }
            wakeRequested = false
            let more: Bool
            do {
                more = try await syncOnce()
                if consecutiveFailures > 0 || account.syncError != nil { await clearError() }
            } catch {
                if Task.isCancelled { break }
                await handle(error)
                if !paused { await idle(seconds: backoff(consecutiveFailures + 1)) }
                continue
            }
            if more || wakeRequested {
                await Task.yield()
                continue
            }
            await idle(until: [nextPollAt, nextOpAt].compactMap { $0 }.min() ?? nextPollAt)
        }
    }

    /// One pass: initial sync if needed, queued ops, a history poll when due (with a full resync if
    /// history expired), then one backfill page or one body-prefetch batch.
    /// Returns true when more background work is waiting.
    @discardableResult
    public func syncOnce() async throws -> Bool {
        try await prepare()
        if account.historyId == nil || account.syncState == .new { try await initialSync() }
        try await drainOps()

        let now = clock.now()
        if pollRequested || now >= nextPollAt {
            pollRequested = false
            nextPollAt = now.addingTimeInterval(isActive ? configuration.activePollInterval : configuration.inactivePollInterval)
            do {
                try await pollHistory()
            } catch GmailAPIError.historyExpired {
                try await fullResync()
            }
        }

        if !account.backfillDone, try await backfillStep() { return true }
        return try await prefetchBodies() > 0
    }

    /// Loads the account (inserting it when the store doesn't have it yet), recovers ops a quit left
    /// inflight, and picks up where the last run stopped.
    public func prepare() async throws {
        guard !prepared else { return }
        let given = account
        let accountId = self.accountId
        account = try await write { db in
            if try Account.fetchOne(db, key: accountId) == nil { try given.insert(db) }
            try MailStore.recoverInterruptedOps(db, accountId: accountId)
            var stored = try Account.fetchOne(db, key: accountId)!
            let resumed = AccountSync.resumedState(stored)
            if stored.syncState != resumed {
                stored.syncState = resumed
                try stored.update(db)
            }
            return stored
        }
        prepared = true
        publishAccount()
    }

    /// The state an account continues in: `.new` until the inbox and recent mail are in.
    static func resumedState(_ account: Account) -> SyncState {
        if account.historyId == nil || (!account.backfillDone && account.backfillPageToken == nil) { return .new }
        return account.backfillDone ? .live : .backfilling
    }

    func idle(until date: Date) async {
        await idle(seconds: date.timeIntervalSince(clock.now()))
    }

    /// Sleeps until `seconds` pass or something calls `wake()`.
    func idle(seconds: Double) async {
        guard !wakeRequested, seconds > 0 else { return }
        let clock = self.clock
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await clock.sleep(seconds: seconds) }
            group.addTask { await self.waitForWake() }
            await group.next()
            group.cancelAll()
        }
    }

    private func waitForWake() async {
        if wakeRequested { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if wakeRequested || Task.isCancelled {
                    continuation.resume()
                } else {
                    wakeContinuation = continuation
                }
            }
        } onCancel: {
            Task { await self.releaseWaiter() }
        }
    }

    private func wake() {
        wakeRequested = true
        releaseWaiter()
    }

    private func releaseWaiter() {
        wakeContinuation?.resume()
        wakeContinuation = nil
    }

    // MARK: Errors

    func handle(_ error: Error) async {
        if case GmailAPIError.unauthorized = error {
            await markNeedsAuth()
            return
        }
        consecutiveFailures += 1
        let message = AccountSync.describe(error)
        _ = try? await updateAccount { $0.syncError = message }
        publish { $0.lastError = message }
    }

    private func clearError() async {
        consecutiveFailures = 0
        if account.syncError != nil { _ = try? await updateAccount { $0.syncError = nil } }
        publish { $0.lastError = nil }
    }

    func markNeedsAuth() async {
        paused = true
        _ = try? await updateAccount {
            $0.syncState = .needsAuth
            $0.syncError = "Sign in to Google again to keep this account in sync."
        }
        publishAccount()
    }

    static func describe(_ error: Error) -> String {
        guard let error = error as? GmailAPIError else { return error.localizedDescription }
        switch error {
        case .unauthorized: return "Google sign-in expired."
        case .notFound: return "Gmail couldn't find that item."
        case .historyExpired: return "Sync history expired; resyncing."
        case .rateLimited: return "Gmail is rate limiting requests; retrying."
        case .server(let status, let message): return message.isEmpty ? "Gmail error \(status)." : "Gmail error \(status): \(message)"
        case .network(let message): return message.isEmpty ? "Offline." : "Offline: \(message)"
        }
    }

    /// Retries rate limits, 5xx and network errors with backoff (on the injected clock) a few times.
    func withRetry<T>(_ request: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await request()
            } catch let error as GmailAPIError {
                attempt += 1
                guard attempt < configuration.maxRequestRetries, let delay = retryDelay(for: error, attempt: attempt) else { throw error }
                try await clock.sleep(seconds: delay)
            }
        }
    }

    func retryDelay(for error: GmailAPIError, attempt: Int) -> Double? {
        switch error {
        case .rateLimited(let retryAfter): return retryAfter ?? backoff(attempt)
        case .network: return backoff(attempt)
        case .server(let status, _) where status >= 500: return backoff(attempt)
        default: return nil
        }
    }

    /// 2 s, 4 s, 8 s… capped.
    func backoff(_ attempt: Int) -> Double {
        min(configuration.retryBaseDelay * pow(2, Double(max(0, attempt - 1))), configuration.retryMaxDelay)
    }

    // MARK: Store and status

    func write<T: Sendable>(_ updates: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await store.database.writer.write(updates)
    }

    /// A short synchronous write for op bookkeeping that must land even while the task is being
    /// cancelled (the async write throws `CancellationError` then, leaving ops stuck inflight).
    func writeNow<T>(_ updates: (Database) throws -> T) throws -> T {
        try store.database.writer.write(updates)
    }

    func read<T: Sendable>(_ value: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await store.database.reader.read(value)
    }

    /// Changes the stored account row (not the cached copy, so other fields edited elsewhere survive).
    @discardableResult
    func updateAccount(_ change: @escaping @Sendable (inout Account) -> Void) async throws -> Account {
        let accountId = self.accountId
        if let updated = try await write({ db in try AccountSync.updateAccountRow(db, accountId, change) }) {
            account = updated
        }
        return account
    }

    static func updateAccountRow(_ db: Database, _ id: String, _ change: (inout Account) -> Void) throws -> Account? {
        guard var account = try Account.fetchOne(db, key: id) else { return nil }
        change(&account)
        try account.update(db)
        return account
    }

    func reloadAccount() async throws {
        let accountId = self.accountId
        if let stored = try await read({ db in try Account.fetchOne(db, key: accountId) }) { account = stored }
    }

    func publish(_ change: (inout SyncStatusSnapshot) -> Void) {
        let before = status
        change(&status)
        if status != before { statusSink(status) }
    }

    /// Copies state, last sync and error from the account row into the status.
    func publishAccount(phase: String? = nil) {
        let account = self.account
        publish {
            $0.state = account.syncState
            if let synced = account.lastSyncAt, synced > ($0.lastSyncAt ?? .distantPast) { $0.lastSyncAt = synced }
            $0.lastError = account.syncError
            if let phase { $0.phase = phase }
        }
    }
}
