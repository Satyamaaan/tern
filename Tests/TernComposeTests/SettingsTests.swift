import AppKit
import Foundation
import Testing
@testable import Tern
@testable import TernCore

// Settings: shortcut overrides (storage, conflicts, reserved keys, reset, bare keys) and the defaults of the
// settings the page added.

@MainActor
private func makeModel(threads: Int = 0) throws -> AppModel {
    let database = try AppDatabase.inMemory()
    let account = Account(email: "me@example.com")
    try database.writer.write { db in
        try account.insert(db)
        try MailStore.upsertMessages(db, (0..<threads).map { index in
            MailMessage(accountId: account.id, id: "m\(index)", threadId: "t\(index)", date: Date(timeIntervalSince1970: Double(1_000 - index)),
                        fromName: "Maya", fromEmail: "maya@lumen.io", toList: [Participant(email: account.email)],
                        subject: "Thread \(index)", bodyText: "Hi", bodyState: .full, labelIds: ["INBOX"])
        })
    }
    let services = AppServices(store: MailStore(database))
    services.accounts = [account]
    return AppModel(services: services, isFake: true, databaseURL: URL(fileURLWithPath: "/dev/null"))
}

/// A registry that keeps its changes to itself: nothing reaches the saved preferences.
@MainActor
private func makeRegistry(_ overrides: ShortcutOverrides = ShortcutOverrides(), threads: Int = 0) throws -> CommandRegistry {
    let model = try makeModel(threads: threads)
    let registry = CommandRegistry(model: model, shell: nil, overrides: overrides)
    model.registry = registry
    return registry
}

private func scratchDefaults() -> UserDefaults {
    let name = "tern-settings-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                     characters: characters, charactersIgnoringModifiers: characters.lowercased(), isARepeat: false, keyCode: keyCode)!
}

// MARK: - Storage

@Test func shortcutsReadBackFromTheirStoredForm() {
    let shortcuts: [KeyShortcut] = [
        .key("e"), .key("J"), .key("#"), .key("?"), .command("k"), .command("l", shift: true), .option("1"),
        KeyShortcut(key: .char("s"), modifiers: [.control, .command]), .special(.tab, [.shift]), .special(.delete),
        .special(.returnKey), .special(.escape), .special(.up), .special(.down), .special(.space, [.option]),
        .command("|"), .command(":"),
    ]
    for shortcut in shortcuts {
        #expect(KeyShortcut(stored: shortcut.stored) == shortcut, "\(shortcut.display) as \(shortcut.stored)")
    }
    #expect(KeyShortcut.command("l", shift: true).stored == "⇧⌘|c:l")
    #expect(KeyShortcut(stored: "nonsense") == nil)
    #expect(KeyShortcut(stored: "X|c:a") == nil)
    #expect(KeyShortcut(stored: "|c:ab") == nil)
}

@Test func overridesSaveOnlyTheChangesAndLoadThemBack() {
    let defaults = scratchDefaults()
    let overrides = ShortcutOverrides(keys: ["archive": [.key("y")], "go.inbox": [.command("i", shift: true)], "star": []])
    overrides.save(to: defaults)
    #expect(defaults.dictionary(forKey: ShortcutOverrides.defaultsKey)?.count == 3)
    #expect(ShortcutOverrides.load(from: defaults) == overrides)
    ShortcutOverrides().save(to: defaults)
    #expect(defaults.object(forKey: ShortcutOverrides.defaultsKey) == nil)
}

@Test func overridesThatDontReadBackFallBackToTheDefaults() {
    let loaded = ShortcutOverrides(stored: [
        "archive": ["|c:y", "garbage"],
        "star": ["⌘|c:q"],
        "mute": ["⌘|c:q", "|c:b"],
        "unread": [],
    ])
    #expect(loaded.keys["archive"] == nil)
    #expect(loaded.keys["star"] == nil)
    #expect(loaded.keys["mute"] == [.key("b")])
    #expect(loaded.keys["unread"] == [])
}

// MARK: - Editing

