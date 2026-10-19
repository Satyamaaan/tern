import Foundation
import GRDB
import TernCore

/// `setting` keys the engine owns.
public enum SyncSettingKey {
    /// The id of the account's "Muted" label (`SyncCoordinator.mute`).
    public static func muteLabel(_ accountId: String) -> String { MailStore.muteLabelKey(accountId) }
}

// Mute. Gmail's API has no mute, so Tern keeps its own: a user label "Muted" on the thread, which is
// archived; new mail in a thread that has the label is archived again as it arrives.
extension AccountSync {
    public static let muteLabelName = "Muted"

    /// The id of the account's "Muted" label, finding or creating it in Gmail the first time (or when
    /// it was deleted there). Stored in `setting` `mute.label.<accountId>`.
    public func muteLabelId() async throws -> String {
        let accountId = self.accountId
        let key = SyncSettingKey.muteLabel(accountId)
        if let known = try await read({ db -> String? in
            guard let id = try Setting.fetchOne(db, key: key)?.value,
                  try MailLabel.fetchOne(db, key: ["accountId": accountId, "id": id]) != nil else { return nil }
            return id
        }) {
            return known
        }
        func existing(_ labels: [GmailLabel]) -> GmailLabel? {
            labels.first { $0.type?.lowercased() != "system" && $0.name.caseInsensitiveCompare(AccountSync.muteLabelName) == .orderedSame }
        }
        var label = existing(try await syncLabels())
        if label == nil {
            do {
                label = try await api.createLabel(name: AccountSync.muteLabelName)
            } catch GmailAPIError.server(let status, _) where status == 409 || status == 400 {
                // Created meanwhile (another mute, another device): use that one.
                label = existing(try await withRetry { [api] in try await api.labels() })
            }
            try await syncLabels()
        }
        guard let id = label?.id else { throw GmailAPIError.server(status: 409, message: "The Muted label couldn't be created") }
        try await write { db in try Setting(key: key, value: id).upsert(db) }
        return id
    }

    /// Mutes threads: archives them and labels them "Muted" through `MailStore.perform`, in the
    /// caller's transaction, so it's instant, works offline and is undoable. Before the label's id is
    /// known in an account, the stand-in `MailStore.pendingMuteLabel` is queued, and the engine finds or
    /// creates the label when it sends the op (`resolvePendingMuteLabel`).
    public static func mute(_ db: Database, _ keys: [ThreadKey]) throws -> UndoToken {
        var actions: [(action: MailAction, threads: [ThreadKey])] = []
        for (accountId, threads) in Dictionary(grouping: keys, by: \.accountId).sorted(by: { $0.key < $1.key }) {
            actions.append((.moveToLabel(try knownMuteLabel(db, accountId: accountId) ?? MailStore.pendingMuteLabel), threads))
        }
        return try MailStore.perform(db, actions)
    }

    /// `mute` in its own write.
    public static func mute(_ keys: [ThreadKey], in store: MailStore) throws -> UndoToken {
        try store.database.writer.write { db in try mute(db, keys) }
    }

    /// The account's Muted label id when Tern knows it and Gmail still has it (its label list does).
    static func knownMuteLabel(_ db: Database, accountId: String) throws -> String? {
        guard let id = try Setting.fetchOne(db, key: SyncSettingKey.muteLabel(accountId))?.value,
              try MailLabel.fetchOne(db, key: ["accountId": accountId, "id": id]) != nil else { return nil }
        return id
    }

    /// Before a label op naming the stand-in Muted label goes out: finds or creates the real label,
    /// then swaps it in, in one write, in every queued label op of the account and on stored messages.
    /// Returns `payload` with it swapped.
    func resolvePendingMuteLabel(_ payload: LabelOpPayload) async throws -> LabelOpPayload {
        let muted = try await muteLabelId()
        let accountId = self.accountId
        try writeNow { db in try AccountSync.replacePendingMuteLabel(db, accountId: accountId, with: muted) }
        return AccountSync.replacingPendingMute(payload, with: muted)
    }

    static func mentionsPendingMute(_ payload: LabelOpPayload) -> Bool {
        payload.changes.contains { ($0.requestAdd + $0.requestRemove).contains(MailStore.pendingMuteLabel) }
    }

    static func replacingPendingMute(_ payload: LabelOpPayload, with muted: String) -> LabelOpPayload {
        var resolved = payload
        resolved.changes = payload.changes.map { $0.replacingLabel(MailStore.pendingMuteLabel, with: muted) }
        return resolved
    }

    static func replacePendingMuteLabel(_ db: Database, accountId: String, with muted: String) throws {
        let placeholder = MailStore.pendingMuteLabel
        for var op in try PendingOp.filter(
            sql: "accountId = ? AND kind = 'modifyLabels' AND instr(payload, ?) > 0", arguments: [accountId, placeholder]).fetchAll(db) {
            guard let payload = try? JSONDecoder().decode(LabelOpPayload.self, from: Data(op.payload.utf8)) else { continue }
            op.payload = String(decoding: try JSONEncoder().encode(replacingPendingMute(payload, with: muted)), as: UTF8.self)
            try op.update(db)
        }
        var labels: [String: [String]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, labelIds FROM message WHERE accountId = ? AND instr(labelIds, ?) > 0",
                                    arguments: [accountId, "\"\(placeholder)\""]) {
            let json: String = row["labelIds"]
            let current = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
            labels[row["id"]] = current.map { $0 == placeholder ? muted : $0 }
        }
        try MailStore.setLabels(db, accountId: accountId, labels)
    }

    /// Inside a history write: threads among `messageIds`' that carry the account's Muted label (or
    /// the stand-in for it) and are in the inbox again are archived and labelled Muted throughout
    /// through `MailStore.perform`, so the change is queued for Gmail and the thread never shows in
    /// the inbox. A Muted label deleted in Gmail no longer counts: archiving to a label Gmail no
    /// longer has would fail and hold up the queue.
    static func rearchiveMuted(_ db: Database, accountId: String, messageIds: [String]) throws {
        guard !messageIds.isEmpty else { return }
        let known = try knownMuteLabel(db, accountId: accountId)
        let mutedLabels: [String] = [MailStore.pendingMuteLabel] + (known.map { [$0] } ?? [])
        var threads = Set<String>()
        for chunk in messageIds.syncChunks(500) {
            threads.formUnion(try String.fetchAll(db, sql: """
                SELECT DISTINCT threadId FROM message WHERE accountId = ? AND id IN (\(databaseQuestionMarks(count: chunk.count)))
                """, arguments: StatementArguments([accountId] + chunk)))
        }
        guard !threads.isEmpty else { return }
        let ids = Array(threads)
        let threadList = databaseQuestionMarks(count: ids.count)
        let labelList = databaseQuestionMarks(count: mutedLabels.count)
        let values: [String] = [accountId] + mutedLabels + ids + [accountId, SystemLabel.inbox] + ids
        let mutedInInbox = try String.fetchAll(db, sql: """
            SELECT threadId FROM thread_label WHERE accountId = ? AND labelId IN (\(labelList)) AND threadId IN (\(threadList))
            INTERSECT
            SELECT threadId FROM thread_label WHERE accountId = ? AND labelId = ? AND threadId IN (\(threadList))
            """, arguments: StatementArguments(values))
        guard !mutedInInbox.isEmpty else { return }
        try MailStore.perform(db, .moveToLabel(known ?? MailStore.pendingMuteLabel),
                              on: mutedInInbox.map { ThreadKey(accountId: accountId, threadId: $0) })
    }
}
