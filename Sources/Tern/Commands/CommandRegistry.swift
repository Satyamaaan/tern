import AppKit
import TernCore

/// Window-level actions the registry needs from the app delegate.
@MainActor
protocol ShellActions: AnyObject {
    func showSettings(_ section: SettingsSection?)
    func addAccount()
    func showMainWindow()
    func showAbout()
}

/// Builds every command once. Closures read the model at run time, so titles and enabled states stay current.
@MainActor
final class CommandRegistry {
    private(set) var commands: [Command] = []
    private var byId: [String: Command] = [:]
    let model: AppModel
    weak var shell: ShellActions?

    init(model: AppModel, shell: ShellActions?) {
        self.model = model
        self.shell = shell
        commands = makeCommands()
        byId = Dictionary(uniqueKeysWithValues: commands.map { ($0.id, $0) })
    }

    subscript(id: String) -> Command? { byId[id] }

    func run(_ id: String) {
        guard let command = byId[id], command.isEnabled() else { return }
        command.run()
    }

    /// Commands with a bare-key shortcut, for `KeyRouter`.
    var bareKeyCommands: [Command] { commands.filter { $0.keys.contains(where: \.isBare) } }
    var chordCommands: [Command] { commands.filter { $0.chord != nil } }

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
            Command(id: "moveToInbox", title: "Move to Inbox", group: .actions, menu: .message,
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

        // File
        list += [
            Command(id: "compose", title: "New Message", group: .actions, keys: [.key("c"), .command("n")], menu: .file,
                    aliases: ["compose", "write", "email"]) { m.compose() },
            Command(id: "addAccount", title: "Add Account…", group: .accounts, menu: .file, section: 1,
                    aliases: ["connect gmail"]) { [weak self] in self?.shell?.addAccount() },
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
            Command(id: "markAllRead", title: "Mark All as Read", group: .actions, menu: .mailbox, section: 1,
                    isEnabled: { !m.snapshot.isEmpty }) { m.markAllRead() },
            Command(id: "newProject", title: "New Project…", group: .projects, menu: .mailbox, section: 2,
                    aliases: ["create project"]) { m.newProject() },
            Command(id: "splitInbox", title: "Split Inbox", group: .settings, menu: .mailbox, section: 2,
                    currentTitle: { m.prefs.splitInbox ? "Turn Off Split Inbox" : "Turn On Split Inbox" }) { m.setSplitInbox(!m.prefs.splitInbox) },
        ]

        // Scope
        list.append(Command(id: "scope.all", title: "All Accounts", group: .accounts, keys: [.command("0")], menu: .mailbox,
                            aliases: ["unified inbox"]) { m.setScope(.all) })
        for slot in 1...9 {
            list.append(Command(
                id: "scope.\(slot)", title: "Account \(slot)", group: .accounts, keys: [.command("\(slot)")], menu: .mailbox,
                hiddenInPalette: true,
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
            Command(id: "go.spam", title: "Spam", group: .goTo, menu: .go) { m.show(.spam) },
            Command(id: "go.trash", title: "Trash", group: .goTo, menu: .go) { m.show(.trash) },
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
            Command(id: "nextSplit", title: "Next Split", group: .goTo, keys: [.special(.tab)], menu: .go, section: 3,
                    isEnabled: { m.showsSplits }) { m.cycleSplit(1) },
            Command(id: "previousSplit", title: "Previous Split", group: .goTo, keys: [.special(.tab, [.shift])], menu: .go, section: 3,
                    isEnabled: { m.showsSplits }) { m.cycleSplit(-1) },
        ]
        for (index, split) in InboxSplit.allCases.enumerated() {
            list.append(Command(id: "split.\(split.rawValue)", title: split.title, group: .goTo, keys: [.option("\(index + 1)")],
                                menu: .go, section: 4, aliases: ["split", "tab"],
                                isEnabled: { m.prefs.splitInbox }) { m.showSplit(split) })
        }

        // View
        list += [
            Command(id: "palette", title: "Command Palette", group: .actions, keys: [.command("k")], menu: .view,
                    hiddenInPalette: true) { m.togglePalette() },
            Command(id: "search", title: "Search Mail", group: .actions, keys: [.key("/")], menu: .view,
                    aliases: ["find"]) { m.beginSearch() },
            Command(id: "shortcuts", title: "Keyboard Shortcuts", group: .settings, keys: [.key("?")], menu: .help,
                    aliases: ["help", "keys", "cheat sheet"]) { m.showsShortcuts.toggle() },
            Command(id: "toggleSidebar", title: "Hide Sidebar", group: .settings, keys: [.command("\\")], menu: .view, section: 1,
                    currentTitle: { m.prefs.sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar" }) { m.toggleSidebar() },
            Command(id: "listOnly", title: "List Only", group: .settings, keys: [.command("\\", shift: true)], menu: .view, section: 1,
                    aliases: ["hide reader", "full width"],
                    currentTitle: { m.listOnly ? "Show Reader" : "List Only" }) { m.toggleListOnly() },
        ]
        for density in Density.allCases {
            list.append(Command(id: "density.\(density.rawValue)", title: "Density: \(density.title)", group: .settings,
                                menu: .view, section: 2, aliases: ["rows", "compact", "comfortable"]) { m.prefs.density = density })
        }
        for mode in AppearanceMode.allCases {
            list.append(Command(id: "appearance.\(mode.rawValue)", title: "Appearance: \(mode.title)", group: .settings,
                                menu: .view, section: 3, aliases: ["theme", "dark mode", "light mode"]) { m.prefs.appearance = mode })
        }
        list.append(Command(id: "dimRead", title: "Dim Old Read Mail", group: .settings, menu: .view, section: 2,
                            currentTitle: { m.prefs.dimReadByAge ? "Don't Dim Old Read Mail" : "Dim Old Read Mail" }) { m.prefs.dimReadByAge.toggle() })

        // App and settings
        list += [
            Command(id: "settings", title: "Settings…", group: .settings, keys: [.command(",")], menu: .app,
                    aliases: ["preferences"]) { [weak self] in self?.shell?.showSettings(nil) },
            Command(id: "about", title: "About Tern", group: .settings, menu: .app, hiddenInPalette: true) { [weak self] in self?.shell?.showAbout() },
            Command(id: "mainWindow", title: "Tern", group: .settings, menu: .window, section: 1, hiddenInPalette: true) { [weak self] in
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
