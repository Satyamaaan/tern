import Foundation
import GRDB
import UniformTypeIdentifiers

public enum DraftError: Error, Equatable {
    /// The draft is already queued or being sent.
    case notEditable
    /// There is no connected account to send from.
    case noAccount
}

/// What `send` and `scheduleSend` queued.
public struct SendReceipt: Hashable, Sendable {
    public var draftId: String
    public var opId: Int64
    /// When the sync engine may send it: the end of the undo window, or the scheduled time.
    public var notBefore: Date
}

/// Writes drafts and queues their Gmail operations. Every write runs on the database writer, off the
/// main thread; reads for opening a composer are small and indexed.
///
/// The sync engine owns `gmailDraftId`, `gmailMessageId` and the `sending`/`sent`/`failed` states;
/// saves here never overwrite them.
public struct DraftStore: Sendable {
    public let database: AppDatabase
    /// Pasted images and copies of attached files, one folder per draft.
    public let filesDirectory: URL

    /// A Gmail draft is updated at most this often while typing.
    public static let saveInterval: TimeInterval = 10
    public static let defaultUndoSeconds = 5

    /// `setting` keys.
    public enum SettingKey {
        /// Seconds Send waits so it can be undone. Default 5; 0 sends at once.
        public static let undoSeconds = "compose.undoSeconds"
        /// "off" stops signatures being inserted.
        public static let signatures = "compose.signatures"
        /// Account id new mail starts from when none is given.
        public static let defaultAccount = "compose.defaultAccount"
        /// Signature HTML for one account.
        public static func signature(_ accountId: String) -> String { "signature.\(accountId)" }
    }

    public init(_ database: AppDatabase, filesDirectory: URL? = nil) {
        self.database = database
        self.filesDirectory = filesDirectory
            ?? AppDatabase.defaultURL().deletingLastPathComponent().appendingPathComponent("Draft Files", isDirectory: true)
    }

    // MARK: Opening

    /// The starting content for a composer. Replies reuse an editing draft of the same kind in the thread.
    /// Nothing is written until the first `save`. Nil when the thread, draft or account is missing.
    public func makeDraft(_ intent: DraftIntent, now: Date = Date(), timeZone: TimeZone = .current) throws -> DraftContent? {
        try database.reader.read { db in try Self.makeDraft(db, intent, now: now, timeZone: timeZone) }
    }

    static func makeDraft(_ db: Database, _ intent: DraftIntent, now: Date, timeZone: TimeZone) throws -> DraftContent? {
        let accounts = try Account.order(Column("sortOrder"), Column("createdAt")).fetchAll(db)
        let own = Set(accounts.map(\.id))

        switch intent {
        case .existing(let id):
            // A draft the engine is sending (or has sent) can't be edited any more.
            guard let draft = try Draft.fetchOne(db, key: id), draft.state != .sending, draft.state != .sent else { return nil }
            return DraftContent(stored: draft)

        case .new(let accountId, let to):
            let preferred = try accountId ?? Setting.fetchOne(db, key: SettingKey.defaultAccount)?.value
            guard let account = accounts.first(where: { $0.id == preferred }) ?? accounts.first else { return nil }
            let draft = Draft(
                accountId: account.id, kind: .new, toList: RecipientParser.deduplicated(to),
                updatedAt: now, createdAt: now)
            return DraftContent(draft: draft, signatureHtml: try signatureHTML(db, accountId: account.id))

        case .reply(let key, let all):
            let kind: Draft.Kind = all ? .replyAll : .reply
            if let existing = try editingDraft(db, thread: key, kinds: [kind]) { return DraftContent(stored: existing) }
            guard let detail = try MailStore.fetchThreadDetail(db, key),
                  let original = detail.messages.last(where: { !$0.isDraft }) else { return nil }
            let recipients = DraftTemplate.replyRecipients(to: original, all: all, ownAddresses: own)
            let draft = Draft(
                accountId: key.accountId, threadId: key.threadId, replyToMessageId: original.id, kind: kind,
                toList: recipients.to, ccList: recipients.cc,
                subject: DraftTemplate.replySubject(original.subject.isEmpty ? detail.thread.subject : original.subject),
                updatedAt: now, createdAt: now)
            return DraftContent(
                draft: draft, signatureHtml: try signatureHTML(db, accountId: key.accountId),
                quoteHtml: DraftTemplate.quoteHTML(for: original, timeZone: timeZone))

        case .forward(let key):
            guard let detail = try MailStore.fetchThreadDetail(db, key),
                  let original = detail.messages.last(where: { !$0.isDraft }) else { return nil }
            let html = original.bodyHtml ?? ""
            let attachments = (detail.attachments[original.id] ?? []).compactMap { file -> DraftAttachment? in
                let contentId = file.isInline ? file.contentId : nil
                // Inline images travel only when the body still points at them.
                if file.isInline, !(contentId.map { html.contains("cid:\($0)") } ?? false) { return nil }
                return DraftAttachment(
                    path: file.localPath ?? "", filename: file.filename, mimeType: file.mimeType, size: file.size,
                    remote: RemoteAttachmentRef(
                        accountId: file.accountId, messageId: file.messageId, partId: file.partId,
                        attachmentId: file.attachmentId),
                    contentId: contentId)
            }
            let draft = Draft(
                accountId: key.accountId, threadId: key.threadId, replyToMessageId: original.id, kind: .forward,
                subject: DraftTemplate.forwardSubject(original.subject.isEmpty ? detail.thread.subject : original.subject),
                attachments: attachments, updatedAt: now, createdAt: now)
            return DraftContent(
                draft: draft, signatureHtml: try signatureHTML(db, accountId: key.accountId),
                quoteHtml: DraftTemplate.forwardHTML(for: original, timeZone: timeZone))
        }
    }

