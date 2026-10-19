import Foundation
import GRDB

/// A draft to discard.
public enum DraftRef: Hashable, Sendable {
    /// A local draft, by id.
    case draft(String)
    /// A DRAFT message: the local draft linked to it, else the Gmail draft alone (one written on the
    /// phone or the web, which Tern only knows as this message).
    case message(MessageKey)
}

/// What `discardDrafts` took away, kept so `restore` can put it back as it was. The drafts' Gmail
/// copies are deleted only once the hold of their `deleteDraft` ops has passed.
public struct DiscardedDrafts: Sendable, Hashable {
    struct Item: Sendable, Hashable {
        /// The local draft as it was; nil for a Gmail draft Tern had no row for.
        var draft: Draft?
        /// Its DRAFT message, when one was stored, with its attachments.
        var message: MailMessage?
        var attachments: [MailAttachment]
        /// Its saves and sends that hadn't gone out, removed with it.
        var ops: [PendingOp]
        /// The held op that deletes its Gmail copy.
        var deleteOpId: Int64
    }

    var items: [Item] = []
    /// Classification and projects of the threads the drafts were in, which go with a thread that
    /// held nothing else.
    var threadAI: [ThreadAI] = []
    var projects: [ThreadProject] = []
    /// Drafts left alone because they are being sent, or a send of them may have gone out.
    public internal(set) var refused: [DraftRef] = []

    /// How many drafts were discarded.
    public var count: Int { items.count }
}

/// What `restore` brought back.
public struct RestoredDrafts: Sendable, Hashable {
    /// Back as they were.
    public var exact = 0
    /// Local drafts whose Gmail copy was already deleted: back, saving a new copy.
    public var resaved = 0
    /// Gmail drafts Tern had no row for that Gmail had already deleted: gone.
    public var lost = 0
    /// Sent from another device meanwhile: they stay sent.
    public var sent = 0

    public init(exact: Int = 0, resaved: Int = 0, lost: Int = 0, sent: Int = 0) {
        self.exact = exact
        self.resaved = resaved
        self.lost = lost
        self.sent = sent
    }
}

extension DraftStore {
    /// `DraftOpPayload.draftId` of the deletion of a Gmail draft Tern had no local row for.
    static let gmailDraftPrefix = "gmail-message:"

    /// The drafts list rows stand for: a local draft's own row (`MailThread.localDraftId`), else every
    /// DRAFT message of the thread. The conversation a draft replies to is never part of it.
    public static func draftRefs(_ db: Database, in keys: [ThreadKey]) throws -> [DraftRef] {
        var refs: [DraftRef] = []
        for key in keys {
            if let id = MailThread.localDraftId(in: key) {
                refs.append(.draft(id))
                continue
            }
            let ids = try String.fetchAll(db, sql: """
                SELECT id FROM message WHERE accountId = ? AND threadId = ? AND isDraft = 1 ORDER BY date
                """, arguments: [key.accountId, key.threadId])
            refs += ids.map { .message(MessageKey(accountId: key.accountId, messageId: $0)) }
        }
        return refs
    }

    /// Discards the drafts of list rows (`draftRefs`); see `discardDrafts(_:holdFor:now:)`.
    public func discardDrafts(inThreads keys: [ThreadKey], holdFor hold: TimeInterval, now: Date = Date()) throws -> DiscardedDrafts {
        try database.writer.write { db in try Self.discardDrafts(db, Self.draftRefs(db, in: keys), holdFor: hold, now: now) }
    }

    /// Takes drafts out of Tern at once (local rows, their pending saves and sends, their DRAFT messages,
    /// so every list and the reader drop them) and queues the deletion of their Gmail copies to run once
    /// `hold` has passed; `restore` before then puts everything back exactly. Files stay until the deletion
    /// runs. A draft being sent, or whose send may have gone out, is left alone and listed in `refused`.
    public func discardDrafts(_ refs: [DraftRef], holdFor hold: TimeInterval, now: Date = Date()) throws -> DiscardedDrafts {
        try database.writer.write { db in try Self.discardDrafts(db, refs, holdFor: hold, now: now) }
    }

