import AppKit
import Foundation
import Testing
@testable import Tern
@testable import TernCore

// Settings: shortcut overrides (storage, validation, conflicts, reserved keys, the key bindings files, reset, bare
// keys, typing, the reader page's keys), the defaults of the settings the page added, what follows triage, Inbox
// Tabs keeping the open thread, and image senders.

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

/// A registry that keeps its changes to itself: nothing reaches the saved preferences, and it reads no key bindings file.
@MainActor
private func makeRegistry(_ overrides: ShortcutOverrides = ShortcutOverrides(), threads: Int = 0) throws -> CommandRegistry {
    let model = try makeModel(threads: threads)
    let registry = CommandRegistry(model: model, shell: nil, overrides: overrides, keyBindings: KeyBindingFiles(urls: []))
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

@MainActor
@Test func savedOverridesThatCantApplyAreDroppedAndSavedAgain() throws {
    let defaults = scratchDefaults()
    defaults.set([
        "archive": ["⌘|c:3"],             // Account 3's key
        "star": ["|c:e"],                 // Archive's built-in key, which Archive gets back
        "settings": [],                   // locked: ⌘, stays
        "scope.2": ["|c:y"],              // locked
        "mute": ["⌃|c:h", "|c:b"],        // ⌃H is for text editing
        "label": ["|c:j"],                // Next Conversation's key
        "unread": ["|c:u", "|c:U"],       // the built-in keys: no change
        "gone.command": ["|c:q"],
        "project": ["⌘|c:y"],
        "previousMessage": ["⌘|c:y"],     // the same menu key as Move to Project
    ], forKey: ShortcutOverrides.defaultsKey)
    let model = try makeModel()
    let registry = CommandRegistry(model: model, shell: nil, overrides: ShortcutOverrides.load(from: defaults), save: { $0.save(to: defaults) })
    #expect(registry.overrides.keys == ["mute": [.key("b")], "project": [.command("y")]])
    #expect(registry["archive"]?.keys == [.key("e")] && registry["star"]?.keys == [.key("s")])
    #expect(registry["settings"]?.keys == [.command(",")] && registry["scope.2"]?.keys == [.command("2")])
    #expect(registry["scope.3"]?.keys == [.command("3")])
    #expect(registry["label"]?.keys == [.key("l")] && registry["previousMessage"]?.keys == [.key("p")])
    #expect(registry["unread"]?.keys == [.key("u"), .key("U")] && !registry.isCustomized("unread"))
    // What was dropped is gone from the saved changes too, even what didn't read back.
    #expect(ShortcutOverrides.load(from: defaults) == registry.overrides)
    #expect(defaults.dictionary(forKey: ShortcutOverrides.defaultsKey) as? [String: [String]] == ["mute": ["|c:b"], "project": ["⌘|c:y"]])
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
    #expect(registry.hint("Archive", "archive") == "Archive")
}

@MainActor
@Test func savedOverridesApplyWhenTheRegistryStarts() throws {
    let registry = try makeRegistry(ShortcutOverrides(keys: ["archive": [.key("y")], "gone.command": [.key("q")]]))
    #expect(registry["archive"]?.keys == [.key("y")])
    #expect(registry["star"]?.keys == [.key("s")])
    #expect(registry.defaultKeys["archive"] == [.key("e")])
    #expect(registry.hint("Archive", "archive") == "Archive  y")
}

@MainActor
@Test func keysSavedForTheOldDoneChordMoveToGoToArchive() throws {
    var saved: ShortcutOverrides?
    let model = try makeModel()
    let registry = CommandRegistry(
        model: model, shell: nil, overrides: ShortcutOverrides(keys: ["go.done": [.command("e", shift: true)]]),
        save: { saved = $0 }, keyBindings: KeyBindingFiles(urls: []))
    #expect(registry["go.done"] == nil)
    #expect(registry["go.archive"]?.chord == "g e")
    #expect(registry["go.archive"]?.keys == [.command("e", shift: true)])
    #expect(saved?.keys == ["go.archive": [.command("e", shift: true)]])

    // Keys of its own win over the old ones.
    let both = CommandRegistry(
        model: model, shell: nil,
        overrides: ShortcutOverrides(keys: ["go.done": [.command("e", shift: true)], "go.archive": [.option("9")]]),
        keyBindings: KeyBindingFiles(urls: []))
    #expect(both["go.archive"]?.keys == [.option("9")])
}

@MainActor
@Test func theArchiveListMovesThreadsBackToTheInbox() throws {
    let registry = try makeRegistry(threads: 3)
    let model = registry.model
    model.reloadList()
    let key = try #require(model.snapshot.order.first)
    try model.store.perform(.archive, on: [key])

    model.show(.archive)
    #expect(model.inArchive && model.snapshot.order == [key] && model.cursor == key)
    #expect(!registry.canRun(registry["archive"]!), "everything here is archived already")
    #expect(registry.canRun(registry["moveToInbox"]!))
    #expect(registry.hint("Move to Inbox", "moveToInbox") == "Move to Inbox  ⇧I")

    registry.run("moveToInbox")
    #expect(model.snapshot.rows[key] == nil, "the row leaves in the same frame")
    #expect(model.toasts.last?.title == "Moved to Inbox" && model.toasts.last?.undo != nil)
    model.writes.sync {}
    #expect(try model.store.threadRows(in: .unifiedInbox).map(\.id).contains(key))

    model.undoLast()
    model.writes.sync {}
    #expect(try !model.store.threadRows(in: .unifiedInbox).map(\.id).contains(key))
    #expect(try model.store.threadRows(in: Mailbox(.archive)).map(\.id) == [key])

    model.searchText = "Thread"
    #expect(!model.inArchive, "search results can hold inbox threads")
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
@Test func onlyBareKeysAreSharedBetweenTheListAndTheReader() throws {
    _ = NSApplication.shared
    let registry = try makeRegistry()
    // A ⌘ key becomes a menu key equivalent for both commands, and the menu bar doesn't know where the
    // keyboard is, so it conflicts whatever the scopes.
    registry.assign(.command("y"), to: "project", replacing: nil)
    #expect(registry.conflicts(.command("y"), for: "previousMessage").map(\.id) == ["project"])
    #expect(SettingsState.problem(.command("y"), for: "previousMessage", registry: registry) == .taken(.command("y"), by: ["project"]))
    #expect(registry.conflicts(.key("p"), for: "project").isEmpty)
    registry.assign(.command("y"), to: "previousMessage", replacing: nil)
    #expect(registry["project"]?.keys == [.key("p")] && registry["previousMessage"]?.keys == [.key("p"), .command("y")])
    let menu = MainMenu(registry: registry).build()
    let items: [NSMenuItem] = menu.items.flatMap { $0.submenu?.items ?? [] }
    let titles = items.filter { $0.keyEquivalent == "y" && $0.keyEquivalentModifierMask == .command }.map { $0.title }
    #expect(titles == ["Previous Message"])
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

@MainActor
@Test func controlKeysTextFieldsEditWithAreReserved() throws {
    let registry = try makeRegistry()
    for letter in "abdefhklnoptvy" {
        for extra: NSEvent.ModifierFlags in [[], .shift, .option, [.option, .shift]] {
            let shortcut = KeyShortcut(key: .char(String(letter)), modifiers: extra.union(.control))
            #expect(SettingsState.problem(shortcut, for: "trash", registry: registry) == .reserved(shortcut, owner: "text editing"), "\(shortcut.display)")
        }
    }
    #expect(ShortcutRules.reservation(.special(.returnKey, [.control]), for: "archive") == "text editing")
    #expect(ShortcutRules.reservation(.special(.delete, [.control, .option]), for: "archive") == "text editing")
    #expect(ShortcutRules.reservation(KeyShortcut(key: .char("g"), modifiers: .control), for: "trash") == nil)
    // A saved override with one is dropped when it loads.
    #expect(ShortcutOverrides(stored: ["trash": ["⌃|c:h"]]).keys["trash"] == nil)
    // The Control keys a key bindings dictionary binds (the system's and the user's are read after launch).
    let parsed = KeyBindingFiles.controlKeys(in: [
        "^w": "deleteToMark:", "~^B": "moveWordBackwardAndModifySelection:", "^\u{F700}": "scrollPageUp:",
        "^\u{19}": "selectPreviousKeyView:", "^x": ["^x": "swapWithMark:"], "@^a": "selectAll:", "a": "insertText:",
        "^": "noop:", "^\u{F702}": "moveToLeftEndOfLine:",
    ])
    #expect(parsed == [
        KeyShortcut(key: .char("w"), modifiers: .control), KeyShortcut(key: .char("b"), modifiers: [.control, .option, .shift]),
        .special(.up, [.control]), .special(.tab, [.control, .shift]), KeyShortcut(key: .char("x"), modifiers: .control),
    ])
}

/// A key bindings file the user could have written: an XML plist of `bindings`.
private func bindingsFile(_ bindings: [String: String]) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tern-keybindings-\(UUID().uuidString).dict")
    try PropertyListSerialization.data(fromPropertyList: bindings, format: .xml, options: 0).write(to: url)
    return url
}

