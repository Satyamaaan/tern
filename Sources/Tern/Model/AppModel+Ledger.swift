import Foundation
import TernCore

extension AppModel {
    var inLedger: Bool { !isSearching && (kind == .waitingOn || kind == .iOwe) }

    var canChangeCommitments: Bool { hasOpenCommitments }
    var hasOpenCommitments: Bool { inLedger && ((try? store.hasCommitments(on: targets, state: .open)) ?? false) }

    func markCommitmentsDone(on keys: [ThreadKey]? = nil) {
        guard inLedger else { return }
        let keys = keys ?? targets
        guard (try? store.hasCommitments(on: keys, state: .open)) == true else { return }
        changeCommitments(on: keys, to: .done)
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
                let ids = try store.commitments(on: keys).filter { $0.state == .open }.compactMap(\.id)
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
