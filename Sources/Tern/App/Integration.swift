import AppKit
import GRDB
import Network
import TernAI
import TernCore
import TernSync

/// Connects the shell's hooks to Google sign-in, sync, notifications, the AI assistant, project rules
/// and the composer.
@MainActor
final class Integration {
    let services: AppServices
    let model: AppModel
    let providers: AIProviders
    let assistant: MailAssistant
    let triage: TriageQueue
    let ledgerQueue: LedgerQueue
    let summaryQueue: PrimarySummaryQueue
    private var google: GoogleAccounts? { didSet { googleBox.set(google) } }
    private var aiSettingsTask: Task<Void, Never>?
    private var effectiveAIState: String?
    private var settingsObservation: AnyDatabaseCancellable?
    /// The Google client for sync's `apiProvider`, which runs off the main actor.
    let googleBox = GoogleBox()
    /// Gmail sync for the real mailbox; nil for demo mail.
    var sync: SyncCoordinator?
    var pathMonitor: NWPathMonitor?
    var activityObservers: [any NSObjectProtocol] = []
    var rateLimitTimer: Timer?
    var notifications: MailNotifications?
    var loginArrivals: LoginArrivals?

    init(services: AppServices, model: AppModel) {
        self.services = services
        self.model = model
        let database = services.store.database
        let providers = AIProviders([GroqProvider(key: { GroqCredential.read() }), CodexCLIProvider(), ClaudeCLIProvider()])
        self.providers = providers
        assistant = MailAssistant(database: database, providers: providers)
        let triage = TriageQueue(database: database, providers: providers)
        self.triage = triage
        summaryQueue = PrimarySummaryQueue(database: database, assistant: assistant, providers: providers, idle: {
            let state = await triage.currentStatus.state
            if case .working = state { return false }
            return true
        })
        ledgerQueue = LedgerQueue(database: database, providers: providers, triageIdle: {
            let state = await triage.currentStatus.state
            if case .working = state { return false }
            return true
        })
    }

    enum Failure: LocalizedError {
        case noGoogleClient
        case differentAccount(String)
        case keychainLocked

        var errorDescription: String? {
            switch self {
            case .noGoogleClient: "Add your Google OAuth client first (Settings → Accounts)."
            case .differentAccount(let email): "You signed in as \(email). Choose the same account to reconnect it."
            case .keychainLocked: "Tern couldn't read this account from your Keychain. Unlock it and try again."
            }
        }
    }

    /// The Google client from the Keychain, cached once loaded.
    var googleAccounts: GoogleAccounts? {
        if google == nil { google = try? GoogleAccounts() }
        return google
    }

    /// A thread-safe slot for the current Google client.
    final class GoogleBox: @unchecked Sendable {
        private let lock = NSLock()
        private var accounts: GoogleAccounts?

        func set(_ accounts: GoogleAccounts?) { lock.withLock { self.accounts = accounts } }
        func get() -> GoogleAccounts? { lock.withLock { accounts } }
    }

