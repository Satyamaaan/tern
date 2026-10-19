import Foundation
import GRDB
import Testing
import TernCore
@testable import TernSync

// Gmail's tabs through sync: categorised mail of every tab (and some Gmail left uncategorised) lands in its tab,
// Move to tab reaches Gmail as a category label swap, and a category change made in Gmail moves the thread here.

/// One inbox message per tab plus one without a category, the newest first.
private func seedTabs(_ fake: FakeGmail) async -> [InboxTab?: GmailMessage] {
    var seeded: [InboxTab?: GmailMessage] = [:]
    let kinds: [InboxTab?] = InboxTab.allCases + [nil]
    for (index, tab) in kinds.enumerated() {
        seeded[tab] = await fake.deliver(FakeEmail(
            from: "Sender \(index) <sender\(index)@example.com>", subject: "Tab \(tab?.rawValue ?? "none")",
            date: testNow.addingTimeInterval(-Double(index + 1) * 60),
            labels: [SystemLabel.inbox, SystemLabel.unread] + (tab.map { [$0.labelId] } ?? [])))
    }
    return seeded
}

private func tabs(_ h: Harness) throws -> [String: InboxTab] {
    let rows = try h.store.database.reader.read { db in try MailStore.fetchInboxRows(db, InboxFilter(), limit: 50) }
    return Dictionary(uniqueKeysWithValues: rows.map { ($0.thread.id, $0.inboxTab) })
}

@Test func syncedMailLandsInItsGmailTab() async throws {
    let h = try Harness()
    let seeded = await seedTabs(h.fake)
    try await h.syncFully()
    let filed = try tabs(h)
    for tab in InboxTab.allCases { #expect(filed[seeded[tab]!.threadId] == tab, "\(tab)") }
    // Uncategorised and not classified yet: Primary.
    #expect(filed[seeded[nil]!.threadId] == .primary)
    let counts = try h.store.scopeCounts(accountId: testEmail)
    #expect(counts.tabThreads == [.primary: 2, .promotions: 1, .social: 1, .updates: 1, .forums: 1])
}

@Test func moveToTabReachesGmailAndGmailsMovesComeBack() async throws {
    let h = try Harness()
    let seeded = await seedTabs(h.fake)
    try await h.syncFully()
    let social = try #require(seeded[.social])

    try h.store.perform(.moveToTab(.primary), on: [h.thread(social.threadId)])
    try await h.sync.drainOps()
    #expect(await h.fake.modifyCalls.last == FakeGmail.ModifyCall(
        ids: [social.id], add: [SystemLabel.categoryPersonal], remove: [SystemLabel.categorySocial]))
    #expect(Set(await h.fake.labels(of: social.id) ?? []) == [SystemLabel.inbox, SystemLabel.unread, SystemLabel.categoryPersonal])
    #expect(try h.ops().isEmpty)
    try await h.sync.pollHistory()
    try await h.expectMirrorsGmail()
    #expect(try tabs(h)[social.threadId] == .primary)

    // Filed under Forums on the phone: history brings it over.
    let forums = try #require(seeded[.promotions])
    await h.fake.remoteModify([forums.id], add: [SystemLabel.categoryForums], remove: [SystemLabel.categoryPromotions])
    try await h.sync.pollHistory()
    #expect(try tabs(h)[forums.threadId] == .forums)
}