    public func draft(id: String) throws -> Draft? {
        try database.reader.read { db in try Draft.fetchOne(db, key: id) }
    }

    /// The draft the user is still writing in a thread, newest first; the reader opens it inline.
    public func editingDraft(inThread key: ThreadKey) throws -> Draft? {
        try database.reader.read { db in try Self.editingDraft(db, thread: key, kinds: [.reply, .replyAll, .forward]) }
    }

    static func editingDraft(_ db: Database, thread key: ThreadKey, kinds: [Draft.Kind]) throws -> Draft? {
        try Draft
            .filter(Column("accountId") == key.accountId && Column("threadId") == key.threadId)
            .filter(kinds.map(\.rawValue).contains(Column("kind")))
            .filter([Draft.State.editing.rawValue, Draft.State.failed.rawValue].contains(Column("state")))
            .order(Column("updatedAt").desc)
            .fetchOne(db)
    }

    /// Opens a Gmail draft that only exists as a `DRAFT` message (e.g. written in the browser): the
    /// local draft linked to it, or new content carrying its `gmailMessageId` (saved on first edit).
    public func importDraftMessage(_ key: MessageKey) throws -> DraftContent? {
        try database.reader.read { db in
            if let linked = try Draft.filter(Column("accountId") == key.accountId && Column("gmailMessageId") == key.messageId).fetchOne(db) {
                return DraftContent(stored: linked)
            }
            guard let message = try MailMessage.fetchOne(db, key: ["accountId": key.accountId, "id": key.messageId]) else {
                return nil
            }
            let replied = message.inReplyTo.flatMap { inReplyTo in
                try? MailMessage.filter(Column("accountId") == key.accountId && Column("rfcMessageId") == inReplyTo).fetchOne(db)
            }
            let html = message.bodyHtml ?? "<div>\(RichText.htmlEscaped(message.bodyText ?? message.snippet))</div>"
            let draft = Draft(
                accountId: key.accountId, gmailMessageId: message.id, threadId: message.threadId,
                replyToMessageId: replied?.id, kind: replied == nil ? .new : .reply,
                toList: message.toList, ccList: message.ccList, bccList: message.bccList, subject: message.subject,
                bodyHtml: html, updatedAt: message.date, createdAt: message.date)
            return DraftContent(stored: draft)
        }
    }

    // MARK: Saving

    /// Writes the draft's fields (recipients, subject, body, attachments, account) and schedules a
    /// Gmail draft update: at most one pending `saveDraft` op per draft, sent `saveInterval` after the
    /// first unsynced edit. Blank drafts stay local. Returns false when the draft is no longer editable.
    @discardableResult
    public func save(_ draft: Draft, now: Date = Date()) async throws -> Bool {
        try await database.writer.write { db in
            guard let saved = try Self.writeFields(db, draft, state: .editing, now: now) else { return false }
            if !DraftContent(stored: saved).isBlank { try Self.queueSave(db, saved, now: now) }
            return true
        }
    }

