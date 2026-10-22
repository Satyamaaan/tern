import Foundation
import GRDB

extension MailStore {
    /// Creates a user-owned item and returns an undo that removes exactly that item.
    public func trackCommitment(on key: ThreadKey, direction: LedgerDirection, deliverable: String,
                                counterparty: Participant, dueAt: Date?, now: Date = Date()) throws -> LedgerUndo {
        try database.writer.write { db in
            guard let detail = try Self.fetchThreadDetail(db, key), let last = detail.messages.last,
                  !deliverable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return LedgerUndo(previous: []) }
            let source = detail.messages.last(where: { message in
                !message.isDraft && (direction == .iOwe ? message.fromEmail.caseInsensitiveCompare(counterparty.email) == .orderedSame : message.isFromMe)
            }) ?? last
            var item = Commitment(id: nil, accountId: key.accountId, threadId: key.threadId, direction: direction,
                kind: "deliverable", counterpartyEmail: counterparty.email.lowercased(), counterpartyName: counterparty.name,
                deliverable: String(deliverable.trimmingCharacters(in: .whitespacesAndNewlines).prefix(90)), dueAt: dueAt, dueText: nil,
                sourceMessageId: source.id, sourceQuote: String(MailText.stripQuoted(source.bodyText ?? source.snippet).prefix(700)),
                sourceDate: source.date, origin: "manual", confidence: 2, state: .open, stateSource: "user",
                resolvedMessageId: nil, resolvedAt: nil, resolutionNote: nil, hintMessageId: nil, hintAt: nil,
                checkedCount: detail.thread.messageCount, surfaceAt: now, surfaced: true,
                fingerprint: "manual|" + UUID().uuidString, createdAt: now, updatedAt: now)
            try item.insert(db)
            item.id = db.lastInsertedRowID
            return LedgerUndo(previous: [], created: [item.id!])
        }
    }
}
