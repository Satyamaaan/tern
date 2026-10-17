import AppKit
import GRDB
import TernCore
import TernSync

/// Checks for the pieces the lanes built separately and the shell now wires together: the reader in
/// the window, the menu bar, inline replies, search, projects, notifications, the Google client and
/// sync against an offline fake Gmail. Nothing here touches the network.
extension SelfCheck {
    func integration() {
        readerWiring()
        menuBar()
        inlineReplies()
        sendAndArchive()
        searchWiring()
        projectRemovalSticks()
        notificationPlanner()
        googleClientText()
        offlineSync()
    }

    private var services: AppServices { model.services }

    private func settle(_ seconds: TimeInterval = 0.3) {
        poll(seconds) { window.contentView?.layoutSubtreeIfNeeded() }
    }

    // MARK: Reader

    private func readerWiring() {
        model.show(.inbox)
        model.showSplit(.people)
        settle(0.2)
        let order = model.snapshot.order
        guard let index = order.indices.dropFirst().dropLast().first(where: { (model.row(order[$0])?.thread.unreadCount ?? 0) > 0 }) else {
            return check("reader: an unread thread to open", false)
        }
        let key = order[index]
        let undoDepth = model.undoStack.count
        model.click(key, command: false, shift: false)
        settle(0.5)
        check("opening a thread marks it read", waitUntil { model.row(key)?.thread.unreadCount == 0 })
        check("marking read on open shows no toast and adds no undo",
              !model.toasts.contains { $0.title == "Marked read" } && model.undoStack.count == undoDepth)
        check("the reader shows the open thread", services.reader.model?.key == key)
        check("the reader gets the neighbours to prefetch", model.readerNeighbours.prefix(2) == [order[index + 1], order[index - 1]])
        check("the reader knows its place in the list", model.readerPosition?.index == index + 1 && model.readerPosition?.total == order.count)
        model.readerPosition?.next?()
        check("› in the reader opens the next thread", model.cursor == order[index + 1])

        model.focusList()
        send("p")
        check("p in the list files into a project", { if case .project = model.palette { true } else { false } }())
        model.palette = nil
        settle(0.1)
        check("closing the palette gives the list the keyboard back", KeyRouter.textInput(in: window) == nil)
        send("", keyCode: 36)
        check("Return opens the thread and gives the page the keyboard", model.focus == .reader && KeyRouter.readerHasKeyboard(window))
        let cursor = model.cursor
        window.makeFirstResponder(nil)
        send("\r", keyCode: 36)
        check("Return in the open thread stays in it", model.focus == .reader && model.cursor == cursor)
        send("p")
        check("p in the open thread goes to the reader", model.palette == nil)
        send("", keyCode: 53)
        let table = (model.listView as? MessageListController)?.table
        check("Esc hands the keyboard back to the list", model.focus == .list && window.firstResponder === table)
    }

    // MARK: Menu bar

    private func menuBar() {
        let menu = MainMenu(registry: registry).build()
        var bound: [String: [String]] = [:]
        for top in menu.items {
            for item in top.submenu?.items ?? [] where !item.keyEquivalent.isEmpty {
                let mods = item.keyEquivalentModifierMask
                guard mods.contains(.command) || mods.contains(.control) else { continue }
                let key = item.keyEquivalent
                let shift = mods.contains(.shift) || (key.count == 1 && key != key.lowercased())
                let name = (mods.contains(.control) ? "⌃" : "") + (mods.contains(.option) ? "⌥" : "") + (shift ? "⇧" : "") + "⌘" + key.lowercased()
                bound[name, default: []].append(item.title)
            }
        }
        let twice = bound.filter { $0.value.count > 1 }
        for (key, titles) in twice { print("  \(key) is bound to: \(titles.joined(separator: ", "))") }
        check("no ⌘ shortcut is bound twice in the menu bar", twice.isEmpty)
        check("⌘F, ⌘G, ⇧⌘G, ⌘P and ⇧⌘S are menu items",
              bound["⌘f"] == ["Find in Conversation…"] && bound["⌘g"] == ["Find Next"] && bound["⇧⌘g"] == ["Find Previous"]
                && bound["⌘p"] == ["Print Conversation…"] && bound["⇧⌘s"] == ["Summarize"])
    }

