import Foundation
import GRDB
import Testing
@testable import TernCore

let ledgerNow = Date(timeIntervalSince1970: 1_790_000_000)

func ledgerFixture(text: String = "Could you review the proposal and let me know?", recipients: [Participant] = [Participant(name: "Maya", email: "maya@example.com")], unsubscribe: String? = nil) throws -> (AppDatabase, MailStore, MailMessage) {
    let database = try AppDatabase.inMemory()
    let store = MailStore(database)
    var account = Account(email: "me@example.com")
    account.id = "a"
    try store.upsertAccount(account)
    let message = MailMessage(accountId: "a", id: "ask", threadId: "t", date: ledgerNow.addingTimeInterval(-4 * 86_400),
        fromEmail: "me@example.com", toList: recipients, subject: "Proposal", snippet: text,
        labelIds: [SystemLabel.sent], isFromMe: true, listUnsubscribe: unsubscribe)
    try database.writer.write { db in
        let keys = try MailStore.upsertMessages(db, [message])
        try MailStore.applyRules(db, keys: keys, now: ledgerNow)
    }
    return (database, store, message)
}