    func wire() {
        wireGoogle()
        wireAI()
        wireRules()
        wireComposer()
        // Sync and notifications start after the window is up, so they never hold up launch.
        if !model.isFake {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.startSync()
                    self?.startNotifications()
                    self?.startAccountPhotos()
                }
            }
        }
    }

    /// Banners for new mail while Tern is in the background.
    func startNotifications() {
        let notifications = MailNotifications(services: services, prefs: model.prefs)
        notifications.start()
        self.notifications = notifications
        let loginArrivals = LoginArrivals(services: services, prefs: model.prefs)
        loginArrivals.start()
        self.loginArrivals = loginArrivals
    }

    /// Reads the accounts' kept photos, then asks Google again for those missing or a week old.
    func startAccountPhotos() {
        let store = services.store
        let google = googleAccounts
        Task { @MainActor in
            let accounts = (try? await Task.detached { try store.accounts() }.value) ?? []
            AccountPhotos.shared.start(accountIds: accounts.map(\.id))
            guard let google else { return }
            let pictures = await Task.detached(priority: .utility) { () -> [(String, URL?)] in
                let directory = AccountPhotos.defaultDirectory
                var pictures: [(String, URL?)] = []
                for account in accounts where AccountPhotos.isStale(account.id, in: directory) && google.hasCredentials(for: account.email) {
                    if let info = try? await google.profile(for: account.email) { pictures.append((account.id, info.pictureURL)) }
                }
                return pictures
            }.value
            for (id, url) in pictures { AccountPhotos.shared.refresh(id, pictureURL: url) }
        }
    }

    // MARK: Google

    private func wireGoogle() {
        services.hasGoogleClient = { (try? GoogleClientConfigStore().load()) != nil }
        services.googleClientId = { (try? GoogleClientConfigStore().load())?.clientId }
        services.googleClients = { [weak self] in
            guard let self, let google = self.googleAccounts else { return [] }
            let emails = self.services.accounts.map(\.id)
            return google.clientIds.map { id in
                GoogleClientInfo(id: id, emails: emails.filter { google.clientId(for: $0) == id })
            }
        }

        services.saveGoogleClient = { [weak self] clientId, clientSecret in
            let config = GoogleClientConfig(
                clientId: clientId.trimmingCharacters(in: .whitespacesAndNewlines),
                clientSecret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines))
            try self?.addGoogleClient(config)
        }

        services.importGoogleClient = { [weak self] data in
            let config: GoogleClientConfig
            do { config = try GoogleClientConfig(downloadedJSON: data) } catch let error as GoogleClientConfigError {
                throw ClientProblem(error)
            }
            try self?.addGoogleClient(config)
        }

        services.removeGoogleClient = { [weak self] clientId in
            try GoogleClientConfigStore().remove(clientId: clientId)
            self?.reloadGoogleClients()
            if self?.services.lastSavedGoogleClientId == clientId { self?.services.lastSavedGoogleClientId = nil }
            self?.services.googleClientsChanged += 1
        }

        services.connectAccountWith = { [weak self] clientId in
            guard let self, let google = self.googleAccounts else { throw Failure.noGoogleClient }
            let info = try await google.connect(clientId: clientId) { url in
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            }
            let account = try await self.saveAccount(info)
            AccountPhotos.shared.refresh(account.id, pictureURL: info.pictureURL)
            if let sync = self.sync {
                // Signing in again with an account that was already there resumes its sync.
                if sync.status(for: account.id) == nil { sync.addAccount(account) } else { sync.reauthorized(accountId: account.id) }
            }
            return account
        }
        services.connectAccount = { [weak self] in
            guard let self else { throw Failure.noGoogleClient }
            return try await self.services.connectAccountWith(nil)
        }

        services.reauthAccount = { [weak self] account in
            guard let self, let google = self.googleAccounts else { throw Failure.noGoogleClient }
            // The account's own client; a Keychain that can't be read stops here rather than use another.
            let clientId: String?
            do { clientId = try google.storedClientId(for: account.email) } catch { throw Failure.keychainLocked }
            let info = try await google.connect(clientId: clientId, loginHint: account.email) { url in
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            }
            guard info.email.lowercased() == account.id else { throw Failure.differentAccount(info.email) }
            AccountPhotos.shared.refresh(account.id, pictureURL: info.pictureURL)
            if let sync = self.sync {
                sync.reauthorized(accountId: account.id)
                return
            }
            let store = self.services.store
            try await Task.detached {
                try store.updateAccount(account.id) { account in
                    if account.syncState == .needsAuth { account.syncState = account.backfillDone ? .live : .backfilling }
                    account.syncError = nil
                }
            }.value
        }

        services.removeAccount = { [weak self] account in
            guard let self else { return }
            if let sync = self.sync {
                try await sync.removeAccount(id: account.id)
            } else {
                let store = self.services.store
                let drafts = self.services.draftFilesDirectory ?? DraftStore.defaultFilesDirectory
                let cache = SyncConfiguration().attachmentFolder(for: account.id)
                try await Task.detached {
                    try store.removeAccount(account.id).delete(draftFilesDirectory: drafts, folders: [cache])
                }.value
            }
            await ReaderRemoteImages.clearCache()
            AccountPhotos.shared.remove(account.id)
            await self.googleAccounts?.signOut(account.email)
        }
    }

    /// Validates and stores one of the user's OAuth clients. Accounts keep the client they signed in
    /// with; the first client is the default for new ones.
    private func addGoogleClient(_ config: GoogleClientConfig) throws {
        do {
            try GoogleClientConfigStore().add(config)
        } catch let error as GoogleClientConfigError {
            throw ClientProblem(error)
        }
        reloadGoogleClients()
        services.lastSavedGoogleClientId = config.clientId
        services.googleClientsChanged += 1
    }

    /// Reads the clients from the Keychain again and hands every syncing account a Gmail client built from
    /// them, so a removed client or a new secret takes effect without a restart.
    private func reloadGoogleClients() {
        google = try? GoogleAccounts()
        for account in services.accounts { sync?.reauthorized(accountId: account.id) }
    }

    /// What went wrong with an entered or imported OAuth client, in words for the person entering it.
    struct ClientProblem: LocalizedError {
        let error: GoogleClientConfigError
        init(_ error: GoogleClientConfigError) { self.error = error }

        var errorDescription: String? {
            switch error {
            case .invalidClientId: "That client ID doesn't look right. It ends in .apps.googleusercontent.com."
            case .invalidClientSecret: "Add the client secret too (it starts with GOCSPX-)."
            case .notDesktopClient: "That file is for a Web application client. Tern needs a Desktop app client."
            case .unreadableFile: "That isn't the JSON file Google offers when you create an OAuth client."
            }
        }
    }

    /// Stores a newly connected account. Reconnecting an existing one keeps its colour and order.
    private func saveAccount(_ info: GoogleAccountInfo) async throws -> Account {
        let store = services.store
        return try await Task.detached {
            let existing = try store.accounts()
            if let current = existing.first(where: { $0.id == info.email.lowercased() }) {
                return current
            }
            let account = Account(
                email: info.email, displayName: Self.label(for: info.email, existing: existing),
                colorIndex: existing.count, sortOrder: existing.count)
            try store.upsertAccount(account)
            return account
        }.value
    }

    /// "Personal" for consumer Gmail, otherwise the organisation from the domain ("Northwind").
    nonisolated static func label(for email: String, existing: [Account]) -> String {
        let domain = email.split(separator: "@").last.map(String.init)?.lowercased() ?? ""
        var label: String
        if ["gmail.com", "googlemail.com"].contains(domain) {
            label = "Personal"
        } else {
            let name = domain.split(separator: ".").first.map(String.init) ?? domain
            label = name.prefix(1).uppercased() + name.dropFirst()
        }
        if existing.contains(where: { $0.displayName == label }) { label = email }
        return label
    }

    // MARK: AI

    private func wireAI() {
        let assistant = self.assistant
        let summaries = self.summaryQueue
        let actions = AIActions(
            summarize: { key in await summaries.yieldToForeground(); return try await assistant.summarize(thread: key) },
            suggestReplies: { key in try await assistant.suggestReplies(thread: key) },
            draftReply: { key, instruction in try await assistant.draftReply(thread: key, instruction: instruction) },
            naturalLanguageQuery: { text in try await assistant.naturalLanguageToQuery(text) })

        let providers = self.providers
        services.aiAvailability = { choice, refresh in
            guard let id = choice.providerID, let provider = providers.provider(id: id) else { return .notInstalled }
            return AIStatus(await provider.availability(refresh: refresh))
        }

        // AI helpers exist only while AI is switched on in Settings.
        let observation = ValueObservation.tracking { db in
            let revision = try Setting.fetchOne(db, key: "ai.groqCredentialRevision")?.value
            return (try AISettings.read(db), revision)
        }
        settingsObservation = observation.startRestarting(
            in: services.store.database.reader, scheduling: .async(onQueue: .main),
            onError: { error in NSLog("Tern: AI settings observation failed, restarting it: \(error)") },
            onChange: { [weak self] settings, _ in
                MainActor.assumeIsolated {
                    self?.aiSettingsTask?.cancel()
                    GroqCredential.invalidate()
                    self?.aiSettingsTask = Task { @MainActor [weak self] in
                        let enabled = await providers.isEnabled(settings)
                        let provider = enabled ? try? await providers.resolve(settings).id : nil
                        guard !Task.isCancelled, let self else { return }
                        let state = "\(enabled):\(provider ?? "none"):\(settings.model ?? "")"
                        guard state != self.effectiveAIState else { return }
                        self.effectiveAIState = state
                        self.services.ai = enabled ? actions : nil
                        await self.triage.poke()
                    }
                }
            })

        let triage = self.triage
        let ledgerQueue = self.ledgerQueue
        services.aiPrioritize = { keys in Task { await triage.prioritize(keys); await ledgerQueue.prioritize(keys) } }
        Task { [weak self] in
            for await status in await triage.statusUpdates() {
                guard let self else { return }
                if case .working = status.state { await ledgerQueue.yieldToTriage(); await self.summaryQueue.yieldToForeground() }
                if case .idle = status.state { await ledgerQueue.poke() }
                let sorting = AISorting(status: status)
                if self.services.aiSorting != sorting { self.services.aiSorting = sorting }
            }
        }
        let summaryQueue = self.summaryQueue
        Task.detached(priority: .utility) { await triage.start(); await ledgerQueue.start(); await summaryQueue.start() }
    }

    // MARK: Projects

    private func wireRules() {
        let database = services.store.database
        services.projectRulesChanged = { projectId in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    _ = try database.writer.write { db in try ProjectRules.recomputeAll(db, projectId: projectId) }
                } catch {
                    NSLog("Tern: applying project rules failed: \(error)")
                }
            }
        }
    }

    // MARK: Composer

    private func wireComposer() {
        services.showSendUndo = { [weak model] notice in
            guard let model else { return }
            var entry = UndoEntry(change: .custom(notice.undo), threads: [])
            entry.expires = true
            model.showToast(notice.message, undo: entry, duration: notice.duration)
        }
        // The first composer in a process costs ~130 ms to build; pay it while idle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [services] in
            MainActor.assumeIsolated { Composer.prewarm(services: services) }
        }
    }

    func stop() {
        let triage = self.triage
        let ledgerQueue = self.ledgerQueue
        let summaryQueue = self.summaryQueue
        Task { await triage.stop(); await ledgerQueue.stop(); await summaryQueue.stop() }
    }

    /// Quitting: lets sync put in-flight work back in its queue, for at most `timeout` seconds.
    func shutdown(timeout: TimeInterval = 2) async {
        notifications?.stop()
        loginArrivals?.stop()
        stopObservingActivity()
        pathMonitor?.cancel()
        await sync?.shutdown(timeout: timeout)
    }
}