@Test func aHugeModifierRunInAKeyBindingStaysCheap() throws {
    // 400,000 ^ then h: the scan stops after `maxBindingLength` scalars, so the entry is ignored at once.
    let long = String(repeating: "^", count: 400_000) + "h"
    var clock = ContinuousClock.now
    let parsed = KeyBindingFiles.controlKeys(in: [long: "deleteBackward:", "^j": "insertNewline:"])
    let parse = ContinuousClock.now - clock
    #expect(parsed == [KeyShortcut(key: .char("j"), modifiers: .control)])
    #expect(parse < .milliseconds(200), "parsed in \(parse)")

    // The same entry as a file: 400 KB is over the size cap, so it isn't even read.
    let big = try bindingsFile([long: "deleteBackward:"])
    defer { try? FileManager.default.removeItem(at: big) }
    clock = ContinuousClock.now
    #expect(KeyBindingFiles.dictionary(at: big) == nil)
    #expect(KeyBindingFiles.read([big]).isEmpty)
    let skip = ContinuousClock.now - clock

    // Under the cap it is read, and the entry is ignored as quickly.
    let medium = try bindingsFile([String(repeating: "^", count: 200_000) + "h": "deleteBackward:", "~^j": "insertNewline:"])
    defer { try? FileManager.default.removeItem(at: medium) }
    clock = ContinuousClock.now
    #expect(KeyBindingFiles.read([medium]) == [KeyShortcut(key: .char("j"), modifiers: [.control, .option])])
    let read = ContinuousClock.now - clock
    #expect(skip < .milliseconds(200) && read < .milliseconds(500), "skipped in \(skip), read in \(read)")
    print("Key bindings: 400k-scalar entry parsed in \(parse), 400 KB file skipped in \(skip), 200 KB file read in \(read)")

    // Not a dictionary, not a file, not there: nothing.
    let text = FileManager.default.temporaryDirectory.appendingPathComponent("tern-keybindings-\(UUID().uuidString).dict")
    try Data("not a plist {".utf8).write(to: text)
    defer { try? FileManager.default.removeItem(at: text) }
    #expect(KeyBindingFiles.read([text, FileManager.default.temporaryDirectory, URL(fileURLWithPath: "/nonexistent/DefaultKeyBinding.dict")]).isEmpty)
}

