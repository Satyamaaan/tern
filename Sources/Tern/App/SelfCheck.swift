import AppKit
import SwiftUI
import TernCore

/// `--check`: drives the shell offscreen through triage, undo, search, splits, selection and key
/// routing, and prints PASS/FAIL per step plus timings. It writes to the database, so point `TERN_DB`
/// at a throwaway copy of a seeded mailbox.
@MainActor
final class SelfCheck {
    let model: AppModel
    let registry: CommandRegistry
    private var failures = 0
    private let window: MainWindow
    private let router: KeyRouter
    private let palette: PaletteController

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
        timeQueries()
        triage()
        multiSelect()
        needsReply()
        search()
        splits()
        scope()
        keys()
        paletteSearch()
        print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Scenarios

    private func triage() {
        model.show(.inbox)
        model.showSplit(.people)
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
        model.showSplit(.people)
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

    private func needsReply() {
        model.showSplit(.people)
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
        _ = try? model.services.search.search("invoice", accountId: nil, limit: 200)
        print(String(format: "  search: %.1f ms for the query itself", Timing.end(interval)))
        model.endSearch(restoreFocus: true)
        check("esc restores the mailbox", !model.isSearching && model.snapshot.rows.count > 0)
    }

    private func splits() {
        model.show(.inbox)
        model.showSplit(.important)
        wait(0.1)
        model.cycleSplit(1)
        wait(0.1)
        check("tab moves to People", model.split == .people)
        check("People holds only people", model.snapshot.order.allSatisfy { model.row($0)?.category == .people })
        model.cycleSplit(-2)
        check("⇧tab wraps to Other", model.split == .other)
        model.showSplit(.important)
        wait(0.1)
        let firstGroup = model.snapshot.items.first
        check("Important starts with NEEDS REPLY", firstGroup == .header("NEEDS REPLY"))
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
        model.showSplit(.people)
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

    // MARK: Timings

    private func timeQueries() {
        let store = model.store
        let source = model.source
        var interval = Timing.begin("page")
        _ = try? store.database.reader.read { db in try source.fetch(db, limit: AppModel.pageSize) }
        print(String(format: "  first page (%d rows): %.1f ms", AppModel.pageSize, Timing.end(interval)))
        interval = Timing.begin("counts")
        _ = try? store.scopeCounts(accountId: nil)
        print(String(format: "  scope counts: %.1f ms", Timing.end(interval)))
        interval = Timing.begin("snapshot")
        _ = ListSnapshot(rows: model.rawRows, needsReplyFirst: true, groupsByDate: true)
        print(String(format: "  list snapshot build: %.2f ms", Timing.end(interval)))
    }

    // MARK: Helpers

    private func isInInbox(_ key: ThreadKey) throws -> Bool {
        try model.store.database.reader.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM thread_label WHERE accountId = ? AND threadId = ? AND labelId = 'INBOX')",
                              arguments: [key.accountId, key.threadId]) ?? false
        }
    }

    private func send(_ characters: String, modifiers: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters.lowercased(), isARepeat: false, keyCode: keyCode)
        else { return }
        if router.handle(event) != nil, let text = KeyRouter.textInput(in: window) { text.keyDown(with: event) }
        wait(0.02)
    }

    private func check(_ name: String, _ ok: Bool) {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)")
    }

    private func wait(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Spins the run loop for `seconds`, calling `body` every few milliseconds.
    private func poll(_ seconds: TimeInterval, _ body: () -> Void) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            body()
            RunLoop.main.run(until: Date().addingTimeInterval(0.004))
        }
    }
}
