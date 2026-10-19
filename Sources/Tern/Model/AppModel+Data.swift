import AppKit
import GRDB
import TernCore

// Database observations. Reads for one screen are indexed and bounded; the first page of a list is
// read synchronously so the list never shows an empty frame, everything after that off the main thread.
extension AppModel {
    func startObservations() {
        let reader = store.database.reader
        accountsObservation = ValueObservation
            .tracking { db in try Account.order(Column("sortOrder"), Column("createdAt")).fetchAll(db) }
            .removeDuplicates()
            .startRestarting(in: reader, scheduling: .immediate, onError: Self.log) { [weak self] accounts in
                self?.receive(accounts: accounts)
            }
        projectsObservation = ValueObservation
            .tracking { db in try Project.order(Column("sortOrder"), Column("name")).fetchAll(db) }
            .removeDuplicates()
            .startRestarting(in: reader, scheduling: .immediate, onError: Self.log) { [weak self] projects in
                guard let self else { return }
                self.projects = projects
                self.services.projects = projects
            }
        observeScope()
        reloadList()
    }

    /// Counts and labels depend on the account in scope. Which of Gmail's tabs have mail is read here first, a
    /// bounded probe (`fetchTabsWithMail`), so the tab bar is right in the first frame; the counts, one pass over
    /// the scope's inbox, always arrive off the main thread and then keep it up to date.
    func observeScope() {
        let reader = store.database.reader
        let accountId = scope.accountId
        tabsWithMail = (try? reader.read { db in try MailStore.fetchTabsWithMail(db, accountId: accountId) }) ?? []
        countsObservation = ValueObservation
            .tracking { db in try MailStore.fetchScopeCounts(db, accountId: accountId) }
            .removeDuplicates()
            .startRestarting(in: reader, scheduling: .async(onQueue: .main), onError: Self.log) { [weak self] counts in
                guard let self else { return }
                self.counts = counts
                let tabs = Set(InboxTab.allCases.filter { counts.tabThreads[$0, default: 0] > 0 })
                if tabs != self.tabsWithMail { self.tabsWithMail = tabs }
                let badge = counts.allAccountsInboxUnread
                NSApp.dockTile.badgeLabel = badge > 0 ? badge.formatted() : nil
            }
        guard let accountId else {
            labelsObservation = nil
            labels = []
            return
        }
        labelsObservation = ValueObservation
            .tracking { db in
                try MailLabel
                    .filter(Column("accountId") == accountId && Column("type") == "user" && Column("hidden") == false)
                    .order(Column("name"))
                    .fetchAll(db)
            }
            .removeDuplicates()
            .startRestarting(in: reader, scheduling: .immediate, onError: Self.log) { [weak self] labels in
                self?.labels = labels
            }
    }

    private func receive(accounts: [Account]) {
        self.accounts = accounts
        services.accounts = accounts
        // The account in scope was removed (Settings → Accounts): all accounts, keeping the place.
        if let id = scope.accountId, !accounts.contains(where: { $0.id == id }) { setScope(.all, keepingPlace: true) }
    }

    // MARK: The list

    /// Starts reading a different list (mailbox, scope or tab changed), from its first row. With
    /// `keepingPlace` (a setting changed under the open thread, like Inbox Tabs) the cursor and the selection
    /// stay on the threads the new list still has, so the open thread stays open as it was, and the same list
    /// isn't read again at all.
    func reloadList(keepingPlace: Bool = false) {
        let next = ListSource(mailbox: mailbox, tab: kind == .inbox && prefs.splitInbox ? inboxTab : nil)
        if keepingPlace, next == source, listLoaded { return }
        source = next
        pendingCursor = nil
        listLoaded = false
        if keepingPlace {
            // Rows the user scrolled to stay read, and threads still being triaged stay out.
            limit = max(limit, Self.pageSize)
        } else {
            limit = Self.pageSize
            hidden = [:]
            checked = []
            cursor = nil
        }
        observeRows(immediate: true, keepingPlace: keepingPlace)
    }

    /// Infinite scroll: read another page when the user nears the end.
    func loadMore() {
        if isSearching { return loadMoreResults() }
        guard hasMore else { return }
        limit += Self.pageSize
        hasMore = false
        observeRows(immediate: false)
    }

