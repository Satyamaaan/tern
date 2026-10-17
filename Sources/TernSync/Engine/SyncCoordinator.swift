import Foundation
import GRDB
import Observation
import TernCore
#if canImport(AppKit)
import AppKit
#endif

/// Runs sync for every account. The app creates one, calls `start()`, keeps it for the life of
/// the app, and reads `statuses` for progress. Sync work runs off the main thread in one
/// `AccountSync` actor per account; accounts have separate Gmail quotas and sync in parallel.
///
/// The reader calls `fetchBodies(for:)` when a thread opens (older mail is stored without bodies)
/// and `prefetchBodies(adjacentTo:)` with the threads around the selection.
///
/// Queued actions are noticed automatically: the coordinator observes `pending_op` and wakes the
/// account's queue whenever an op is added, so `MailStore.perform` needs no extra call (`kick()`
/// is there for anything that wants it explicitly).
@MainActor
@Observable
public final class SyncCoordinator {
    public let store: MailStore
    /// Live status per account id.
    public private(set) var statuses: [String: SyncStatus] = [:]

    @ObservationIgnored private let apiProvider: @Sendable (String) -> any GmailAPI
    @ObservationIgnored private let encodeDraft: @Sendable (Draft, Account) throws -> Data
    @ObservationIgnored private let configuration: SyncConfiguration
    @ObservationIgnored private let clock: any SyncClock
    @ObservationIgnored private var syncs: [String: AccountSync] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var serviceTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var lastOpCounts: [String: PendingOpCounts] = [:]
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var isActive = true
    @ObservationIgnored public private(set) var isRunning = false
    @ObservationIgnored private let relay = StatusRelay()

    /// - Parameters:
    ///   - accounts: Accounts to sync; each is stored if the database doesn't have it yet.
    ///   - apiProvider: The Gmail client for an account id (asked again after `reauthorized`).
    ///   - encodeDraft: Builds the RFC 822 message for a draft: `DraftEncoder.make(store:)`.
    public init(store: MailStore, accounts: [Account],
                apiProvider: @escaping @Sendable (String) -> any GmailAPI,
                encodeDraft: @escaping @Sendable (Draft, Account) throws -> Data,
                configuration: SyncConfiguration = SyncConfiguration(),
                clock: any SyncClock = SystemSyncClock()) {
        self.store = store
        self.apiProvider = apiProvider
        self.encodeDraft = encodeDraft
        self.configuration = configuration
        self.clock = clock
        for account in accounts { register(account) }
    }

    /// The status for one account.
    public func status(for accountId: String) -> SyncStatus? { statuses[accountId] }

    /// The account's sync actor, for callers that want to drive a step directly.
    public func sync(for accountId: String) -> AccountSync? { syncs[accountId] }

    // MARK: Lifecycle

