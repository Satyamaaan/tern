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
            .start(in: reader, scheduling: .immediate, onError: Self.log) { [weak self] accounts in
                self?.receive(accounts: accounts)
            }
        projectsObservation = ValueObservation
            .tracking { db in try Project.order(Column("sortOrder"), Column("name")).fetchAll(db) }
            .removeDuplicates()
            .start(in: reader, scheduling: .immediate, onError: Self.log) { [weak self] projects in
                guard let self else { return }
                self.projects = projects
                self.services.projects = projects
            }
        observeScope()
        reloadList()
    }

    /// Counts and labels depend on the account in scope.
    func observeScope() {
        let reader = store.database.reader
        let accountId = scope.accountId
        countsObservation = ValueObservation
            .tracking { db in try MailStore.fetchScopeCounts(db, accountId: accountId) }
            .removeDuplicates()
            .start(in: reader, scheduling: .async(onQueue: .main), onError: Self.log) { [weak self] counts in
                guard let self else { return }
                self.counts = counts
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
            .start(in: reader, scheduling: .immediate, onError: Self.log) { [weak self] labels in
                self?.labels = labels
            }
    }

    private func receive(accounts: [Account]) {
        self.accounts = accounts
        services.accounts = accounts
        if let id = scope.accountId, !accounts.contains(where: { $0.id == id }) { setScope(.all) }
    }

    // MARK: The list

    /// Starts reading a different list (mailbox, scope or split changed).
    func reloadList() {
        source = ListSource(mailbox: mailbox, split: showsSplits ? split : nil)
        limit = Self.pageSize
        hidden = [:]
        checked = []
        cursor = nil
        listLoaded = false
        observeRows(immediate: true)
    }

    /// Infinite scroll: read another page when the user nears the end.
    func loadMore() {
        guard hasMore, !isSearching else { return }
        limit += Self.pageSize
        hasMore = false
        observeRows(immediate: false)
    }

    private func observeRows(immediate: Bool) {
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
            self.hasMore = rows.count >= limit
            self.listLoaded = true
            if !self.isSearching { self.rebuildSnapshot(first ? .reset : .none) }
            if first, let done = self.onFirstRows { self.onFirstRows = nil; done() }
        }
        let reader = store.database.reader
        rowsObservation = immediate
            ? observation.start(in: reader, scheduling: .immediate, onError: Self.log, onChange: receive)
            : observation.start(in: reader, scheduling: .async(onQueue: .main), onError: Self.log, onChange: receive)
    }

    /// Recomputes what the list shows from the latest rows, keeping hidden (just triaged) threads out
    /// and the cursor on a sensible row.
    func rebuildSnapshot(_ animation: ListAnimation) {
        let input = isSearching ? searchRows : rawRows
        let present = Set(input.map(\.id))
        for (key, state) in hidden where state == .committed && !present.contains(key) { hidden[key] = nil }
        let rows = hidden.isEmpty ? input : input.filter { hidden[$0.id] == nil }

        let old = snapshot
        snapshot = ListSnapshot(
            rows: rows,
            needsReplyFirst: !isSearching && source.needsReplyFirst,
            groupsByDate: isSearching || source.groupsByDate)

        checked = checked.filter { snapshot.rows[$0] != nil }
        var newCursor = cursor
        if let pending = pendingCursor, snapshot.rows[pending] != nil {
            newCursor = pending
            pendingCursor = nil
        } else if let current = cursor, snapshot.rows[current] == nil {
            newCursor = Self.successor(of: current, in: old, keeping: snapshot)
        } else if cursor == nil, animation == .reset {
            newCursor = snapshot.order.first
        }
        cursor = newCursor
        if cursorAnchor.map({ snapshot.rows[$0] == nil }) ?? true { cursorAnchor = cursor }

        listView?.listDidChange(snapshot, animation: animation)
        listView?.selectionDidChange(scrollTo: animation == .reset ? nil : newCursor)
    }

    /// The row that takes a removed row's place: the next one still listed, else the previous one.
    private static func successor(of key: ThreadKey, in old: ListSnapshot, keeping new: ListSnapshot) -> ThreadKey? {
        guard let index = old.position[key] else { return new.order.first }
        if let next = old.order[index...].first(where: { new.rows[$0] != nil }) { return next }
        return old.order[..<index].last(where: { new.rows[$0] != nil })
    }

    nonisolated static func log(_ error: Error) {
        NSLog("Tern: database observation failed: \(error)")
    }
}
