import Foundation
import GRDB
import TernCore

// The pending-op queue: user actions and drafts on their way to Gmail.
//
// Send later: the Gmail API has no scheduled send, so a draft scheduled for later is sent by Tern
// itself when its time comes, and only while Tern is running. A send that is due while Tern is
// closed goes out the next time it starts.
extension AccountSync {
    enum OpOutcome {
        case done
        /// Not yet; due again at this time. Later ops for the same messages or draft wait too.
        case deferred(Date)
        /// Offline or rate limited: stop draining until this time.
        case halt(Date)
    }

    /// Sends queued ops to Gmail in id order. A label op that is backing off holds back later label
    /// ops, so changes to the same messages land in order; draft ops only wait for earlier ops on
    /// the same draft. Ops whose `notBefore` hasn't come (undo-send window, send later, retry
    /// backoff) are skipped, and `nextOpAt` records when to come back.
    public func drainOps() async throws {
        // Bulk work drains between its requests (`serviceActions`); never two drains at once.
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        nextOpAt = nil
        for _ in 0..<50 {
            guard try await drainPass() else { break }
        }
    }

    private func drainPass() async throws -> Bool {
        let accountId = self.accountId
        let ops = try await read { db in try MailStore.queuedOps(db, accountId: accountId) }
        guard !ops.isEmpty else { return false }
        let now = clock.now()
        var labelsBlocked = false
        var blockedDrafts = Set<String>()
        var progressed = false

        for op in ops {
            let draftId = op.kind == .modifyLabels ? nil : AccountSync.draftId(of: op)
            func holdBack() {
                if op.kind == .modifyLabels { labelsBlocked = true } else if let draftId { blockedDrafts.insert(draftId) }
            }
            if op.kind == .modifyLabels ? labelsBlocked : draftId.map(blockedDrafts.contains) ?? false { continue }
            if let notBefore = op.notBefore, notBefore > now {
                holdBack()
                noteDue(notBefore)
                continue
            }
            switch try await execute(op, now: now) {
            case .done:
                progressed = true
            case .deferred(let date):
                holdBack()
                noteDue(date)
            case .halt(let date):
                noteDue(date)
                return false
            }
        }
        return progressed
    }

    private func noteDue(_ date: Date) {
        nextOpAt = min(nextOpAt ?? date, date)
    }

    private func execute(_ op: PendingOp, now: Date) async throws -> OpOutcome {
        do {
            switch op.kind {
            case .modifyLabels: try await sendLabelChanges(op)
            case .sendDraft: return try await sendDraft(op, now: now)
            case .saveDraft: try await saveDraft(op)
            case .deleteDraft: try await deleteDraft(op)
            }
            return .done
        } catch {
            return try await failed(op, error)
        }
    }

    // MARK: Labels

    /// One batchModify per distinct (add, remove) pair, at most `maxBatchModifyIds` ids each.
    private func sendLabelChanges(_ op: PendingOp) async throws {
        guard let opId = op.id else { return }
        guard let payload = try? JSONDecoder().decode(LabelOpPayload.self, from: Data(op.payload.utf8)) else {
            try await deleteOp(opId)
            return
        }
        try await setOpState(opId, .inflight)
        // Messages Gmail has deleted since (history removed them here) would fail the whole call.
        let accountId = self.accountId
        let ids = payload.changes.map(\.messageId)
        let stored = try await read { db in try MailStore.storedMessageIds(db, accountId: accountId, among: ids) }

        var groups: [(add: [String], remove: [String], ids: [String])] = []
        var groupIndex: [String: Int] = [:]
        for change in payload.changes where stored.contains(change.messageId) {
            let add = Array(Set(change.add)).sorted()
            let remove = Array(Set(change.remove)).sorted()
            guard !add.isEmpty || !remove.isEmpty else { continue }
            let key = add.joined(separator: ",") + "|" + remove.joined(separator: ",")
            if let index = groupIndex[key] {
                groups[index].ids.append(change.messageId)
            } else {
                groupIndex[key] = groups.count
                groups.append((add, remove, [change.messageId]))
            }
        }
        for group in groups {
            for chunk in group.ids.syncChunks(configuration.maxBatchModifyIds) {
                try await batchModify(chunk, add: group.add, remove: group.remove)
            }
        }
        try deleteOpNow(opId)
    }

