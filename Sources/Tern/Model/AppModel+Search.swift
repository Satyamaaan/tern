import Foundation
import TernCore

// Search as you type: each keystroke cancels the previous query, waits a few milliseconds for the next
// key, then reads on a background thread. Results replace the list; Esc brings the mailbox back.
extension AppModel {
    nonisolated static let searchDebounce: UInt64 = 12_000_000
    nonisolated static let searchLimit = 200

    /// `/`: focus the search pill.
    func beginSearch() {
        palette = nil
        focus = .list
        searchFieldFocused = true
    }

    /// Esc: clear the query and show the mailbox again.
    func endSearch(restoreFocus: Bool) {
        searchTask?.cancel()
        searchFieldFocused = false
        if !searchText.isEmpty { searchText = "" }
        leaveResults()
        if restoreFocus { focus = .list }
    }

    /// ↓ or Return in the search pill: move into the results.
    func focusResults(open: Bool) {
        searchFieldFocused = false
        focus = .list
        if open { self.open() }
    }

    func searchTextChanged() {
        searchTask?.cancel()
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            leaveResults()
            return
        }
        if !isSearching {
            cursorBeforeSearch = cursor
            isSearching = true
        }
        searchGeneration += 1
        let generation = searchGeneration
        let search = services.search
        let accountId = scope.accountId
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.searchDebounce)
            guard !Task.isCancelled else { return }
            let interval = Timing.begin("search")
            let rows = await Task.detached(priority: .userInitiated) {
                (try? search.search(text, accountId: accountId, limit: Self.searchLimit)) ?? []
            }.value
            Timing.end(interval)
            guard let self, !Task.isCancelled, generation == self.searchGeneration, self.isSearching else { return }
            self.searchRows = rows
            self.cursor = nil
            self.rebuildSnapshot(.reset)
        }
    }

    private func leaveResults() {
        guard isSearching else { return }
        isSearching = false
        searchRows = []
        cursor = cursorBeforeSearch.flatMap { key in rawRows.contains { $0.id == key } ? key : nil }
        cursorBeforeSearch = nil
        rebuildSnapshot(.reset)
    }
}
