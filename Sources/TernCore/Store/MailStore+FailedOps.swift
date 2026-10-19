import Foundation
import GRDB

// Failed ops are what the sidebar counts as "didn't reach Gmail". Gmail rejected them for good and
// their local change was rolled back; they stay as a notice while the change could still matter.
extension MailStore {
    /// Deletes the account's failed ops that no longer matter:
    /// - label changes whose messages are all gone, that name a user label the account no longer has,
    ///   or that are true of every message's labels by now (done again here or in Gmail);
    /// - Gmail saves of a draft that is gone, being sent or sent again, or in another account;
    /// - sends of a draft that is gone, or that the user has taken back to edit or send again.
    public static func pruneFailedOps(_ db: Database, accountId: String) throws {
        let failed = try PendingOp
            .filter(Column("accountId") == accountId && Column("state") == PendingOp.State.failed.rawValue)
            .fetchAll(db)
        guard !failed.isEmpty else { return }
        let labels = Set(try String.fetchAll(db, sql: "SELECT id FROM label WHERE accountId = ?", arguments: [accountId]))
        for op in failed where !(try stillMatters(db, op, labels: labels)) {
            try op.delete(db)
        }
    }

    private static func stillMatters(_ db: Database, _ op: PendingOp, labels: Set<String>) throws -> Bool {
        switch op.kind {
        case .modifyLabels:
            guard let payload = try? JSONDecoder().decode(LabelOpPayload.self, from: Data(op.payload.utf8)) else { return false }
            let named = Set(payload.changes.flatMap { $0.requestAdd + $0.requestRemove }).subtracting(SystemLabel.all)
            if !labels.isEmpty, !named.isSubset(of: labels) { return false }
            let current = try messageLabels(db, accountId: op.accountId, messageIds: payload.changes.map(\.messageId))
            return payload.changes.contains { change in
                guard let now = current[change.messageId] else { return false }
                return !Set(change.requestAdd).isSubset(of: now) || !Set(change.requestRemove).isDisjoint(with: now)
            }
        case .saveDraft, .sendDraft:
            guard let draftId = (try? JSONDecoder().decode(DraftOpPayload.self, from: Data(op.payload.utf8)))?.draftId,
                  let draft = try Draft.fetchOne(db, key: draftId), draft.accountId == op.accountId else { return false }
            return op.kind == .saveDraft ? draft.state == .editing || draft.state == .failed : draft.state == .failed
        case .deleteDraft:
            return true
        }
    }
}