    /// Starts syncing every account, the op-queue observer, the snooze timer, daily upkeep and the
    /// wake observer.
    public func start() {
        guard !isRunning else { return }
        isRunning = true

        let updates = relay.connect()
        serviceTasks.append(Task { [weak self] in
            for await snapshot in updates { self?.statuses[snapshot.accountId]?.apply(snapshot) }
        })

        let reader = store.database.reader
        serviceTasks.append(Task { [weak self] in
            let observation = ValueObservation.tracking { db in try MailStore.pendingOpCounts(db) }.removeDuplicates()
            do {
                for try await counts in observation.values(in: reader) { self?.opCountsChanged(counts) }
            } catch {}
        })

        let clock = self.clock
        let interval = configuration.snoozeCheckInterval
        serviceTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.wakeSnoozedThreads()
                try? await clock.sleep(seconds: interval)
            }
        })
        let daily = configuration.dailyInterval
        serviceTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.runDailyUpkeep()
                try? await clock.sleep(seconds: daily)
            }
        })

        #if canImport(AppKit)
        if configuration.observeSystemWake {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemDidWake() }
            }
        }
        #endif

        for sync in syncs.values { launch(sync) }
    }

    /// Stops all sync work. Ops in flight finish or return to the queue on next launch.
    public func stop() {
        isRunning = false
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        for task in serviceTasks { task.cancel() }
        serviceTasks.removeAll()
        relay.disconnect()
        #if canImport(AppKit)
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        #endif
    }

    /// Stops and waits for the account tasks to finish.
    public func shutdown() async {
        let running = Array(tasks.values) + serviceTasks
        stop()
        for task in running { await task.value }
    }

    /// Stops and waits for the account tasks to finish, for at most `timeout` seconds of real time.
    /// Returns at the deadline even when a task is stuck in a request that ignores cancellation,
    /// without waiting for it any further.
    public func shutdown(timeout: TimeInterval) async {
        let running = Array(tasks.values) + serviceTasks
        stop()
        let once = ResumeOnce<Void>()
        _ = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            once.set(continuation)
            Task.detached {
                for task in running { await task.value }
                once.resume(with: .success(()))
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(max(0, timeout)))
                once.resume(with: .success(()))
            }
        }
    }

    // MARK: Accounts

    /// Adds an account after sign-in and starts syncing it.
    public func addAccount(_ account: Account) {
        guard syncs[account.id] == nil else { return }
        let sync = register(account)
        if isRunning { launch(sync) }
    }

    /// Removes an account from this Mac: stops its sync and waits until it has stopped, so nothing
    /// writes the account back, then deletes its data (`MailStore.removeAccount`), its downloaded
    /// attachments and its drafts' files.
    public func removeAccount(id: String) async throws {
        let task = tasks.removeValue(forKey: id)
        task?.cancel()
        syncs.removeValue(forKey: id)
        statuses.removeValue(forKey: id)
        lastOpCounts.removeValue(forKey: id)
        await task?.value
        let store = self.store, configuration = self.configuration
        try await Task.detached(priority: .userInitiated) {
            try store.removeAccount(id).delete(draftFilesDirectory: configuration.draftFilesDirectory,
                                               folders: [configuration.attachmentFolder(for: id)])
        }.value
    }

    /// The account signed in again after `syncState == .needsAuth`; sync resumes with a fresh client.
    public func reauthorized(accountId: String) {
        guard let sync = syncs[accountId] else { return }
        let api = apiProvider(accountId)
        Task { await sync.resume(api: api) }
    }

    // MARK: Triggers

    /// Polls every 5 s while the app is active, every 60 s in the background.
    public func setActive(_ active: Bool) {
        isActive = active
        for sync in syncs.values { Task { await sync.setActive(active) } }
    }

    /// Checks Gmail for changes now (all accounts, or one).
    public func syncNow(accountId: String? = nil) {
        for sync in targets(accountId) { Task { await sync.syncNow() } }
    }

    /// Sends queued actions now (all accounts, or one).
    public func kick(accountId: String? = nil) {
        for sync in targets(accountId) { Task { await sync.kick() } }
    }

    /// Wakes due snoozes and syncs; called automatically when the Mac wakes from sleep.
    public func systemDidWake() {
        Task { await wakeSnoozedThreads() }
        syncNow()
    }

    /// Returns snoozed threads whose time has come to the inbox.
    public func wakeSnoozedThreads() async {
        let store = self.store
        let now = clock.now()
        let woken = (try? await Task.detached(priority: .utility) { try store.wakeSnoozed(now: now) }.value) ?? []
        for accountId in Set(woken.map(\.accountId)) { kick(accountId: accountId) }
    }

    /// Clears needs-reply on threads whose last message aged past `RuleClassifier.needsReplyWindow`.
    /// Runs at start and daily.
    public func runDailyUpkeep() async {
        let store = self.store
        let now = clock.now()
        _ = try? await Task.detached(priority: .utility) {
            try await store.database.writer.write { db in try RuleClassifier.expireNeedsReply(db, now: now) }
        }.value
    }

    // MARK: Requests

    /// Makes sure every message of the thread is stored with its body (call when it opens).
    /// Interactive priority: it never waits behind the backfill. Returns at once when nothing's missing.
    public func fetchBodies(for thread: ThreadKey) async throws {
        guard let sync = syncs[thread.accountId] else { throw SyncError.unknownAccount(thread.accountId) }
        try await sync.fetchBodies(thread)
    }

    /// Prefetches bodies of the threads around the selection, when the quota allows. Replaces the
    /// previous request; returns at once.
    public func prefetchBodies(adjacentTo threads: [ThreadKey]) {
        for (accountId, keys) in Dictionary(grouping: threads, by: \.accountId) {
            guard let sync = syncs[accountId] else { continue }
            Task { await sync.prefetchAdjacent(keys) }
        }
    }

    /// A local file for the attachment, downloaded and cached on first use.
    public func downloadAttachment(_ attachment: MailAttachment) async throws -> URL {
        guard let sync = syncs[attachment.accountId] else { throw SyncError.unknownAccount(attachment.accountId) }
        return try await sync.downloadAttachment(attachment)
    }

    /// Searches Gmail for mail not stored locally; matching messages are stored, threads returned.
    public func serverSearch(accountId: String, query: String, limit: Int = 50) async throws -> [ThreadKey] {
        guard let sync = syncs[accountId] else { throw SyncError.unknownAccount(accountId) }
        return try await sync.serverSearch(query: query, limit: limit)
    }

    // MARK: Mute

    /// Mutes threads: archives them and labels them "Muted" through `MailStore.perform`
    /// (`AccountSync.mute`), so it's instant, works offline and is undoable. The first time in an
    /// account the engine finds or creates the label in Gmail when it sends the change. New mail in a
    /// muted thread is archived again as it arrives. Returns the undo.
    @discardableResult
    public func mute(_ keys: [ThreadKey]) async throws -> UndoToken {
        for accountId in Set(keys.map(\.accountId)) where syncs[accountId] == nil { throw SyncError.unknownAccount(accountId) }
        let store = self.store
        return try await Task.detached(priority: .userInitiated) { try AccountSync.mute(keys, in: store) }.value
    }

    /// Unmutes threads: removes the "Muted" label, or its stand-in before the label is known (they
    /// stay where they are, like Gmail's unmute). No network wait. Returns the undo.
    @discardableResult
    public func unmute(_ keys: [ThreadKey]) async throws -> UndoToken {
        let store = self.store
        return try await Task.detached(priority: .userInitiated) {
            try store.database.writer.write { db in
                var actions: [(action: MailAction, threads: [ThreadKey])] = []
                for (accountId, threads) in Dictionary(grouping: keys, by: \.accountId).sorted(by: { $0.key < $1.key }) {
                    if let label = try Setting.fetchOne(db, key: SyncSettingKey.muteLabel(accountId))?.value {
                        actions.append((.removeLabel(label), threads))
                    }
                    actions.append((.removeLabel(MailStore.pendingMuteLabel), threads))
                }
                return try MailStore.perform(db, actions)
            }
        }.value
    }

    // MARK: Internals

    @discardableResult
    private func register(_ account: Account) -> AccountSync {
        let relay = self.relay
        let sync = AccountSync(
            account: account, store: store, api: apiProvider(account.id), encodeDraft: encodeDraft,
            configuration: configuration, clock: clock,
            remoteAttachmentFetcher: { [weak self] ref, file in
                guard let owner = await self?.sync(for: ref.accountId) else { throw SyncError.unknownAccount(ref.accountId) }
                return try await owner.attachmentData(ref, file: file)
            },
            statusSink: { relay.yield($0) })
        syncs[account.id] = sync
        let status = SyncStatus(accountId: account.id, quotaLimit: configuration.quota.unitsPerMinute)
        status.apply(SyncStatusSnapshot(accountId: account.id, state: account.syncState,
                                        lastSyncAt: account.lastSyncAt, lastError: account.syncError))
        statuses[account.id] = status
        return sync
    }

    private func launch(_ sync: AccountSync) {
        let active = isActive
        tasks[sync.accountId] = Task.detached(priority: .utility) {
            await sync.setActive(active)
            await sync.run()
        }
    }

    private func targets(_ accountId: String?) -> [AccountSync] {
        accountId.map { id in syncs[id].map { [$0] } ?? [] } ?? Array(syncs.values)
    }

    private func opCountsChanged(_ counts: [String: PendingOpCounts]) {
        for (accountId, status) in statuses {
            let current = counts[accountId] ?? PendingOpCounts(queued: 0, failed: 0, maxId: 0)
            status.pendingOps = current.queued
            status.failedOps = current.failed
            let previous = lastOpCounts[accountId]
            if current.queued > 0, current.maxId != previous?.maxId || current.queued != previous?.queued {
                kick(accountId: accountId)
            }
            lastOpCounts[accountId] = current
        }
    }
}

/// Carries status snapshots from the account actors to the main actor, in order. Reconnects on
/// each `start()`; snapshots sent while stopped are dropped (each snapshot is complete, so the next
/// one catches the UI up).
private final class StatusRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<SyncStatusSnapshot>.Continuation?

    func connect() -> AsyncStream<SyncStatusSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: SyncStatusSnapshot.self)
        lock.withLock {
            self.continuation?.finish()
            self.continuation = continuation
        }
        return stream
    }

    func disconnect() {
        lock.withLock {
            continuation?.finish()
            continuation = nil
        }
    }

    func yield(_ snapshot: SyncStatusSnapshot) {
        _ = lock.withLock { continuation }?.yield(snapshot)
    }
}