@MainActor
@Test func launchReadsNoKeyBindingsFileAndTheBackgroundReadCleansUp() async throws {
    // The user binds ⌃J in their DefaultKeyBinding.dict and has given ⌃J to Archive.
    let file = try bindingsFile(["^j": "insertNewline:"])
    defer { try? FileManager.default.removeItem(at: file) }
    let files = KeyBindingFiles(urls: [file])
    let defaults = scratchDefaults()
    let controlJ = KeyShortcut(key: .char("j"), modifiers: .control)
    ShortcutOverrides(keys: ["archive": [controlJ], "star": [.key("y")]]).save(to: defaults)

    // What launch runs: the preferences, then the registry. Neither reads the file.
    let prefs = Preferences(defaults: defaults)
    #expect(prefs.shortcutOverrides.keys["archive"] == [controlJ])
    let registry = CommandRegistry(model: try makeModel(), shell: nil, overrides: prefs.shortcutOverrides,
                                   save: { $0.save(to: defaults) }, keyBindings: files)
    #expect(files.reads == 0 && files.keys == nil)
    #expect(registry["archive"]?.keys == [controlJ] && registry.reservation(controlJ, for: "trash") == nil)

    // After launch it is read once in the background, and the change that uses its key goes.
    registry.loadKeyBindings()
    registry.loadKeyBindings()
    let keys = await withCheckedContinuation { continuation in files.load { continuation.resume(returning: $0) } }
    #expect(keys == [controlJ] && files.reads == 1)
    #expect(registry["archive"]?.keys == [.key("e")] && registry["star"]?.keys == [.key("y")])
    #expect(ShortcutOverrides.load(from: defaults).keys == ["star": [.key("y")]])
    #expect(SettingsState.problem(controlJ, for: "trash", registry: registry) == .reserved(controlJ, owner: "text editing"))
    // A registry made later starts with what was read.
    let later = CommandRegistry(model: try makeModel(), shell: nil, overrides: ShortcutOverrides(keys: ["mute": [controlJ]]), keyBindings: files)
    #expect(later.overrides.isEmpty && files.reads == 1)
}

