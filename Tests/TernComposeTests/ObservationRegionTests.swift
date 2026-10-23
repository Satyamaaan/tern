import Foundation
@testable import GRDB
import Testing
@testable import Tern
import TernCore

@Test func listObservationCoversEveryMailboxQuery() throws {
    let database = try AppDatabase.inMemory()
    let account = Account(email: "synthetic@example.com")
    try database.writer.write { db in
        try account.insert(db)
        try Draft(accountId: account.id, subject: "Local draft", bodyHtml: "<p>Unsent</p>").insert(db)
        try Setting(key: "ledger.enabled", value: "true").insert(db)
        let kinds: [Mailbox.Kind] = [.inbox, .starred, .important, .snoozed, .sent, .drafts, .allMail,
            .archive, .spam, .trash, .label("custom"), .project("project"), .needsReply, .due, .iOwe, .waitingOn]
            + MailCategory.allCases.map(Mailbox.Kind.category)
        let observed = try observationRegion(ListObservationSource.regions, db)
        for accountId in [nil, account.id] {
            for kind in kinds {
                let tabs: [InboxTab?] = kind == .inbox ? [nil] + InboxTab.allCases.map(Optional.some) : [nil]
                for tab in tabs {
                    let source = ListSource(mailbox: Mailbox(kind, accountId: accountId), tab: tab)
                    var selected = DatabaseRegion()
                    let rows = try db.recordingSelection(&selected) { try source.fetch(db, limit: 200) }
                    if kind == .drafts { #expect(rows.contains { MailThread.localDraftId(in: $0.id) != nil }) }
                    #expect(observed.union(selected) == observed, "Missing region for \(source): \(selected)")
                }
            }
        }
    }
}

private func observationRegion(_ regions: [any DatabaseRegionConvertible], _ db: Database) throws -> DatabaseRegion {
    try regions.reduce(into: DatabaseRegion()) { result, region in
        try result.formUnion(region.databaseRegion(db))
    }
}

@Test func scopeObservationsCoverCountsAndLabelsQueries() throws {
    let database = try AppDatabase.inMemory()
    let account = Account(email: "synthetic@example.com")
    try database.writer.write { db in
        try account.insert(db)
        try Draft(accountId: account.id, subject: "Local draft").insert(db)
        let countsRegion = try observationRegion(ScopeObservationSource.countsRegions, db)
        let labelsRegion = try observationRegion(ScopeObservationSource.labelsRegions, db)
        for enabled in [true, false] {
            try Setting(key: "ledger.enabled", value: String(enabled)).upsert(db)
            for showMaybe in [true, false] {
                try Setting(key: "ledger.showMaybe", value: String(showMaybe)).upsert(db)
                for accountId in [nil, account.id] {
                    let request = ScopeObservationSource.Request(accountId: accountId)
                    var selectedCounts = DatabaseRegion()
                    _ = try db.recordingSelection(&selectedCounts) { try request.fetchCounts(db) }
                    #expect(countsRegion.union(selectedCounts) == countsRegion, "Missing counts region: \(selectedCounts)")
                    var selectedLabels = DatabaseRegion()
                    _ = try db.recordingSelection(&selectedLabels) { try request.fetchLabels(db) }
                    #expect(labelsRegion.union(selectedLabels) == labelsRegion, "Missing labels region: \(selectedLabels)")
                }
            }
        }
    }
}

@Test func unrelatedHotColumnsDoNotInvalidateMailObservations() throws {
    let database = try AppDatabase.inMemory()
    try database.reader.read { db in
        let list = try observationRegion(ListObservationSource.regions, db)
        let counts = try observationRegion(ScopeObservationSource.countsRegions, db)
        for region in [list, counts] {
            #expect(!region.isModified(byEventsOfKind: .update(tableName: "message", columnNames: ["bodyText", "bodyHtml", "bodyState"])))
            #expect(!region.isModified(byEventsOfKind: .update(tableName: "thread_ai", columnNames: ["classifiedAt"])))
        }
        #expect(!list.isModified(byEventsOfKind: .update(tableName: "account", columnNames: ["historyId", "lastSyncAt"])))
        #expect(list.isModified(byEventsOfKind: .update(tableName: "message", columnNames: ["searchRecipients"])))
        #expect(list.isModified(byEventsOfKind: .update(tableName: "draft", columnNames: ["bodyHtml"])))
        #expect(!counts.isModified(byEventsOfKind: .update(tableName: "draft", columnNames: ["bodyHtml", "updatedAt"])))
        #expect(!counts.isModified(byEventsOfKind: .update(tableName: "commitment", columnNames: ["sourceQuote", "updatedAt"])))
    }
}
