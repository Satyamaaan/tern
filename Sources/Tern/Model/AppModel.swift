import AppKit
import GRDB
import Observation
import TernCore

/// Which accounts the window shows.
enum Scope: Hashable {
    case all
    case account(String)

    var accountId: String? {
        if case .account(let id) = self { return id }
        return nil
    }
}

/// Where keyboard input goes in the main window.
enum Focus: Hashable { case sidebar, list, reader }

/// What the ⌘K palette is showing.
enum PaletteMode: Equatable {
    case commands
    /// Toggle a label on threads.
    case label([ThreadKey])
    /// Toggle a project on threads.
    case project([ThreadKey])
    case snooze([ThreadKey])
    case goToLabel
    case goToProject
}

/// Receives list changes from the model, in the same frame. Implemented by the AppKit list.
@MainActor
protocol ListPresenting: AnyObject {
    func listDidChange(_ snapshot: ListSnapshot, animation: ListAnimation)
    func selectionDidChange(scrollTo key: ThreadKey?)
    /// Makes the list the first responder.
    func takeKeyboard()
}

enum ListAnimation {
    /// New data in place (observation updates).
    case none
    /// Rows leave after a triage action: 160 ms collapse.
    case collapse
    /// A different list: reload and scroll to the top.
    case reset
}

/// State of the main window. Everything the shell shows reads from here; the database is observed
/// and every write goes through `perform`, off the main thread.
@MainActor
@Observable
final class AppModel {
    let services: AppServices
    let prefs = Preferences.shared
    @ObservationIgnored let store: MailStore
    @ObservationIgnored let isFake: Bool
    @ObservationIgnored let databaseURL: URL

    // MARK: Navigation

    var scope: Scope = .all
    var kind: Mailbox.Kind = .inbox
    var split: InboxSplit = .important
    var focus: Focus = .list
    /// List-only layout (⌘⇧\): the reader takes the full width while a thread is open.
    var listOnly = false
    /// In list-only layout, whether the open thread fills the window.
    var readerExpanded = false

    // MARK: Search

    var searchText = "" { didSet { if searchText != oldValue { searchTextChanged() } } }
    /// The list shows search results instead of the mailbox.
    var isSearching = false
    /// Mirrors the search pill's focus.
    var searchFieldFocused = false
    /// The dropdown under the search pill: people, labels, projects, operators, recent searches.
    var suggestions: [SearchSuggestion] = []
    /// The highlighted dropdown row (into `suggestionItems`); nil while the caret is in the text.
    var suggestionIndex: Int?
    /// Esc closed the dropdown; it opens again with the next keystroke.
    var suggestionsDismissed = false
    /// True while ✦ Ask turns the text into a query.
    var askingAI = false
    /// The "Search older mail on Gmail" row at the end of the results.
    var serverSearchState = ServerSearchState.idle

    // MARK: Overlays

    var palette: PaletteMode?
    var showsShortcuts = false
    /// Pending `g` chord, shown in a small HUD.
    var chordHUD: String?
    var projectEditor: ProjectDraft?
    /// Threads waiting on a custom snooze date.
    var snoozeDateFor: [ThreadKey]?
    var toasts: [Toast] = []

    // MARK: Data

    var accounts: [Account] = []
    var projects: [Project] = []
    /// User labels of the account in scope (empty in the unified view).
    var labels: [MailLabel] = []
    var counts = ScopeCounts()
    var snapshot = ListSnapshot.empty
    /// True while the demo mailbox is being written on first launch.
    var isSeeding = false
    /// False until the first rows for the current list arrive.
    var listLoaded = false
    var hasMore = false
    /// The open thread (keyboard cursor).
    var cursor: ThreadKey?
    /// Explicit multi-selection (x, ⇧J/⇧K, ⌘/⇧-click, ⌘A). Empty means "just the cursor".
    var checked: Set<ThreadKey> = []

    // MARK: Internals