    static func discardDrafts(_ db: Database, _ refs: [DraftRef], holdFor hold: TimeInterval, now: Date) throws -> DiscardedDrafts {
        var discarded = DiscardedDrafts()
        var seenDrafts = Set<String>()
        var seenMessages = Set<MessageKey>()
        var threads = Set<ThreadKey>()

        for ref in refs {
            var draft: Draft?
            var messageKey: MessageKey?
            switch ref {
            case .draft(let id):
                guard let row = try Draft.fetchOne(db, key: id) else { continue }
                draft = row
            case .message(let key):
                draft = try Draft.filter(Column("accountId") == key.accountId && Column("gmailMessageId") == key.messageId).fetchOne(db)
                messageKey = key
            }
            if let draft {
                guard seenDrafts.insert(draft.id).inserted else { continue }
                if try isBeingSent(db, draft) {
                    discarded.refused.append(ref)
                    continue
                }
                messageKey = draft.gmailMessageId.map { MessageKey(accountId: draft.accountId, messageId: $0) }
            }
            if let key = messageKey, !seenMessages.insert(key).inserted, draft == nil { continue }

            // Only a message that is still a draft goes; nothing that was sent.
            let message = try messageKey.flatMap { key in
                try MailMessage.fetchOne(db, key: ["accountId": key.accountId, "id": key.messageId])
            }.flatMap { $0.isDraft ? $0 : nil }
            guard draft != nil || message != nil else { continue }

            var attachments: [MailAttachment] = []
            if let message {
                attachments = try MailAttachment
                    .filter(Column("accountId") == message.accountId && Column("messageId") == message.id)
                    .fetchAll(db)
                if threads.insert(message.threadKey).inserted {
                    let key = ["accountId": message.accountId, "threadId": message.threadId]
                    if let ai = try ThreadAI.fetchOne(db, key: key) { discarded.threadAI.append(ai) }
                    discarded.projects += try ThreadProject
                        .filter(Column("accountId") == message.accountId && Column("threadId") == message.threadId)
                        .fetchAll(db)
                }
                try MailStore.deleteMessages(db, accountId: message.accountId, ids: [message.id])
            }

            var ops: [PendingOp] = []
            if let draft {
                ops = try PendingOp
                    .filter([PendingOp.Kind.saveDraft.rawValue, PendingOp.Kind.sendDraft.rawValue].contains(Column("kind")))
                    .filter([PendingOp.State.pending.rawValue, PendingOp.State.failed.rawValue].contains(Column("state")))
                    .filter(sql: "json_extract(payload, '$.draftId') = ?", arguments: [draft.id])
                    .order(Column("id"))
                    .fetchAll(db)
                for op in ops { try op.delete(db) }
                try Draft.deleteOne(db, key: draft.id)
            }

            let accountId = draft?.accountId ?? message?.accountId ?? ""
            let payload = DraftOpPayload(
                draftId: draft?.id ?? gmailDraftPrefix + (message?.id ?? ""), gmailDraftId: draft?.gmailDraftId,
                gmailMessageId: message?.id ?? draft?.gmailMessageId, rfcMessageId: message?.rfcMessageId)
            let op = try queueOp(db, .deleteDraft, accountId: accountId, payload: payload, now: now,
                                 notBefore: now.addingTimeInterval(hold))
            discarded.items.append(DiscardedDrafts.Item(
                draft: draft, message: message, attachments: attachments, ops: ops, deleteOpId: op.id ?? 0))
        }
        return discarded
    }

    /// Whether the draft is being sent, or a send of it may already have gone out.
    static func isBeingSent(_ db: Database, _ draft: Draft) throws -> Bool {
        if draft.state == .sending { return true }
        let sends = try PendingOp
            .filter(Column("kind") == PendingOp.Kind.sendDraft.rawValue)
            .filter(sql: "json_extract(payload, '$.draftId') = ?", arguments: [draft.id])
            .fetchAll(db)
        return sends.contains { $0.state == .inflight || mayHaveGoneOut($0) }
    }

