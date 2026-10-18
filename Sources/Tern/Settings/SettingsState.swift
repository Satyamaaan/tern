import AppKit
import Observation
import TernCore

enum SettingsSection: String, CaseIterable, Identifiable {
    case accounts, mail, appearance, layout, notifications, ai, shortcuts, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accounts: "Accounts"
        case .mail: "Mail"
        case .appearance: "Appearance"
        case .layout: "Layout"
        case .notifications: "Notifications"
        case .ai: "AI"
        case .shortcuts: "Shortcuts"
        case .advanced: "Advanced"
        }
    }

    var icon: Icon {
        switch self {
        case .accounts: .at
        case .mail: .allMail
        case .appearance: .sun
        case .layout: .readingPane
        case .notifications: .notification
        case .ai: .sparkles
        case .shortcuts: .command
        case .advanced: .sliders
        }
    }
}

/// AI choices. Stored in the database `setting` table so the AI lane reads the same values.
enum AIProvider: String, CaseIterable, Identifiable {
    case claude, codex, off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .off: "Off"
        }
    }

    /// The command-line tool behind the provider.
    var executable: String? {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .off: nil
        }
    }
}

/// Setting keys shared with other lanes.
enum SettingKey {
    static let aiEnabled = "ai.enabled"
    static let aiProvider = "ai.provider"
    static let aiModel = "ai.model"
    static let aiAutoProjects = "ai.autoProjects"
}

/// A shortcut being recorded in Settings → Shortcuts.
struct ShortcutRecording: Equatable {
    let commandId: String
    /// The key being replaced, by its place in the command's keys; nil adds one.
    let slot: Int?
    var problem: Problem?

    enum Problem: Equatable {
        /// A key Tern can't bind (function keys, ← →).
        case unsupported
        case reserved(KeyShortcut, owner: String)
        /// Other commands use it; Replace takes it from them.
        case taken(KeyShortcut, by: [String])
    }
}

/// The open settings page: which section it shows, what is being searched or recorded, and the settings
/// that live in the database (AI, sending, signatures, image senders), read when the page opens.
@MainActor
@Observable
final class SettingsState {
    let model: AppModel
    private(set) var section: SettingsSection
    /// Typed in the field above the sections: the page lists matching settings instead of a section.
    var query = ""
    var searchFocused = false
    var provider: AIProvider { didSet { saveAI() } }
    var aiModel: String { didSet { saveAI() } }
    var autoProjects: Bool { didSet { saveAI() } }
    let board = AIStatusBoard()
    var indexStatus: String?
    /// Opens the Google client editor at once (snapshots).
    var editsGoogleClient = false
    /// Auto-update; nil in development builds.
    var updater: Updater?
    /// Seconds Send waits so it can be undone; 0 sends at once.
    var undoSeconds: Int { didSet { save(DraftStore.SettingKey.undoSeconds, undoSeconds == DraftStore.defaultUndoSeconds ? nil : "\(undoSeconds)") } }
    var signatures: Bool { didSet { save(DraftStore.SettingKey.signatures, signatures ? nil : "off") } }
    /// The account new mail starts from; nil is the first account.
    var sendFrom: String? { didSet { save(DraftStore.SettingKey.defaultAccount, sendFrom) } }
    /// Senders whose remote images load by themselves, sorted.
    private(set) var imageSenders: [String]
    /// Why the last sender couldn't be taken off that list, shown in its row.
    var imageSendersError: String?
    var shortcutFilter = ""
    var filterFocused = false
    private(set) var recording: ShortcutRecording?
    /// The page's own key view, which holds the keyboard whenever no field does.
    @ObservationIgnored weak var keyView: NSView?

    init(model: AppModel, section: SettingsSection, updater: Updater?) {
        self.model = model
        self.section = section
        self.updater = updater
        let store = model.store
        func read(_ key: String) -> String? { (try? store.setting(key)) ?? nil }
        let provider = read(SettingKey.aiProvider).flatMap(AIProvider.init(rawValue:))
        self.provider = read(SettingKey.aiEnabled) == "false" ? .off : (provider ?? .off)
        aiModel = read(SettingKey.aiModel) ?? ""
        autoProjects = read(SettingKey.aiAutoProjects) == "true"
        undoSeconds = read(DraftStore.SettingKey.undoSeconds).flatMap(Int.init) ?? DraftStore.defaultUndoSeconds
        signatures = read(DraftStore.SettingKey.signatures) != "off"
        sendFrom = read(DraftStore.SettingKey.defaultAccount)
        imageSenders = ((try? store.imageAllowedSenders()) ?? []).sorted()
    }

