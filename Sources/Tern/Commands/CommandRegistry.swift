import AppKit
import Observation
import TernCore

/// Window-level actions the registry needs from the app delegate.
@MainActor
protocol ShellActions: AnyObject {
    func showSettings(_ section: SettingsSection?)
    func addAccount()
    func showMainWindow()
    func showAbout()
    /// Auto-update; nil in development builds, which hide "Check for Updates…".
    var updater: Updater? { get }
    func checkForUpdates()
}

/// Builds every command once. Closures read the model at run time, so titles and enabled states stay current.
/// Keys are the built-in ones with the user's overrides on top; views that show shortcuts read them from
/// here, so they follow an edit at once.
@MainActor
@Observable
final class CommandRegistry {
    private(set) var commands: [Command] = []
    /// The user's shortcut changes, applied over `defaultKeys`.
    private(set) var overrides = ShortcutOverrides()
    @ObservationIgnored private var index: [String: Int] = [:]
    /// Each command's built-in keys.
    @ObservationIgnored private(set) var defaultKeys: [String: [KeyShortcut]] = [:]
    /// Persists overrides; the app writes them to `Preferences`.
    @ObservationIgnored var saveOverrides: (ShortcutOverrides) -> Void
    /// Where the Control keys of the key bindings files come from (`loadKeyBindings`).
    @ObservationIgnored let keyBindings: KeyBindingFiles
    /// Those keys once read, reserved for text editing like the built-in ones; empty until then.
    @ObservationIgnored private(set) var textKeys: Set<KeyShortcut>
    @ObservationIgnored let model: AppModel
    @ObservationIgnored weak var shell: ShellActions?

    /// Posted after any shortcut changes, so the menu bar and key routing rebuild.
    static let shortcutsDidChange = Notification.Name("TernShortcutsDidChange")

    /// `overrides` defaults to the saved ones; passing them (tests) leaves the saved ones alone unless `save`
    /// is given too. Changes that can't apply any more are dropped, and the rest saved again, so nothing
    /// invalid (unreadable, reserved, locked, clashing) stays in UserDefaults. This runs at launch, so it checks
    /// only the built-in reserved keys and those of `keyBindings` (default `KeyBindingFiles.shared`) already read;
    /// it never reads a file.
    init(model: AppModel, shell: ShellActions?, overrides: ShortcutOverrides? = nil, save: ((ShortcutOverrides) -> Void)? = nil,
         keyBindings: KeyBindingFiles? = nil) {
        self.model = model
        self.shell = shell
        let keyBindings = keyBindings ?? .shared
        self.keyBindings = keyBindings
        textKeys = keyBindings.keys ?? []
        saveOverrides = overrides == nil ? { [weak model] in model?.prefs.shortcutOverrides = $0 } : save ?? { _ in }
        commands = makeCommands()
        index = Dictionary(uniqueKeysWithValues: commands.enumerated().map { ($1.id, $0) })
        defaultKeys = Dictionary(uniqueKeysWithValues: commands.map { ($0.id, $0.keys) })
        self.overrides = Self.validated(overrides ?? model.prefs.shortcutOverrides, commands: commands, textKeys: textKeys)
        saveOverrides(self.overrides)
        applyOverrides()
    }

    subscript(id: String) -> Command? { index[id].map { commands[$0] } }

    func run(_ id: String) {
        guard let command = self[id], canRun(command) else { return }
        command.run()
    }

    /// Enabled, and not something that acts on mail while the settings page hides it.
    func canRun(_ command: Command) -> Bool {
        (!model.settingsOpen || command.availableInSettings) && command.isEnabled()
    }

    /// "Title  key" for a tooltip, with the command's shortcut as it is now.
    func hint(_ title: String, _ id: String) -> String {
        guard let shortcut = self[id]?.shortcutText else { return title }
        return "\(title)  \(shortcut)"
    }

    private func applyOverrides() {
        for offset in commands.indices {
            let id = commands[offset].id
            commands[offset].keys = overrides.keys[id] ?? defaultKeys[id] ?? []
        }
    }

    // MARK: The list