    /// One batchModify. If Gmail rejects it because some messages were deleted meanwhile (which
    /// history hasn't told us yet), it is resent for the messages that still exist.
    private func batchModify(_ ids: [String], add: [String], remove: [String]) async throws {
        do {
            try await api.batchModify(messageIds: ids, add: add, remove: remove)
        } catch let error as GmailAPIError {
            switch error {
            case .notFound, .server(400, _): break
            default: throw error
            }
            let existing = Set(try await api.messages(ids: ids, format: .minimal).map(\.id))
            let remaining = ids.filter(existing.contains)
            guard remaining.count < ids.count else { throw error }
            if !remaining.isEmpty { try await api.batchModify(messageIds: remaining, add: add, remove: remove) }
        }
    }

    // MARK: Drafts
    //
    // `DraftStore` writes drafts and their ops; the engine sends what it wrote. While a send runs the
    // draft is `sending` and its op `inflight`, so the composer can't change or undo it. Once the
    // Gmail draft to send exists its id goes into the op payload (`sendingDraftId`): from then on
    // retries look in Sent first and only call drafts.send for it, and the send can't be undone, so a
    // lost response or a crash never sends twice. When drafts.send answers `notFound` and Sent
    // doesn't show the message, the send is unconfirmed (`unconfirmedSend`): it is never tried again.

    private enum DraftClaim: Sendable {
        case gone
        case wait(Date)
        case ready(Draft, Account)
    }

