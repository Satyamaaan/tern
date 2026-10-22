import Foundation
import TernCore

extension AppModel {
    func beginManualCommitment(_ direction: LedgerDirection) {
        guard let key = readerVisible ? readerKey : targets.first, let detail = try? store.threadDetail(key),
              let message = detail.messages.last(where: { !$0.isDraft }) else { return }
        let own = Set(accounts.map { $0.email.lowercased() })
        let person = ([Participant(name: message.fromName, email: message.fromEmail)] + message.toList + message.ccList)
            .first { !own.contains($0.email.lowercased()) }
        guard let person else { return }
        manualCommitment = ManualCommitmentDraft(key: key, direction: direction, deliverable: detail.thread.subject, person: person)
    }

    func saveManualCommitment(_ draft: ManualCommitmentDraft, deliverable: String, due: Date?) {
        let store = store
        let result = WriteResult<LedgerUndo>()
        let entry = UndoEntry(change: .ledger(result), threads: [draft.key])
        showToast("Tracking commitment", undo: entry)
        writes.async {
            do { result.value = try store.trackCommitment(on: draft.key, direction: draft.direction, deliverable: deliverable, counterparty: draft.person, dueAt: due) }
            catch { DispatchQueue.main.async { MainActor.assumeIsolated { self.writeFailed(error, unhide: [], entry: entry) } } }
        }
    }

    var inLedger: Bool { !isSearching && (kind == .waitingOn || kind == .iOwe) }

    var canChangeCommitments: Bool { hasOpenCommitments }
    var hasOpenCommitments: Bool {
        if readerVisible, focus == .reader, services.reader.shows(readerKey) {
            return services.reader.model?.detail?.commitments.contains { $0.state == .open } == true
        }
        return inLedger && ((try? store.hasCommitments(on: targets, state: .open)) ?? false)
    }

    func markCommitmentsDone(on keys: [ThreadKey]? = nil) {
        guard inLedger || (readerVisible && focus == .reader && services.reader.shows(readerKey)) else { return }
        if keys == nil, readerVisible, focus == .reader, let item = services.reader.model?.detail?.commitments.first(where: { $0.state == .open }) {
            changeCommitment(item, to: .done); return
        }
        let keys = keys ?? targets
        guard (try? store.hasCommitments(on: keys, state: .open)) == true else { return }
        changeCommitments(on: keys, to: .done)
    }

    func reopenCommitment() { changeCommitments(on: targets, to: .open) }

    func changeCommitment(_ item: Commitment, to state: CommitmentState) {
        guard let id = item.id else { return }
        let store = store
        let result = WriteResult<LedgerUndo>()
        let key = ThreadKey(accountId: item.accountId, threadId: item.threadId)
        let entry = UndoEntry(change: .ledger(result), threads: [key])
        showToast(state == .open ? "Reopened" : state == .done ? "Marked done" : "Dismissed", undo: entry)
        writes.async {
            do { result.value = try store.setCommitmentState([id], to: state) }
            catch { DispatchQueue.main.async { MainActor.assumeIsolated { self.writeFailed(error, unhide: [], entry: entry) } } }
        }
    }

    func dismissCommitment() {
        guard hasOpenCommitments else { return }
        if readerVisible, focus == .reader, let item = services.reader.model?.detail?.commitments.first(where: { $0.state == .open }) {
            changeCommitment(item, to: .dismissed); return
        }
        changeCommitments(on: targets, to: .dismissed)
    }

    func changeCommitments(on keys: [ThreadKey], to state: CommitmentState) {
        if inLedger, state != .open { hide(keys) }
        let store = self.store
        let result = WriteResult<LedgerUndo>()
        let title = state == .open ? "Reopened" : state == .done ? "Marked done" : "Dismissed"
        let entry = UndoEntry(change: .ledger(result), threads: keys)
        showToast(title, undo: entry)
        writes.async {
            do {
                let ids = try store.commitments(on: keys).filter { $0.state == (state == .open ? .done : .open) }.compactMap(\.id)
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
