import Foundation
import TernCore

// Discard Draft from a row, the keyboard, ⌘K and the reader. The undo is real: drafts leave at once, but
// their Gmail copies are deleted only after the toast's undo window (`DraftStore.discardDrafts`), so Undo
// puts back the local draft, its message in the lists, its content and its files.
extension AppModel {
    /// How long "Draft discarded · Undo" stays. Undo works only while it shows.
    static let discardUndoSeconds: TimeInterval = 5
    /// How much longer the Gmail deletions wait, so an undo at the last moment still finds them unsent.
    static let discardHoldMargin: TimeInterval = 10

    /// A row that is a draft rather than a conversation: a local draft's row, any row of the Drafts
    /// mailbox, or a thread with nothing in it but drafts.
    func isDraftRow(_ key: ThreadKey) -> Bool {
        if MailThread.localDraftId(in: key) != nil { return true }
        if case .drafts = kind, !isSearching { return true }
        guard let thread = row(key)?.thread else { return false }
        return thread.hasDraft && thread.lastInboundDate == nil && !thread.labelIds.contains(SystemLabel.sent)
    }

    /// A draft row, or a conversation with a draft of yours in it.
    func holdsDraft(_ key: ThreadKey) -> Bool {
        isDraftRow(key) || row(key)?.thread.hasDraft == true
    }

    /// Every target is a draft row: delete and `#` discard rather than trash.
    var targetsAreDrafts: Bool {
        let keys = targets
        return !keys.isEmpty && keys.allSatisfy(isDraftRow)
    }

    /// Some targets are draft rows and some aren't: delete and `#` discard the one and trash the other.
    var targetsMixDrafts: Bool {
        let keys = targets
        return keys.contains(where: isDraftRow) && !keys.allSatisfy(isDraftRow)
    }

    /// Some target holds a draft (⌘K Discard Draft).
    var targetsHoldDrafts: Bool { targets.contains(where: holdsDraft) }

    /// Discards the drafts of rows. A draft row leaves the list in the same frame; a conversation a draft
    /// replies to stays, without the draft.
    func discardDrafts(_ keys: [ThreadKey]) {
        discard(keys.filter(holdsDraft), trashing: [])
    }

    /// Delete and `#`: draft rows are discarded and the other rows go to Trash, with one toast and one undo.
    func trashOrDiscard(_ keys: [ThreadKey]) {
        let drafts = keys.filter(isDraftRow)
        guard !drafts.isEmpty else { return perform(.trash, on: keys) }
        discard(drafts, trashing: keys.filter { !isDraftRow($0) })
    }

    /// The reader's Discard beside one draft of a conversation.
    func discardDraft(_ message: MessageKey, in thread: ThreadKey) {
        let leaving = !isSearching && isDraftRow(thread) && snapshot.rows[thread] != nil ? [thread] : []
        discard(leaving: leaving, count: 1) { drafts, hold in
            try drafts.discardDrafts([.message(message)], holdFor: hold)
        }
    }

    /// "Draft discarded", "3 drafts discarded", "Moved 2 to Trash and discarded a draft".
    static func discardTitle(drafts: Int, trashed: Int) -> String {
        if trashed == 0 { return drafts == 1 ? "Draft discarded" : "\(drafts) drafts discarded" }
        if drafts == 0 { return toastTitle(.trash, count: trashed) }
        return "Moved \(trashed) to Trash and discarded " + (drafts == 1 ? "a draft" : "\(drafts) drafts")
    }

    /// What an undo that couldn't put everything back as it was says, or nil.
    static func restoredTitle(_ restored: RestoredDrafts) -> String? {
        if restored.lost > 0 {
            return "Too late: Gmail already deleted " + (restored.lost == 1 ? "the draft" : "\(restored.lost) drafts")
        }
        if restored.resaved > 0 { return restored.resaved == 1 ? "Draft back, saved to Gmail again" : "Drafts back, saved to Gmail again" }
        return nil
    }

    private func discard(_ keys: [ThreadKey], trashing trashed: [ThreadKey]) {
        guard !keys.isEmpty else { return }
        let leaving = isSearching ? [] : keys.filter { isDraftRow($0) && snapshot.rows[$0] != nil }
        discard(leaving: leaving, count: keys.count, trashing: trashed) { drafts, hold in
            try drafts.discardDrafts(inThreads: keys, holdFor: hold)
        }
    }

    private func discard(
        leaving drafted: [ThreadKey], count: Int, trashing trashed: [ThreadKey] = [],
        _ write: @escaping @Sendable (DraftStore, TimeInterval) throws -> DiscardedDrafts
    ) {
        let leaving = drafted + trashed.filter { leavesList(.trash) && snapshot.rows[$0] != nil }
        if !leaving.isEmpty { hide(leaving) }
        if !trashed.isEmpty, case .inbox = kind { prefs.clearedToday += trashed.count }
        let drafts = services.drafts
        let store = self.store
        let hold = Self.discardUndoSeconds + Self.discardHoldMargin
        let result = WriteResult<DiscardedDrafts>()
        let trash = WriteResult<UndoToken>()
        let title = Self.discardTitle(drafts: count, trashed: trashed.count)
        let entry = UndoEntry(change: .custom { [weak self] in self?.restoreDrafts(result, trash, leaving, trashed: trashed.count) },
                              threads: leaving, expires: true)
        showToast(title, undo: entry, duration: Self.discardUndoSeconds)
        writes.async {
            do {
                result.value = try write(drafts, hold)
                if !trashed.isEmpty { trash.value = try store.perform(.trash, on: trashed) }
            } catch {
                if let discarded = result.value { _ = try? drafts.restore(discarded) }
                DispatchQueue.main.async { MainActor.assumeIsolated { self.writeFailed(error, unhide: leaving, entry: entry) } }
                return
            }
            let refused = result.value?.refused.count ?? 0, discarded = result.value?.count ?? 0
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.committed(leaving)
                    if discarded == 0, trashed.isEmpty {
                        self.undoStack.removeAll { $0.id == entry.id }
                        self.toasts.removeAll { $0.undo?.id == entry.id }
                    } else if let index = self.toasts.firstIndex(where: { $0.undo?.id == entry.id }) {
                        // Some drafts were refused, or a row held more than one.
                        self.toasts[index].title = Self.discardTitle(drafts: discarded, trashed: trashed.count)
                    }
                    guard refused > 0 else { return }
                    self.showToast(refused == 1 ? "A draft being sent can't be discarded" : "Drafts being sent can't be discarded", undo: nil)
                }
            }
        }
    }

    private func restoreDrafts(_ result: WriteResult<DiscardedDrafts>, _ trash: WriteResult<UndoToken>, _ keys: [ThreadKey], trashed: Int) {
        pendingCursor = keys.first
        if trashed > 0, case .inbox = kind { prefs.clearedToday = max(0, prefs.clearedToday - trashed) }
        let drafts = services.drafts
        let store = self.store
        writes.async {
            var restored = RestoredDrafts()
            var failed = false
            do {
                if let token = trash.value { try store.undo(token) }
                if let discarded = result.value { restored = try drafts.restore(discarded) }
            } catch {
                failed = true
                NSLog("Tern: restoring drafts failed: \(error)")
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for key in keys { self.hidden[key] = nil }
                    self.rebuildSnapshot(.none)
                    if self.isSearching { self.refreshSearch() }
                    if let title = failed ? "Couldn't bring the drafts back" : Self.restoredTitle(restored) {
                        self.showToast(title, undo: nil)
                    }
                }
            }
        }
    }
}
