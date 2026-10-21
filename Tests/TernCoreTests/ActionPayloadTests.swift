import Foundation
import GRDB
import Testing
@testable import TernCore

// JSONEncoder does not promise object-key order. Compare bytes with just those keys sorted; array order,
// omitted fields and all payload values must remain identical.
private func payloadBytes(_ json: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: Data(json.utf8)), options: .sortedKeys)
}

@Test func longThreadArchiveKeepsPayloadOrderAndUndo() throws {
    let store = MailStore(try AppDatabase.inMemory())
    let account = Account(email: "me@example.com")
    try store.upsertAccount(account)
    let messages = (0..<1_200).map { i in
        MailMessage(accountId: account.id, id: "m\(i)", threadId: "thread", date: Date(timeIntervalSince1970: Double(i)),
                    fromEmail: "sender@example.com", labelIds: ["INBOX", "UNREAD"])
    }
    try store.upsertMessages(messages)
    let key = ThreadKey(accountId: account.id, threadId: "thread")
    let token = try store.perform(.archive, on: [key])
    let expected = messages.map { LabelChange(messageId: $0.id, add: [], remove: ["INBOX"]) }
    #expect(token.ops.first?.changes == expected)
    #expect(token.ops.first?.labelsAfter == Dictionary(uniqueKeysWithValues: messages.map { ($0.id, ["UNREAD"]) }))
    let op = try #require(try store.database.reader.read { try PendingOp.fetchOne($0) })
    #expect(try payloadBytes(op.payload) == payloadBytes(encodeJSON(
        LabelOpPayload(action: "archive", threadIds: ["thread"], changes: expected))))
    try store.database.writer.write { db in
        try db.execute(sql: "UPDATE pending_op SET state = 'inflight'")
    }
    try store.undo(token)
    let undo = try #require(try store.database.reader.read { try PendingOp.order(Column("id").desc).fetchOne($0) })
    #expect(try payloadBytes(undo.payload) == payloadBytes(encodeJSON(LabelOpPayload(
        action: "undo-archive", threadIds: ["thread"],
        changes: messages.map { LabelChange(messageId: $0.id, add: ["INBOX"], remove: []) }))))
    #expect(try store.threadDetail(key)?.messages.map(\.labelIds) == messages.map(\.labelIds))
}

@Test func tabMoveKeepsEffectiveChangesBeforeIntentOnlyMessages() throws {
    let store = MailStore(try AppDatabase.inMemory())
    let account = Account(email: "me@example.com")
    try store.upsertAccount(account)
    let labels = [["INBOX", "CATEGORY_PROMOTIONS"], ["INBOX", "CATEGORY_UPDATES"], ["INBOX"], ["DRAFT"]]
    try store.upsertMessages(labels.enumerated().map { i, labels in
        MailMessage(accountId: account.id, id: "m\(i)", threadId: "thread", date: Date(timeIntervalSince1970: Double(i)),
                    fromEmail: "sender@example.com", labelIds: labels)
    })
    let token = try store.perform(.moveToTab(.updates), on: [ThreadKey(accountId: account.id, threadId: "thread")])
    let remove = ["CATEGORY_PERSONAL", "CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL", "CATEGORY_FORUMS"]
    let expected = [
        LabelChange(messageId: "m0", add: ["CATEGORY_UPDATES"], remove: ["CATEGORY_PROMOTIONS"],
                    intentAdd: ["CATEGORY_UPDATES"], intentRemove: remove),
        LabelChange(messageId: "m2", add: ["CATEGORY_UPDATES"], remove: [],
                    intentAdd: ["CATEGORY_UPDATES"], intentRemove: remove),
        LabelChange(messageId: "m1", add: [], remove: [], intentAdd: ["CATEGORY_UPDATES"], intentRemove: remove),
    ]
    let queued = try #require(token.ops.first)
    #expect(queued.changes == expected)
    #expect(queued.tabsBefore == ["m0": .promotions, "m1": .updates])
    let op = try #require(try store.database.reader.read { try PendingOp.fetchOne($0) })
    #expect(try payloadBytes(op.payload) == payloadBytes(encodeJSON(
        LabelOpPayload(action: "moveToTab", threadIds: ["thread"], changes: expected))))
    try store.undo(token)
    let undo = try #require(try store.database.reader.read { try PendingOp.fetchOne($0) })
    let restored = [
        LabelChange(messageId: "m0", add: ["CATEGORY_PROMOTIONS"], remove: ["CATEGORY_UPDATES"],
                    intentAdd: ["CATEGORY_PROMOTIONS"],
                    intentRemove: ["CATEGORY_PERSONAL", "CATEGORY_SOCIAL", "CATEGORY_UPDATES", "CATEGORY_FORUMS"]),
        LabelChange(messageId: "m2", add: [], remove: ["CATEGORY_UPDATES"], intentAdd: [],
                    intentRemove: ["CATEGORY_PERSONAL", "CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL", "CATEGORY_UPDATES", "CATEGORY_FORUMS"]),
        LabelChange(messageId: "m1", add: [], remove: [], intentAdd: ["CATEGORY_UPDATES"], intentRemove: remove),
    ]
    #expect(try payloadBytes(undo.payload) == payloadBytes(encodeJSON(
        LabelOpPayload(action: "undo-moveToTab", threadIds: ["thread"], changes: restored))))
}
