import Foundation
import GRDB
import Testing
@testable import TernCore

struct LedgerGoldTests {
    @Test func precision() throws {
        let database = try AppDatabase.inMemory()
        let gold = try FakeMailbox.populateLedgerGold(database, count: 160, now: ledgerNow)
        let predicted = Set(try MailStore(database).threadRows(in: Mailbox(.waitingOn), limit: 1000).map(\.id))
        let expected = Set(gold.filter(\.waiting).map(\.key))
        let precision = Double(predicted.intersection(expected).count) / Double(max(1, predicted.count))
        print("Ledger gold precision \(precision), predicted \(predicted.count), expected \(expected.count)")
        #expect(precision >= 0.95)
        #expect(expected.isSubset(of: predicted))
    }
}
