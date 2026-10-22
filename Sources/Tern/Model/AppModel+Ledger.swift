import Foundation
import TernCore

extension AppModel {
    var inLedger: Bool { !isSearching && (kind == .waitingOn || kind == .iOwe) }

    var canChangeCommitments: Bool { (try? store.hasCommitments(on: targets)) ?? false }
    var hasOpenCommitments: Bool { (try? store.hasCommitments(on: targets, state: .open)) ?? false }
    var commitmentsAreDone: Bool { canChangeCommitments && !hasOpenCommitments }

    func toggleCommitmentDone(on keys: [ThreadKey]? = nil) {
        let keys = keys ?? targets
        guard (try? store.hasCommitments(on: keys)) == true else { return }
        let reopen = (try? store.hasCommitments(on: keys, state: .open)) == false
        changeCommitments(on: keys, to: reopen ? .open : .done)
    }

    func dismissCommitment() {
        guard hasOpenCommitments else { return }
        changeCommitments(on: targets, to: .dismissed)
    }

    private func changeCommitments(on keys: [ThreadKey], to state: CommitmentState) {
        if inLedger, state != .open { hide(keys) }
        let store = self.store
        let result = WriteResult<LedgerUndo>()
        let title = state == .open ? "Reopened" : state == .done ? "Marked done" : "Dismissed"
        let entry = UndoEntry(change: .ledger(result), threads: keys)
        showToast(title, undo: entry)
        writes.async {
            do {
                let ids = try store.commitments(on: keys).filter { state == .open || $0.state == .open }.compactMap(\.id)
                result.value = try store.setCommitmentState(ids, to: state)
            } catch {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.writeFailed(error, unhide: keys, entry: entry) }
                }
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.committed(keys.filter { self.hidden[$0] != nil })
                    if self.isSearching { self.refreshSearch() }
                }
            }
        }
    }
}
