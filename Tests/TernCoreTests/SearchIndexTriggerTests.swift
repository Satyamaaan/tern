import Foundation
import GRDB
import Testing
@testable import TernCore

private let account = Account(email: "me@example.com")

private func message(_ id: String, labels: [String] = ["INBOX"], subject: String = "Quarterly report",
                     body: String = "The numbers are in") -> MailMessage {
    MailMessage(
        accountId: account.id, id: id, threadId: "t-\(id)", date: Date(timeIntervalSince1970: 100),
        fromName: "Ann", fromEmail: "ann@example.com", toList: [Participant(email: account.email)],
        subject: subject, snippet: body, bodyText: body, bodyState: .full, labelIds: labels)
}

private func makeStore() throws -> MailStore {
    let store = MailStore(try AppDatabase.inMemory())
    try store.upsertAccount(account)
    return store
}

/// Rows of the index's segment storage. Every index write (a delete or an insert) adds a segment when its
/// transaction commits, so an unchanged count means the trigger left the index alone.
private func indexSegmentRows(_ store: MailStore) throws -> Int {
    try store.database.reader.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM message_fts_data") ?? 0 }
}

private func indexIsConsistent(_ store: MailStore) throws -> Bool {
    do {
        try store.database.writer.write { db in
            try db.execute(sql: "INSERT INTO message_fts(message_fts, rank) VALUES ('integrity-check', 1)")
        }
        return true
    } catch {
        return false
    }
}

@Test func identicalUpsertLeavesTheSearchIndexAlone() throws {
    let store = try makeStore()
    try store.upsertMessages([message("m1")])
    let before = try indexSegmentRows(store)

    try store.upsertMessages([message("m1")])
    #expect(try indexSegmentRows(store) == before)
    #expect(try SearchService(store.database).search("quarterly").map(\.thread.id) == ["t-m1"])
}

@Test func labelOnlyRefetchLeavesTheSearchIndexAlone() throws {
    let store = try makeStore()
    try store.upsertMessages([message("m1")])
    let before = try indexSegmentRows(store)

    var metadata = message("m1", labels: ["INBOX", "STARRED"])
    metadata.bodyText = nil
    metadata.bodyState = .metadata
    try store.upsertMessages([metadata])
    #expect(try indexSegmentRows(store) == before)
    #expect(try SearchService(store.database).search("numbers").map(\.thread.id) == ["t-m1"])
    #expect(try indexIsConsistent(store))
}

@Test func changedTextIsReindexed() throws {
    let store = try makeStore()
    try store.upsertMessages([message("m1")])

    try store.upsertMessages([message("m1", subject: "Annual summary", body: "Totals for the year")])
    let search = SearchService(store.database)
    #expect(try search.search("annual").map(\.thread.id) == ["t-m1"])
    #expect(try search.search("totals").map(\.thread.id) == ["t-m1"])
    #expect(try search.search("quarterly").isEmpty)
    #expect(try indexIsConsistent(store))
}

@Test func emptiedBodyIsReindexed() throws {
    let store = try makeStore()
    try store.upsertMessages([message("m1", body: "Lighthouse keeper")])
    try store.database.writer.write { db in
        try db.execute(sql: "UPDATE message SET bodyText = NULL, snippet = '' WHERE id = 'm1'")
    }
    #expect(try SearchService(store.database).search("lighthouse").isEmpty)
    #expect(try indexIsConsistent(store))
}