    private func observeRows(immediate: Bool, keepingPlace: Bool = false) {
        let source = self.source
        let limit = self.limit
        let signpost = Timing.begin("list")
        let observation = ValueObservation
            .tracking { db in try source.fetch(db, limit: limit) }
            .removeDuplicates()
        let receive: ([ThreadRow]) -> Void = { [weak self] rows in
            Timing.end(signpost)
            guard let self, self.source == source else { return }
            let first = !self.listLoaded
            self.rawRows = rows
            if self.hasMore != (rows.count >= limit) { self.hasMore = rows.count >= limit }
            if first { self.listLoaded = true }
            if !self.isSearching { self.rebuildSnapshot(first && !keepingPlace ? .reset : .none, keepingPlace: first && keepingPlace) }
            if first, let done = self.onFirstRows { self.onFirstRows = nil; done() }
        }
        let reader = store.database.reader
        rowsObservation = immediate
            ? observation.startRestarting(in: reader, scheduling: .immediate, onError: Self.log, onChange: receive)
            : observation.startRestarting(in: reader, scheduling: .async(onQueue: .main), onError: Self.log, onChange: receive)
    }

    /// Recomputes what the list shows from the latest rows, keeping hidden (just triaged) threads out
    /// and the cursor on a sensible row. `keepingPlace` is the first rows of a list read with
    /// `reloadList(keepingPlace:)`: a cursor the new list doesn't have goes to its first row, like a new list.
    func rebuildSnapshot(_ animation: ListAnimation, keepingPlace: Bool = false) {
        let input = isSearching ? searchRows : rawRows
        let present = Set(input.map(\.id))
        for (key, state) in hidden where state == .committed && !present.contains(key) { hidden[key] = nil }
        let rows = hidden.isEmpty ? input : input.filter { hidden[$0.id] == nil }

        let old = snapshot
        snapshot = ListSnapshot(
            rows: rows,
            groupsByDate: isSearching || source.groupsByDate,
            footer: serverSearchFooter.map(ListItem.serverSearch))

        let stillChecked = checked.filter { snapshot.rows[$0] != nil }
        if stillChecked != checked { checked = stillChecked }
        var newCursor = cursor
        if let pending = pendingCursor, snapshot.rows[pending] != nil {
            newCursor = pending
            pendingCursor = nil
        } else if let current = cursor, snapshot.rows[current] == nil {
            let upward = animation == .collapse && prefs.afterTriage == .previous
            newCursor = keepingPlace ? snapshot.order.first : Self.successor(of: current, in: old, keeping: snapshot, upward: upward)
        } else if cursor == nil, animation == .reset || keepingPlace {
            newCursor = snapshot.order.first
        }
        let moved = newCursor != cursor
        if moved { cursor = newCursor }
        // After triage the next thread is on screen: treat it like moving onto it (opened at once when
        // reading in the reader), unless the user goes back to the list after triage or no thread is left
        // to show, which closes the reader either way.
        if moved, animation == .collapse {
            if prefs.afterTriage == .list || newCursor == nil, readerExpanded || focus == .reader {
                readerExpanded = false
                focusList()
            }
            if newCursor != nil { scheduleMarkRead(open: focus == .reader || readerExpanded, changed: true) }
        }
        if cursorAnchor.map({ snapshot.rows[$0] == nil }) ?? true { cursorAnchor = cursor }

        listView?.listDidChange(snapshot, animation: animation)
        listView?.selectionDidChange(scrollTo: animation == .reset ? nil : newCursor)
    }

    /// The row that takes a removed row's place: the next one still listed, else the previous one
    /// (`upward`: the previous one first).
    static func successor(of key: ThreadKey, in old: ListSnapshot, keeping new: ListSnapshot, upward: Bool = false) -> ThreadKey? {
        // A thread opened from outside the list (notification, palette) stays open.
        guard let index = old.position[key] else { return key }
        let below = old.order[index...].first(where: { new.rows[$0] != nil })
        let above = old.order[..<index].last(where: { new.rows[$0] != nil })
        return upward ? above ?? below : below ?? above
    }

    nonisolated static func log(_ error: Error) {
        NSLog("Tern: database observation failed, restarting it: \(error)")
    }
}
