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

    /// Some target holds a draft (⌘K Discard Draft).
    var targetsHoldDrafts: Bool { targets.contains(where: holdsDraft) }

    /// Discards the drafts of rows. A draft row leaves the list in the same frame; a conversation a draft
    /// replies to stays, without the draft.
    func discardDrafts(_ keys: [ThreadKey]) {
        let keys = keys.filter(holdsDraft)
        guard !keys.isEmpty else { return }
        let leaving = isSearching ? [] : keys.filter { isDraftRow($0) && snapshot.rows[$0] != nil }
        discard(leaving: leaving, title: keys.count > 1 ? "\(keys.count) drafts discarded" : "Draft discarded") { drafts, hold in
            try drafts.discardDrafts(inThreads: keys, holdFor: hold)
        }
    }

    /// The reader's Discard beside one draft of a conversation.
    func discardDraft(_ message: MessageKey, in thread: ThreadKey) {
        let leaving = !isSearching && isDraftRow(thread) && snapshot.rows[thread] != nil ? [thread] : []
        discard(leaving: leaving, title: "Draft discarded") { drafts, hold in
            try drafts.discardDrafts([.message(message)], holdFor: hold)
        }
    }

    private func discard(
        leaving: [ThreadKey], title: String, _ write: @escaping @Sendable (DraftStore, TimeInterval) throws -> DiscardedDrafts
    ) {
        if !leaving.isEmpty { hide(leaving) }
        let drafts = services.drafts
        let hold = Self.discardUndoSeconds + Self.discardHoldMargin
        let result = WriteResult<DiscardedDrafts>()
        let entry = UndoEntry(change: .custom { [weak self] in self?.restoreDrafts(result, leaving) }, threads: leaving, expires: true)
        showToast(title, undo: entry, duration: Self.discardUndoSeconds)
        writes.async {
            do {
                result.value = try write(drafts, hold)
            } catch {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.writeFailed(error, unhide: leaving, entry: entry) } }
                return
            }
            let refused = result.value?.refused.count ?? 0, discarded = result.value?.count ?? 0
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.committed(leaving)
                    guard refused > 0 else { return }
                    if discarded == 0 {
                        self.undoStack.removeAll { $0.id == entry.id }
                        self.toasts.removeAll { $0.undo?.id == entry.id }
                    }
                    self.showToast(refused == 1 ? "A draft being sent can't be discarded" : "Drafts being sent can't be discarded", undo: nil)
                }
            }
        }
    }

    private func restoreDrafts(_ result: WriteResult<DiscardedDrafts>, _ keys: [ThreadKey]) {
        pendingCursor = keys.first
        let drafts = services.drafts
        writes.async {
            var restored = true
            if let discarded = result.value {
                do {
                    restored = try drafts.restore(discarded)
                } catch {
                    restored = false
                    NSLog("Tern: restoring drafts failed: \(error)")
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for key in keys { self.hidden[key] = nil }
                    self.rebuildSnapshot(.none)
                    if self.isSearching { self.refreshSearch() }
                    if !restored { self.showToast("Gmail had already deleted the draft", undo: nil) }
                }
            }
        }
    }
}