@MainActor
@Test func theRecorderAsksForTheKeyBindingsFiles() throws {
    let file = try bindingsFile(["^j": "insertNewline:"])
    defer { try? FileManager.default.removeItem(at: file) }
    let files = KeyBindingFiles(urls: [file])
    let model = try makeModel()
    let registry = CommandRegistry(model: model, shell: nil, overrides: ShortcutOverrides(), keyBindings: files)
    model.registry = registry
    #expect(files.reads == 0)
    SettingsState(model: model, section: .shortcuts, updater: nil).startRecording("archive", slot: 0)
    #expect(files.reads == 1)
}

@MainActor
@Test func onlyCommandsThatNeverActOnMailAreTextSafe() throws {
    let registry = try makeRegistry()
    let safe = Set(registry.commands.filter(\.isTextSafe).map(\.id))
    let expected: Set<String> = [
        "palette", "compose", "settings", "find", "findNext", "findPrevious", "print", "newProject", "addAccount",
        "scope.all", "scope.1", "scope.2", "scope.3", "scope.4", "scope.5", "scope.6", "scope.7", "scope.8", "scope.9",
        "toggleSidebar", "readingPane", "readerOverlay", "appearance.toggle", "appearance.system", "appearance.light", "appearance.dark",
        "density.compact", "density.comfortable", "dimRead", "senderLogos", "shortcuts",
        "about", "checkForUpdates", "mainWindow",
    ]
    #expect(safe == expected)
    // Inbox Tabs rebuilds the tabs and the list: a settings command, but not one for while typing.
    #expect(registry["splitInbox"]?.isTextSafe == false && registry["splitInbox"]?.availableInSettings == true)
}

@MainActor
@Test func mailKeysDontFireFromTheMenuBarWhileTyping() throws {
    _ = NSApplication.shared
    let registry = try makeRegistry(threads: 2)
    let model = registry.model
    model.reloadList()
    try #require(model.cursor != nil)
    let control = KeyShortcut(key: .char("g"), modifiers: .control)
    registry.assign(control, to: "trash", replacing: nil)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    window.contentView = text
    func event(_ characters: String, _ ignoring: String, _ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                         characters: characters, charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: keyCode)!
    }
    let trash = event("\u{7}", "g", 5, .control)
    #expect(!registry.leavesToText(trash, in: window))
    window.makeFirstResponder(text)
    try #require(KeyRouter.textInput(in: window) === text)
    #expect(registry.leavesToText(trash, in: window))
    #expect(registry.leavesToText(event("U", "u", 32, [.command, .shift]), in: window))
    // Text-safe commands keep their keys: ⌘K, ⌘N, ⌘F. So does the Edit menu's Select All, though ⌘A is also
    // Select All Conversations outside text fields.
    #expect(!registry.leavesToText(event("a", "a", 0, .command), in: window))
    #expect(!registry.leavesToText(event("k", "k", 40, .command), in: window))
    #expect(!registry.leavesToText(event("n", "n", 45, .command), in: window))
    #expect(!registry.leavesToText(event("f", "f", 3, .command), in: window))
    // So do ⌘, ⌘G, ⌘P, ⇧⌘P, ⌘0–⌘9 and the view keys (⌘\, ⇧⌘L, ⌃⌘S).
    for (characters, keyCode, modifiers) in [(",", UInt16(43), NSEvent.ModifierFlags.command), ("g", 5, .command), ("p", 35, .command),
                                             ("p", 35, [.command, .shift]), ("0", 29, .command), ("1", 18, .command), ("9", 25, .command),
                                             ("\\", 42, .command), ("l", 37, [.command, .shift]), ("s", 1, [.control, .command])] {
        #expect(!registry.leavesToText(event(characters, characters, keyCode, modifiers), in: window), "\(characters) \(modifiers)")
    }
    // A modified key given to Inbox Tabs keeps its meaning in the text: the tabs and the list stay.
    registry.assign(KeyShortcut(key: .char("j"), modifiers: [.command, .option]), to: "splitInbox", replacing: nil)
    #expect(registry.leavesToText(event("∆", "j", 38, [.command, .option]), in: window))

    let mainMenu = MainMenu(registry: registry)
    let menu = mainMenu.build()
    let undo = model.undoStack.count
    #expect(menu.performKeyEquivalent(with: trash) == false)
    #expect(model.undoStack.count == undo)
    // Out of the text the same key trashes, as assigned.
    window.makeFirstResponder(nil)
    #expect(!registry.leavesToText(trash, in: window))
    #expect(menu.performKeyEquivalent(with: trash) == true)
    #expect(model.undoStack.count == undo + 1)
    withExtendedLifetime(mainMenu) {}
}