    @ObservationIgnored weak var listView: ListPresenting?
    /// The command registry, for menus built inside views (row `…`, context menus).
    @ObservationIgnored weak var registry: CommandRegistry?
    @ObservationIgnored var source: ListSource
    @ObservationIgnored var rawRows: [ThreadRow] = []
    @ObservationIgnored var searchRows: [ThreadRow] = []
    @ObservationIgnored var searchHits: [ThreadKey: SearchHit] = [:]
    @ObservationIgnored var searchHighlights: [ThreadKey: RowHighlight] = [:]
    /// Results asked for: a page per keystroke, more as the list scrolls.
    @ObservationIgnored var searchLimit = AppModel.searchPage
    @ObservationIgnored var searchHasMore = false
    @ObservationIgnored var suggestionTask: Task<Void, Never>?
    @ObservationIgnored var lastRecordedSearch: String?
    @ObservationIgnored var limit = AppModel.pageSize
    @ObservationIgnored var hidden: [ThreadKey: HiddenState] = [:]
    @ObservationIgnored var pendingCursor: ThreadKey?
    @ObservationIgnored var undoStack: [UndoEntry] = []
    @ObservationIgnored var rowsObservation: AnyDatabaseCancellable?
    @ObservationIgnored var countsObservation: AnyDatabaseCancellable?
    @ObservationIgnored var accountsObservation: AnyDatabaseCancellable?
    @ObservationIgnored var projectsObservation: AnyDatabaseCancellable?
    @ObservationIgnored var labelsObservation: AnyDatabaseCancellable?
    @ObservationIgnored var searchTask: Task<Void, Never>?
    @ObservationIgnored var searchGeneration = 0
    @ObservationIgnored var markReadTimer: Timer?
    @ObservationIgnored var cursorAnchor: ThreadKey?
    @ObservationIgnored var cursorBeforeSearch: ThreadKey?
    /// Threads being dragged onto the sidebar.
    @ObservationIgnored var draggedKeys: [ThreadKey] = []
    /// Serial queue for every database write the UI makes.
    @ObservationIgnored let writes = DispatchQueue(label: "dev.tern.writes", qos: .userInitiated)
    /// Called once the first page of the first list is on screen (launch timing).
    @ObservationIgnored var onFirstRows: (() -> Void)?

    static let pageSize = 200

    enum HiddenState { case writing, committed }

    init(services: AppServices, isFake: Bool, databaseURL: URL) {
        self.services = services
        self.store = services.store
        self.isFake = isFake
        self.databaseURL = databaseURL
        self.source = ListSource(mailbox: .unifiedInbox, split: Preferences.shared.splitInbox ? .important : nil)
    }

    // MARK: Derived

    var mailbox: Mailbox { Mailbox(kind, accountId: scope.accountId) }

    var title: String {
        if isSearching { return "Search" }
        switch kind {
        case .label(let id): return labels.first { $0.id == id }?.name ?? id
        case .project(let id): return projects.first { $0.id == id }?.name ?? "Project"
        default: return kind.title
        }
    }

    var showsSplits: Bool {
        guard !isSearching, prefs.splitInbox, case .inbox = kind else { return false }
        return true
    }

    var scopedAccount: Account? { scope.accountId.flatMap { id in accounts.first { $0.id == id } } }

    /// The thread the reader shows; nil when several are selected.
    var readerKey: ThreadKey? { checked.count > 1 ? nil : cursor }

    /// Threads an action applies to: the multi-selection, else the cursor.
    var targets: [ThreadKey] {
        if checked.isEmpty { return cursor.map { [$0] } ?? [] }
        return snapshot.order.filter(checked.contains)
    }

    func isSelected(_ key: ThreadKey) -> Bool { key == cursor || checked.contains(key) }

    func row(_ key: ThreadKey) -> ThreadRow? { snapshot.rows[key] }

    /// Dots in the Flock: threads in this list that need you (unread or needs reply).
    var flockCount: Int? {
        if isSearching { return nil }
        if let filter = source.inboxFilter { return counts.needingAction(in: filter) }
        switch kind {
        case .needsReply: return counts.needsReply
        case .project(let id): return counts.projectUnread[id] ?? 0
        default: return nil
        }
    }

    func unreadCount(_ split: InboxSplit) -> Int { counts.unread(in: split.filter(accountId: scope.accountId)) }

    func account(_ id: String) -> Account? { accounts.first { $0.id == id } }

    func project(_ id: String) -> Project? { projects.first { $0.id == id } }

    // MARK: Navigation

    func setScope(_ scope: Scope) {
        guard scope != self.scope else { return }
        if case .label = kind, scope == .all { kind = .inbox }
        self.scope = scope
        observeScope()
        reloadList()
    }

    func show(_ kind: Mailbox.Kind) {
        if isSearching { endSearch(restoreFocus: false) }
        focus = .list
        readerExpanded = false
        guard kind != self.kind else { return }
        self.kind = kind
        reloadList()
    }

    func showSplit(_ split: InboxSplit) {
        if isSearching { endSearch(restoreFocus: false) }
        if case .inbox = kind, self.split == split { return }
        self.split = split
        kind = .inbox
        reloadList()
    }

    func cycleSplit(_ step: Int) {
        guard showsSplits else { return }
        let all = InboxSplit.allCases
        let index = all.firstIndex(of: split) ?? 0
        showSplit(all[(index + step + all.count) % all.count])
    }

    func setSplitInbox(_ enabled: Bool) {
        prefs.splitInbox = enabled
        reloadList()
    }

    // MARK: Cursor and selection

    /// j / k. With `extend`, grows the multi-selection (⇧J / ⇧K).
    func moveCursor(_ step: Int, extend: Bool = false) {
        guard let next = snapshot.key(from: cursor, offset: step) else { return }
        if extend {
            if checked.isEmpty, let cursor { checked.insert(cursor) }
            checked.insert(next)
        }
        setCursor(next, open: false)
    }

    func moveToTop() { if let first = snapshot.order.first { setCursor(first, open: false) } }
    func moveToBottom() { if let last = snapshot.order.last { setCursor(last, open: false) } }

