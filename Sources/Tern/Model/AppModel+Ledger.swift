import Foundation
import TernCore

extension AppModel {
    var canTrackCommitment: Bool {
        guard let key = readerVisible ? readerKey : targets.first else { return false }
        let participants = readerVisible ? services.reader.model?.detail?.thread.participants : row(key)?.thread.participants
        let own = Set(accounts.map { $0.email.lowercased() })
        return participants?.contains { !$0.email.isEmpty && !own.contains($0.email.lowercased()) } == true
    }

    var canReopenCommitment: Bool {
        if readerVisible, focus == .reader { return services.reader.model?.focusedCommitment?.state == .done }
        return targets.contains { row($0)?.ledger?.completion != nil }
    }

    func beginManualCommitment(_ direction: LedgerDirection) {
        guard let key = readerVisible ? readerKey : targets.first, let detail = try? store.threadDetail(key),
              !detail.messages.isEmpty else { return }
        let own = Set(accounts.map { $0.email.lowercased() })
        let person = detail.messages.reversed().flatMap { [Participant(name: $0.fromName, email: $0.fromEmail)] + $0.toList + $0.ccList }
            .first { !own.contains($0.email.lowercased()) }
        guard let person else { return }
        manualCommitment = ManualCommitmentDraft(key: key, direction: direction, deliverable: detail.thread.subject, person: person)
    }

    func saveManualCommitment(_ draft: ManualCommitmentDraft, deliverable: String, due: Date?) {
        guard !deliverable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let store = store
        let result = WriteResult<LedgerUndo>()
        let entry = UndoEntry(change: .ledger(result), threads: [draft.key])
        writes.async {
            do {
                result.value = try store.trackCommitment(on: draft.key, direction: draft.direction, deliverable: deliverable, counterparty: draft.person, dueAt: due)
                if !(result.value?.created.isEmpty ?? true) {
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.showToast("Tracking commitment", undo: entry) } }
                }
            }
            catch { DispatchQueue.main.async { MainActor.assumeIsolated { self.writeFailed(error, unhide: [], entry: entry) } } }
        }
    }

    var inLedger: Bool { !isSearching && (kind == .waitingOn || kind == .iOwe) }

    var canChangeCommitments: Bool { hasOpenCommitments }
    var hasOpenCommitments: Bool {
        if readerVisible, focus == .reader, services.reader.shows(readerKey) {
            return services.reader.model?.focusedCommitment?.state == .open
        }
        return inLedger && ((try? store.hasCommitments(on: targets, state: .open)) ?? false)
    }

    func markCommitmentsDone(on keys: [ThreadKey]? = nil) {
        guard inLedger || (readerVisible && focus == .reader && services.reader.shows(readerKey)) else { return }
        if keys == nil, readerVisible, focus == .reader, let item = services.reader.model?.focusedCommitment, item.state == .open {
            changeCommitment(item, to: .done); return
        }
        let keys = keys ?? targets
        guard (try? store.hasCommitments(on: keys, state: .open)) == true else { return }
        changeCommitments(on: keys, to: .done)
    }

    func reopenCommitment() {
        if readerVisible, focus == .reader, let item = services.reader.model?.focusedCommitment, item.state == .done {
            changeCommitment(item, to: .open)
        } else { changeCommitments(on: targets, to: .open) }
    }

    func changeCommitment(_ item: Commitment, to state: CommitmentState) {
        guard let id = item.id else { return }
        let store = store
        let result = WriteResult<LedgerUndo>()
        let key = ThreadKey(accountId: item.accountId, threadId: item.threadId)
        if inLedger, state != .open { hide([key]) }
        let entry = UndoEntry(change: .ledger(result), threads: [key])
        showToast(state == .open ? "Reopened" : state == .done ? "Marked done" : "Dismissed", undo: entry)
        writes.async {
            do {
                result.value = try store.setCommitmentState([id], to: state)
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    self.committed([key].filter { self.hidden[$0] != nil })
                    if self.isSearching { self.refreshSearch() }
                } }
            }
            catch { DispatchQueue.main.async { MainActor.assumeIsolated { self.writeFailed(error, unhide: [key], entry: entry) } } }
        }
    }

    func dismissCommitment() {
        guard hasOpenCommitments else { return }
        if readerVisible, focus == .reader, let item = services.reader.model?.focusedCommitment, item.state == .open {
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
                let ids = try store.commitments(on: keys).filter { $0.state == (state == .open ? .done : .open) && (state != .open || $0.updatedAt >= Date().addingTimeInterval(-14 * 86_400)) }.compactMap(\.id)
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
