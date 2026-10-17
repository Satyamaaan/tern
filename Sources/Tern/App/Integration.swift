import AppKit
import GRDB
import TernAI
import TernCore
import TernSync

/// Connects the shell's hooks to Google sign-in, the AI assistant, project rules and the composer.
@MainActor
final class Integration {
    let services: AppServices
    let model: AppModel
    let assistant: MailAssistant
    let triage: TriageQueue
    private var google: GoogleAccounts?
    private var settingsObservation: AnyDatabaseCancellable?

    init(services: AppServices, model: AppModel) {
        self.services = services
        self.model = model
        let database = services.store.database
        assistant = MailAssistant(database: database)
        triage = TriageQueue(database: database)
    }

    enum Failure: LocalizedError {
        case noGoogleClient
        case differentAccount(String)

        var errorDescription: String? {
            switch self {
            case .noGoogleClient: "Add your Google OAuth client first (Settings → Accounts)."
            case .differentAccount(let email): "You signed in as \(email). Choose the same account to reconnect it."
            }
        }
    }

    /// The Google client from the Keychain, cached once loaded.
    var googleAccounts: GoogleAccounts? {
        if google == nil { google = try? GoogleAccounts() }
        return google
    }

    func wire() {
        wireGoogle()
        wireAI()
        wireRules()
        wireComposer()
    }

    // MARK: Google

    private func wireGoogle() {
        services.hasGoogleClient = { (try? GoogleClientConfigStore().load()) != nil }

        services.saveGoogleClient = { [weak self] clientId, clientSecret in
            let config = GoogleClientConfig(
                clientId: clientId.trimmingCharacters(in: .whitespacesAndNewlines),
                clientSecret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines))
            try config.validate()
            try GoogleClientConfigStore().save(config)
            self?.google = GoogleAccounts(config: config)
        }

        services.connectAccount = { [weak self] in
            guard let self, let google = self.googleAccounts else { throw Failure.noGoogleClient }
            let info = try await google.connect { url in
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            }
            return try await self.saveAccount(info)
        }

        services.reauthAccount = { [weak self] account in
            guard let self, let google = self.googleAccounts else { throw Failure.noGoogleClient }
            let info = try await google.connect(loginHint: account.email) { url in
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            }
            guard info.email.lowercased() == account.id else { throw Failure.differentAccount(info.email) }
            let store = self.services.store
            try await Task.detached {
                try store.updateAccount(account.id) { account in
                    if account.syncState == .needsAuth { account.syncState = account.backfillDone ? .live : .backfilling }
                    account.syncError = nil
                }
            }.value
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
        let actions = AIActions(
            summarize: { key in try await assistant.summarize(thread: key) },
            suggestReplies: { key in try await assistant.suggestReplies(thread: key) },
            draftReply: { key, instruction in try await assistant.draftReply(thread: key, instruction: instruction) },
            naturalLanguageQuery: { text in try await assistant.naturalLanguageToQuery(text) })

        // AI helpers exist only while AI is switched on in Settings.
        let observation = ValueObservation.tracking { db in try AISettings.read(db).enabled }.removeDuplicates()
        settingsObservation = observation.start(
            in: services.store.database.reader, scheduling: .async(onQueue: .main),
            onError: { error in NSLog("Tern: AI settings observation failed: \(error)") },
            onChange: { [weak self] enabled in
                MainActor.assumeIsolated {
                    self?.services.ai = enabled ? actions : nil
                    if let triage = self?.triage { Task { await triage.poke() } }
                }
            })

        let triage = self.triage
        Task.detached(priority: .utility) { await triage.start() }
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
        Task { await triage.stop() }
    }
}
