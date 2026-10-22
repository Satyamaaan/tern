import Foundation
import GRDB
import Testing
@testable import TernCore

struct LedgerSchemaTests {
    @Test func fingerprintAndCascade() throws {
        let (database, store, ask) = try ledgerFixture()
        try database.writer.write { db in
            try Ledger.refresh(db, keys: [ThreadKey(accountId: ask.accountId, threadId: ask.threadId)], now: ledgerNow)
            #expect(try Commitment.fetchCount(db) == 1)
            try MailStore.refreshThreads(db, [ThreadKey(accountId: ask.accountId, threadId: ask.threadId)])
            #expect(try Commitment.fetchCount(db) == 1)
        }
        let item = try #require(store.commitments(on: [ThreadKey(accountId: ask.accountId, threadId: ask.threadId)]).first)
        _ = try store.setCommitmentState([try #require(item.id)], to: .dismissed)
        try database.writer.write { db in
            try Ledger.refresh(db, keys: [ThreadKey(accountId: ask.accountId, threadId: ask.threadId)], now: ledgerNow)
            #expect(try Commitment.fetchAll(db).map(\.state) == [.dismissed])
            try db.execute(sql: "DELETE FROM thread WHERE accountId='a' AND id='t'")
            #expect(try Commitment.fetchCount(db) == 0)
        }
    }
}