    /// The Message-ID every copy of a draft goes out with. Derived from the draft id, so it's the
    /// same on every attempt without storing anything, and a retry can look for a send or a Gmail
    /// draft that went through (`rfc822msgid:`). The engine sets it on whatever `encodeDraft`
    /// returns, so the MIME builder needn't, but may use it.
    public static func messageId(for draft: Draft, account: Account) -> String {
        let local = draft.id.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }
        let domain = account.email.split(separator: "@").last.map(String.init) ?? "tern.local"
        // FNV-1a keeps odd ids stable across launches (Swift's hashValue isn't).
        let name = local.isEmpty
            ? String(draft.id.utf8.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }, radix: 36)
            : local
        return "<tern.\(name)@\(domain)>"
    }

    /// The draft as RFC 822, forwarded files downloaded, with its stable Message-ID.
    private func encoded(_ draft: Draft, _ account: Account) async throws -> Data {
        let local = try await withLocalFiles(draft)
        return MailParsing.settingHeader("Message-ID", to: AccountSync.messageId(for: draft, account: account),
                                         in: try encodeDraft(local, account))
    }

    /// The draft's thread when it's one of this account's (a reply that moved to another account
    /// starts a new conversation there; Gmail rejects a threadId it doesn't know).
    private func threadToSend(_ draft: Draft) async throws -> String? {
        guard let threadId = draft.threadId else { return nil }
        let accountId = self.accountId
        let known = try await read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM message WHERE accountId = ? AND threadId = ? AND isDraft = 0)
                """, arguments: [accountId, threadId]) ?? false
        }
        return known ? threadId : nil
    }

    /// The sent message with this Message-ID, if Gmail has one (5 units).
    private func findSent(messageId: String) async throws -> GmailMessageRef? {
        let bare = messageId.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        let page = try await withRetry { [api] in
            try await api.messageIds(query: "rfc822msgid:\(bare) in:sent", labelIds: [], pageToken: nil, maxResults: 5)
        }
        return page.messages?.first
    }

    /// A Gmail draft this local draft already has but doesn't know the id of (5 units): one an
    /// earlier attempt created whose response was lost (found by the stable Message-ID), or the
    /// browser draft it was opened from (`gmailMessageId`, found by that message's Message-ID).
    private func existingGmailDraft(_ draft: Draft, account: Account) async throws -> String? {
        guard !draftListUnsupported else { return nil }
        var wanted = [AccountSync.messageId(for: draft, account: account)]
        let accountId = self.accountId
        if let imported = draft.gmailMessageId,
           let rfc = try await read({ db in
               try String.fetchOne(db, sql: "SELECT rfcMessageId FROM message WHERE accountId = ? AND id = ?",
                                   arguments: [accountId, imported])
           }) {
            wanted.insert(rfc, at: 0)
        }
        for messageId in wanted {
            let bare = messageId.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
            let page: GmailDraftPage
            do {
                page = try await withRetry { [api] in
                    try await api.drafts(query: "rfc822msgid:\(bare)", pageToken: nil, maxResults: 5)
                }
            } catch GmailAPIError.server(501, GmailDraftPage.unsupported) {
                draftListUnsupported = true
                return nil
            }
            let drafts = page.drafts ?? []
            if let match = drafts.first(where: { $0.message?.id == draft.gmailMessageId }) ?? drafts.first { return match.id }
        }
        return nil
    }

    private enum SavedDraft {
        case saved(GmailDraft)
        /// Sending: the Gmail draft is gone because an earlier send of it went out.
        case alreadySent(GmailMessageRef)
    }

    /// Updates the draft's Gmail copy, creating it when there is none (or it was deleted elsewhere).
    /// Looks for a copy it doesn't know the id of first, so a lost create isn't repeated. For a send,
    /// a copy that's gone may have been sent by an earlier attempt: Sent is checked first.
    private func saveGmailDraft(_ draft: Draft, account: Account, raw: Data, threadId: String?,
                                forSend: Bool = false) async throws -> SavedDraft {
        var gmailDraftId = draft.gmailDraftId
        if gmailDraftId == nil { gmailDraftId = try await existingGmailDraft(draft, account: account) }
        if let gmailDraftId {
            do {
                return .saved(try await api.updateDraft(id: gmailDraftId, raw: raw, threadId: threadId))
            } catch GmailAPIError.notFound {
                if forSend, let sent = try await findSent(messageId: AccountSync.messageId(for: draft, account: account)) {
                    return .alreadySent(sent)
                }
                // Deleted in another client; make a new one.
            }
        }
        return .saved(try await api.createDraft(raw: raw, threadId: threadId))
    }

    /// Sends the draft once its undo window (`notBefore`) and `scheduledAt` have passed: downloads
    /// forwarded files, saves it as a Gmail draft (updating the one it has), sends that, then removes
    /// it locally, with its files, and stores the sent message so it shows in the thread at once.
    private func sendDraft(_ op: PendingOp, now: Date) async throws -> OpOutcome {
        guard let opId = op.id,
              let payload = try? JSONDecoder().decode(DraftOpPayload.self, from: Data(op.payload.utf8)) else {
            if let id = op.id { try await deleteOp(id) }
            return .done
        }
        let draftId = payload.draftId
        let accountId = self.accountId
        let claim = try await write { db -> DraftClaim in
            guard var draft = try Draft.fetchOne(db, key: draftId), draft.state != .sent, draft.accountId == accountId,
                  let account = try Account.fetchOne(db, key: accountId) else {
                _ = try PendingOp.deleteOne(db, key: opId)
                return .gone
            }
            if let scheduled = draft.scheduledAt, scheduled > now { return .wait(scheduled) }
            // Undone in the meantime?
            guard var fresh = try PendingOp.fetchOne(db, key: opId), fresh.state == .pending else { return .gone }
            fresh.state = .inflight
            try fresh.update(db)
            draft.state = .sending
            draft.lastError = nil
            try draft.update(db)
            return .ready(draft, account)
        }
        let draft: Draft, account: Account
        switch claim {
        case .gone: return .done
        case .wait(let date): return .deferred(date)
        case .ready(let claimedDraft, let claimedAccount): (draft, account) = (claimedDraft, claimedAccount)
        }

        var draftMessageIds = draft.gmailMessageId.map { [$0] } ?? []
        var ref: GmailMessageRef?
        // A retry after a 5xx, a network error or a quit: Gmail may already have sent it.
        let isRetry = payload.sendingDraftId != nil || op.attempts > 0 || op.lastError != nil
        if isRetry, let sent = try await findSent(messageId: AccountSync.messageId(for: draft, account: account)) {
            ref = sent
        } else if let checks = payload.confirmChecks {
            return try unconfirmedSend(op, payload, checks: checks + 1, now: now)
        } else if let staged = payload.sendingDraftId {
            do {
                ref = try await api.sendDraft(id: staged)
            } catch GmailAPIError.notFound {
                // Gmail deletes a draft when it sends it, so an earlier attempt most likely went out
                // and Sent's search hasn't caught up; but the draft may have been deleted elsewhere.
                return try unconfirmedSend(op, payload, checks: 0, now: now)
            }
        } else {
            let raw = try await encoded(draft, account)
            switch try await saveGmailDraft(draft, account: account, raw: raw, threadId: try await threadToSend(draft), forSend: true) {
            case .alreadySent(let sent):
                ref = sent
            case .saved(let saved):
                if let messageId = saved.message?.id { draftMessageIds.append(messageId) }
                var staged = payload
                staged.sendingDraftId = saved.id
                let stagedJSON = String(decoding: try JSONEncoder().encode(staged), as: UTF8.self)
                try writeNow { db in
                    try db.execute(sql: "UPDATE pending_op SET payload = ? WHERE id = ?", arguments: [stagedJSON, opId])
                    if var row = try Draft.fetchOne(db, key: draftId) {
                        row.gmailDraftId = saved.id
                        if let messageId = saved.message?.id { row.gmailMessageId = messageId }
                        try row.update(db)
                    }
                }
                ref = try await api.sendDraft(id: saved.id)
            }
        }

        // Sent. Nothing below may reach the retry path.
        var parsed: [ParsedMessage] = []
        if let ref {
            let fetched = (try? await withRetry { [api] in try await api.messages(ids: [ref.id], format: .full) }) ?? []
            parsed = fetched.map { GmailMessageParser.parse($0, accountId: accountId, accountEmail: account.email, format: .full) }
        }
        let removedMessages = draftMessageIds
        do {
            try writeNow { db in
                for other in try MailStore.draftOps(db, draftId: draftId) where other.kind != .deleteDraft { _ = try other.delete(db) }
                if var row = try Draft.fetchOne(db, key: draftId) {
                    row.state = .sent
                    if let ref { row.gmailMessageId = ref.id }
                    try row.update(db)
                    _ = try row.delete(db)
                }
                try MailStore.deleteMessages(db, accountId: accountId, ids: removedMessages)
                try MailStore.upsertServerMessages(db, parsed.map(\.message), attachments: parsed.flatMap(\.attachments))
            }
        } catch {
            // Sent all the same: never leave the draft "sending" with nothing behind it.
            _ = try? writeNow { db in
                _ = try PendingOp.deleteOne(db, key: opId)
                _ = try Draft.deleteOne(db, key: draftId)
            }
        }
        try? FileManager.default.removeItem(at: DraftStore.folder(for: draftId, in: configuration.draftFilesDirectory))
        return .done
    }

    /// A staged send whose Gmail draft is gone while Sent doesn't show the message, after `checks`
    /// further looks at Sent. Sent is checked again after each `sendConfirmationDelays` (the draft
    /// stays `queued`, so it can't be edited, undone or discarded meanwhile); drafts.send is never
    /// called again. If it never shows up, the op is dropped and the draft, with its files, is kept
    /// as `failed` with `DraftStore.unconfirmedSendError`: only the user can send it again.
    private func unconfirmedSend(_ op: PendingOp, _ payload: DraftOpPayload, checks: Int, now: Date) throws -> OpOutcome {
        guard let opId = op.id else { return .done }
        let draftId = payload.draftId
        let delays = configuration.sendConfirmationDelays
        guard checks < delays.count else {
            try writeNow { db in
                _ = try PendingOp.deleteOne(db, key: opId)
                guard var draft = try Draft.fetchOne(db, key: draftId), draft.state != .sent else { return }
                draft.state = .failed
                draft.lastError = DraftStore.unconfirmedSendError
                try draft.update(db)
            }
            return .done
        }
        var waiting = payload
        waiting.confirmChecks = checks
        let json = String(decoding: try JSONEncoder().encode(waiting), as: UTF8.self)
        let retryAt = now.addingTimeInterval(delays[checks])
        try writeNow { db in
            guard var row = try PendingOp.fetchOne(db, key: opId) else { return }
            row.payload = json
            row.state = .pending
            row.notBefore = retryAt
            try row.update(db)
            guard var draft = try Draft.fetchOne(db, key: draftId), draft.state != .sent else { return }
            draft.state = .queued
            draft.lastError = nil
            try draft.update(db)
        }
        return .deferred(retryAt)
    }

    /// Creates or updates the Gmail copy of a draft being written and records its ids on the row.
    /// When the draft was discarded or moved to another account meanwhile, the copy just saved
    /// isn't wanted: its deletion is queued.
    private func saveDraft(_ op: PendingOp) async throws {
        guard let opId = op.id, let draftId = AccountSync.draftId(of: op) else {
            if let id = op.id { try await deleteOp(id) }
            return
        }
        let accountId = self.accountId
        let claim = try await write { db -> DraftClaim in
            guard let draft = try Draft.fetchOne(db, key: draftId), draft.state != .sent, draft.state != .sending,
                  draft.accountId == accountId,
                  let account = try Account.fetchOne(db, key: accountId),
                  var fresh = try PendingOp.fetchOne(db, key: opId) else {
                _ = try PendingOp.deleteOne(db, key: opId)
                return .gone
            }
            fresh.state = .inflight
            try fresh.update(db)
            return .ready(draft, account)
        }
        guard case .ready(let draft, let account) = claim else { return }

        let raw = try await encoded(draft, account)
        guard case .saved(let saved) = try await saveGmailDraft(draft, account: account, raw: raw,
                                                                 threadId: try await threadToSend(draft)) else { return }
        try writeNow { db in
            if var row = try Draft.fetchOne(db, key: draftId), row.accountId == accountId, row.state != .sent {
                row.gmailDraftId = saved.id
                if let messageId = saved.message?.id { row.gmailMessageId = messageId }
                row.lastError = nil
                try row.update(db)
            } else {
                var cleanup = PendingOp(accountId: accountId, kind: .deleteDraft,
                                        payload: try String(decoding: JSONEncoder().encode(DraftOpPayload(draftId: draftId, gmailDraftId: saved.id)), as: UTF8.self))
                try cleanup.insert(db)
            }
            _ = try PendingOp.deleteOne(db, key: opId)
        }
    }

    /// Deletes a Gmail draft. `DraftStore` has already removed the local draft (discard) or moved
    /// it to another account, so only Gmail's copy goes; history then removes its message here.
    private func deleteDraft(_ op: PendingOp) async throws {
        guard let opId = op.id,
              let payload = try? JSONDecoder().decode(DraftOpPayload.self, from: Data(op.payload.utf8)) else {
            if let id = op.id { try await deleteOp(id) }
            return
        }
        var gmailDraftId = payload.gmailDraftId
        if gmailDraftId == nil {
            let accountId = self.accountId
            gmailDraftId = try await read { db in
                try Draft.fetchOne(db, key: payload.draftId).flatMap { $0.accountId == accountId ? $0.gmailDraftId : nil }
            }
        }
        try await setOpState(opId, .inflight)
        if let gmailDraftId {
            do {
                try await api.deleteDraft(id: gmailDraftId)
            } catch GmailAPIError.notFound {
                // Already gone on Gmail.
            }
        }
        try deleteOpNow(opId)
    }

    // MARK: Failures

    /// Unauthorized pauses the account; offline and rate limits wait without using up attempts;
    /// anything else backs off exponentially and fails for good after `maxOpAttempts`, rolling the
    /// local change back to what Gmail has.
    private func failed(_ op: PendingOp, _ error: Error) async throws -> OpOutcome {
        guard let opId = op.id else { return .done }
        let now = clock.now()
        let message = AccountSync.describe(error)
        let notBefore = op.notBefore

        switch error as? GmailAPIError {
        case .unauthorized?:
            try await updateOp(opId) { $0.state = .pending }
            try await restoreDraftState(op, state: .queued, error: nil)
            throw GmailAPIError.unauthorized
        case .network?, .rateLimited?:
            var delay = backoff(consecutiveFailures + 1)
            if case .rateLimited(let retryAfter?)? = error as? GmailAPIError { delay = retryAfter }
            let retryAt = now.addingTimeInterval(delay)
            try await updateOp(opId) {
                $0.state = .pending
                $0.lastError = message
                $0.notBefore = max(notBefore ?? retryAt, retryAt)
            }
            try await restoreDraftState(op, state: .queued, error: message)
            return .halt(retryAt)
        default:
            let attempts = op.attempts + 1
            // A staged send may already have gone out: on a server error it's never made editable
            // (Send again could then deliver it twice); it keeps retrying, at most every few minutes.
            let transient: Bool
            if case .server(let status, _)? = error as? GmailAPIError, status >= 500 { transient = true } else { transient = false }
            if attempts >= configuration.maxOpAttempts, !(transient && AccountSync.isStaged(op)) {
                try await updateOp(opId) {
                    $0.state = .failed
                    $0.attempts = attempts
                    $0.lastError = message
                }
                await rollBack(op, error: message)
                return .done
            }
            let retryAt = now.addingTimeInterval(backoff(attempts))
            try await updateOp(opId) {
                $0.state = .pending
                $0.attempts = attempts
                $0.lastError = message
                $0.notBefore = max(notBefore ?? retryAt, retryAt)
            }
            try await restoreDraftState(op, state: .queued, error: message)
            return .deferred(retryAt)
        }
    }

    /// After an op fails for good: labels go back to Gmail's, a failed send marks its draft failed.
    private func rollBack(_ op: PendingOp, error: String) async {
        let accountId = self.accountId
        switch op.kind {
        case .modifyLabels:
            guard let payload = try? JSONDecoder().decode(LabelOpPayload.self, from: Data(op.payload.utf8)) else { return }
            let ids = Array(Set(payload.changes.map(\.messageId)))
            for chunk in ids.syncChunks(batchSize(cost: configuration.quota.getMessage)) {
                guard let fetched = try? await api.messages(ids: chunk, format: .minimal) else { return }
                var labels: [String: [String]] = [:]
                for message in fetched { labels[message.id] = message.labelIds ?? [] }
                let update = labels
                _ = try? await write { db in try MailStore.applyServerLabels(db, accountId: accountId, update) }
            }
        case .sendDraft:
            try? await restoreDraftState(op, state: .failed, error: error)
        case .saveDraft, .deleteDraft:
            try? await restoreDraftState(op, state: nil, error: error)
        }
    }

    /// Puts a send's draft back to `state` (nil keeps it) with `error`. No-op for label and delete ops.
    private func restoreDraftState(_ op: PendingOp, state: Draft.State?, error: String?) async throws {
        // A deleteDraft's local draft is gone or lives on in another account.
        guard op.kind == .sendDraft || op.kind == .saveDraft, let draftId = AccountSync.draftId(of: op) else { return }
        let isSend = op.kind == .sendDraft
        try writeNow { db in
            guard var draft = try Draft.fetchOne(db, key: draftId), draft.state != .sent else { return }
            if let state, isSend || state == .failed { draft.state = state }
            draft.lastError = error
            try draft.update(db)
        }
    }

    // MARK: Helpers

    static func draftId(of op: PendingOp) -> String? {
        (try? JSONDecoder().decode(DraftOpPayload.self, from: Data(op.payload.utf8)))?.draftId
    }

    /// A send whose Gmail draft exists and may already have been sent.
    static func isStaged(_ op: PendingOp) -> Bool {
        op.kind == .sendDraft && (try? JSONDecoder().decode(DraftOpPayload.self, from: Data(op.payload.utf8)))?.sendingDraftId != nil
    }

    private func setOpState(_ id: Int64, _ state: PendingOp.State) async throws {
        try await updateOp(id) { $0.state = state }
    }

    private func deleteOp(_ id: Int64) async throws {
        try deleteOpNow(id)
    }

    private func deleteOpNow(_ id: Int64) throws {
        _ = try writeNow { db in try PendingOp.deleteOne(db, key: id) }
    }

    /// Changes the stored op if it still exists (undo may have removed it).
    private func updateOp(_ id: Int64, _ change: @escaping @Sendable (inout PendingOp) -> Void) async throws {
        try writeNow { db in
            guard var op = try PendingOp.fetchOne(db, key: id) else { return }
            change(&op)
            try op.update(db)
        }
    }
}