    private func makeCommands() -> [Command] {
        let m = model
        var list: [Command] = []
        func hasTargets() -> Bool { !m.targets.isEmpty }
        func notSearching() -> Bool { !m.isSearching }

        // Message
        list += [
            Command(id: "archive", title: "Archive", group: .actions, keys: [.key("e")], menu: .message,
                    aliases: ["done", "mark done"], isEnabled: hasTargets) { m.perform(.archive, on: m.targets) },
            Command(id: "snooze", title: "Snooze…", group: .actions, keys: [.key("h")], menu: .message,
                    aliases: ["remind", "later"], isEnabled: hasTargets) { m.palette = .snooze(m.targets) },
            Command(id: "trash", title: "Move to Trash", group: .actions, keys: [.key("#"), .special(.delete)], menu: .message,
                    aliases: ["delete"], isEnabled: hasTargets) { m.perform(.trash, on: m.targets) },
            Command(id: "spam", title: "Report Spam", group: .actions, keys: [.key("!")], menu: .message,
                    aliases: ["junk"], isEnabled: hasTargets) { m.perform(.markSpam, on: m.targets) },
            Command(id: "moveToInbox", title: "Move to Inbox", group: .actions, keys: [.key("I")], menu: .message,
                    aliases: ["unarchive", "restore"],
                    isEnabled: { hasTargets() && !(m.kind == .inbox) }) { m.perform(.moveToInbox, on: m.targets) },
            Command(id: "star", title: "Star", group: .actions, keys: [.key("s")], menu: .message, section: 1,
                    aliases: ["flag"], isEnabled: hasTargets,
                    currentTitle: { m.targets.allSatisfy { m.row($0)?.thread.isStarred ?? false } && hasTargets() ? "Unstar" : "Star" }) { m.toggleStar() },
            Command(id: "unread", title: "Mark as Unread", group: .actions, keys: [.key("u"), .key("U")], menu: .message, section: 1,
                    aliases: ["read"], isEnabled: hasTargets,
                    currentTitle: { m.targets.contains { (m.row($0)?.thread.unreadCount ?? 0) > 0 } ? "Mark as Read" : "Mark as Unread" }) { m.toggleUnread() },
            Command(id: "needsReply", title: "Mark Needs Reply", group: .actions, keys: [.key("R")], menu: .message, section: 1,
                    aliases: ["reply later", "waiting"], isEnabled: hasTargets,
                    currentTitle: { m.targets.allSatisfy { m.row($0)?.needsReply ?? false } && hasTargets() ? "Clear Needs Reply" : "Mark Needs Reply" }) { m.toggleNeedsReply() },
            Command(id: "mute", title: "Mute", group: .actions, keys: [.key("m")], menu: .message, section: 1,
                    aliases: ["ignore"], isEnabled: hasTargets) { m.mute() },
            Command(id: "label", title: "Label…", group: .actions, keys: [.key("l")], menu: .message, section: 2,
                    aliases: ["tag"], isEnabled: { hasTargets() && m.labelsForTargets() != nil }) { m.palette = .label(m.targets) },
            Command(id: "project", title: "Move to Project…", group: .actions, keys: [.key("p")], menu: .message, section: 2,
                    aliases: ["file"], yieldsToReader: true, isEnabled: hasTargets) { m.palette = .project(m.targets) },
            Command(id: "reply", title: "Reply", group: .actions, keys: [.key("r")], menu: .message, section: 3,
                    isEnabled: { m.readerKey != nil }) { m.reply(all: false) },
            Command(id: "replyAll", title: "Reply All", group: .actions, keys: [.key("a")], menu: .message, section: 3,
                    isEnabled: { m.readerKey != nil }) { m.reply(all: true) },
            Command(id: "forward", title: "Forward", group: .actions, keys: [.key("f")], menu: .message, section: 3,
                    isEnabled: { m.readerKey != nil }) { m.forward() },
            Command(id: "undo", title: "Undo Last Action", group: .actions, keys: [.key("z")], menu: .message, section: 4,
                    isEnabled: { !m.undoStack.isEmpty }) { m.undoLast() },
        ]

        // Gmail's tabs: palette and the row and reader menus (`ThreadMenu.moveToTabItem`), no menu bar items.
        for tab in InboxTab.allCases {
            list.append(Command(id: "moveToTab.\(tab.rawValue)", title: "Move to \(tab.title)", group: .actions,
                                aliases: ["tab", "category", "move to tab"],
                                isEnabled: { m.prefs.splitInbox && m.targets.contains { m.row($0)?.inboxTab != tab } }) {
                m.perform(.moveToTab(tab), on: m.targets)
            })
        }

        // File
        list += [
            Command(id: "compose", title: "New Message", group: .actions, keys: [.key("c"), .command("n")], menu: .file,
                    aliases: ["compose", "write", "email"], isTextSafe: true) { m.compose() },
            Command(id: "addAccount", title: "Add Account…", group: .accounts, keys: [.command("n", shift: true)], menu: .file, section: 1,
                    aliases: ["connect gmail"], isTextSafe: true) { [weak self] in self?.shell?.addAccount() },
        ]

        // Selection and the list
        list += [
            Command(id: "select", title: "Select Conversation", group: .actions, keys: [.key("x")], menu: .mailbox, section: 1,
                    aliases: ["check"], isEnabled: { m.cursor != nil }) { m.toggleChecked() },
            Command(id: "extendDown", title: "Extend Selection Down", group: .actions, keys: [.key("J")], menu: .mailbox, section: 1,
                    hiddenInPalette: true) { m.moveCursor(1, extend: true) },
            Command(id: "extendUp", title: "Extend Selection Up", group: .actions, keys: [.key("K")], menu: .mailbox, section: 1,
                    hiddenInPalette: true) { m.moveCursor(-1, extend: true) },
            Command(id: "selectAll", title: "Select All Conversations", group: .actions, keys: [.command("a")],
                    isEnabled: { !m.snapshot.isEmpty }) { m.selectAll() },
            Command(id: "markAllRead", title: "Mark All as Read", group: .actions, keys: [.command("u", shift: true)], menu: .mailbox, section: 1,
                    isEnabled: { !m.snapshot.isEmpty }) { m.markAllRead() },
            Command(id: "newProject", title: "New Project…", group: .projects, keys: [.command("p", shift: true)], menu: .mailbox, section: 2,
                    aliases: ["create project"], isTextSafe: true) { m.newProject() },
            Command(id: "splitInbox", title: "Inbox Tabs", group: .settings, menu: .mailbox, section: 2,
                    aliases: ["split inbox", "primary", "promotions", "social", "updates", "forums", "categories"],
                    currentTitle: { m.prefs.splitInbox ? "Turn Off Inbox Tabs" : "Turn On Inbox Tabs" }) { m.setSplitInbox(!m.prefs.splitInbox) },
        ]

        // Scope
        list.append(Command(id: "scope.all", title: "All Accounts", group: .accounts, keys: [.command("0")], menu: .mailbox,
                            aliases: ["unified inbox"], isTextSafe: true) { m.setScope(.all) })
        for slot in 1...9 {
            list.append(Command(
                id: "scope.\(slot)", title: "Account \(slot)", group: .accounts, keys: [.command("\(slot)")], menu: .mailbox,
                hiddenInPalette: true, isTextSafe: true,
                isEnabled: { m.accounts.count >= slot },
                currentTitle: { m.accounts.indices.contains(slot - 1) ? m.accountTitle(m.accounts[slot - 1]) : "Account \(slot)" },
                isVisible: { m.accounts.count >= slot }
            ) { if m.accounts.indices.contains(slot - 1) { m.setScope(.account(m.accounts[slot - 1].id)) } })
        }

        // Go
        let mailboxes: [(String, String, Mailbox.Kind, String, [String])] = [
            ("go.inbox", "Inbox", .inbox, "g i", []),
            ("go.needsReply", "Needs Reply", .needsReply, "g r", ["waiting"]),
            ("go.snoozed", "Snoozed", .snoozed, "g h", []),
            ("go.starred", "Starred", .starred, "g s", []),
            ("go.drafts", "Drafts", .drafts, "g d", []),
            ("go.sent", "Sent", .sent, "g t", []),
            ("go.allMail", "All Mail", .allMail, "g a", ["done", "archive"]),
        ]
        for (id, title, kind, chord, aliases) in mailboxes {
            list.append(Command(id: id, title: title, group: .goTo, chord: chord, menu: .go, aliases: aliases) { m.show(kind) })
        }
        list += [
            Command(id: "go.done", title: "Done", group: .goTo, chord: "g e", hiddenInPalette: true) { m.show(.allMail) },
            Command(id: "go.spam", title: "Spam", group: .goTo, chord: "g !", menu: .go) { m.show(.spam) },
            Command(id: "go.trash", title: "Trash", group: .goTo, chord: "g #", menu: .go) { m.show(.trash) },
            Command(id: "go.label", title: "Label…", group: .goTo, chord: "g l", menu: .go, section: 1,
                    isEnabled: { m.scope.accountId != nil }) { m.palette = .goToLabel },
            Command(id: "go.project", title: "Project…", group: .goTo, chord: "g p", menu: .go, section: 1) { m.palette = .goToProject },
            Command(id: "next", title: "Next Conversation", group: .goTo, keys: [.key("j"), .special(.down)], menu: .go, section: 2,
                    hiddenInPalette: true) { m.moveCursor(1) },
            Command(id: "previous", title: "Previous Conversation", group: .goTo, keys: [.key("k"), .special(.up)], menu: .go, section: 2,
                    hiddenInPalette: true) { m.moveCursor(-1) },
            Command(id: "top", title: "First Conversation", group: .goTo, chord: "g g", menu: .go, section: 2) { m.moveToTop() },
            Command(id: "bottom", title: "Last Conversation", group: .goTo, keys: [.key("G")], menu: .go, section: 2) { m.moveToBottom() },
            Command(id: "open", title: "Open Conversation", group: .goTo, keys: [.special(.returnKey), .key("o")], menu: .go, section: 2,
                    hiddenInPalette: true, isEnabled: { m.cursor != nil }) { m.open() },
            Command(id: "back", title: "Back to List", group: .goTo, keys: [.special(.escape)], menu: .go, section: 2,
                    hiddenInPalette: true) { m.back() },
            Command(id: "nextSplit", title: "Next Tab", group: .goTo, keys: [.special(.tab)], menu: .go, section: 3,
                    isEnabled: { !m.isSearching }) { m.cycleTab(1) },
            Command(id: "previousSplit", title: "Previous Tab", group: .goTo, keys: [.special(.tab, [.shift])], menu: .go, section: 3,
                    isEnabled: { !m.isSearching }) { m.cycleTab(-1) },
            Command(id: "tab.all", title: "All", group: .goTo, keys: [.option("1")], menu: .go, section: 4,
                    aliases: ["inbox", "tab", "everything"]) { m.select(.all) },
            Command(id: "tab.needsReply", title: "Needs Reply Tab", group: .goTo, keys: [.option("2")], menu: .go, section: 4,
                    aliases: ["tab", "waiting"], hiddenInPalette: true) { m.select(.needsReply) },
        ]
        for (index, tab) in InboxTab.allCases.enumerated() {
            list.append(Command(id: "tab.\(tab.rawValue)", title: tab.title, group: .goTo, keys: [.option("\(index + 3)")],
                                menu: .go, section: 4, aliases: ["tab", "inbox", "category"],
                                isEnabled: { m.prefs.splitInbox }) { m.showInboxTab(tab) })
        }

        // View
        list += [
            Command(id: "palette", title: "Command Palette", group: .actions, keys: [.command("k")], menu: .view,
                    hiddenInPalette: true, isTextSafe: true) { m.togglePalette() },
            Command(id: "search", title: "Search Mail", group: .actions, keys: [.key("/")], menu: .view,
                    aliases: ["find"]) { m.beginSearch() },
            Command(id: "pinTab", title: "Pin This Search as a Tab", group: .actions, menu: .view,
                    aliases: ["saved search", "tab"], isEnabled: { m.isSearching && !m.isPinned(m.activeTab) }) { m.pin(m.activeTab) },
            Command(id: "shortcuts", title: "Keyboard Shortcuts", group: .settings, keys: [.key("?")], menu: .help,
                    aliases: ["help", "keys", "cheat sheet"], isTextSafe: true) { m.showsShortcuts.toggle() },
            Command(id: "toggleSidebar", title: "Show Sidebar", group: .settings,
                    keys: [KeyShortcut(key: .char("s"), modifiers: [.control, .command])], menu: .view, section: 1,
                    aliases: ["mailboxes", "projects", "labels"], isTextSafe: true,
                    currentTitle: { m.prefs.sidebarOpen ? "Hide Sidebar" : "Show Sidebar" }) { m.toggleSidebar() },
            Command(id: "readingPane", title: "Show Reading Pane", group: .settings, keys: [.command("\\")], menu: .view, section: 1,
                    aliases: ["split view", "side by side", "reader", "list only"], isTextSafe: true,
                    currentTitle: { m.prefs.readingPane ? "Hide Reading Pane" : "Show Reading Pane" }) { m.toggleReadingPane() },
        ]
        for density in Density.allCases {
            list.append(Command(id: "density.\(density.rawValue)", title: "Density: \(density.title)", group: .settings,
                                menu: .view, section: 2, aliases: ["rows", "compact", "comfortable"], isTextSafe: true) { m.prefs.density = density })
        }
        list.append(Command(id: "appearance.toggle", title: "Switch to Light Appearance", group: .settings,
                            keys: [.command("l", shift: true)], menu: .view, section: 3,
                            aliases: ["theme", "dark mode", "light mode", "toggle appearance"], isTextSafe: true,
                            currentTitle: { AppearanceMode.showsDark ? "Switch to Light Appearance" : "Switch to Dark Appearance" }) {
            m.prefs.appearance = AppearanceMode.flipped
        })
        for mode in AppearanceMode.allCases {
            list.append(Command(id: "appearance.\(mode.rawValue)", title: "Appearance: \(mode.title)", group: .settings,
                                menu: .view, section: 3, aliases: ["theme", "dark mode", "light mode"], isTextSafe: true) { m.prefs.appearance = mode })
        }
        list.append(Command(id: "dimRead", title: "Dim Old Read Mail", group: .settings, menu: .view, section: 2, isTextSafe: true,
                            currentTitle: { m.prefs.dimReadByAge ? "Don't Dim Old Read Mail" : "Dim Old Read Mail" }) { m.prefs.dimReadByAge.toggle() })
        list.append(Command(id: "senderLogos", title: "Hide Sender Logos", group: .settings, menu: .view, section: 2, aliases: ["avatars", "icons", "favicons"],
                            isTextSafe: true, currentTitle: { m.prefs.showSenderLogos ? "Hide Sender Logos" : "Show Sender Logos" }) { m.prefs.showSenderLogos.toggle() })

        // The open conversation. The reader page answers the keys of Next and Previous Message, Open and Quick
        // Look itself while it has the keyboard; these run the same actions from the list, the menus and the palette.
        let reader = m.services.reader
        func reading() -> Bool { reader.isActive && m.readerKey != nil }
        list += [
            Command(id: "nextMessage", title: "Next Message", group: .goTo, keys: [.key("n")], menu: .go, section: 2,
                    isEnabled: reading) { reader.nextMessage() },
            Command(id: "previousMessage", title: "Previous Message", group: .goTo, keys: [.key("p")], menu: .go, section: 2,
                    readerOnly: true, isEnabled: { reading() && m.focus == .reader }) { reader.previousMessage() },
            Command(id: "quickLook", title: "Quick Look Attachment", group: .actions, keys: [.special(.space)], menu: .message, section: 4,
                    aliases: ["preview"], readerOnly: true, isEnabled: { reading() && m.focus == .reader }) { reader.quickLook() },
            Command(id: "summarize", title: "Summarize", group: .actions, keys: [.command("s", shift: true)], menu: .message, section: 4,
                    aliases: ["tl;dr", "ai"], isEnabled: { reading() && m.services.ai != nil }) { reader.summarize() },
            Command(id: "showOriginal", title: "Show Original", group: .actions, menu: .message, section: 4,
                    aliases: ["source", "headers", "raw"], isEnabled: reading) { reader.showOriginal() },
            // ⌘F finds in the open conversation while it is on screen, and searches mail otherwise.
            Command(id: "find", title: "Find in Conversation…", group: .actions, keys: [.command("f")], menu: .edit, isTextSafe: true,
                    currentTitle: { reading() && m.readerVisible ? "Find in Conversation…" : "Search Mail" }) {
                if reading() && m.readerVisible { reader.find() } else { m.beginSearch() }
            },
            Command(id: "findNext", title: "Find Next", group: .actions, keys: [.command("g")], menu: .edit,
                    hiddenInPalette: true, isTextSafe: true, isEnabled: reading) { reader.findNext() },
            Command(id: "findPrevious", title: "Find Previous", group: .actions, keys: [.command("g", shift: true)], menu: .edit,
                    hiddenInPalette: true, isTextSafe: true, isEnabled: reading) { reader.findPrevious() },
            Command(id: "print", title: "Print Conversation…", group: .actions, keys: [.command("p")], menu: .file, section: 2,
                    isTextSafe: true, isEnabled: reading) { reader.printThread() },
        ]

        // App and settings
        list += [
            Command(id: "about", title: "About Tern", group: .settings, menu: .app, hiddenInPalette: true, isTextSafe: true) { [weak self] in
                self?.shell?.showAbout()
            },
            Command(id: "checkForUpdates", title: "Check for Updates…", group: .settings, menu: .app,
                    aliases: ["update", "upgrade", "new version", "install"], isTextSafe: true,
                    isEnabled: { [weak self] in self?.shell?.updater?.canCheck ?? false },
                    isVisible: { [weak self] in self?.shell?.updater != nil }) { [weak self] in self?.shell?.checkForUpdates() },
            Command(id: "settings", title: "Settings…", group: .settings, keys: [.command(",")], menu: .app, section: 1,
                    aliases: ["preferences"], isTextSafe: true) { [weak self] in self?.shell?.showSettings(nil) },
            Command(id: "mainWindow", title: "Tern", group: .settings, menu: .window, section: 1, hiddenInPalette: true,
                    isTextSafe: true) { [weak self] in
                self?.shell?.showMainWindow()
            },
        ]
        for section in SettingsSection.allCases {
            list.append(Command(id: "settings.\(section.rawValue)", title: "Settings: \(section.title)", group: .settings,
                                paletteOnly: true) { [weak self] in self?.shell?.showSettings(section) })
        }
        return list
    }
}