    // MARK: Composer

    private func inlineReplies() {
        model.showSplit(.people)
        settle(0.2)
        guard let key = model.snapshot.order.dropFirst(2).first else { return check("reply: a thread", false) }
        model.click(key, command: false, shift: false)
        settle()
        model.focusList()
        let windows = NSApp.windows.filter { $0 is ComposerWindow }.count
        send("r")
        settle(0.4)
        check("r answers inline in the reader", services.reader.model?.composing == .reply(key, all: false))
        check("r opens no composer window", NSApp.windows.filter { $0 is ComposerWindow }.count == windows)
        check("the inline reply appears with the caret in its body", KeyRouter.textInput(in: window) != nil)
        services.reader.model?.composing = nil
        settle(0.4)

        services.reader.model?.quickReply("Sounds good, thanks")
        settle(0.5)
        check("a ✦ quick reply opens the inline reply with its text", services.reader.model?.composing == .reply(key, all: false)
              && services.replyPrefill[key] == nil && (KeyRouter.textInput(in: window)?.string.contains("Sounds good, thanks") ?? false))
        services.reader.model?.composing = nil
        settle(1.0)
        let draft = try? services.drafts.editingDraft(inThread: key)
        check("the quick reply's text is in the saved reply draft", draft?.bodyHtml.contains("Sounds good, thanks") == true)
        if let draft {
            model.focusList()
            send("r")
            settle(0.3)
            check("r reopens the reply already being written", services.reader.model?.composing == .draft(id: draft.id))
            services.reader.model?.composing = nil
            settle(0.4)
            let drafts = services.drafts
            Task { _ = try? await drafts.discard(draft.id) }
            settle(0.4)
        }
    }

    private func sendAndArchive() {
        model.show(.inbox)
        model.showSplit(.people)
        settle(0.2)
        let order = model.snapshot.order
        guard order.count > 3, let archiveSent = services.archiveSent else { return check("send and archive: rows", false) }
        let key = order[1], next = order[2]
        model.setCursor(key, open: false)
        let toasts = model.toasts.count
        var token: UndoToken?
        var finished = false
        Task {
            token = await archiveSent(key)
            finished = true
        }
        var hidden = false, reappeared = false
        poll(0.8) {
            if model.snapshot.rows[key] == nil { hidden = true } else if hidden { reappeared = true }
        }
        check("send and archive takes the row out and selects the next", hidden && finished && model.cursor == next)
        check("send and archive never flickers the row back", !reappeared)
        check("send and archive adds no toast of its own", model.toasts.count == toasts)
        if let token {
            let store = model.store
            var undone: Bool?
            Task.detached {
                let ok = (try? store.undo(token)) != nil
                await MainActor.run { undone = ok }
            }
            poll(0.8) {}
            check("undoing the send brings the row back", undone == true && model.snapshot.rows[key] != nil)
        } else {
            check("send and archive returns what undo needs", false)
        }
    }

    // MARK: Search

