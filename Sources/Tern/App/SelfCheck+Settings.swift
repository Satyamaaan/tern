import AppKit
import GRDB
import TernCore

/// The settings page in the main window and edited shortcuts: opening and closing it leaves the mail as it
/// was (whatever Layout changed, Inbox Tabs included, and with the keyboard back in the field it was in, also
/// when ⌘K opened it), mail keys and the palette's mail entries do nothing while it is open, a changed shortcut
/// fires from the keyboard and the menu bar while the old key no longer does, the reader page follows edited
/// keys, and a mail command's ⌃ key never fires while typing.
extension SelfCheck {
    func settings() {
        settingsRoundTrip()
        aiModelSaves()
        settingsLayoutRestore()
        settingsSplitInbox()
        settingsRestoresTyping()
        settingsKeys()
        settingsPalette()
        editedShortcuts()
        readerPageKeys()
        typingKeepsTextKeys()
    }

    private func settingsRoundTrip() {
        // The thread opens over the list, whatever an earlier run left the layout as.
        let pane = model.prefs.readingPane
        defer { model.prefs.readingPane = pane }
        model.prefs.readingPane = false
        model.show(.inbox)
        model.showInboxTab(.primary)
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

    /// The AI model name is saved when the field commits it, in one transaction, and not at all when it is unchanged.
    /// (Typing into the field needs a provider on, which would start the real CLI, so this drives the state.)
    private func aiModelSaves() {
        model.openSettings(.ai)
        wait(0.2)
        guard let settings = model.settings else { return check("settings: the AI section", false) }
        final class Count { var value = 0 }
        let transactions = Count()
        let observer = DatabaseRegionObservation(tracking: Table("setting")).start(
            in: model.store.database.writer, onError: { _ in },
            onChange: { _ in DispatchQueue.main.async { transactions.value += 1 } })
        defer { observer.cancel() }
        let saved = settings.aiModel
        func settle() { model.writes.sync {}; wait(0.1) }

        settings.commitAIModel(saved)
        settings.commitAIModel(" \(saved) ")
        settle()
        check("committing the AI model unchanged writes nothing", transactions.value == 0)
        settings.commitAIModel("check-model")
        settle()
        let stored = (try? model.store.setting(SettingKey.aiModel)) ?? nil
        print("  ai model: committing a new name wrote \(transactions.value) transaction(s)")
        check("a new AI model is saved in one transaction", transactions.value == 1 && stored == "check-model")

        settings.editAIModel("check-closed")
        model.closeSettings()
        settle()
        check("closing settings saves a model name not yet committed", ((try? model.store.setting(SettingKey.aiModel)) ?? nil) == "check-closed")
        model.openSettings(.ai)
        wait(0.2)
        model.settings?.editAIModel("check-quit")
        model.prepareToQuit()
        check("quitting saves a model name not yet committed before it goes",
              ((try? model.store.setting(SettingKey.aiModel)) ?? nil) == "check-quit")
        model.settings?.commitAIModel(saved)
        settle()
        model.closeSettings()
    }

    /// Layout's reading pane toggle runs `toggleReadingPane`, as ⌘\ does.
    private func settingsLayoutRestore() {
        let pane = model.prefs.readingPane
        defer { model.prefs.readingPane = pane }
        model.prefs.readingPane = false
        model.show(.inbox)
        model.showInboxTab(.primary)
        wait(0.2)
        let order = model.snapshot.order
        guard order.count > 4 else { return check("settings layout: rows", false) }
        model.click(order[2], command: false, shift: false)
        wait(0.3)
        let table = (model.listView as? MessageListController)?.table

        model.openSettings(.layout)
        wait(0.1)
        model.toggleReadingPane()
        model.toggleReadingPane()
        model.closeSettings()
        _ = waitUntil(1) { KeyRouter.readerHasKeyboard(window) }
        check("reading pane on and off in Layout keeps the thread open over the list",
              model.readerExpanded && model.readerVisible && model.cursor == order[2] && model.focus == .reader)
        check("…and the keyboard goes back to that thread", KeyRouter.readerHasKeyboard(window))

        model.openSettings(.layout)
        wait(0.1)
        model.toggleReadingPane()
        model.closeSettings()
        _ = waitUntil(1) { KeyRouter.readerHasKeyboard(window) }
        check("reading pane on in Layout shows the thread beside the list, with the keyboard",
              model.prefs.readingPane && !model.readerExpanded && model.focus == .reader && KeyRouter.readerHasKeyboard(window))

        model.openSettings(.layout)
        wait(0.1)
        model.toggleReadingPane()
        model.closeSettings()
        _ = waitUntil(1) { window.firstResponder === table }
        check("reading pane off in Layout gives the list the keyboard, the thread no longer showing",
              !model.readerVisible && model.focus == .list && window.firstResponder === table)
    }

    /// Inbox Tabs switched in Layout leaves the open conversation as it was: on All (the same list either way) and
    /// on a Gmail tab (which becomes All, still holding the thread), with its find bar still open.
    private func settingsSplitInbox() {
        let pane = model.prefs.readingPane, split = model.prefs.splitInbox
        defer {
            model.prefs.readingPane = pane
            if model.prefs.splitInbox != split { model.setSplitInbox(split) }
        }
        model.prefs.readingPane = false
        if !model.prefs.splitInbox { model.setSplitInbox(true) }
        guard let reader = model.services.reader.model else { return check("inbox tabs: a reader", false) }

        func roundTrip(_ tab: InboxTab?, _ name: String) {
            model.showInboxTab(tab)
            wait(0.2)
            let order = model.snapshot.order
            guard order.count > 4 else { return check("inbox tabs \(name): rows", false) }
            let thread = order[3]
            model.click(thread, command: false, shift: false)
            wait(0.3)
            model.services.reader.find()
            _ = waitUntil(1) { reader.findVisible }
            model.openSettings(.layout)
            wait(0.1)
            model.setSplitInbox(false)
            wait(0.2)
            check("Inbox Tabs off in Layout keeps the conversation open in All (\(name))",
                  model.activeTab == .all && model.cursor == thread && reader.key == thread && reader.findVisible && model.readerExpanded)
            model.setSplitInbox(true)
            wait(0.2)
            check("…and on again keeps it (\(name))", model.activeTab == .all && model.cursor == thread && reader.key == thread && reader.findVisible)
            model.closeSettings()
            check("…and closing settings shows it as it was (\(name))", model.cursor == thread && model.readerExpanded && model.focus == .reader)
            reader.closeFind()
            model.back()
            wait(0.2)
        }
        roundTrip(nil, "All")
        roundTrip(.primary, "a Gmail tab")
    }

    /// The find bar and an inline reply get the keyboard back, not the page around them, also when Settings is
    /// opened from ⌘K, whose own field has the keyboard by then.
    private func settingsRestoresTyping() {
        let pane = model.prefs.readingPane
        defer { model.prefs.readingPane = pane }
        model.prefs.readingPane = false
        model.showInboxTab(.primary)
        wait(0.2)
        let order = model.snapshot.order
        guard order.count > 4, let reader = model.services.reader.model else { return check("settings typing: a thread", false) }
        model.click(order[3], command: false, shift: false)
        wait(0.3)

        func roundTrip(_ name: String) {
            guard waitUntil(1, { KeyRouter.textInput(in: window) != nil }), let field = AppModel.textView(in: window) else {
                return print("  (\(name) did not take focus offscreen; check skipped)")
            }
            model.openSettings(.mail)
            _ = waitUntil(1) { KeyRouter.textInput(in: window) == nil }
            model.closeSettings()
            _ = waitUntil(1) { AppModel.textView(in: window) === field }
            check("closing settings gives \(name) the keyboard back", AppModel.textView(in: window) === field && model.focus == .reader)

            // ⌘K, then its Settings command: the palette's field has the keyboard when Settings opens. Offscreen
            // SwiftUI doesn't always move focus from one of its fields to another, so put it there as a click would.
            model.palette = .commands
            func paletteHasKeyboard() -> Bool { KeyRouter.textInput(in: window) != nil && AppModel.textView(in: window) !== field }
            if !waitUntil(1, paletteHasKeyboard), let input = textField(placeholder: palette.placeholder) { window.makeFirstResponder(input) }
            guard waitUntil(1, paletteHasKeyboard) else {
                model.palette = nil
                return print("  (the palette did not take focus offscreen; the ⌘K check for \(name) skipped)")
            }
            palette.run(PaletteItem(id: "settings", title: "Settings…") { [model] in model.openSettings(.mail) })
            _ = waitUntil(1) { self.model.paletteReturn == nil && KeyRouter.textInput(in: window) == nil }
            model.closeSettings()
            _ = waitUntil(1) { AppModel.textView(in: window) === field }
            check("Settings from ⌘K gives \(name) the keyboard back on closing", AppModel.textView(in: window) === field && model.focus == .reader)
        }

        model.services.reader.find()
        roundTrip("the find bar")
        reader.closeFind()
        wait(0.2)

        model.focusList()
        send("r")
        wait(0.4)
        roundTrip("an inline reply")
        reader.composing = nil
        wait(0.4)
    }

    private func settingsKeys() {
        model.showInboxTab(.primary)
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
                && model.checked.isEmpty && !model.searchShown && model.chordPending == nil && model.chordHUD == nil)
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

    /// ⌘K over the settings page lists only what can run there: no thread, project, label or account to jump to.
    private func settingsPalette() {
        guard let project = model.projects.first else { return check("settings palette: a project", false) }
        func mailEntries() -> [PaletteItem] {
            palette.flatItems.filter { item in ["project.", "label.", "account.", "thread."].contains(where: item.id.hasPrefix) }
        }
        model.openSettings(.appearance)
        wait(0.1)
        model.palette = .commands
        palette.query = project.name
        check("the palette over settings lists no projects, labels or accounts", mailEntries().isEmpty)
        palette.query = "invoice"
        wait(Double(AppModel.searchDebounce) / 1_000_000_000 + 0.4)
        check("the palette over settings finds no threads", palette.threadRows.isEmpty && mailEntries().isEmpty)
        palette.close()
        model.closeSettings()

        model.palette = .commands
        palette.query = project.name
        check("outside settings the palette lists projects", palette.flatItems.contains { $0.id == "project.\(project.id)" })
        palette.close()
        wait(0.1)
    }

    private func editedShortcuts() {
        let saved = registry.overrides
        model.showInboxTab(.primary)
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

    /// The keys the reader page answers itself follow the registry: `n` given to Archive archives from the page,
    /// and the page stops moving between messages on it.
    private func readerPageKeys() {
        let saved = registry.overrides
        let pane = model.prefs.readingPane
        defer { model.prefs.readingPane = pane }
        model.prefs.readingPane = false
        model.showInboxTab(.primary)
        wait(0.2)
        let order = model.snapshot.order
        guard order.count > 4 else { return check("reader keys: rows", false) }
        model.setCursor(order[1], open: false)
        model.focusList()
        send("", keyCode: 36)
        _ = waitUntil(1) { KeyRouter.readerHasKeyboard(window) && self.model.services.reader.model?.key == order[1] }
        wait(0.3)
        guard KeyRouter.readerHasKeyboard(window) else { return print("  (the reader page did not take the keyboard offscreen; checks skipped)") }

        let n = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                 context: nil, characters: "n", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45)!
        check("the page knows n as Next Message", ReaderWebEngine.shared.keyActions["n"] == "next")
        check("n goes to the page while it has the keyboard", router.handle(n) != nil)
        check("the page moves to the next message on n", pagePrevents("n") == true)

        registry.assign(.key("n"), to: "archive", replacing: nil)
        check("n given to Archive leaves the page's keys", ReaderWebEngine.shared.keyActions["n"] == nil)
        check("the page no longer answers n", pagePrevents("n") == false)
        let undo = model.undoStack.count
        check("n archives from the open thread", router.handle(n) == nil && model.snapshot.rows[order[1]] == nil && model.undoStack.count == undo + 1)
        model.undoLast()
        poll(0.6) {}
        registry.removeKey(at: 0, from: "previousMessage")
        check("a removed p leaves the page's keys", ReaderWebEngine.shared.keyActions["p"] == nil && pagePrevents("p") == false)
        registry.restore(saved)
        check("the built-in keys come back to the page", ReaderWebEngine.shared.keyActions["n"] == "next" && ReaderWebEngine.shared.keyActions["p"] == "previous")
        model.back()
    }

    /// The text field in the window showing `placeholder`.
    private func textField(placeholder: String) -> NSTextField? {
        func search(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.placeholderString == placeholder { return field }
            return view.subviews.lazy.compactMap(search).first
        }
        return window.contentView.flatMap(search)
    }

    /// Whether the reader page handles a keydown of `key` (it prevents the default when it does).
    private func pagePrevents(_ key: String) -> Bool? {
        var answer: Bool?
        var done = false
        ReaderWebEngine.shared.run("""
            const event = new KeyboardEvent('keydown', { key: k, bubbles: true, cancelable: true });
            document.body.dispatchEvent(event);
            return event.defaultPrevented;
            """, ["k": key]) { result in
            answer = try? result.get() as? Bool
            done = true
        }
        _ = waitUntil(2) { done }
        return answer
    }

    /// A ⌃ key given to a mail command keeps its text meaning while typing; text-safe ⌘ keys still fire.
    private func typingKeepsTextKeys() {
        let saved = registry.overrides
        defer { registry.restore(saved) }
        model.showInboxTab(.primary)
        wait(0.2)
        let control = KeyShortcut(key: .char("g"), modifiers: .control)
        registry.assign(control, to: "trash", replacing: nil)
        check("⌃H is reserved for text editing", SettingsState.problem(KeyShortcut(key: .char("h"), modifiers: .control), for: "trash", registry: registry)
              == .reserved(KeyShortcut(key: .char("h"), modifiers: .control), owner: "text editing"))
        model.beginSearch()
        guard waitUntil(1, { KeyRouter.textInput(in: window) != nil }) else {
            model.endSearch(restoreFocus: true)
            return print("  (search field did not take focus offscreen; typing checks skipped)")
        }
        func event(_ characters: String, _ ignoring: String, _ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                             context: nil, characters: characters, charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: keyCode)!
        }
        let undo = model.undoStack.count, rows = model.snapshot.order.count
        let trash = event("\u{7}", "g", 5, .control)
        check("a mail command's ⌃ key passes the router while typing", router.handle(trash) != nil)
        check("…and doesn't fire from the menu bar", NSApp.mainMenu?.performKeyEquivalent(with: trash) == false
              && model.undoStack.count == undo && model.snapshot.order.count == rows)
        check("⌘A while typing is the Edit menu's Select All", NSApp.mainMenu?.performKeyEquivalent(with: event("a", "a", 0, .command)) == true
              && model.checked.isEmpty)
        check("⌘K still opens the palette while typing", NSApp.mainMenu?.performKeyEquivalent(with: event("k", "k", 40, .command)) == true
              && model.palette == .commands)
        model.palette = nil
        wait(0.1)
        // Inbox Tabs with a ⌥⌘ key: typing keeps the key, and the tabs and the list stay.
        registry.assign(KeyShortcut(key: .char("j"), modifiers: [.command, .option]), to: "splitInbox", replacing: nil)
        model.beginSearch()
        if waitUntil(1, { KeyRouter.textInput(in: window) != nil }) {
            let split = model.prefs.splitInbox, tabs = model.tabs
            check("an Inbox Tabs key doesn't fire from the menu bar while typing",
                  NSApp.mainMenu?.performKeyEquivalent(with: event("∆", "j", 38, [.command, .option])) == false
                    && model.prefs.splitInbox == split && model.tabs == tabs)
        }
        model.endSearch(restoreFocus: true)
    }
}