// MARK: - Shortcut changes

extension CommandRegistry {
    /// Whether the user changed the command's keys.
    func isCustomized(_ id: String) -> Bool { overrides.keys[id] != nil }

    /// What `shortcut` is kept for (`ShortcutRules.reservation`), with the key bindings files' keys once read.
    func reservation(_ shortcut: KeyShortcut, for id: String) -> String? {
        ShortcutRules.reservation(shortcut, for: id, textKeys: textKeys)
    }

    /// Reads the key bindings files in the background, once per run, then drops saved changes that use one of
    /// their Control keys and saves the rest. Launch never waits for this: the app asks once its window is up,
    /// and the recorder when it starts.
    func loadKeyBindings() {
        keyBindings.load { [weak self] keys in
            guard let self, keys != self.textKeys else { return }
            self.textKeys = keys
            let builtIn = self.commands.map { command in
                var command = command
                command.keys = self.defaultKeys[command.id] ?? []
                return command
            }
            self.update(Self.validated(self.overrides, commands: builtIn, textKeys: keys))
        }
    }

    /// Commands that already use `shortcut` where `id`'s keys act too (for a ⌘ or ⌃ key, anywhere).
    func conflicts(_ shortcut: KeyShortcut, for id: String) -> [Command] {
        guard let command = self[id] else { return [] }
        return commands.filter {
            $0.id != id && $0.keys.contains(shortcut) && !ShortcutRules.canShare(shortcut, $0.keyScope, command.keyScope)
        }
    }