    private func searchWiring() {
        model.searchText = "invoice"
        settle(0.5)
        check("search reads one page per keystroke", waitUntil { (1...AppModel.searchPage).contains(model.searchRows.count) })
        if let first = model.snapshot.order.first, let mark = model.highlight(for: first) {
            check("result rows mark the matched words", !mark.subject.isEmpty || !mark.snippetRanges.isEmpty)
            check("result rows show the hit's excerpt", !mark.snippet.isEmpty)
        } else {
            check("result rows mark the matched words", false)
        }
        if model.searchHasMore {
            let count = model.searchRows.count
            model.loadMore()
            settle(0.5)
            check("scrolling reads the next page of results", model.searchRows.count > count)
        }
        model.searchFieldFocused = true
        model.submitSearch()
        settle(0.4)
        check("Return records the search", (try? services.search.recentSearches().first) == "invoice")
        model.endSearch(restoreFocus: true)

        model.beginSearch()
        model.searchText = "from:"
        settle(0.4)
        check("from: suggests people", waitUntil { model.suggestions.contains { $0.kind == .contact } })
        check("the dropdown opens under the pill", model.showsSuggestions)
        _ = model.moveSuggestion(1)
        check("↓ highlights the first suggestion", model.suggestionIndex == 0)
        _ = model.completeSuggestion()
        check("Tab completes it", model.searchText.hasPrefix("from:") && model.searchText.count > "from:".count)
        settle(0.3)
        check("Esc closes the dropdown before the search", model.dismissSuggestions() && !model.showsSuggestions && model.isSearching)

        let ai = services.ai
        services.ai = AIActions(summarize: { _ in [] }, suggestReplies: { _ in [] }, draftReply: { _, _ in "" },
                                naturalLanguageQuery: { _ in "subject:invoice" })
        model.searchText = "invoices from last month"
        settle(0.3)
        check("with AI on, the last suggestion is ✦ Ask", model.suggestionItems.last == .ask("invoices from last month"))
        model.choose(.ask("invoices from last month"))
        settle(0.5)
        check("✦ Ask runs the query it wrote", model.searchText == "subject:invoice" && model.isSearching)
        services.ai = ai

        services.serverSearch = { _ in 0 }
        model.searchText = "zeppelin quartz"
        settle(0.4)
        check("few results end with Search older mail on Gmail", model.snapshot.items.last == .serverSearch("Search older mail on Gmail"))
        model.searchOnServer()
        settle(0.4)
        check("…and say when Gmail has nothing more", model.snapshot.items.last == .serverSearch("Nothing older on Gmail"))
        services.serverSearch = nil
        model.endSearch(restoreFocus: true)
    }

    // MARK: Projects

    private func projectRemovalSticks() {
        let store = model.store
        guard let projectId = model.projects.first?.id else { return check("projects: a project", false) }
        model.show(.project(projectId))
        settle(0.3)
        let links = (try? store.database.reader.read { db in
            try ThreadProject.filter(Column("projectId") == projectId && Column("source") == "rule").fetchAll(db)
        }) ?? []
        let ruled = Set(links.map { ThreadKey(accountId: $0.accountId, threadId: $0.threadId) })
        guard let key = model.snapshot.order.first(where: ruled.contains) else { return check("projects: a rule-filed thread", false) }
        let link = ThreadProject(accountId: key.accountId, threadId: key.threadId, projectId: projectId, source: .rule)
        model.toggleProject(link.projectId, on: [key])
        settle(0.4)
        _ = try? store.database.writer.write { db in try ProjectRules.apply(db, keys: [key]) }
        settle(0.4)
        let out = waitUntil {
            let still = try? store.database.reader.read { db in
                try ThreadProject.exists(db, key: ["accountId": key.accountId, "threadId": key.threadId, "projectId": link.projectId])
            }
            return still == false && model.row(key) == nil
        }
        check("a thread taken out of a project by hand stays out when rules run", out)
        model.undoLast()
        settle(0.5)
        check("undo puts it back in the project", model.row(key) != nil)
        model.show(.inbox)
        settle(0.2)
    }

    // MARK: Notifications

