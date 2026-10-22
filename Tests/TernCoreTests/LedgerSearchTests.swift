import Foundation
import GRDB
import Testing
@testable import TernCore

struct LedgerSearchTests {
    @Test func waitingAndDue() throws {
        let (database, _, _) = try ledgerFixture()
        let search = SearchService(database)
        #expect(try search.search("is:waiting").count == 1)
        #expect(try search.search("is:waiting due:none").count == 1)
        #expect(try search.search("is:waiting due:overdue").isEmpty)
        #expect(SearchQuery("is:waiting due:today").gmailQuery == nil)
        #expect(try search.search("-is:waiting").isEmpty)
    }
}


extension LedgerSearchTests {
    @Test func dueDatesAndSuggestions() throws {
        let (database, store, _) = try ledgerFixture()
        let search = SearchService(database)
        let options = SearchOptions(now: ledgerNow, timeZone: TimeZone(secondsFromGMT: 0)!)
        try database.writer.write { db in
            try db.execute(sql: "UPDATE commitment SET dueAt=?", arguments: [ledgerNow.timeIntervalSince1970 - 60])
        }
        #expect(try search.search(SearchQuery("due:overdue"), options: options).count == 1)
        #expect(try search.search(SearchQuery("due:today"), options: options).count == 1)
        #expect(try search.search(SearchQuery("due:week"), options: options).count == 1)
        #expect(try search.search(SearchQuery("due:none"), options: options).isEmpty)
        #expect(try search.suggestions(for: "due:").count == 4)
        try store.setLedgerSettings(enabled: false, waitingDays: 3)
        #expect(try search.search("is:waiting").isEmpty)
        #expect(try store.scopeCounts(accountId: nil).waitingOn == 0)
    }
}