    /// Whether the menu bar should leave `event` alone because a text field in `window` has the keyboard and
    /// the key is the menu key of a command that isn't text-safe: the key keeps its meaning in the text (⌃H
    /// deletes back) instead of acting on mail the user can't see they've selected. The Edit menu's own items
    /// (⌘A, ⌘Z, ⌘C…) aren't commands, so they still work.
    func leavesToText(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard KeyRouter.textInput(in: window) != nil else { return false }
        return commands.contains { command in
            !command.isTextSafe && command.menu != nil && !command.paletteOnly && command.menuKey?.matches(event) == true
        }
    }

    /// Saved changes as they can apply: only commands that exist and aren't locked, without reserved keys
    /// (`textKeys` from the key bindings files among them), without keys equal to the built-in ones, and without
    /// a key another command has where both act. `commands` have their built-in keys. A built-in key wins over a
    /// change; between two changes the command listed first keeps it. A change left with no keys falls back to
    /// the built-in ones, which can take a key from a later change in turn.
    static func validated(_ saved: ShortcutOverrides, commands: [Command], textKeys: Set<KeyShortcut> = []) -> ShortcutOverrides {
        var changes: [String: [KeyShortcut]] = [:]
        for command in commands where !ShortcutRules.isLocked(command.id) {
            guard let stored = saved.keys[command.id] else { continue }
            let allowed = unique(stored.filter { ShortcutRules.reservation($0, for: command.id, textKeys: textKeys) == nil })
            if (allowed.isEmpty && !stored.isEmpty) || allowed == command.keys { continue }
            changes[command.id] = allowed
        }
        while true {
            var taken = commands.filter { changes[$0.id] == nil }.flatMap { command in command.keys.map { (command.keyScope, $0) } }
            var fallback: String?
            for command in commands {
                guard let keys = changes[command.id] else { continue }
                let kept = keys.filter { key in !taken.contains { $0.1 == key && !ShortcutRules.canShare(key, $0.0, command.keyScope) } }
                if kept.isEmpty && !keys.isEmpty {
                    fallback = command.id
                    break
                }
                taken += kept.map { (command.keyScope, $0) }
                changes[command.id] = kept == command.keys ? nil : kept
            }
            guard let fallback else { break }
            changes[fallback] = nil
        }
        return ShortcutOverrides(keys: changes)
    }

