import AppKit
import GRDB
import Network
import TernCore
import TernSync

// Gmail sync for the real mailbox: one coordinator for every account, started after the window is up.
// Demo mail, `--check` and `--snapshot` never sync.
extension Integration {
    func startSync() {
        guard sync == nil else { return }
        let store = services.store
        let box = googleBox
        _ = googleAccounts
        let coordinator = SyncCoordinator(
            store: store, accounts: (try? store.accounts()) ?? [],
            apiProvider: { accountId in box.get()?.api(for: accountId) ?? SignedOutGmail() },
            encodeDraft: Self.encodeDraft(store))
        sync = coordinator
        coordinator.setActive(NSApp.isActive)
        coordinator.start()

        services.loadAttachment = { [weak coordinator] attachment in
            guard let coordinator else { throw CocoaError(.featureUnsupported) }
            return try await coordinator.downloadAttachment(attachment)
        }
        services.fetchBodies = { [weak coordinator] key in try await coordinator?.fetchBodies(for: key) }
        services.prefetchBodies = { [weak coordinator] keys in coordinator?.prefetchBodies(adjacentTo: keys) }
        services.serverSearch = { [weak self] text in try await self?.searchGmail(text) ?? 0 }

        observeActivity()
        observeNetwork()
        observeSyncStatus()
    }

    /// Builds the RFC 822 message for a draft: From is the account, replies carry the threading headers.
    /// Kept to one function so it can give way to the engine's own encoder.
    nonisolated static func encodeDraft(_ store: MailStore) -> @Sendable (Draft, Account) throws -> Data {
        { draft, account in
            let (replied, name) = try store.database.reader.read { db in
                (try draft.replyToMessageId.flatMap { id in
                    try MailMessage.filter(Column("accountId") == draft.accountId && Column("id") == id).fetchOne(db)
                }, try Contact.fetchOne(db, key: account.id)?.name ?? "")
            }
            let threaded = draft.kind == .reply || draft.kind == .replyAll ? replied : nil
            let references = [threaded?.refs, threaded?.rfcMessageId].compactMap { $0 }.joined(separator: " ")
            return try MIMEBuilder.build(
                draft: draft, from: Participant(name: name, email: account.email),
                inReplyTo: threaded?.rfcMessageId, references: references.isEmpty ? nil : references)
        }
    }

    // MARK: Search on Gmail

    /// Searches Gmail in every account in scope for mail not stored yet. Returns how many threads matched.
    func searchGmail(_ text: String) async throws -> Int {
        guard let sync, let query = SearchQuery(text).gmailQuery else { return 0 }
        let accounts = model.scope.accountId.map { [$0] } ?? model.accounts.map(\.id)
        var found = Set<ThreadKey>()
        var failure: Error?
        for accountId in accounts where sync.status(for: accountId) != nil {
            do {
                found.formUnion(try await sync.serverSearch(accountId: accountId, query: query))
            } catch {
                failure = error
            }
        }
        if found.isEmpty, let failure { throw failure }
        return found.count
    }

    // MARK: Active, network, status

    private func observeActivity() {
        let center = NotificationCenter.default
        activityObservers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sync?.setActive(true) }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sync?.setActive(false) }
            },
        ]
    }

    func stopObservingActivity() {
        for observer in activityObservers { NotificationCenter.default.removeObserver(observer) }
        activityObservers = []
    }

    private func observeNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.services.isOffline != offline else { return }
                    self.services.isOffline = offline
                    if !offline { self.sync?.syncNow() }
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "dev.tern.network", qos: .utility))
        pathMonitor = monitor
    }

    /// Keeps the sidebar's sync line and `syncProgress` current while statuses change.
    private func observeSyncStatus() {
        guard let sync else { return }
        withObservationTracking {
            let statuses = Array(sync.statuses.values)
            let line = SyncSummary.line(statuses, now: Date())
            if services.syncLine != line { services.syncLine = line }
            let progress = SyncSummary.progress(statuses)
            if services.syncProgress != progress { services.syncProgress = progress }
            scheduleRateLimitRefresh(statuses.compactMap(\.rateLimitedUntil).min())
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.observeSyncStatus() } }
        }
    }

    /// "Waiting for Gmail (2 min)" counts down without a status change, so refresh it on a timer.
    private func scheduleRateLimitRefresh(_ until: Date?) {
        rateLimitTimer?.invalidate()
        rateLimitTimer = nil
        guard let until, until > Date() else { return }
        rateLimitTimer = Timer.scheduledTimer(withTimeInterval: min(15, until.timeIntervalSinceNow + 0.5), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.observeSyncStatus() }
        }
    }
}