    // MARK: Sections

    func show(_ section: SettingsSection) {
        recording = nil
        query = ""
        self.section = section
        model.prefs.settingsSection = section.rawValue
    }

    /// ↑ ↓ and ⌃Tab: the next or previous section, wrapping.
    func move(_ step: Int) {
        let all = SettingsSection.allCases
        let index = all.firstIndex(of: section) ?? 0
        show(all[(index + step + all.count) % all.count])
    }

    func close() { model.closeSettings() }

    // MARK: Keyboard

    /// Keys while no field has the keyboard. Everything else falls through to the registry, which runs
    /// only the commands that make sense here (appearance, ⌘K, new mail), never one on mail.
    func handleKey(_ event: NSEvent, registry: CommandRegistry) -> Bool {
        let flags = event.modifierFlags.intersection(KeyShortcut.relevantModifiers)
        switch (event.keyCode, flags) {
        case (53, []):
            if model.showsShortcuts { model.showsShortcuts = false } else if query.isEmpty { close() } else { query = "" }
        case (126, []): move(-1)
        case (125, []): move(1)
        case (48, [.control]): move(1)
        case (48, [.control, .shift]): move(-1)
        default:
            if Self.isBack(event) {
                close()
            } else if registry["find"]?.keys.contains(where: { $0.matches(event) }) == true {
                searchFocused = true
            } else {
                return false
            }
        }
        return true
    }

    /// Keys while a field on the page has the keyboard: Esc clears a search, then leaves the field.
    func handleKeyWhileTyping(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(KeyShortcut.relevantModifiers)
        switch (event.keyCode, flags) {
        case (53, []):
            if searchFocused, !query.isEmpty { query = "" } else if filterFocused, !shortcutFilter.isEmpty { shortcutFilter = "" } else { takeKeyboard() }
        case (36, []) where searchFocused, (76, []) where searchFocused:
            guard let first = SettingsCatalog.results(for: query, model: model).first else { return true }
            show(first.section)
            takeKeyboard()
        case (48, [.control]): move(1)
        case (48, [.control, .shift]): move(-1)
        default:
            guard Self.isBack(event) else { return false }
            close()
        }
        return true
    }

    /// ⌘[ goes back, like Esc.
    private static func isBack(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(KeyShortcut.relevantModifiers) == .command && event.characters(byApplyingModifiers: []) == "["
    }

    /// Gives the keyboard to the page itself, out of any field.
    func takeKeyboard() {
        searchFocused = false
        filterFocused = false
        guard let keyView, let window = keyView.window else { return }
        window.makeFirstResponder(keyView)
    }

    // MARK: Recording shortcuts

    /// Click on a keycap (or +): the next key pressed becomes the shortcut. The key bindings files are read now
    /// if launch hasn't read them yet, so their Control keys count.
    func startRecording(_ commandId: String, slot: Int?) {
        takeKeyboard()
        model.registry?.loadKeyBindings()
        recording = ShortcutRecording(commandId: commandId, slot: slot)
    }

    func cancelRecording() { recording = nil }

    /// A key while recording: Esc cancels, ⌫ removes the key, Return takes a key another command has, and
    /// anything else is checked and saved, or explained.
    func record(_ event: NSEvent) {
        guard var recording, let registry = model.registry, !event.isARepeat else { return }
        let flags = event.modifierFlags.intersection(KeyShortcut.relevantModifiers)
        if flags.isEmpty {
            switch event.keyCode {
            case 53:
                self.recording = nil
                return
            case 51, 117:
                if let slot = recording.slot { registry.removeKey(at: slot, from: recording.commandId) }
                self.recording = nil
                return
            case 36, 76:
                if case .taken = recording.problem { return replace() }
            default: break
            }
        }
        guard let shortcut = KeyShortcut(recording: event) else {
            recording.problem = .unsupported
            self.recording = recording
            return
        }
        recording.problem = Self.problem(shortcut, for: recording.commandId, registry: registry)
        if recording.problem == nil {
            registry.assign(shortcut, to: recording.commandId, replacing: recording.slot)
            self.recording = nil
        } else {
            self.recording = recording
        }
    }

