import Foundation
import GRDB
import Testing
@testable import TernCore

struct LedgerRowTests {
    @Test func rowsCountsAndScope() throws {
        let (database, store, ask) = try ledgerFixture()
        let rows = try store.threadRows(in: Mailbox(.waitingOn))
        #expect(rows.count == 1)
        #expect(rows.first?.ledger?.counterpartyName == "Maya")
        #expect(try store.scopeCounts(accountId: "a").waitingOn == 1)
        #expect(try store.scopeCounts(accountId: "other").waitingOn == 0)
        #expect(try store.threadRows(in: Mailbox(.waitingOn, accountId: "other")).isEmpty)
        #expect(try store.threadRows(in: Mailbox(.sent)).first?.ledger == nil)
        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO commitment (accountId,threadId,direction,deliverable,sourceMessageId,sourceDate,origin,surfaceAt,surfaced,fingerprint,createdAt,updatedAt) SELECT accountId,threadId,direction,'Deliverable',sourceMessageId,sourceDate+1,'manual',surfaceAt,1,'second',createdAt,updatedAt FROM commitment")
        }
        #expect(try store.threadRows(in: Mailbox(.waitingOn)).first?.ledger?.extraCount == 1)
        #expect(try store.scopeCounts(accountId: nil).waitingOn == 1)
        #expect(try store.commitments(on: [ThreadKey(accountId: ask.accountId, threadId: ask.threadId)]).count == 2)
    }
}
