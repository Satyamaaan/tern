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
                do {
                    try await api.batchModify(messageIds: chunk, add: group.add, remove: group.remove)
                } catch GmailAPIError.notFound {
                    // The messages are gone; nothing left to change.
                }
            }
        }
        try await deleteOp(opId)
    }

    // MARK: Drafts

    private enum DraftClaim: Sendable {
        case gone
        case wait(Date)
        case ready(Draft, Account)
    }

    /// Sends the draft once its undo window (`notBefore`) and `scheduledAt` have passed, then
    /// removes it and stores the sent message so it shows in the thread at once.
    private func sendDraft(_ op: PendingOp, now: Date) async throws -> OpOutcome {
        guard let opId = op.id, let draftId = AccountSync.draftId(of: op) else {
            if let id = op.id { try await deleteOp(id) }
            return .done
        }
        let accountId = self.accountId
        let claim = try await write { db -> DraftClaim in
            guard var draft = try Draft.fetchOne(db, key: draftId), draft.state != .sent,
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

        let raw = try encodeDraft(draft, account)
        let ref = try await api.send(raw: raw, threadId: draft.threadId)

        // Sent. Nothing below may reach the retry path, or the message would go out twice.
        if let gmailDraftId = draft.gmailDraftId { try? await api.deleteDraft(id: gmailDraftId) }
        let fetched = (try? await withRetry { [api] in try await api.messages(ids: [ref.id], format: .full) }) ?? []
        let parsed = fetched.map { GmailMessageParser.parse($0, accountId: accountId, accountEmail: account.email, format: .full) }
        let draftMessageId = draft.gmailMessageId
        do {
            try await write { db in
                for other in try MailStore.draftOps(db, draftId: draftId) { _ = try other.delete(db) }
                if var row = try Draft.fetchOne(db, key: draftId) {
                    row.state = .sent
                    row.gmailMessageId = ref.id
                    try row.update(db)
                    _ = try row.delete(db)
                }
                if let draftMessageId { try MailStore.deleteMessages(db, accountId: accountId, ids: [draftMessageId]) }
                try MailStore.upsertServerMessages(db, parsed.map(\.message), attachments: parsed.flatMap(\.attachments))
            }
        } catch {
            _ = try? await write { db in try PendingOp.deleteOne(db, key: opId) }
        }
        return .done
    }

    /// Creates or updates the Gmail draft and records its ids on the draft row.
    private func saveDraft(_ op: PendingOp) async throws {
        guard let opId = op.id, let draftId = AccountSync.draftId(of: op) else {
            if let id = op.id { try await deleteOp(id) }
            return
        }
        let accountId = self.accountId
        let claim = try await write { db -> DraftClaim in
            guard let draft = try Draft.fetchOne(db, key: draftId), draft.state != .sent, draft.state != .sending,
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

        let raw = try encodeDraft(draft, account)
        let saved: GmailDraft
        if let gmailDraftId = draft.gmailDraftId {
            do {
                saved = try await api.updateDraft(id: gmailDraftId, raw: raw, threadId: draft.threadId)
            } catch GmailAPIError.notFound {
                saved = try await api.createDraft(raw: raw, threadId: draft.threadId)
            }
        } else {
            saved = try await api.createDraft(raw: raw, threadId: draft.threadId)
        }
        try await write { db in
            if var row = try Draft.fetchOne(db, key: draftId) {
                row.gmailDraftId = saved.id
                if let messageId = saved.message?.id { row.gmailMessageId = messageId }
                row.lastError = nil
                try row.update(db)
            }
            _ = try PendingOp.deleteOne(db, key: opId)
        }
    }

    /// Deletes the Gmail draft, then the draft row, its stored message and its other queued ops.
    private func deleteDraft(_ op: PendingOp) async throws {
        guard let opId = op.id, let draftId = AccountSync.draftId(of: op) else {
            if let id = op.id { try await deleteOp(id) }
            return
        }
        let accountId = self.accountId
        let draft = try await read { db in try Draft.fetchOne(db, key: draftId) }
        try await setOpState(opId, .inflight)
        if let gmailDraftId = draft?.gmailDraftId {
            do {
                try await api.deleteDraft(id: gmailDraftId)
            } catch GmailAPIError.notFound {
                // Already gone on Gmail.
            }
        }
        let draftMessageId = draft?.gmailMessageId
        try await write { db in
            for other in try MailStore.draftOps(db, draftId: draftId) { _ = try other.delete(db) }
            _ = try Draft.deleteOne(db, key: draftId)
            if let draftMessageId { try MailStore.deleteMessages(db, accountId: accountId, ids: [draftMessageId]) }
        }
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
            if attempts >= configuration.maxOpAttempts {
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
            for chunk in ids.syncChunks(configuration.fetchBatchSize) {
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

    /// Puts a send's draft back to `state` (nil keeps it) with `error`. No-op for label ops.
    private func restoreDraftState(_ op: PendingOp, state: Draft.State?, error: String?) async throws {
        guard op.kind != .modifyLabels, let draftId = AccountSync.draftId(of: op) else { return }
        let isSend = op.kind == .sendDraft
        try await write { db in
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

    private func setOpState(_ id: Int64, _ state: PendingOp.State) async throws {
        try await updateOp(id) { $0.state = state }
    }

    private func deleteOp(_ id: Int64) async throws {
        _ = try await write { db in try PendingOp.deleteOne(db, key: id) }
    }

    /// Changes the stored op if it still exists (undo may have removed it).
    private func updateOp(_ id: Int64, _ change: @escaping @Sendable (inout PendingOp) -> Void) async throws {
        try await write { db in
            guard var op = try PendingOp.fetchOne(db, key: id) else { return }
            change(&op)
            try op.update(db)
        }
    }
}