    /// Puts `shortcut` in place of the key at `slot` (or after the others when `slot` is nil) and takes it
    /// away from every command it conflicted with.
    func assign(_ shortcut: KeyShortcut, to id: String, replacing slot: Int?) {
        guard let command = self[id] else { return }
        var next = overrides
        for other in conflicts(shortcut, for: id) {
            next.keys[other.id] = Self.delta(other.keys.filter { $0 != shortcut }, defaults: defaultKeys[other.id])
        }
        var keys = command.keys
        if let slot, keys.indices.contains(slot) { keys[slot] = shortcut } else { keys.append(shortcut) }
        next.keys[id] = Self.delta(Self.unique(keys), defaults: defaultKeys[id])
        update(next)
    }

    /// Removes one of the command's keys. It still runs from the menus and ⌘K.
    func removeKey(at slot: Int, from id: String) {
        guard var keys = self[id]?.keys, keys.indices.contains(slot) else { return }
        keys.remove(at: slot)
        var next = overrides
        next.keys[id] = Self.delta(keys, defaults: defaultKeys[id])
        update(next)
    }

    /// Back to the built-in keys, taking them from any command the user gave them to since.
    func resetKeys(for id: String) {
        var next = overrides
        next.keys[id] = nil
        for key in defaultKeys[id] ?? [] {
            for other in conflicts(key, for: id) {
                next.keys[other.id] = Self.delta(other.keys.filter { $0 != key }, defaults: defaultKeys[other.id])
            }
        }
        update(next)
    }