    /// Inserts or updates the user-owned columns. Nil when the stored draft is queued or sending.
    static func writeFields(_ db: Database, _ draft: Draft, state: Draft.State, now: Date) throws -> Draft? {
        guard var stored = try Draft.fetchOne(db, key: draft.id) else {
            var fresh = draft
            fresh.state = state
            fresh.updatedAt = now
            fresh.lastError = nil
            try fresh.insert(db)
            return fresh
        }
        guard stored.state == .editing || stored.state == .failed else { return nil }
        if stored.accountId != draft.accountId {
            // The Gmail draft lives in the old account: remove it there and start again in the new one.
            if let gmailDraftId = stored.gmailDraftId {
                try queueOp(db, .deleteDraft, accountId: stored.accountId,
                            payload: DraftOpPayload(draftId: stored.id, gmailDraftId: gmailDraftId), now: now)
            }
            try deleteOps(db, draftId: stored.id, kinds: [.saveDraft, .sendDraft])
            stored.gmailDraftId = nil
            stored.gmailMessageId = nil
            stored.accountId = draft.accountId
        }
        stored.threadId = draft.threadId
        stored.replyToMessageId = draft.replyToMessageId
        stored.kind = draft.kind
        stored.toList = draft.toList
        stored.ccList = draft.ccList
        stored.bccList = draft.bccList
        stored.subject = draft.subject
        stored.bodyHtml = draft.bodyHtml
        stored.attachments = draft.attachments
        stored.scheduledAt = draft.scheduledAt
        stored.state = state
        stored.lastError = nil
        stored.updatedAt = now
        if stored.gmailMessageId == nil { stored.gmailMessageId = draft.gmailMessageId }
        try stored.update(db)
        return stored
    }

    static func queueSave(_ db: Database, _ draft: Draft, now: Date) throws {
        let pending = try pendingOps(db, draftId: draft.id, kinds: [.saveDraft])
        guard pending.isEmpty else { return }
        try queueOp(db, .saveDraft, accountId: draft.accountId, payload: DraftOpPayload(draftId: draft.id),
                    now: now, notBefore: now.addingTimeInterval(saveInterval))
    }

    // MARK: Sending

    /// Saves the draft as `queued` and queues `sendDraft` with `notBefore` at the end of the undo window
    /// (`undoSeconds`, else the `compose.undoSeconds` setting, else 5). Pending saves are dropped; the
    /// recipients count as contacted for autocomplete.
    @discardableResult
    public func send(_ draft: Draft, undoSeconds: Int? = nil, now: Date = Date()) async throws -> SendReceipt {
        let seconds = try undoSeconds ?? self.undoSeconds()
        var draft = draft
        draft.scheduledAt = nil
        return try await queueSend(draft, notBefore: now.addingTimeInterval(TimeInterval(max(0, seconds))), now: now)
    }

    /// Send later: like `send`, but the op waits until `date`. Tern has to be running then.
    @discardableResult
    public func scheduleSend(_ draft: Draft, at date: Date, now: Date = Date()) async throws -> SendReceipt {
        var draft = draft
        draft.scheduledAt = date
        return try await queueSend(draft, notBefore: date, now: now)
    }

    private func queueSend(_ draft: Draft, notBefore: Date, now: Date) async throws -> SendReceipt {
        try await database.writer.write { db in
            guard let saved = try Self.writeFields(db, draft, state: .queued, now: now) else { throw DraftError.notEditable }
            try Self.deleteOps(db, draftId: saved.id, kinds: [.saveDraft, .sendDraft])
            let op = try Self.queueOp(db, .sendDraft, accountId: saved.accountId,
                                      payload: DraftOpPayload(draftId: saved.id), now: now, notBefore: notBefore)
            try Self.noteContacted(db, saved.toList + saved.ccList + saved.bccList, at: now)
            return SendReceipt(draftId: saved.id, opId: op.id ?? 0, notBefore: notBefore)
        }
    }

    /// Undo send / cancel a scheduled send: removes the `sendDraft` op if the engine hasn't picked it up,
    /// and puts the draft back to `editing`. False when it's already on its way.
    @discardableResult
    public func cancelSend(_ draftId: String, now: Date = Date()) async throws -> Bool {
        try await database.writer.write { db in
            guard var draft = try Draft.fetchOne(db, key: draftId), draft.state == .queued else { return false }
            let ops = try Self.pendingOps(db, draftId: draftId, kinds: [.sendDraft])
            guard !ops.isEmpty else { return false }
            try Self.deleteOps(db, draftId: draftId, kinds: [.sendDraft])
            draft.state = .editing
            draft.scheduledAt = nil
            draft.updatedAt = now
            try draft.update(db)
            if !DraftContent(stored: draft).isBlank { try Self.queueSave(db, draft, now: now) }
            return true
        }
    }

