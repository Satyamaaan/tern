import Foundation
import GRDB
import Testing
@testable import TernCore

struct SummaryStoreTests {
    @Test func summariesReadWithRowsAndFallbackToSnippet() throws {
        let (db, store, ask) = try ledgerFixture()
        let key = ThreadKey(accountId: ask.accountId, threadId: ask.threadId)
        #expect(try store.threadRows(in: Mailbox(.sent)).first?.summary == nil)
        try db.writer.write { try SummaryStore.save($0, key: key, messageCount: 1, lastDate: ask.date, bullets: ["Review the proposal."]) }
        #expect(try store.threadRows(in: Mailbox(.sent)).first?.summary == "Review the proposal.")
        #expect(try store.threadRows(in: Mailbox(.sent)).first?.thread.snippet == ask.snippet)
    }
}
