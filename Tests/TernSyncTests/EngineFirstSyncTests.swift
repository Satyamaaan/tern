import Foundation
import GRDB
import Testing
import TernCore
@testable import TernSync

@Test func aHugeInboxOnlyHasItsNewestMailFetchedInFullAtFirst() async throws {
    var configuration = SyncConfiguration.test()
    configuration.initialInboxLimit = 10
    configuration.initialRecentLimit = 5
    let h = try Harness(configuration: configuration)
    await seed(h.fake, count: 60, inboxEvery: 1, spacing: 6 * 3600)
    try await h.sync.initialSync()

    #expect(try h.account().syncState == .backfilling, "usable after the newest inbox mail")
    #expect(try h.messages().count == 10)
    #expect(try h.messages().values.allSatisfy { $0.bodyState == .full })
    #expect(await h.fake.listCalls.allSatisfy { $0.pageToken == nil }, "listing stopped at the limits")

    while try await h.sync.backfillStep() {}
    #expect(try h.inboxThreadIds().count == 60, "the rest of the inbox arrives with the backfill")
    try await h.expectMirrorsGmail()
}

/// Four accounts (two personal, two Workspace) syncing at once through the coordinator.
@MainActor
@Test func fourAccountsSyncSideBySide() async throws {
    let store = try MailStore(AppDatabase.inMemory())
    let emails = ["me@gmail.com", "me.too@gmail.com", "sam@northwind.example", "sam@contoso.example"]
    var fakes: [String: FakeGmail] = [:]
    for (index, email) in emails.enumerated() {
        let fake = FakeGmail(email: email, sleep: { _ in })
        await fake.setSendAs([GmailSendAs(sendAsEmail: email, displayName: "Sam \(index)", signature: "<div>sig \(index)</div>",
                                          isPrimary: true, isDefault: true)])
        for message in 0..<(15 + index * 5) {
            await fake.deliver(FakeEmail(from: "Jo <jo\(message % 4)@gmail.com>", subject: "Note \(message)",
                                         date: Date().addingTimeInterval(-Double(message) * 3600),
                                         labels: message % 3 == 0 ? [SystemLabel.inbox, SystemLabel.unread] : [SystemLabel.categoryUpdates]))
        }
        fakes[email] = fake
    }
    var configuration = SyncConfiguration.test()
    configuration.activePollInterval = 0.05
    let coordinator = SyncCoordinator(store: store, accounts: emails.map { Account(email: $0) },
                                      apiProvider: { fakes[$0]! }, encodeDraft: DraftEncoder.make(store: store),
                                      configuration: configuration)
    coordinator.start()

    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline, !emails.allSatisfy({ coordinator.status(for: $0)?.state == .live }) {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(emails.allSatisfy { coordinator.status(for: $0)?.state == .live })
    for (index, email) in emails.enumerated() {
        let count = try await store.database.reader.read { db in
            try MailMessage.filter(Column("accountId") == email).fetchCount(db)
        }
        #expect(count == 15 + index * 5, "\(email)")
        let signature = try await store.database.reader.read { db in try Setting.fetchOne(db, key: DraftStore.SettingKey.signature(email))?.value }
        #expect(signature == "<div>sig \(index)</div>")
    }
    let unsorted = try await store.database.reader.read { db in
        try Int.fetchOne(db, sql: """
            SELECT count(*) FROM thread t LEFT JOIN thread_ai ai ON ai.accountId = t.accountId AND ai.threadId = t.id
            WHERE ai.threadId IS NULL
            """)
    }
    #expect(unsorted == 0, "every thread of every account is sorted")
    await coordinator.shutdown()
}