    /// Deletes the draft, its pending ops and files; queues `deleteDraft` when Gmail has a copy. Also
    /// removes the local `DRAFT` message so lists update at once. False when it is being sent.
    @discardableResult
    public func discard(_ draftId: String) async throws -> Bool {
        let removed = try await database.writer.write { db -> Bool in
            guard let draft = try Draft.fetchOne(db, key: draftId) else { return true }
            let sending = try PendingOp
                .filter(sql: "kind = 'sendDraft' AND state = 'inflight' AND json_extract(payload, '$.draftId') = ?", arguments: [draftId])
                .fetchCount(db)
            guard draft.state != .sending, sending == 0 else { return false }
            try Self.deleteOps(db, draftId: draftId, kinds: [.saveDraft, .sendDraft])
            if let gmailDraftId = draft.gmailDraftId {
                try Self.queueOp(db, .deleteDraft, accountId: draft.accountId,
                                 payload: DraftOpPayload(draftId: draftId, gmailDraftId: gmailDraftId), now: Date())
            }
            if let messageId = draft.gmailMessageId {
                try MailStore.deleteMessages(db, accountId: draft.accountId, ids: [messageId])
            }
            try Draft.deleteOne(db, key: draftId)
            return true
        }
        if removed { try? FileManager.default.removeItem(at: folder(for: draftId)) }
        return removed
    }

    // MARK: Settings

    public func undoSeconds() throws -> Int {
        let value = try database.reader.read { db in try Setting.fetchOne(db, key: SettingKey.undoSeconds)?.value }
        return value.flatMap(Int.init) ?? Self.defaultUndoSeconds
    }

    /// The account's signature, or nil when it has none or signatures are off.
    public func signature(accountId: String) throws -> String? {
        try database.reader.read { db in try Self.signatureHTML(db, accountId: accountId) }
    }

    public func setSignature(_ html: String?, accountId: String) async throws {
        try await database.writer.write { db in
            let key = SettingKey.signature(accountId)
            if let html, !html.isEmpty { try Setting(key: key, value: html).upsert(db) } else { _ = try Setting.deleteOne(db, key: key) }
        }
    }

    static func signatureHTML(_ db: Database, accountId: String) throws -> String? {
        guard try Setting.fetchOne(db, key: SettingKey.signatures)?.value != "off" else { return nil }
        let html = try Setting.fetchOne(db, key: SettingKey.signature(accountId))?.value
        return html?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? html : nil
    }

    // MARK: Files

    /// The folder holding a draft's own files.
    public func folder(for draftId: String) -> URL {
        filesDirectory.appendingPathComponent(draftId, isDirectory: true)
    }

    /// Copies a file into the draft's folder (a clone on APFS, so instant) and describes it.
    public func addFile(_ url: URL, to draftId: String) async throws -> DraftAttachment {
        let folder = folder(for: draftId)
        return try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = Self.uniqueURL(in: folder, filename: url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: destination)
            return Self.attachment(at: destination)
        }.value
    }

    /// Writes pasted data (an image, usually) into the draft's folder.
    public func addData(_ data: Data, filename: String, to draftId: String) async throws -> DraftAttachment {
        let folder = folder(for: draftId)
        return try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = Self.uniqueURL(in: folder, filename: filename)
            try data.write(to: destination)
            return Self.attachment(at: destination)
        }.value
    }

    static func attachment(at url: URL) -> DraftAttachment {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let type = UTType(filenameExtension: url.pathExtension)
        return DraftAttachment(
            path: url.path, filename: url.lastPathComponent,
            mimeType: type?.preferredMIMEType ?? "application/octet-stream", size: size)
    }

    static func uniqueURL(in folder: URL, filename: String) -> URL {
        let name = filename.isEmpty ? "Attachment" : filename
        var candidate = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)")
            index += 1
        }
        return candidate
    }

    // MARK: Ops

    static func pendingOps(_ db: Database, draftId: String, kinds: [PendingOp.Kind]) throws -> [PendingOp] {
        try PendingOp
            .filter(kinds.map(\.rawValue).contains(Column("kind")))
            .filter(Column("state") == PendingOp.State.pending.rawValue)
            .filter(sql: "json_extract(payload, '$.draftId') = ?", arguments: [draftId])
            .fetchAll(db)
    }

    /// Removes ops the engine hasn't started.
    static func deleteOps(_ db: Database, draftId: String, kinds: [PendingOp.Kind]) throws {
        _ = try PendingOp
            .filter(kinds.map(\.rawValue).contains(Column("kind")))
            .filter(Column("state") == PendingOp.State.pending.rawValue)
            .filter(sql: "json_extract(payload, '$.draftId') = ?", arguments: [draftId])
            .deleteAll(db)
    }

    @discardableResult
    static func queueOp(
        _ db: Database, _ kind: PendingOp.Kind, accountId: String, payload: DraftOpPayload, now: Date, notBefore: Date? = nil
    ) throws -> PendingOp {
        var op = PendingOp(accountId: accountId, kind: kind, payload: try encodeJSON(payload), createdAt: now, notBefore: notBefore)
        try op.insert(db)
        op.id = db.lastInsertedRowID
        return op
    }
}
