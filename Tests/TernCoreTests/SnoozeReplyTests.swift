import Foundation
import GRDB
import Testing
@testable import TernCore

private let account = Account(email: "me@example.com")

private func message(_ id: String, date: Date, from: String = "ann@example.com", labels: [String]) -> MailMessage {
    MailMessage(
        accountId: account.id, id: id, threadId: "t1", date: date, fromName: "Ann", fromEmail: from,
        subject: "Plans", snippet: "x", bodyText: "x", bodyState: .full, labelIds: labels, isFromMe: from == account.email)
}

private func snoozedThread() throws -> (MailStore, ThreadKey) {
    let store = MailStore(try AppDatabase.inMemory())
    try store.upsertAccount(account)
    try store.upsertMessages([message("m1", date: Date().addingTimeInterval(-3_600), labels: ["INBOX"])])
    let key = ThreadKey(accountId: account.id, threadId: "t1")
    try store.perform(.snooze(until: Date().addingTimeInterval(3 * 86_400)), on: [key])
    return (store, key)
}

private func sync(_ store: MailStore, _ messages: [MailMessage]) throws {
    try store.database.writer.write { db in try MailStore.upsertServerMessages(db, messages) }
}

private func isSnoozed(_ store: MailStore) throws -> Bool {
    try store.database.reader.read { db in try Snooze.fetchCount(db) } == 1
}

@Test func aReplyAfterSnoozingEndsTheSnooze() throws {
    let (store, _) = try snoozedThread()
    #expect(try isSnoozed(store))
    let later = Date().addingTimeInterval(60)

    // Not a reply to the snooze: backfill of older mail, your own message, a reply a filter kept out of the inbox.
    try sync(store, [message("old", date: Date().addingTimeInterval(-7_200), labels: ["INBOX"])])
    try sync(store, [message("mine", date: later, from: account.email, labels: ["SENT"])])
    try sync(store, [message("filtered", date: later, labels: ["Label_1"])])
    #expect(try isSnoozed(store))

    // Friday's reply comes back to the inbox: the snooze ends, so Monday's wake can't bring the thread back.
    try sync(store, [message("reply", date: later, labels: ["INBOX", "UNREAD"])])
    #expect(try !isSnoozed(store))
    #expect(try store.wakeSnoozed(now: Date().addingTimeInterval(4 * 86_400)).isEmpty)
}

@Test func snoozesAreStampedWhenSetAndChanged() throws {
    let (store, key) = try snoozedThread()
    let stamp = { try store.database.reader.read { db in try Double.fetchOne(db, sql: "SELECT setAt FROM snooze") } }
    let first = try #require(try stamp())
    #expect(abs(first - Date().timeIntervalSince1970) < 5)
    try store.database.writer.write { db in try db.execute(sql: "UPDATE snooze SET setAt = 0") }
    try store.perform(.snooze(until: Date().addingTimeInterval(86_400)), on: [key])
    #expect(try #require(try stamp()) > 0, "snoozing again restamps")
}