    /// Undo of `discardDrafts`. While a draft's Gmail deletion hasn't started it is dropped and the draft
    /// comes back exactly: its local row with its saves and sends, its DRAFT message and attachments (so it
    /// shows in the lists and the reader again), its thread's classification and projects. A save that was on
    /// its way at the discard and finished since left its Gmail ids on the deletion; the draft takes them and
    /// saves again, so its message comes back through sync. A local draft whose Gmail copy is already gone
    /// comes back without it and saves a new one; a Gmail draft Tern had no row for can't come back then.
    /// A draft sent from another device meanwhile (its message is in Tern now, and not a draft) stays sent:
    /// neither its DRAFT copy nor its local row comes back, and its deletion, left to run, deletes nothing.
    public func restore(_ discarded: DiscardedDrafts, now: Date = Date()) throws -> RestoredDrafts {
        try database.writer.write { db in
            var result = RestoredDrafts()
            var messages: [MailMessage] = []
            var attachments: [MailAttachment] = []
            for item in discarded.items {
                let held = try PendingOp.fetchOne(db, key: item.deleteOpId)
                let stopped = held.map { $0.state == .pending && !$0.dispatched } ?? false
                let payload = held.flatMap { try? JSONDecoder().decode(DraftOpPayload.self, from: Data($0.payload.utf8)) }
                if try Self.wasSent(db, item, payload) {
                    result.sent += 1
                    continue
                }
                if stopped { _ = try held?.delete(db) }
                guard var draft = item.draft else {
                    if stopped, let message = item.message {
                        messages.append(message)
                        attachments += item.attachments
                        result.exact += 1
                    } else {
                        result.lost += 1
                    }
                    continue
                }
                let saved = stopped && payload.map { $0.gmailDraftId != draft.gmailDraftId || $0.gmailMessageId != draft.gmailMessageId } == true
                if !stopped {
                    draft.gmailDraftId = nil
                    draft.gmailMessageId = nil
                } else if saved, let payload {
                    draft.gmailDraftId = payload.gmailDraftId
                    draft.gmailMessageId = payload.gmailMessageId
                }
                try draft.insert(db)
                for op in item.ops {
                    var copy = op
                    copy.id = nil
                    try copy.insert(db)
                }
                // A save or send coming back with it brings the message back; a failed one won't run.
                let queued = item.ops.contains { ($0.kind == .saveDraft || $0.kind == .sendDraft) && $0.state == .pending }
                if !stopped || saved, !queued, !DraftContent(stored: draft).isBlank {
                    try Self.queueSave(db, draft, now: now)
                }
                if stopped, !saved, let message = item.message {
                    messages.append(message)
                    attachments += item.attachments
                }
                if stopped { result.exact += 1 } else { result.resaved += 1 }
            }
            try MailStore.upsertServerMessages(db, messages, attachments: attachments)
            for ai in discarded.threadAI where try MailThread.exists(db, key: ["accountId": ai.accountId, "id": ai.threadId]) {
                try ai.insert(db, onConflict: .ignore)
            }
            for project in discarded.projects
            where try MailThread.exists(db, key: ["accountId": project.accountId, "id": project.threadId])
                && Project.exists(db, key: project.projectId) {
                try project.insert(db, onConflict: .ignore)
            }
            return result
        }
    }

    /// Whether a message of the discarded draft is in Tern now as something other than a draft: sent.
    private static func wasSent(_ db: Database, _ item: DiscardedDrafts.Item, _ payload: DraftOpPayload?) throws -> Bool {
        guard let accountId = item.draft?.accountId ?? item.message?.accountId else { return false }
        let ids = Set([item.message?.id, item.draft?.gmailMessageId, payload?.gmailMessageId].compactMap { $0 })
        guard !ids.isEmpty else { return false }
        return try MailMessage
            .filter(Column("accountId") == accountId && ids.contains(Column("id")) && Column("isDraft") == false)
            .fetchCount(db) > 0
    }
}