    func resetAllKeys() { update(ShortcutOverrides()) }

    /// Puts back a whole set of changes saved earlier (snapshots and the self-check leave the user's own).
    func restore(_ saved: ShortcutOverrides) { update(saved) }

    private func update(_ next: ShortcutOverrides) {
        guard next != overrides else { return }
        overrides = next
        applyOverrides()
        saveOverrides(next)
        NotificationCenter.default.post(name: Self.shortcutsDidChange, object: self)
    }

    /// The override to store: nil when the keys are the built-in ones.
    private static func delta(_ keys: [KeyShortcut], defaults: [KeyShortcut]?) -> [KeyShortcut]? {
        keys == (defaults ?? []) ? nil : keys
    }

    private static func unique(_ keys: [KeyShortcut]) -> [KeyShortcut] {
        keys.reduce(into: []) { result, key in if !result.contains(key) { result.append(key) } }
    }
}

extension AppModel {
    func togglePalette() {
        palette = palette == .commands ? nil : .commands
    }

    /// Labels that can be applied to the current targets: those of their one account.
    func labelsForTargets() -> [MailLabel]? {
        let accounts = Set(targets.map(\.accountId))
        guard accounts.count == 1, let accountId = accounts.first else { return nil }
        if scope.accountId == accountId { return labels }
        return (try? store.labels(accountId: accountId))?.filter { $0.type == "user" && !$0.hidden }
    }

    func accountTitle(_ account: Account) -> String {
        account.displayName.isEmpty ? account.email : account.displayName
    }
}