    /// "Replace": takes the key from the commands that have it.
    func replace() {
        guard let recording, case .taken(let shortcut, _) = recording.problem, let registry = model.registry else { return }
        registry.assign(shortcut, to: recording.commandId, replacing: recording.slot)
        self.recording = nil
    }

    /// Why `shortcut` can't simply go to `commandId`, if it can't.
    static func problem(_ shortcut: KeyShortcut, for commandId: String, registry: CommandRegistry) -> ShortcutRecording.Problem? {
        if let owner = registry.reservation(shortcut, for: commandId) { return .reserved(shortcut, owner: owner) }
        let others = registry.conflicts(shortcut, for: commandId)
        if let locked = others.first(where: { ShortcutRules.isLocked($0.id) }) { return .reserved(shortcut, owner: locked.displayTitle) }
        return others.isEmpty ? nil : .taken(shortcut, by: others.map(\.id))
    }

    // MARK: Saving

    /// Writes AI settings off the main thread.
    private func saveAI() {
        let store = model.store
        let provider = provider
        let aiModel = aiModel.trimmingCharacters(in: .whitespaces)
        let autoProjects = autoProjects
        model.writes.async {
            try? store.setSetting(SettingKey.aiEnabled, provider == .off ? "false" : "true")
            if provider != .off { try? store.setSetting(SettingKey.aiProvider, provider.rawValue) }
            try? store.setSetting(SettingKey.aiModel, aiModel.isEmpty ? nil : aiModel)
            try? store.setSetting(SettingKey.aiAutoProjects, autoProjects ? "true" : "false")
        }
    }

    private func save(_ key: String, _ value: String?) {
        let store = model.store
        model.writes.async { try? store.setSetting(key, value) }
    }

    /// Takes a sender off the list: their remote images are blocked again until allowed in a message. If that
    /// can't be saved, the sender comes back (as it would after a restart) and the row says so.
    func forgetImages(from sender: String) {
        imageSenders.removeAll { $0 == sender }
        imageSendersError = nil
        ReaderModel.forgetTrustedSender(sender)
        let store = model.store
        model.writes.async {
            do {
                try store.setImagesAllowed(false, sender: sender)
            } catch {
                NSLog("Tern: taking \(sender) off the image senders failed: \(error)")
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if !self.imageSenders.contains(sender) { self.imageSenders = (self.imageSenders + [sender]).sorted() }
                        ReaderModel.rememberTrustedSender(sender)
                        self.imageSendersError = "Couldn't take \(sender) off the list. Try again."
                    }
                }
            }
        }
    }

    func rebuildSearchIndex() {
        indexStatus = "Rebuilding…"
        let store = model.store
        model.writes.async {
            let result = (try? store.rebuildSearchIndex()) != nil ? "Search index rebuilt" : "Couldn't rebuild the index"
            DispatchQueue.main.async { MainActor.assumeIsolated { self.indexStatus = result } }
        }
    }

    func remove(_ account: Account) {
        let alert = NSAlert()
        alert.messageText = "Remove \(account.email)?"
        alert.informativeText = "Its mail is deleted from this Mac and Tern signs out of it. Nothing changes in Gmail."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let services = model.services
        Task {
            do { try await services.removeAccount(account) } catch { NSLog("Tern: removing an account failed: \(error)") }
        }
    }

    /// Demo mode only: wipe the demo mailbox and start again with a fresh one.
    func resetDemoMail() {
        UserDefaults.standard.set(true, forKey: DemoReset.key)
        (NSApp.delegate as? AppDelegate)?.relaunchWithDemoMail()
    }
}

// MARK: - Helpers

/// Finds command-line tools the way a login shell would (PATH plus the usual install places).
enum CLITool {
    static func find(_ name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.claude/local"]
        for directory in directories {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
}

/// Demo-mail reset, carried across a relaunch.
enum DemoReset {
    static let key = "resetDemoMailOnLaunch"

    /// Deletes the demo database before it opens, when a reset was requested.
    static func applyIfRequested(_ options: LaunchOptions) {
        guard options.isFake, UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.removeObject(forKey: key)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: options.databaseURL.path + suffix)
        }
    }
}
