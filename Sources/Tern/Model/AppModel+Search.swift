import AppKit
import TernCore

// Search as you type: each keystroke cancels the previous query, waits a few milliseconds for the next
// key, then reads a page of hits on a background thread. Results replace the list, with the matched
// words marked; Esc brings the mailbox back. A dropdown under the pill suggests people, labels,
// projects, operators and recent searches, plus "✦ Ask" when AI is on.
extension AppModel {
    nonisolated static let searchDebounce: UInt64 = 8_000_000
    /// Hits asked for per keystroke; scrolling near the end asks for this many more.
    nonisolated static let searchPage = 40
    nonisolated static let suggestionLimit = 6

    /// `/`: focus the search pill.
    func beginSearch() {
        palette = nil
        focus = .list
        searchFieldFocused = true
    }

    /// Esc: clear the query and show the mailbox again.
    func endSearch(restoreFocus: Bool) {
        searchTask?.cancel()
        suggestionTask?.cancel()
        searchFieldFocused = false
        if !searchText.isEmpty { searchText = "" }
        suggestions = []
        suggestionIndex = nil
        leaveResults()
        if restoreFocus { focusList() }
    }

    /// ↓ or Return in the search pill: move into the results.
    func focusResults(open: Bool) {
        searchFieldFocused = false
        focusList()
        if open { self.open() }
    }

    func searchTextChanged() {
        searchTask?.cancel()
        suggestionsDismissed = false
        suggestionIndex = nil
        serverSearchState = .idle
        refreshSuggestions()
        let text = trimmedSearch
        guard !text.isEmpty else {
            leaveResults()
            return
        }
        if !isSearching {
            cursorBeforeSearch = cursor
            isSearching = true
        }
        searchGeneration += 1
        searchLimit = Self.searchPage
        runSearch(text, generation: searchGeneration, debounce: true)
    }

    /// Reads the current query again after a write or a server search, keeping the cursor where it is.
    func refreshSearch(then done: (() -> Void)? = nil) {
        let text = trimmedSearch
        guard isSearching, !text.isEmpty else { return }
        runSearch(text, generation: searchGeneration, debounce: false, then: done)
    }

    /// Scrolling near the end of the results asks for the next page.
    func loadMoreResults() {
        guard isSearching, searchHasMore else { return }
        searchHasMore = false
        searchLimit += Self.searchPage * 2
        refreshSearch()
    }

    var trimmedSearch: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func runSearch(_ text: String, generation: Int, debounce: Bool, then done: (() -> Void)? = nil) {
        let search = services.search
        let options = SearchOptions(accountId: scope.accountId, limit: searchLimit)
        let task = Task { [weak self] in
            if debounce {
                try? await Task.sleep(nanoseconds: Self.searchDebounce)
                guard !Task.isCancelled else { return }
            }
            let interval = Timing.begin("search")
            let hits = await Task.detached(priority: .userInitiated) {
                (try? search.searchHits(text, options: options)) ?? []
            }.value
            Timing.end(interval)
            guard let self, !Task.isCancelled, generation == self.searchGeneration, self.isSearching else { return }
            self.receive(hits, limit: options.limit, reset: debounce)
            done?()
        }
        if debounce { searchTask = task }
    }