@MainActor
@Test func editingKeepsOnlyTheDeltaFromTheBuiltInKeys() throws {
    let registry = try makeRegistry()
    #expect(registry["archive"]?.keys == [.key("e")])
    registry.assign(.key("y"), to: "archive", replacing: 0)
    #expect(registry["archive"]?.keys == [.key("y")])
    #expect(registry.overrides.keys == ["archive": [.key("y")]])
    #expect(registry.isCustomized("archive"))
    registry.assign(.key("e"), to: "archive", replacing: 0)
    #expect(registry.overrides.isEmpty)
    #expect(!registry.isCustomized("archive"))

    // Adding a key keeps the others; removing one leaves the command in the menus without it.
    registry.assign(.command("e", shift: true), to: "archive", replacing: nil)
    #expect(registry["archive"]?.keys == [.key("e"), .command("e", shift: true)])
    registry.removeKey(at: 0, from: "archive")
    registry.removeKey(at: 0, from: "archive")
    #expect(registry["archive"]?.keys == [])
    #expect(registry.overrides.keys["archive"] == [])
    #expect(registry.hint("Done", "archive") == "Done")
}

@MainActor
@Test func savedOverridesApplyWhenTheRegistryStarts() throws {
    let registry = try makeRegistry(ShortcutOverrides(keys: ["archive": [.key("y")], "gone.command": [.key("q")]]))
    #expect(registry["archive"]?.keys == [.key("y")])
    #expect(registry["star"]?.keys == [.key("s")])
    #expect(registry.defaultKeys["archive"] == [.key("e")])
    #expect(registry.hint("Done", "archive") == "Done  y")
}

@MainActor
@Test func conflictsOnlyCountWhereBothCommandsAct() throws {
    let registry = try makeRegistry()
    #expect(registry.conflicts(.key("s"), for: "archive").map(\.id) == ["star"])
    // `p` is Move to Project in the list and Previous Message in the open conversation.
    #expect(registry.conflicts(.key("p"), for: "project").isEmpty)
    #expect(registry.conflicts(.key("p"), for: "previousMessage").isEmpty)
    #expect(Set(registry.conflicts(.key("p"), for: "archive").map(\.id)) == ["project", "previousMessage"])
    #expect(registry.conflicts(.key("y"), for: "archive").isEmpty)
    #expect(registry.conflicts(.key("e"), for: "archive").isEmpty)
}

@MainActor
@Test func replaceTakesTheKeyAndResetTakesItBack() throws {
    let registry = try makeRegistry()
    registry.assign(.key("s"), to: "archive", replacing: 0)
    #expect(registry["archive"]?.keys == [.key("s")])
    #expect(registry["star"]?.keys == [])
    registry.resetKeys(for: "star")
    #expect(registry["star"]?.keys == [.key("s")])
    #expect(registry["archive"]?.keys == [])
    registry.assign(.key("y"), to: "mute", replacing: 0)
    registry.resetAllKeys()
    #expect(registry.overrides.isEmpty)
    #expect(registry["archive"]?.keys == [.key("e")] && registry["mute"]?.keys == [.key("m")])
}

@MainActor
@Test func reservedAndLockedKeysCantBeTaken() throws {
    let registry = try makeRegistry()
    func problem(_ shortcut: KeyShortcut, _ id: String) -> ShortcutRecording.Problem? {
        SettingsState.problem(shortcut, for: id, registry: registry)
    }
    #expect(problem(.command("q"), "archive") == .reserved(.command("q"), owner: "Quit Tern"))
    #expect(problem(.command(","), "archive") == .reserved(.command(","), owner: "Settings"))
    #expect(problem(.special(.tab, [.command]), "archive") != nil)
    #expect(problem(.special(.space, [.command]), "archive") != nil)
    #expect(problem(.command("`"), "archive") != nil)
    #expect(problem(.command("w"), "archive") != nil)
    #expect(problem(.command("h"), "archive") != nil)
    #expect(problem(.command("m"), "archive") != nil)
    #expect(problem(.key("g"), "archive") != nil)
    #expect(problem(.command("a"), "archive") == .reserved(.command("a"), owner: "Select All"))
    #expect(problem(.command("a"), "selectAll") == nil)
    // ⌘1–⌘9 follow the account order.
    #expect(problem(.command("3"), "archive") == .reserved(.command("3"), owner: "Account 3"))
    #expect(problem(.key("s"), "archive") == .taken(.key("s"), by: ["star"]))
    #expect(problem(.key("y"), "archive") == nil)
    #expect(ShortcutRules.isLocked("settings") && ShortcutRules.isLocked("scope.4") && !ShortcutRules.isLocked("scope.all"))
}

