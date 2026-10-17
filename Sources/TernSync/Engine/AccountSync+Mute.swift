import Foundation
import GRDB
import TernCore

/// `setting` keys the engine owns.
public enum SyncSettingKey {
    /// The id of the account's "Muted" label (`SyncCoordinator.mute`).
    public static func muteLabel(_ accountId: String) -> String { "mute.label.\(accountId)" }
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

    /// Inside a history write: threads among `messageIds`' that carry the account's Muted label and
    /// are in the inbox again are archived (and labelled Muted throughout) through `MailStore.perform`,
    /// so the change is queued for Gmail and the thread never shows in the inbox.
    static func rearchiveMuted(_ db: Database, accountId: String, messageIds: [String]) throws {
        guard !messageIds.isEmpty, let muted = try Setting.fetchOne(db, key: SyncSettingKey.muteLabel(accountId))?.value,
              // Deleted in Gmail: archiving to a label Gmail no longer has would fail and hold up the queue.
              try MailLabel.fetchOne(db, key: ["accountId": accountId, "id": muted]) != nil else { return }
        var threads = Set<String>()
        for chunk in messageIds.syncChunks(500) {
            threads.formUnion(try String.fetchAll(db, sql: """
                SELECT DISTINCT threadId FROM message WHERE accountId = ? AND id IN (\(databaseQuestionMarks(count: chunk.count)))
                """, arguments: StatementArguments([accountId] + chunk)))
        }
        guard !threads.isEmpty else { return }
        let ids = Array(threads)
        let mutedInInbox = try String.fetchAll(db, sql: """
            SELECT threadId FROM thread_label WHERE accountId = ? AND labelId = ? AND threadId IN (\(databaseQuestionMarks(count: ids.count)))
            INTERSECT
            SELECT threadId FROM thread_label WHERE accountId = ? AND labelId = ? AND threadId IN (\(databaseQuestionMarks(count: ids.count)))
            """, arguments: StatementArguments([accountId, muted] + ids + [accountId, SystemLabel.inbox] + ids))
        guard !mutedInInbox.isEmpty else { return }
        try MailStore.perform(db, .moveToLabel(muted), on: mutedInInbox.map { ThreadKey(accountId: accountId, threadId: $0) })
    }
}