    /// A click on a row. ⌘ toggles it in the selection, ⇧ selects the range from the cursor.
    func click(_ key: ThreadKey, command: Bool, shift: Bool) {
        focus = .list
        if command {
            if checked.isEmpty, let cursor { checked.insert(cursor) }
            if checked.contains(key) { checked.remove(key) } else { checked.insert(key) }
            cursorAnchor = key
            setCursor(key, open: false, keepAnchor: true)
        } else if shift, let anchor = cursorAnchor ?? cursor {
            checked = Set(snapshot.range(from: anchor, to: key))
            setCursor(key, open: false, keepAnchor: true)
        } else {
            checked = []
            setCursor(key, open: true)
            recordSearch()
        }
    }

    /// Moves the cursor to a row without opening it (right-click, drag).
    func select(_ key: ThreadKey) {
        focus = .list
        checked = []
        setCursor(key, open: false, dwell: false)
    }

    /// x: adds or removes the cursor thread from the selection.
    func toggleChecked() {
        guard let cursor else { return }
        if checked.contains(cursor) { checked.remove(cursor) } else { checked.insert(cursor) }
        listView?.selectionDidChange(scrollTo: nil)
    }

    func selectAll() {
        checked = Set(snapshot.order)
        listView?.selectionDidChange(scrollTo: nil)
    }

    func clearSelection() {
        guard !checked.isEmpty else { return }
        checked = []
        listView?.selectionDidChange(scrollTo: nil)
    }

    /// Moves the cursor. `open` marks the thread read now; otherwise it is marked read after a moment
    /// on screen, unless `dwell` is false (right-click, drag), which never marks it read.
    func setCursor(_ key: ThreadKey?, open: Bool, keepAnchor: Bool = false, dwell: Bool = true) {
        if !keepAnchor { cursorAnchor = key }
        let changed = key != cursor
        if changed { cursor = key }
        listView?.selectionDidChange(scrollTo: key)
        if open || dwell {
            scheduleMarkRead(open: open, changed: changed)
        } else {
            markReadTimer?.invalidate()
        }
    }

    /// Enter / o: open the thread for reading. In the open thread, Enter expands or collapses the
    /// focused message.
    func open() {
        guard let cursor else { return }
        if focus == .reader, services.reader.isActive {
            services.reader.toggleMessage()
            return
        }
        focus = .reader
        if listOnly { readerExpanded = true }
        markRead([cursor])
        recordSearch()
        services.reader.focus()
    }

    /// Esc: leave the reader, clear search, or clear the selection, in that order.
    func back() {
        if palette != nil { palette = nil; return }
        if showsShortcuts { showsShortcuts = false; return }
        if isSearching { endSearch(restoreFocus: true); return }
        if readerExpanded { readerExpanded = false; focusList(); return }
        if focus == .reader { focusList(); return }
        clearSelection()
    }

    /// Gives the list the keyboard again.
    func focusList() {
        focus = .list
        listView?.takeKeyboard()
    }

    func toggleSidebar() { prefs.sidebarCollapsed.toggle() }

    func toggleListOnly() {
        listOnly.toggle()
        readerExpanded = false
        focus = .list
    }

    // MARK: Mark read on open

    /// Opening a thread (click, Enter) marks it read at once; moving onto it with j/k marks it read
    /// after it has been on screen for a moment, so skimming past doesn't.
    func scheduleMarkRead(open: Bool, changed: Bool) {
        markReadTimer?.invalidate()
        guard let key = cursor, checked.count <= 1 else { return }
        if open { markRead([key]); return }
        guard changed else { return }
        markReadTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.cursor == key, self.checked.count <= 1 else { return }
                self.markRead([key])
            }
        }
    }

    private func markRead(_ keys: [ThreadKey]) {
        // Threads opened from outside the list (notifications) have no row; the write is a no-op if read.
        let unread = keys.filter { row($0).map { $0.thread.unreadCount > 0 } ?? true }
        guard !unread.isEmpty else { return }
        perform(.markRead, on: unread, toast: nil)
    }
}

/// A transient message at the bottom of the list ("Archived · Undo z").
struct Toast: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var undo: UndoEntry?

    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

/// Something `z` can put back. The toast appears in the same frame as the action, before the write
/// finishes, so the details needed to undo arrive later in a box filled on the serial write queue.
struct UndoEntry: Identifiable {
    enum Change {
        case mail(MailAction, WriteResult<UndoToken>)
        case needsReply(WriteResult<NeedsReplyUndo>)
        case project(String, [ThreadKey], assigned: Bool)
        /// Undo handled by its owner on the main actor, e.g. cancelling a send.
        case custom(@MainActor () -> Void)
    }

    let id = UUID()
    var change: Change
    var threads: [ThreadKey]
    /// Dropped from the undo stack when its toast goes away (a send can't be undone after it left).
    var expires = false
}

/// A value produced by a write on `AppModel.writes`. Only read it from that queue, where every
/// earlier write has finished.
final class WriteResult<Value>: @unchecked Sendable {
    var value: Value?
}