// MARK: - Recording and routing

@MainActor
@Test func keyPressesRecordAsTheRegistryWritesThem() {
    #expect(KeyShortcut(recording: key("e", keyCode: 14)) == .key("e"))
    #expect(KeyShortcut(recording: key("J", keyCode: 38, modifiers: .shift)) == .key("J"))
    #expect(KeyShortcut(recording: key("#", keyCode: 20, modifiers: .shift)) == .key("#"))
    // Caps Lock alone doesn't make a capital shortcut.
    #expect(KeyShortcut(recording: key("E", keyCode: 14, modifiers: .capsLock)) == .key("e"))
    #expect(KeyShortcut(recording: key("L", keyCode: 37, modifiers: [.command, .shift])) == .command("l", shift: true))
    #expect(KeyShortcut(recording: key("¡", keyCode: 18, modifiers: .option)) == .option("1"))
    #expect(KeyShortcut(recording: key("\t", keyCode: 48, modifiers: .shift)) == .special(.tab, [.shift]))
    #expect(KeyShortcut(recording: key(" ", keyCode: 49)) == .special(.space))
    // F5 and ← can't be bound.
    #expect(KeyShortcut(recording: key("\u{F708}", keyCode: 96)) == nil)
    #expect(KeyShortcut(recording: key("\u{F702}", keyCode: 123)) == nil)
}

@MainActor
@Test func theRecorderSavesCancelsRemovesAndExplains() throws {
    let registry = try makeRegistry()
    let settings = SettingsState(model: registry.model, section: .shortcuts, updater: nil)
    settings.startRecording("archive", slot: 0)
    settings.record(key("y", keyCode: 16))
    #expect(settings.recording == nil && registry["archive"]?.keys == [.key("y")])

    settings.startRecording("archive", slot: 0)
    settings.record(key("", keyCode: 53))
    #expect(settings.recording == nil && registry["archive"]?.keys == [.key("y")])

    settings.startRecording("archive", slot: 0)
    settings.record(key("q", keyCode: 12, modifiers: .command))
    #expect(settings.recording?.problem == .reserved(.command("q"), owner: "Quit Tern"))
    settings.record(key("\u{F708}", keyCode: 96))
    #expect(settings.recording?.problem == .unsupported)
    settings.record(key("s", keyCode: 1))
    #expect(settings.recording?.problem == .taken(.key("s"), by: ["star"]))
    settings.record(key("\r", keyCode: 36))
    #expect(settings.recording == nil && registry["archive"]?.keys == [.key("s")] && registry["star"]?.keys == [])

    // ⌫ removes the key being edited; the command still runs from the menus.
    settings.startRecording("archive", slot: 0)
    settings.record(key("\u{7F}", keyCode: 51))
    #expect(settings.recording == nil && registry["archive"]?.keys == [])
}

@MainActor
@Test func bareKeysStayWithTheRouterAndNeverFireFromTheMenu() throws {
    _ = NSApplication.shared
    let registry = try makeRegistry(threads: 3)
    let model = registry.model
    model.reloadList()
    try #require(!model.snapshot.isEmpty)
    registry.assign(.key("y"), to: "archive", replacing: 0)
    let router = KeyRouter(registry: registry)
    // `e` is free now; `y` archives.
    let first = try #require(model.cursor)
    #expect(router.handle(key("e", keyCode: 14)) != nil)
    #expect(model.snapshot.rows[first] != nil)
    #expect(router.handle(key("y", keyCode: 16)) == nil)
    #expect(model.snapshot.rows[first] == nil)

    let menu = MainMenu(registry: registry).build()
    let archive = menu.items.first { $0.title == "Message" }?.submenu?.items.first { $0.title == "Archive" }
    #expect(archive?.keyEquivalent == "y" && archive?.keyEquivalentModifierMask == [])
    #expect(menu.performKeyEquivalent(with: key("y", keyCode: 16)) == false)

    // A ⌘ key on a command outside the menu bar goes through the router instead, and the old one stops.
    registry.assign(.command("a", shift: true), to: "selectAll", replacing: 0)
    #expect(router.handle(key("a", keyCode: 0, modifiers: .command)) != nil)
    #expect(model.checked.isEmpty)
    #expect(router.handle(key("A", keyCode: 0, modifiers: [.command, .shift])) == nil)
    #expect(model.checked.count == model.snapshot.order.count)
}

