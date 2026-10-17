import Foundation
import GRDB
import TernCore

/// Builds the RFC 822 message for a draft with `MIMEBuilder`: the `encodeDraft` closure the app
/// passes to `SyncCoordinator`. The engine has already downloaded forwarded attachments into the
/// draft's folder and sets a stable Message-ID on the result.
public enum DraftEncoder {
    /// - From: the account's address, with the name Gmail's send-as settings give it (the engine
    ///   stores it in `setting` `sender.name.<accountId>`; without it the address goes alone).
    /// - Replies and forwards: In-Reply-To and References from the message they answer
    ///   (`rfcMessageId`, `refs`).
    /// - Body: sent as the composer assembled it, signature included.
    public static func make(store: MailStore, timeZone: TimeZone = .current) -> @Sendable (Draft, Account) throws -> Data {
        let database = store.database
        return { draft, account in
            let (name, parent) = try database.reader.read { db in
                (try Setting.fetchOne(db, key: DraftStore.SettingKey.senderName(account.id))?.value,
                 try repliedMessage(db, draft))
            }
            let from = Participant(name: name ?? "", email: account.email)
            return try MIMEBuilder(date: Date(), timeZone: timeZone)
                .build(draft: draft, from: from, inReplyTo: parent?.rfcMessageId, references: parent?.refs)
        }
    }

    /// The message a reply or forward answers: in the draft's account, else any (the draft may have
    /// moved to another account after it was started).
    static func repliedMessage(_ db: Database, _ draft: Draft) throws -> MailMessage? {
        guard let id = draft.replyToMessageId else { return nil }
        if let own = try MailMessage.fetchOne(db, key: ["accountId": draft.accountId, "id": id]) { return own }
        return try MailMessage.filter(Column("id") == id).fetchOne(db)
    }
}
