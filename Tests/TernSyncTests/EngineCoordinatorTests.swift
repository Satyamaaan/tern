import Foundation
import GRDB
import Testing
import TernCore
@testable import TernSync

/// Polls `condition` until it holds or `timeout` passes (real time; for the coordinator's real loop).
@MainActor
private func waitUntil(timeout: Double = 10, _ condition: @MainActor () async throws -> Bool,
                       sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("timed out", sourceLocation: sourceLocation)
}

@MainActor
@Test func coordinatorSyncsSendsActionsAndPicksUpNewMail() async throws {
    let store = MailStore(try AppDatabase.inMemory())
    let fake = FakeGmail(email: testEmail, sleep: { _ in })
    let seeded = await seed(fake, count: 40)
    var configuration = SyncConfiguration.test()
    configuration.activePollInterval = 0.05
    let coordinator = SyncCoordinator(
        store: store, accounts: [Account(email: testEmail, displayName: "Me")], apiProvider: { _ in fake },
        encodeDraft: testEncoder, configuration: configuration)
    coordinator.start()

    try await waitUntil { coordinator.status(for: testEmail)?.state == .live }
    let status = try #require(coordinator.status(for: testEmail))
    #expect(status.phase == "Up to date")
    #expect(try await store.database.reader.read { db in try MailMessage.fetchCount(db) } == 40)
    #expect(try store.accounts().first?.displayName == "Me")

    // A local action reaches Gmail without an explicit kick.
    try store.perform(.archive, on: [ThreadKey(accountId: testEmail, threadId: seeded[0].threadId)])
    try await waitUntil { await fake.labels(of: seeded[0].id)?.contains(SystemLabel.inbox) == false }
    try await waitUntil { status.pendingOps == 0 }

    // New mail arrives through polling.
    let fresh = await fake.deliver(FakeEmail(subject: "Ping", text: "Pong"))
    try await waitUntil {
        try await store.database.reader.read { db in try MailMessage.filter(Column("id") == fresh.id).fetchCount(db) } == 1
    }

    // A snooze that has come due returns to the inbox.
    let snoozed = ThreadKey(accountId: testEmail, threadId: seeded[4].threadId)
    try store.perform(.snooze(until: Date().addingTimeInterval(-1)), on: [snoozed])
    await coordinator.wakeSnoozedThreads()
    #expect(try store.threadRows(in: Mailbox(.inbox, accountId: testEmail), limit: 100).contains { $0.id == snoozed })
    try await waitUntil { status.pendingOps == 0 }

    await coordinator.shutdown()
    #expect(!coordinator.isRunning)
}

@MainActor
@Test func coordinatorPausesOnUnauthorizedAndResumesAfterSignIn() async throws {
    let store = MailStore(try AppDatabase.inMemory())
    let fake = FakeGmail(email: testEmail, sleep: { _ in })
    await seed(fake, count: 8)
    await fake.failNext(1, with: .unauthorized, on: .profile)
    var configuration = SyncConfiguration.test()
    configuration.activePollInterval = 0.05
    let coordinator = SyncCoordinator(store: store, accounts: [Account(email: testEmail)], apiProvider: { _ in fake },
                                      encodeDraft: testEncoder, configuration: configuration)
    coordinator.start()

    try await waitUntil { coordinator.status(for: testEmail)?.state == .needsAuth }
    #expect(try store.accounts().first?.syncState == .needsAuth)
    // Kicks while paused must not keep the account busy (resume below would never get in).
    coordinator.kick()
    coordinator.syncNow()
    try await Task.sleep(for: .milliseconds(50))

    coordinator.reauthorized(accountId: testEmail)
    try await waitUntil { coordinator.status(for: testEmail)?.state == .live }
    #expect(try await store.database.reader.read { db in try MailMessage.fetchCount(db) } == 8)
    await coordinator.shutdown()
}

@MainActor
@Test func coordinatorKeepsPublishingStatusAfterRestart() async throws {
    let store = MailStore(try AppDatabase.inMemory())
    let fake = FakeGmail(email: testEmail, sleep: { _ in })
    await seed(fake, count: 6)
    var configuration = SyncConfiguration.test()
    configuration.activePollInterval = 0.05
    let coordinator = SyncCoordinator(store: store, accounts: [Account(email: testEmail)], apiProvider: { _ in fake },
                                      encodeDraft: testEncoder, configuration: configuration)
    coordinator.start()
    try await waitUntil { coordinator.status(for: testEmail)?.state == .live }
    await coordinator.shutdown()

    let stoppedAt = Date()
    coordinator.start()
    try await waitUntil { (coordinator.status(for: testEmail)?.lastSyncAt ?? .distantPast) > stoppedAt }
    let fresh = await fake.deliver(FakeEmail(subject: "After restart"))
    try await waitUntil {
        try await store.database.reader.read { db in try MailMessage.filter(Column("id") == fresh.id).fetchCount(db) } == 1
    }
    await coordinator.shutdown()
}

@MainActor
@Test func shutdownReturnsAtItsDeadlineWhenARequestHangs() async throws {
    let store = MailStore(try AppDatabase.inMemory())
    // Every request takes 3 s and ignores cancellation, like a stalled connection.
    let fake = FakeGmail(email: testEmail, latency: 3, sleep: { seconds in
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
        }
    })
    let coordinator = SyncCoordinator(store: store, accounts: [Account(email: testEmail)], apiProvider: { _ in fake },
                                      encodeDraft: testEncoder, configuration: .test())
    coordinator.start()
    try await Task.sleep(for: .milliseconds(100))

    let started = Date()
    await coordinator.shutdown(timeout: 0.3)
    #expect(Date().timeIntervalSince(started) < 1.5, "quitting doesn't wait out the hung request")
    #expect(!coordinator.isRunning)
}