    private func notificationPlanner() {
        guard let rows = try? model.store.threadRows(in: .unifiedInbox, limit: 400) else { return }
        let unread = rows.filter { $0.thread.unreadCount > 0 }
        let people = unread.filter { $0.category == .people && !$0.needsReply }
        guard people.count >= 3, let newsletter = unread.first(where: { $0.category == .newsletter && !$0.needsReply }) else {
            return check("notifications: sample rows", false)
        }
        let now = Date()
        var planner = NotificationPlanner(since: .distantPast)
        planner.consider([people[0]], appActive: false, enabled: true, onlyImportant: true)
        check("new mail from a person gets a banner", planner.next(now: now)?.thread == people[0].id)
        planner.consider([people[1], people[2]], appActive: false, enabled: true, onlyImportant: true)
        check("no second banner within 10 s", planner.next(now: now.addingTimeInterval(3)) == nil)
        check("…then one banner sums up what came in between",
              planner.next(now: now.addingTimeInterval(10))?.title == "2 new conversations")
        planner.consider([newsletter], appActive: false, enabled: true, onlyImportant: true)
        check("only important mail: a newsletter gets no banner", planner.next(now: now.addingTimeInterval(30)) == nil)

        var active = NotificationPlanner(since: .distantPast)
        active.consider([people[0]], appActive: true, enabled: true, onlyImportant: true)
        active.consider([people[0]], appActive: false, enabled: true, onlyImportant: true)
        check("mail that arrived while Tern was active never notifies later", active.next(now: now) == nil)
        var off = NotificationPlanner(since: .distantPast)
        off.consider([people[0]], appActive: false, enabled: false, onlyImportant: false)
        check("notifications off: no banner", off.next(now: now) == nil)
        var everything = NotificationPlanner(since: .distantPast)
        everything.consider([newsletter], appActive: false, enabled: true, onlyImportant: false)
        check("all mail: a newsletter gets a banner", everything.next(now: now) != nil)
    }

    // MARK: Google client

    private func googleClientText() {
        check("the Google client ID is shown masked",
              GoogleClientText.masked("1234567890-abcdefghijklmnop.apps.googleusercontent.com") == "1234••••mnop.apps.googleusercontent.com")
    }

    // MARK: Sync

    /// A real SyncCoordinator against FakeGmail in an in-memory database: the first sync fills the store,
    /// the sidebar line goes quiet, and the draft encoder threads a reply.
    private func offlineSync() {
        guard let database = try? AppDatabase.inMemory() else { return check("sync: database", false) }
        let store = MailStore(database)
        let account = Account(email: "me@example.com", displayName: "Personal")
        try? store.upsertAccount(account)
        let gmail = FakeGmail(email: account.email)
        var seeded = false
        Task {
            for index in 0..<20 {
                await gmail.deliver(FakeEmail(from: "Maya Chen <maya@example.com>", to: [account.email], subject: "Offline check \(index)",
                                              text: "Body \(index)", date: Date().addingTimeInterval(Double(index - 40) * 60)))
            }
            seeded = true
        }
        let seeding = Date()
        while !seeded, Date().timeIntervalSince(seeding) < 3 { wait(0.02) }
        var configuration = SyncConfiguration()
        configuration.observeSystemWake = false
        configuration.attachmentCacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("tern-check-\(UUID().uuidString)")
        let coordinator = SyncCoordinator(store: store, accounts: [account], apiProvider: { _ in gmail },
                                          encodeDraft: DraftEncoder.make(store: store), configuration: configuration)
        coordinator.start()
        var threads = 0
        let started = Date()
        while Date().timeIntervalSince(started) < 10 {
            threads = (try? database.reader.read { db in try MailThread.fetchCount(db) }) ?? 0
            if threads == 20, coordinator.status(for: account.id)?.state != .new { break }
            wait(0.05)
        }
        check("sync against an offline Gmail fills the store", threads == 20)
        let line = SyncSummary.line(Array(coordinator.statuses.values), now: Date())
        check("the sync line is quiet once the inbox is in", line == nil || line?.tone == .quiet)
        print("  sync: first sync of 20 messages in \(Int(Date().timeIntervalSince(started) * 1000)) ms; line: \(line?.text ?? "Up to date")")

        let rows = (try? store.threadRows(in: .unifiedInbox, limit: 1)) ?? []
        if let key = rows.first?.id, let content = try? DraftStore(database).makeDraft(.reply(key, all: false)) {
            let draft = content.assembledDraft()
            let raw = (try? DraftEncoder.make(store: store)(draft, account)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            check("a reply is threaded and sent from the account",
                  raw.contains("In-Reply-To: <") && raw.contains("References: <")
                    && raw.components(separatedBy: "\r\n").contains { $0.hasPrefix("From:") && $0.contains("me@example.com") })
        } else {
            check("sync: a reply to encode", false)
        }
        coordinator.stop()
        check("rate limits read as minutes", SyncSummary.wait(95) == "2 min" && SyncSummary.wait(12) == "12 s")
    }
}