    private func receive(_ hits: [SearchHit], limit: Int, reset: Bool) {
        searchRows = hits.map(\.row)
        searchHits = Dictionary(hits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        searchHighlights = [:]
        searchHasMore = hits.count >= limit
        if reset { cursor = nil }
        rebuildSnapshot(reset ? .reset : .none)
    }

    private func leaveResults() {
        guard isSearching else { return }
        isSearching = false
        searchRows = []
        searchHits = [:]
        searchHighlights = [:]
        serverSearchState = .idle
        cursor = cursorBeforeSearch.flatMap { key in rawRows.contains { $0.id == key } ? key : nil }
        cursorBeforeSearch = nil
        rebuildSnapshot(.reset)
    }

    /// The matched words of a result row, found when the row is first drawn.
    func highlight(for key: ThreadKey) -> RowHighlight? {
        if let cached = searchHighlights[key] { return cached }
        guard let hit = searchHits[key] else { return nil }
        let highlight = RowHighlight(subject: hit.subjectHighlights, snippet: hit.snippet, snippetRanges: hit.highlights)
        searchHighlights[key] = highlight
        return highlight
    }

    /// Remembers the query once the user acts on it (Enter, or opening a result).
    func recordSearch() {
        let text = trimmedSearch
        guard isSearching, !text.isEmpty, text != lastRecordedSearch else { return }
        lastRecordedSearch = text
        let search = services.search
        writes.async { try? search.recordRecentSearch(text) }
    }

    // MARK: Suggestions

    /// A dropdown row: a suggestion from the index, or "✦ Ask" with the typed text.
    enum SuggestionItem: Hashable, Identifiable {
        case suggestion(SearchSuggestion)
        case ask(String)

        var id: String {
            switch self {
            case .suggestion(let suggestion): suggestion.id
            case .ask: "ask"
            }
        }
    }

    var suggestionItems: [SuggestionItem] {
        var items = suggestions.map(SuggestionItem.suggestion)
        let text = trimmedSearch
        if services.ai != nil, text.contains(where: \.isLetter), !text.hasSuffix(":") { items.append(.ask(text)) }
        return items
    }

    var showsSuggestions: Bool { searchFieldFocused && !suggestionsDismissed && !suggestionItems.isEmpty }

    func refreshSuggestions() {
        suggestionTask?.cancel()
        let text = searchText
        let search = services.search
        suggestionTask = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                (try? search.suggestions(for: text, limit: AppModel.suggestionLimit)) ?? []
            }.value
            guard let self, !Task.isCancelled, self.searchText == text else { return }
            if found != self.suggestions { self.suggestions = found }
            if let index = self.suggestionIndex, index >= self.suggestionItems.count { self.suggestionIndex = nil }
        }
    }

    /// ↑ / ↓ in the pill while the dropdown is open. Returns false when it isn't.
    func moveSuggestion(_ step: Int) -> Bool {
        guard showsSuggestions else { return false }
        let count = suggestionItems.count
        switch (suggestionIndex, step > 0) {
        case (nil, true): suggestionIndex = 0
        case (nil, false): return true
        case (let index?, true): suggestionIndex = min(index + 1, count - 1)
        case (let index?, false): suggestionIndex = index == 0 ? nil : index - 1
        }
        return true
    }

    /// Tab: completes the highlighted (or first) suggestion. Returns false when the dropdown is closed.
    func completeSuggestion() -> Bool {
        guard showsSuggestions else { return false }
        let items = suggestionItems
        let item = items[min(suggestionIndex ?? 0, items.count - 1)]
        if case .suggestion(let suggestion) = item, !suggestion.runsImmediately {
            searchText = suggestion.completion
        } else {
            choose(item)
        }
        return true
    }

    /// Return in the pill: the highlighted suggestion, else search and move into the results.
    func submitSearch() {
        if showsSuggestions, let index = suggestionIndex, suggestionItems.indices.contains(index) {
            choose(suggestionItems[index])
            return
        }
        recordSearch()
        suggestionsDismissed = true
        focusResults(open: !snapshot.isEmpty)
    }

    /// Esc in the pill: closes the dropdown first. Returns false when it was closed already.
    func dismissSuggestions() -> Bool {
        guard showsSuggestions else { return false }
        suggestionsDismissed = true
        suggestionIndex = nil
        return true
    }

    func choose(_ item: SuggestionItem) {
        switch item {
        case .suggestion(let suggestion):
            searchText = suggestion.completion
            if suggestion.runsImmediately {
                recordSearch()
                suggestionsDismissed = true
            }
        case .ask(let text):
            askAI(text)
        }
    }

    /// ✦ Ask: turns natural language into a query and runs it. Typing goes on meanwhile; a result
    /// for text that has since changed is dropped.
    func askAI(_ text: String) {
        guard let ai = services.ai, !askingAI else { return }
        askingAI = true
        Task { [weak self] in
            let query = try? await ai.naturalLanguageQuery(text)
            guard let self else { return }
            self.askingAI = false
            guard self.trimmedSearch == text, let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                return
            }
            self.searchText = query
            self.suggestionsDismissed = true
            self.recordSearch()
        }
    }

    // MARK: Older mail on Gmail

    /// The quiet last row of the results: shown when sync can search Gmail and every local hit is listed.
    var serverSearchFooter: String? {
        guard isSearching, services.serverSearch != nil, !searchHasMore, listLoaded else { return nil }
        switch serverSearchState {
        case .idle: return "Search older mail on Gmail"
        case .running: return "Searching Gmail…"
        case .done(let added): return added == 0 ? "Nothing older on Gmail" : "Found \(added) more on Gmail"
        case .failed: return "Couldn't search Gmail"
        }
    }

    func searchOnServer() {
        guard let serverSearch = services.serverSearch, serverSearchState == .idle || serverSearchState == .failed else { return }
        let text = trimmedSearch
        let before = searchRows.count
        serverSearchState = .running
        rebuildSnapshot(.none)
        Task { [weak self] in
            let found: Int?
            do { found = try await serverSearch(text) } catch { found = nil }
            guard let self, self.trimmedSearch == text, self.isSearching else { return }
            guard let found else {
                self.serverSearchState = .failed
                self.rebuildSnapshot(.none)
                return
            }
            self.searchLimit = max(self.searchLimit, before + found + Self.searchPage)
            self.refreshSearch { [weak self] in
                guard let self, self.trimmedSearch == text else { return }
                self.serverSearchState = .done(max(0, self.searchRows.count - before))
                self.rebuildSnapshot(.none)
            }
        }
    }
}

enum ServerSearchState: Equatable {
    case idle, running, failed
    case done(Int)
}

/// The matched words of a search result row: ranges in the subject, and the excerpt shown in place of
/// the preview with its ranges (UTF-16, for `NSAttributedString`).
struct RowHighlight: Equatable {
    var subject: [NSRange]
    var snippet: String
    var snippetRanges: [NSRange]
}