@MainActor
@Test func theReaderPageGetsTheKeysOfTheCommandsItRuns() throws {
    let registry = try makeRegistry()
    #expect(KeyRouter.pageKeyMap(registry) == ["n": "next", "p": "previous", "Enter": "open", "o": "open", " ": "quicklook"])
    registry.assign(.key("n"), to: "archive", replacing: nil)
    registry.removeKey(at: 0, from: "previousMessage")
    registry.assign(.special(.returnKey, [.shift]), to: "nextMessage", replacing: nil)
    // ⌥ keys don't reach the page's handler; the registry runs them.
    registry.assign(.option("n"), to: "nextMessage", replacing: nil)
    #expect(KeyRouter.pageKeyMap(registry) == ["Shift+Enter": "next", "Enter": "open", "o": "open", " ": "quicklook"])
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
@Test func theReaderClosesWhenTriageLeavesNothingToShow() throws {
    let prefs = Preferences.shared
    let saved = (prefs.afterTriage, prefs.readingPane)
    defer { (prefs.afterTriage, prefs.readingPane) = saved }
    prefs.readingPane = false
    for mode in AfterTriage.allCases {
        prefs.afterTriage = mode
        let model = try makeModel(threads: 1)
        model.reloadList()
        let only = try #require(model.cursor)
        model.open()
        #expect(model.readerExpanded && model.focus == .reader)
        model.perform(.archive, on: [only])
        #expect(model.cursor == nil && !model.readerExpanded && model.focus == .list, "\(mode)")
    }

    // At the ends of the list Next and Previous take the other neighbour, and the thread stays open.
    for (mode, end) in [(AfterTriage.next, 2), (.previous, 0)] {
        prefs.afterTriage = mode
        let model = try makeModel(threads: 3)
        model.reloadList()
        let order = model.snapshot.order
        try #require(order.count == 3)
        model.setCursor(order[end], open: false)
        model.open()
        model.perform(.archive, on: [order[end]])
        #expect(model.cursor == order[1] && model.readerExpanded && model.focus == .reader, "\(mode)")
    }
}

extension InboxPreferencesTests {
    @MainActor
    @Test func splitInboxKeepsTheOpenThreadAndTheSelection() throws {
        let prefs = Preferences.shared
        let saved = prefs.splitInbox
        defer { prefs.splitInbox = saved }
        prefs.splitInbox = true
        let model = try makeModel(threads: 6)
        model.reloadList()
        // Unclassified mail with no Gmail category is in Primary, so that tab lists every thread.
        model.showInboxTab(.primary)
        let order = model.snapshot.order
        try #require(order.count == 6 && model.cursor == order[0])
        model.setCursor(order[3], open: false)
        model.click(order[4], command: true, shift: false)
        let checked: Set<ThreadKey> = [order[3], order[4]]
        #expect(model.checked == checked)

        // Off: the tab becomes All, which still has both threads, with the cursor where it was.
        model.setSplitInbox(false)
        #expect(model.activeTab == .all && model.source.tab == nil)
        #expect(model.cursor == order[4] && model.checked == checked && model.snapshot.order == order)

        // On again, the list is All either way: nothing is read again.
        model.checked = []
        model.setCursor(order[2], open: false)
        let source = model.source
        model.setSplitInbox(true)
        #expect(model.source == source && model.activeTab == .all && model.cursor == order[2])

        // Choosing another list still starts at its first row.
        model.show(.allMail)
        #expect(model.cursor == model.snapshot.order.first && model.cursor != order[2])
    }

}

@MainActor
@Test func aSenderThatCantBeTakenOffTheListComesBack() async throws {
    let model = try makeModel()
    try model.store.setImagesAllowed(true, sender: "news@figma.com")
    try await model.store.database.writer.write { db in
        try db.execute(sql: """
            CREATE TRIGGER keep_image_senders BEFORE DELETE ON setting WHEN old.key LIKE 'images.allow.%'
            BEGIN SELECT RAISE(ABORT, 'read-only'); END
            """)
    }
    let settings = SettingsState(model: model, section: .mail, updater: nil)
    settings.forgetImages(from: "news@figma.com")
    #expect(settings.imageSenders.isEmpty)
    for _ in 0..<200 where settings.imageSendersError == nil { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(settings.imageSenders == ["news@figma.com"])
    #expect(settings.imageSendersError?.contains("news@figma.com") == true)
    #expect(try model.store.imageAllowedSenders() == ["news@figma.com"])

    // Removing it once the write works clears the message.
    try await model.store.database.writer.write { db in try db.execute(sql: "DROP TRIGGER keep_image_senders") }
    settings.forgetImages(from: "news@figma.com")
    model.writes.sync {}
    #expect(settings.imageSenders.isEmpty && settings.imageSendersError == nil)
    #expect(try model.store.imageAllowedSenders().isEmpty)
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

@MainActor
@Test func imagesLoadAutomaticallyUnlessTheUserAsks() throws {
    let defaults = scratchDefaults()
    #expect(Preferences(defaults: defaults).imagesInMail == .automatic, "mail looks the way its sender made it")
    Preferences(defaults: defaults).imagesInMail = .ask
    #expect(Preferences(defaults: defaults).imagesInMail == .ask)

    // The always-load list shows, and is found, only while images wait for a click.
    let model = try makeModel()
    let saved = model.prefs.imagesInMail
    defer { model.prefs.imagesInMail = saved }
    model.prefs.imagesInMail = .automatic
    #expect(SettingsItem.items(in: .mail, model: model).contains(.imagesInMail))
    #expect(!SettingsItem.items(in: .mail, model: model).contains(.remoteImages))
    #expect(SettingsCatalog.results(for: "images", model: model) == [.imagesInMail])
    #expect(SettingsCatalog.results(for: "tracking pixels", model: model) == [.imagesInMail])
    model.prefs.imagesInMail = .ask
    let mail = SettingsItem.items(in: .mail, model: model)
    #expect(mail.firstIndex(of: .imagesInMail).map { $0 + 1 } == mail.firstIndex(of: .remoteImages), "the list sits under the choice")
    #expect(SettingsCatalog.results(for: "images", model: model) == [.imagesInMail, .remoteImages])
}

@MainActor
@Test func theSlideOverOpensBesideTheListAndExpandsUntilItCloses() throws {
    let registry = try makeRegistry(threads: 2)
    let model = registry.model
    let pane = model.prefs.readingPane, overlay = model.prefs.readerOverlay
    defer { model.prefs.readingPane = pane; model.prefs.readerOverlay = overlay }
    model.prefs.readingPane = false
    model.prefs.readerOverlay = .panel
    model.reloadList()
    try #require(model.cursor != nil)
    #expect(registry["readerWide"]?.isEnabled() == false)
    model.open()
    #expect(model.readerExpanded && model.readerInPanel)
    #expect(registry["readerWide"]?.isEnabled() == true)
    registry["readerWide"]?.run()
    #expect(model.readerWide && !model.readerInPanel && model.readerVisible)
    model.back()
    #expect(!model.readerExpanded && !model.readerWide)
    // Full width and the reading pane never show the panel.
    model.prefs.readerOverlay = .full
    model.open()
    #expect(model.readerExpanded && !model.readerInPanel)
    model.back()
    model.prefs.readingPane = true
    model.prefs.readerOverlay = .panel
    #expect(!model.readerInPanel)
}