/// The sidebar's sync line from every account's live status, most pressing first.
@MainActor
enum SyncSummary {
    static func line(_ statuses: [SyncStatus], now: Date) -> SyncLine? {
        guard !statuses.isEmpty else { return nil }
        if let until = statuses.compactMap(\.rateLimitedUntil).filter({ $0 > now }).min() {
            return SyncLine(text: "Waiting for Gmail (\(wait(until.timeIntervalSince(now))))", tone: .quiet)
        }
        let failed = statuses.reduce(0) { $0 + $1.failedOps }
        if failed > 0 {
            return SyncLine(text: failed == 1 ? "1 change didn't reach Gmail" : "\(failed) changes didn't reach Gmail", tone: .attention)
        }
        if let first = statuses.first(where: { $0.state == .new }) {
            let phase = first.phase.isEmpty ? "Syncing" : first.phase
            if let total = first.total, total > 0 {
                return SyncLine(text: "\(phase) \(first.fetched.formatted()) of \(total.formatted())", tone: .working)
            }
            return SyncLine(text: phase.hasSuffix("…") ? phase : phase + "…", tone: .working)
        }
        if let backfill = statuses.first(where: { $0.state == .backfilling }) {
            // The sidebar has room for one short line; the engine's own wording goes in the tooltip.
            let percent = backfill.backfillProgress.map { " · \(Int(($0 * 100).rounded(.down)))%" } ?? ""
            return SyncLine(text: "Older mail syncing" + percent, tone: .quiet,
                            detail: (backfill.background ?? "Older mail syncing in the background") + percent)
        }
        return nil
    }

    /// Fetched and expected for accounts on their first sync; nil when none is.
    static func progress(_ statuses: [SyncStatus]) -> SyncProgress? {
        let first = statuses.filter { $0.state == .new && ($0.total ?? 0) > 0 }
        guard !first.isEmpty else { return nil }
        return SyncProgress(done: first.reduce(0) { $0 + $1.fetched }, total: first.reduce(0) { $0 + ($1.total ?? 0) })
    }

    /// A backfill line for snapshots.
    static let preview = SyncLine(text: "Older mail syncing · 34%", tone: .quiet, detail: "Older mail syncing in the background · 34%")

    /// "40 s", "2 min".
    static func wait(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(max(1, Int(seconds.rounded(.up)))) s" : "\(Int((seconds / 60).rounded(.up))) min"
    }
}

/// Stands in for an account's Gmail client when no OAuth client is stored: every call says the
/// account must sign in again, which sync shows as "Sign in again".
struct SignedOutGmail: GmailAPI {
    func profile() async throws -> GmailProfile { throw GmailAPIError.unauthorized }
    func labels() async throws -> [GmailLabel] { throw GmailAPIError.unauthorized }
    func createLabel(name: String) async throws -> GmailLabel { throw GmailAPIError.unauthorized }
    func deleteLabel(id: String) async throws { throw GmailAPIError.unauthorized }
    func messageIds(query: String?, labelIds: [String], pageToken: String?, maxResults: Int) async throws -> GmailIdPage {
        throw GmailAPIError.unauthorized
    }
    func messages(ids: [String], format: GmailMessageFormat) async throws -> [GmailMessage] { throw GmailAPIError.unauthorized }
    func threads(ids: [String], format: GmailMessageFormat) async throws -> [GmailThread] { throw GmailAPIError.unauthorized }
    func history(startHistoryId: String, pageToken: String?) async throws -> GmailHistoryPage { throw GmailAPIError.unauthorized }
    func batchModify(messageIds: [String], add: [String], remove: [String]) async throws { throw GmailAPIError.unauthorized }
    func trashThread(id: String) async throws { throw GmailAPIError.unauthorized }
    func untrashThread(id: String) async throws { throw GmailAPIError.unauthorized }
    func attachment(messageId: String, attachmentId: String) async throws -> Data { throw GmailAPIError.unauthorized }
    func send(raw: Data, threadId: String?) async throws -> GmailMessageRef { throw GmailAPIError.unauthorized }
    func createDraft(raw: Data, threadId: String?) async throws -> GmailDraft { throw GmailAPIError.unauthorized }
    func updateDraft(id: String, raw: Data, threadId: String?) async throws -> GmailDraft { throw GmailAPIError.unauthorized }
    func deleteDraft(id: String) async throws { throw GmailAPIError.unauthorized }
    func sendDraft(id: String) async throws -> GmailMessageRef { throw GmailAPIError.unauthorized }
    func sendAs() async throws -> [GmailSendAs] { throw GmailAPIError.unauthorized }
}
