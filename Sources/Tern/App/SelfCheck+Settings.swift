import AppKit
import TernCore

/// The settings page in the main window and edited shortcuts: opening and closing it leaves the mail as it
/// was, mail keys do nothing while it is open, and a changed shortcut fires from the keyboard and the menu
/// bar while the old key no longer does.
extension SelfCheck {
    func settings() {
        settingsRoundTrip()
        settingsKeys()
        editedShortcuts()
    }

    private func settingsRoundTrip() {
        // The thread opens over the list, whatever an earlier run left the layout as.
        let pane = model.prefs.readingPane
        defer { model.prefs.readingPane = pane }
        model.prefs.readingPane = false
        model.show(.inbox)
        model.showSplit(.people)
        wait(0.2)
        let order = model.snapshot.order
        guard order.count > 4 else { return check("settings: rows", false) }
        // Reading a thread over the list.
        model.click(order[2], command: false, shift: false)
        wait(0.3)
        let tab = model.activeTab, cursor = model.cursor, expanded = model.readerExpanded
        model.openSettings(.mail)
        _ = waitUntil(1) { window.firstResponder is NSView && !KeyRouter.readerHasKeyboard(window) }
        check("settings opens as a page in the main window", model.settingsOpen && model.settings?.section == .mail)
        check("settings takes the keyboard from the reader", !KeyRouter.readerHasKeyboard(window))
        send("", keyCode: 53)
        check("esc closes settings", !model.settingsOpen)
        check("closing settings puts back the tab, the thread and the reader",
              model.activeTab == tab && model.cursor == cursor && model.readerExpanded == expanded && expanded)
        check("closing settings gives the keyboard back to the reader", model.focus == .reader)

        model.back()
        model.focusList()
        let listCursor = model.cursor
        model.openSettings()
        check("settings opens at the section shown last", model.settings?.section == .mail)
        wait(0.1)
        send("[", modifiers: .command, keyCode: 33)
        let table = (model.listView as? MessageListController)?.table
        check("⌘[ closes settings and the list has the keyboard", !model.settingsOpen && model.cursor == listCursor && window.firstResponder === table)
    }

    private func settingsKeys() {
        model.showSplit(.people)
        wait(0.2)
        model.moveToTop()
        model.focusList()
        let cursor = model.cursor, kind = model.kind, rows = model.snapshot.order.count, toasts = model.toasts.count
        let composers = NSApp.windows.filter { $0 is ComposerWindow }.count
        model.openSettings(.accounts)
        wait(0.1)
        for key in ["e", "#", "j", "k", "r", "x", "s", "/"] { send(key) }
        send("g"); send("i")
        send("g"); send("s")
        wait(0.2)
        check("mail keys do nothing while settings is open",
              model.cursor == cursor && model.kind == kind && model.snapshot.order.count == rows && model.toasts.count == toasts
                && model.checked.isEmpty && !model.searchShown && model.chordHUD == nil)
        check("r opens no composer while settings is open", NSApp.windows.filter { $0 is ComposerWindow }.count == composers)
        check("mail commands are off in the menus while settings is open",
              registry["archive"].map(registry.canRun) == false && registry["appearance.toggle"].map(registry.canRun) == true)

        send("", keyCode: 125)
        check("↓ moves to the next section", model.settings?.section == .mail)
        send("", keyCode: 126)
        check("↑ moves back", model.settings?.section == .accounts)
        send("\t", modifiers: .control, keyCode: 48)
        check("⌃Tab moves to the next section", model.settings?.section == .mail)

        model.settings?.searchFocused = true
        _ = waitUntil(1) { KeyRouter.textInput(in: window) != nil }
        if KeyRouter.textInput(in: window) != nil {
            for key in ["u", "n", "d", "o"] { send(key) }
            wait(0.1)
            check("typing in the settings search works", model.settings?.query == "undo")
            check("search finds Undo send", SettingsCatalog.results(for: model.settings?.query ?? "", model: model).contains(.undoSend))
            send("", keyCode: 53)
            check("esc clears the search first", model.settings?.query == "" && model.settingsOpen)
        } else {
            print("  (settings search did not take focus offscreen; typing check skipped)")
        }
        model.closeSettings()
        check("the list is as it was after settings", model.cursor == cursor && model.kind == kind)
    }

    private func editedShortcuts() {
        let saved = registry.overrides
        model.showSplit(.people)
        wait(0.2)
        model.moveToTop()
        model.focusList()
        guard let first = model.cursor else { return check("shortcuts: a row", false) }

        registry.assign(.key("y"), to: "archive", replacing: 0)
        check("an edited shortcut is saved as a change", registry.isCustomized("archive") && registry["archive"]?.keys == [.key("y")])
        send("e")
        check("the old key no longer archives", model.snapshot.rows[first] != nil)
        send("y")
        check("the new key archives", model.snapshot.rows[first] == nil && model.toasts.last?.title == "Archived")
        model.undoLast()
        poll(0.6) {}
        let menu = NSApp.mainMenu?.items.first { $0.title == MenuName.message.rawValue }?.submenu?.items.first { $0.title == "Archive" }
        check("the menu bar shows the new key", menu?.keyEquivalent == "y")
        let bare = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                    context: nil, characters: "y", charactersIgnoringModifiers: "y", isARepeat: false, keyCode: 16)!
        check("a bare key never fires as a menu key equivalent", NSApp.mainMenu?.performKeyEquivalent(with: bare) == false)

        // A ⌘ key on a g command fires from the menu bar.
        registry.assign(.command("j", shift: true), to: "go.inbox", replacing: nil)
        model.show(.starred)
        wait(0.1)
        let shortcut = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, characters: "J", charactersIgnoringModifiers: "j",
                                        isARepeat: false, keyCode: 38)!
        _ = NSApp.mainMenu?.performKeyEquivalent(with: shortcut)
        check("an added ⌘ shortcut fires its command from the menu bar", model.kind == .inbox)

        // A key another command has: Replace takes it.
        check("s on Archive conflicts with Star", registry.conflicts(.key("s"), for: "archive").map(\.id) == ["star"])
        check("⌘Q can't be taken", SettingsState.problem(.command("q"), for: "archive", registry: registry) == .reserved(.command("q"), owner: "Quit Tern"))
        registry.assign(.key("s"), to: "archive", replacing: 0)
        check("Replace takes the key from the other command", registry["archive"]?.keys == [.key("s")] && registry["star"]?.keys == [])
        registry.resetKeys(for: "star")
        check("resetting takes the built-in key back", registry["star"]?.keys == [.key("s")] && registry["archive"]?.keys == [])
        registry.resetAllKeys()
        check("reset all brings every built-in key back", registry.overrides.isEmpty && registry["archive"]?.keys == [.key("e")])
        send("e")
        check("e archives again", model.snapshot.rows[first] == nil)
        model.undoLast()
        poll(0.6) {}
        registry.restore(saved)
    }
}
