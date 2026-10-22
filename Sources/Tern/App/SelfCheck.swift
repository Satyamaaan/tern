import AppKit
import GRDB
import SwiftUI
import TernCore

/// `--check`: drives the shell offscreen through triage, undo, search, the inbox tabs, selection, key routing,
/// the settings page and typing through the real event path, and prints PASS/FAIL per step plus timings. It
/// writes to the database, so point `TERN_DB` at a throwaway copy of a seeded mailbox.
@MainActor
final class SelfCheck {
    let model: AppModel
    let registry: CommandRegistry
    private var failures = 0
    let window: MainWindow
    let router: KeyRouter
    let palette: PaletteController

    init(model: AppModel, registry: CommandRegistry) {
        self.model = model
        self.registry = registry
        palette = PaletteController(model: model, registry: registry)
        router = KeyRouter(registry: registry)
        router.paletteKeys = { [palette] key in palette.handle(key) }
        let hosting = NSHostingView(rootView: MainView(palette: palette).environment(model).environment(model.services))
        hosting.sizingOptions = []
        window = MainWindow(contentView: hosting)
        window.setContentSize(MainWindow.defaultSize)
        router.mainWindow = window
    }

    func run() -> Never {
        wait(0.3)
        check("list loaded", model.listLoaded && !model.snapshot.isEmpty)
        check("first row selected", model.cursor == model.snapshot.order.first)
        check("launch opens the inbox on Primary", !model.prefs.splitInbox || model.activeTab == .category(.primary))
        timeQueries()
        previews()
        triage()
        multiSelect()
        archiveMailbox()
        discardDrafts()
        clicks()
        paging()
        dropOnProject()
        needsReply()
        ledger()
        reviewFixes()
        search()
        tabs()
        scope()
        keys()
        paletteSearch()
        integration()
        settings()
        typing()
        if ProcessInfo.processInfo.environment["TERN_CHECK_MENUS"] == "1" { printMenus() }
        print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        // exit() doesn't wait for the last preference writes (a check putting a setting back) to be saved.
        UserDefaults.standard.synchronize()
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Scenarios

    private func previews() {
        check("a preview that repeats the subject drops it",
              ThreadRowView.preview("Priya mentioned you in Mobile app We're leaning", subject: "Priya mentioned you in Mobile app") == "We're leaning")
        check("a preview that doesn't repeat the subject is kept",
              ThreadRowView.preview("Hi Alex, the numbers", subject: "Q3 numbers") == "Hi Alex, the numbers")
    }


    private func triage() {
        model.show(.inbox)
        model.showInboxTab(.primary)
        wait(0.2)
        guard let first = model.cursor, let second = model.snapshot.key(from: first, offset: 1) else {
            return check("triage has rows", false)
        }
        var reappeared = false
        model.perform(.archive, on: [first])
        check("archive hides the row in the same frame", model.snapshot.rows[first] == nil)
        check("archive selects the next row in the same frame", model.cursor == second)
        check("archive shows a toast", model.toasts.last?.title == "Archived")
        poll(0.6) { if self.model.snapshot.rows[first] != nil { reappeared = true } }
        check("archived row never flickers back", !reappeared)
        check("archive reached the database", !(try! self.isInInbox(first)))

        model.undoLast()
        poll(0.6) {}
        check("undo puts the row back", model.snapshot.rows[first] != nil)
        check("undo selects the restored row", model.cursor == first)
        check("undo restored the database", try! isInInbox(first))
    }

    private func multiSelect() {
        model.showInboxTab(.primary)
        wait(0.2)
        model.moveToTop()
        model.moveCursor(1, extend: true)
        model.moveCursor(1, extend: true)
        check("⇧J twice selects three", model.checked.count == 3 && model.targets.count == 3)
        let targets = model.targets
        let next = model.snapshot.key(from: targets.last, offset: 1)
        model.perform(.archive, on: targets)
        check("archiving a selection removes all of it", targets.allSatisfy { model.snapshot.rows[$0] == nil })
        check("cursor moves past the selection", model.cursor == next)
        check("selection clears", model.checked.isEmpty)
        wait(0.5)
        model.undoLast()
        poll(0.6) {}
        check("undo restores the selection's threads", targets.allSatisfy { model.snapshot.rows[$0] != nil })
    }

    private func clicks() {
        model.showInboxTab(.primary)
        wait(0.2)
        let order = model.snapshot.order
        guard order.count > 5 else { return check("click rows", false) }
        model.click(order[1], command: false, shift: false)
        check("click opens the row", model.cursor == order[1] && model.checked.isEmpty)
        model.click(order[3], command: true, shift: false)
        check("⌘-click adds to the selection", model.checked == [order[1], order[3]])
        model.click(order[5], command: false, shift: true)
        check("⇧-click selects the range from the anchor", model.checked == Set(order[3...5]))
        model.clearSelection()
    }

    private func paging() {
        model.show(.allMail)
        wait(0.2)
        let first = model.snapshot.order.count
        model.loadMore()
        poll(0.8) {}
        check("scrolling near the end loads the next page", first == AppModel.pageSize && model.snapshot.order.count == 2 * AppModel.pageSize)
        model.show(.inbox)
        wait(0.2)
    }

    private func dropOnProject() {
        guard let project = model.projects.first else { return check("projects", false) }
        model.showInboxTab(.primary)
        wait(0.2)
        guard let key = model.snapshot.order.first(where: { !(model.row($0)?.projectIds.contains(project.id) ?? true) }) else {
            return check("drop candidate", false)
        }
        model.draggedKeys = [key]
        model.dropDragged(onProject: project.id)
        poll(0.6) {}
        check("dropping a row on a project files it", model.row(key)?.projectIds.contains(project.id) == true)
        model.undoLast()
        poll(0.6) {}
        check("undo takes it out again", model.row(key)?.projectIds.contains(project.id) == false)
    }

    /// Regressions found in review.
    private func reviewFixes() {
        // The next thread after triage is marked read when reading in the reader.
        model.showInboxTab(.primary)
        wait(0.2)
        if let index = model.snapshot.order.indices.dropLast().first(where: { (model.row(model.snapshot.order[$0 + 1])?.thread.unreadCount ?? 0) > 0 }) {
            let key = model.snapshot.order[index], next = model.snapshot.order[index + 1]
            model.select(key)
            model.focus = .reader
            model.perform(.archive, on: [key])
            let read = waitUntil { model.cursor == next && model.row(next)?.thread.unreadCount == 0 }
            check("triage from the reader marks the next thread read", read)
            model.undoLast()
            poll(0.6) {}
            model.perform(.markUnread, on: [next], toast: nil)
            poll(0.4) {}
            model.focus = .list
        }

        // Undoing "add to project" leaves threads that were already in it.
        if let project = model.projects.first {
            model.show(.allMail)
            wait(0.2)
            let order = model.snapshot.order
            let inside = order.first { model.row($0)?.projectIds.contains(project.id) == true }
            let outside = order.first { model.row($0)?.projectIds.contains(project.id) == false }
            if let inside, let outside {
                model.toggleProject(project.id, on: [inside, outside])
                poll(0.5) {}
                model.undoLast()
                poll(0.5) {}
                check("project undo keeps threads that were already in it",
                      model.row(inside)?.projectIds.contains(project.id) == true && model.row(outside)?.projectIds.contains(project.id) == false)
            }
        }

        // A thread opened from outside the list survives the next observation.
        model.show(.inbox)
        model.showInboxTab(.primary)
        wait(0.2)
        if let outsider = try? model.store.threadRows(in: Mailbox(.sent), limit: 50).first(where: { model.snapshot.rows[$0.id] == nil })?.id,
           let other = model.snapshot.order.first {
            model.reveal(outsider)
            model.perform(.star, on: [other], toast: nil)
            poll(0.5) {}
            check("a revealed thread stays open after the list updates", model.cursor == outsider)
            model.perform(.unstar, on: [other], toast: nil)
            poll(0.3) {}
            model.focus = .list
            model.reloadList()
            wait(0.2)
        }

        // Search results refresh after a write. Wait for results before selecting a target.
        model.searchText = "invoice"
        _ = waitUntil { model.isSearching && !model.searchRows.isEmpty }
        if let first = model.snapshot.order.first, let row = model.row(first) {
            let starred = row.thread.isStarred
            model.select(first)
            model.toggleStar()
            check("search results show a star change", waitUntil { model.row(first)?.thread.isStarred == !starred })
            model.toggleStar()
            _ = waitUntil { model.row(first)?.thread.isStarred == starred }
        }
        model.endSearch(restoreFocus: true)

        // ⌘A while typing in the search pill belongs to the text field.
        model.beginSearch()
        wait(0.1)
        if KeyRouter.textInput(in: window) != nil {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
            check("⌘A in the search pill is left to the text", router.handle(event) != nil && model.checked.isEmpty)
        }
        model.endSearch(restoreFocus: true)
        window.makeFirstResponder(nil)

        check("⌘N is the menu key for New Message", registry["compose"]?.menuKey == .command("n"))
    }

    private func needsReply() {
        model.showInboxTab(.primary)
        wait(0.2)
        guard let key = model.snapshot.order.first(where: { !(model.row($0)?.needsReply ?? true) }) else {
            return check("needs-reply candidate", false)
        }
        model.setCursor(key, open: false)
        let before = model.counts.needsReply
        model.toggleNeedsReply()
        poll(0.6) {}
        check("⇧R flags needs reply", model.row(key)?.needsReply == true)
        check("needs-reply count goes up", model.counts.needsReply == before + 1)
        model.undoLast()
        poll(0.6) {}
        check("undo clears the flag", model.row(key)?.needsReply == false)
    }

    private func search() {
        let cold = Timing.begin("search-cold")
        _ = try? model.services.search.search("receipt", accountId: nil, limit: 200)
        print(String(format: "  search: %.1f ms for a first (cold) query", Timing.end(cold)))
        let started = DispatchTime.now().uptimeNanoseconds
        model.searchText = "invoice"
        var elapsed = 0.0
        poll(1.0) {
            if elapsed == 0, self.model.isSearching, !self.model.searchRows.isEmpty {
                elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            }
        }
        check("search shows results", model.isSearching && !model.snapshot.isEmpty)
        print(String(format: "  search: results %.1f ms after the keystroke (debounce %.0f ms included)", elapsed, Double(AppModel.searchDebounce) / 1_000_000))
        let interval = Timing.begin("search-raw")
        _ = try? model.services.search.searchHits("invoice", options: SearchOptions(limit: AppModel.searchPage))
        print(String(format: "  search: %.1f ms for the query itself (%d hits with excerpts)", Timing.end(interval), AppModel.searchPage))
        model.endSearch(restoreFocus: true)
        check("esc restores the mailbox", !model.isSearching && model.snapshot.rows.count > 0)
    }

    private func tabs() {
        if !model.prefs.splitInbox { model.setSplitInbox(true) }
        model.show(.sent)
        model.show(.inbox)
        wait(0.2)
        check("the Inbox opens on Primary", model.activeTab == .category(.primary))
        check("Primary holds only Primary threads",
              !model.snapshot.isEmpty && model.snapshot.order.allSatisfy { model.row($0)?.inboxTab == .primary })
        let shown = model.tabs.compactMap { tab -> InboxTab? in if case .category(let inbox) = tab { inbox } else { nil } }
        print("  tabs: \(shown.map(\.title).joined(separator: ", ")); unread \(InboxTab.allCases.map { "\($0.title) \(model.counts.tabUnread[$0, default: 0])" }.joined(separator: ", "))")
        guard shown.count > 1 else { return check("inbox tabs: a second tab", false) }
        model.cycleTab(1)
        wait(0.2)
        check("tab moves to \(shown[1].title)", model.activeTab == .category(shown[1]))
        check("\(shown[1].title) holds only its threads",
              !model.snapshot.isEmpty && model.snapshot.order.allSatisfy { model.row($0)?.inboxTab == shown[1] })
        model.cycleTab(-2)
        wait(0.1)
        check("⇧tab twice goes back to Needs reply", model.activeTab == .needsReply)
        check("Needs reply lists only threads waiting on you",
              !model.snapshot.isEmpty && model.snapshot.order.allSatisfy { model.row($0)?.needsReply == true })
        model.cycleTab(-2)
        check("⇧tab wraps past All to the last tab", model.activeTab == model.tabs.last)
        model.select(.all)
        wait(0.1)
        if case .header = model.snapshot.items.first {
            check("All starts with a date group", true)
        } else {
            check("All starts with a date group", false)
        }
        check("⌥4 is Promotions", registry["tab.promotions"]?.keys == [.option("4")])
        let promotionsUnread = model.counts.tabUnread[.promotions, default: 0]
        check("Promotions shows its unread count, All and Primary none",
              promotionsUnread > 0 && model.count(for: .category(.promotions)) == promotionsUnread
                && model.count(for: .all) == nil && model.count(for: .category(.primary)) == nil)

        hiddenTabs()
        moveToTab()
        model.showInboxTab(.primary)
        wait(0.1)
    }

    /// A tab with nothing in the scope's inbox hides, except while it is open.
    private func hiddenTabs() {
        let scopes = [Scope.all] + model.accounts.map { Scope.account($0.id) }
        var found: (Scope, InboxTab)?
        var probes: [Bool] = []
        for scope in scopes {
            model.setScope(scope)
            let probed = model.tabsWithMail
            wait(0.3)
            probes.append(probed == Set(InboxTab.allCases.filter { model.counts.tabThreads[$0, default: 0] > 0 }))
            if let empty = InboxTab.allCases.first(where: { $0 != .primary && model.counts.tabThreads[$0, default: 0] == 0 }) {
                found = (scope, empty)
                break
            }
        }
        check("the tabs read when the scope changes are the ones the counts find", !probes.contains(false))
        guard let (scope, empty) = found else { return check("an empty tab in some scope", false) }
        check("an empty tab (\(empty.title), \(scope)) is hidden", !model.tabs.contains(.category(empty)))
        model.select(.category(empty))
        wait(0.2)
        check("…but shows while it is open", model.tabs.contains(.category(empty)) && model.activeTab == .category(empty) && model.snapshot.isEmpty)
        model.showInboxTab(.primary)
        wait(0.1)
        check("…and hides again once left", !model.tabs.contains(.category(empty)))
        model.setScope(.all)
        wait(0.3)
    }

    /// Move to Primary from Promotions: the row leaves in the same frame, Gmail's labels swap (queued for Gmail),
    /// it shows in Primary, and undo puts it back.
    private func moveToTab() {
        model.showInboxTab(.promotions)
        wait(0.2)
        guard let key = model.snapshot.order.first, let next = model.snapshot.key(from: key, offset: 1) else {
            return check("move to tab: a Promotions thread", false)
        }
        let before = gmailTab(key)
        model.setCursor(key, open: false)

        let menu = ThreadMenu.make(registry: registry, model: model)
        let tabsItem = menu.items.first { $0.title == "Move to Tab" }
        check("the row menu has Move to Tab with Gmail's five tabs, Promotions ticked",
              tabsItem?.submenu?.items.map(\.title) == InboxTab.allCases.map(\.title)
                && tabsItem?.submenu?.items.first { $0.state == .on }?.title == "Promotions")
        model.palette = .commands
        palette.query = "move to pri"
        check("⌘K offers Move to Primary", palette.flatItems.first?.title == "Move to Primary")
        palette.close()

        registry.run("moveToTab.primary")
        check("Move to Primary takes the thread out of Promotions in the same frame",
              model.snapshot.rows[key] == nil && model.cursor == next)
        check("…with a toast", model.toasts.last?.title == "Moved to Primary")
        let filed = waitUntil { self.gmailTab(key) == .primary }
        check("…and files it under Gmail's Primary", filed)
        let move = latestLabelOp(key)
        check("…queuing the label swap for Gmail",
              move?.action == "moveToTab" && move?.change.add == [SystemLabel.categoryPersonal]
                && Set(move?.change.remove ?? ["?"]).isSubset(of: InboxTab.allCases.filter { $0 != .primary }.map(\.labelId)))
        model.showInboxTab(.primary)
        _ = waitUntil { self.model.snapshot.rows[key] != nil }
        check("…where Primary lists it", model.snapshot.rows[key] != nil)
        model.showInboxTab(.promotions)
        wait(0.2)
        model.undoLast()
        let back = waitUntil { self.model.snapshot.rows[key] != nil && self.gmailTab(key) == before }
        check("undo puts it back in Promotions", back && model.cursor == key)
        let moveBack = latestLabelOp(key)
        check("…and queues the move back for Gmail, Primary off",
              moveBack?.action == "undo-moveToTab" && moveBack?.change.requestRemove.contains(SystemLabel.categoryPersonal) == true)
    }

    private func scope() {
        guard let account = model.accounts.first else { return check("accounts", false) }
        model.setScope(.account(account.id))
        wait(0.2)
        check("⌘1 scopes the list", model.snapshot.order.allSatisfy { $0.accountId == account.id })
        check("labels load for the scoped account", !model.labels.isEmpty)
        model.setScope(.all)
        wait(0.2)
    }

    private func keys() {
        model.showInboxTab(.primary)
        wait(0.2)
        model.moveToTop()
        let start = model.cursor
        send("j")
        check("j moves down", model.cursor == model.snapshot.key(from: start, offset: 1))
        send("k")
        check("k moves up", model.cursor == start)
        send("x")
        check("x checks the row", model.checked == [start!])
        send("x")
        send("g")
        check("g starts a chord", model.chordHUD == "g")
        send("s")
        check("g s goes to Starred", model.kind == .starred && model.chordHUD == nil)
        send("g"); send("o")
        check("g o goes to I owe", model.kind == .iOwe && model.chordHUD == nil)
        send("g"); send("w")
        check("g w goes to Waiting on", model.kind == .waitingOn && model.chordHUD == nil)
        send("g"); send("i")
        check("g i goes to Inbox", model.kind == .inbox)
        send("/")
        wait(0.1)
        check("/ focuses search", model.searchFieldFocused)
        if let editor = KeyRouter.textInput(in: window) {
            send("e")
            check("bare keys type into the search field", editor.string == "e" && model.toasts.last?.title != "Archived")
        } else {
            print("  (search field did not take focus offscreen; typing check skipped)")
        }
        model.endSearch(restoreFocus: true)
        window.makeFirstResponder(nil)
        send("k", modifiers: .command)
        check("⌘K is left to the menu bar", model.palette == nil)
        model.palette = .commands
        wait(0.05)
        send("", keyCode: 53)
        check("esc closes the palette", model.palette == nil)
    }

    private func paletteSearch() {
        model.palette = .commands
        palette.query = "arc"
        check("fuzzy 'arc' ranks Archive first", palette.flatItems.first?.title == "Archive")
        palette.query = "mtp"
        check("fuzzy 'mtp' finds Move to Project", palette.flatItems.contains { $0.title == "Move to Project…" })
        palette.close()
    }

    private func printMenus() {
        let menu = MainMenu(registry: registry).build()
        for top in menu.items {
            print("[\(top.title)]")
            for item in top.submenu?.items ?? [] {
                if item.isSeparatorItem { print("  ---"); continue }
                var key = item.keyEquivalent
                if key == "\r" { key = "↵" } else if key == "\u{1b}" { key = "esc" } else if key == "\t" { key = "⇥" }
                let mods = item.keyEquivalentModifierMask
                let prefix = (mods.contains(.control) ? "⌃" : "") + (mods.contains(.option) ? "⌥" : "") + (mods.contains(.shift) ? "⇧" : "") + (mods.contains(.command) ? "⌘" : "")
                print("  \(item.title)\(key.isEmpty ? "" : "   \(prefix)\(key)")\(item.toolTip.map { "   (\($0))" } ?? "")")
            }
        }
    }

    // MARK: Timings

    private func timeQueries() {
        let store = model.store
        let source = model.source
        var interval = Timing.begin("page")
        _ = try? store.database.reader.read { db in try source.fetch(db, limit: AppModel.pageSize) }
        print(String(format: "  first page (%d rows): %.1f ms", AppModel.pageSize, Timing.end(interval)))
        interval = Timing.begin("counts")
        _ = try? store.scopeCounts(accountId: nil)
        print(String(format: "  scope counts (off the main thread): %.1f ms", Timing.end(interval)))
        interval = Timing.begin("tabs")
        _ = try? store.database.reader.read { db in try MailStore.fetchTabsWithMail(db, accountId: nil) }
        print(String(format: "  tabs with mail (main thread, scope change): %.2f ms", Timing.end(interval)))
        interval = Timing.begin("snapshot")
        _ = ListSnapshot(rows: model.rawRows, groupsByDate: true)
        print(String(format: "  list snapshot build: %.2f ms", Timing.end(interval)))
    }

    // MARK: Helpers

    private func gmailTab(_ key: ThreadKey) -> InboxTab? {
        try? model.store.database.reader.read { db in
            try MailThread.fetchOne(db, key: ["accountId": key.accountId, "id": key.threadId])?.gmailTab
        }
    }

    /// The newest queued label op touching the thread: its action and the first message's change.
    private func latestLabelOp(_ key: ThreadKey) -> (action: String, change: LabelChange)? {
        let op = try? model.store.database.reader.read { db in
            try PendingOp.filter(Column("accountId") == key.accountId && Column("kind") == PendingOp.Kind.modifyLabels.rawValue)
                .order(Column("id").desc).fetchOne(db)
        }
        guard let op, let payload = try? JSONDecoder().decode(LabelOpPayload.self, from: Data(op.payload.utf8)),
              payload.threadIds.contains(key.threadId), let change = payload.changes.first else { return nil }
        return (payload.action, change)
    }

    func isInInbox(_ key: ThreadKey) throws -> Bool {
        try model.store.database.reader.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM thread_label WHERE accountId = ? AND threadId = ? AND labelId = 'INBOX')",
                              arguments: [key.accountId, key.threadId]) ?? false
        }
    }

    func send(_ characters: String, modifiers: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters.lowercased(), isARepeat: false, keyCode: keyCode)
        else { return }
        if router.handle(event) != nil, let text = KeyRouter.textInput(in: window) { text.keyDown(with: event) }
        wait(0.02)
    }

    func check(_ name: String, _ ok: Bool) {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)")
    }

    func wait(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Spins the run loop until `condition` holds or `timeout` passes; returns the last answer.
    /// Checks of timers and background writes use it so a busy machine doesn't fail them.
    @discardableResult
    func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= end { return false }
            for window in NSApp.windows { window.contentView?.layoutSubtreeIfNeeded() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return true
    }

    /// Spins the run loop for `seconds`, calling `body` every few milliseconds.
    func poll(_ seconds: TimeInterval, _ body: () -> Void) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            body()
            RunLoop.main.run(until: Date().addingTimeInterval(0.004))
        }
    }
}