// MARK: - New settings

@MainActor
@Test func newSettingsDefaultToTodaysBehaviour() throws {
    let prefs = Preferences(defaults: scratchDefaults())
    #expect(prefs.afterTriage == .next)
    #expect(prefs.markRead == .afterDelay)
    #expect(prefs.shortcutOverrides.isEmpty)
    #expect(prefs.settingsSection == "")
    #expect(MarkReadMode.dwell == 1.5)

    let model = try makeModel()
    let settings = SettingsState(model: model, section: .mail, updater: nil)
    #expect(settings.undoSeconds == DraftStore.defaultUndoSeconds && settings.undoSeconds == 5)
    #expect(settings.signatures)
    #expect(settings.sendFrom == nil)
    #expect(settings.imageSenders.isEmpty)
}

@MainActor
@Test func mailSettingsWriteTheSettingsTheComposerReads() throws {
    let model = try makeModel()
    let settings = SettingsState(model: model, section: .mail, updater: nil)
    settings.undoSeconds = 10
    settings.signatures = false
    model.writes.sync {}
    #expect(try model.services.drafts.undoSeconds() == 10)
    #expect(try model.store.setting(DraftStore.SettingKey.signatures) == "off")
    settings.undoSeconds = DraftStore.defaultUndoSeconds
    settings.signatures = true
    model.writes.sync {}
    #expect(try model.store.setting(DraftStore.SettingKey.undoSeconds) == nil)
    #expect(try model.store.setting(DraftStore.SettingKey.signatures) == nil)

    try model.store.setImagesAllowed(true, sender: "news@figma.com")
    let reopened = SettingsState(model: model, section: .mail, updater: nil)
    #expect(reopened.imageSenders == ["news@figma.com"])
    reopened.forgetImages(from: "news@figma.com")
    model.writes.sync {}
    #expect(try model.store.imageAllowedSenders().isEmpty)
}

@MainActor
@Test func afterTriageChoosesTheNextOrThePreviousConversation() throws {
    let model = try makeModel(threads: 4)
    let rows = try model.store.threadRows(in: Mailbox(.allMail), limit: 10)
    #expect(rows.count == 4)
    let old = ListSnapshot(rows: rows, groupsByDate: false)
    let middle = rows[1].id
    let new = ListSnapshot(rows: rows.filter { $0.id != middle }, groupsByDate: false)
    #expect(AppModel.successor(of: middle, in: old, keeping: new) == rows[2].id)
    #expect(AppModel.successor(of: middle, in: old, keeping: new, upward: true) == rows[0].id)
    // At the ends each falls back to the other side.
    let top = ListSnapshot(rows: Array(rows.dropFirst()), groupsByDate: false)
    #expect(AppModel.successor(of: rows[0].id, in: old, keeping: top, upward: true) == rows[1].id)
}

@MainActor
@Test func settingsSearchFindsSettingsAcrossSections() throws {
    let model = try makeModel()
    #expect(SettingsCatalog.results(for: "undo", model: model) == [.undoSend])
    #expect(SettingsCatalog.results(for: "dark", model: model).contains(.theme))
    #expect(SettingsCatalog.results(for: "pinned tabs", model: model) == [.pinnedTabs])
    #expect(SettingsCatalog.results(for: "", model: model).isEmpty)
    // Words match from their start: "arch" is Archive, not Search.
    #expect(SettingsCatalog.matches("arch", in: "archive done"))
    #expect(!SettingsCatalog.matches("arch", in: "search mail"))
    #expect(SettingsCatalog.matches("⇧r", in: "needs reply ⇧r"))
    // Several accounts are needed before "Send new mail from" shows.
    #expect(!SettingsItem.items(in: .mail, model: model).contains(.sendFrom))
}
