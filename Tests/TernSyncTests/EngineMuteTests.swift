import Foundation
import GRDB
import Testing
import TernCore
@testable import TernSync

/// A coordinator over one FakeGmail account, driven step by step (not started).
@MainActor
private struct MuteHarness {
    let store: MailStore
    let fake: FakeGmail
    let coordinator: SyncCoordinator
    let sync: AccountSync
    let clock = EngineTestClock()

    init() throws {
        store = try MailStore(AppDatabase.inMemory())
        let fake = FakeGmail(email: testEmail, sleep: { _ in })
        self.fake = fake
        coordinator = SyncCoordinator(store: store, accounts: [Account(email: testEmail)], apiProvider: { _ in fake },
                                      encodeDraft: testEncoder, configuration: .test(), clock: clock)
        sync = coordinator.sync(for: testEmail)!
    }

    func labels(_ id: String) throws -> [String] {
        try store.database.reader.read { db in try MailMessage.fetchOne(db, key: ["accountId": testEmail, "id": id])?.labelIds ?? [] }
    }

    func ops() throws -> [PendingOp] {
        try store.database.reader.read { db in try PendingOp.order(Column("id")).fetchAll(db) }
    }

    func inInbox(_ threadId: String) throws -> Bool {
        try store.threadRows(in: Mailbox(.inbox, accountId: testEmail), limit: 1000).contains { $0.thread.id == threadId }
    }

    func muteLabel() throws -> String? {
        try store.database.reader.read { db in try Setting.fetchOne(db, key: SyncSettingKey.muteLabel(testEmail))?.value }
    }
}

@MainActor
@Test func muteArchivesLabelsAndKeepsNewMailOutOfTheInbox() async throws {
    let h = try MuteHarness()
    let thread = await h.fake.deliver(FakeEmail(subject: "Weekly sync", date: testNow.addingTimeInterval(-600)))
    let other = await h.fake.deliver(FakeEmail(subject: "Lunch", date: testNow.addingTimeInterval(-300)))
    try await h.sync.initialSync()
    let key = ThreadKey(accountId: testEmail, threadId: thread.threadId)

    try await h.coordinator.mute([key])
    #expect(try !h.inInbox(thread.threadId), "archived at once")
    try await h.sync.drainOps()
    let label = try #require(try h.muteLabel())
    #expect(try h.store.threadDetail(key)?.thread.labelIds.contains(label) == true)
    let stored = try await h.store.database.reader.read { db in try MailLabel.fetchOne(db, key: ["accountId": testEmail, "id": label]) }
    #expect(stored?.name == "Muted")
    #expect(await h.fake.labels(of: thread.id).map(Set.init) == [label, SystemLabel.unread])

    // A reply arrives in the muted thread: archived again in the same write that stores it.
    let reply = await h.fake.deliver(FakeEmail(subject: "Re: Weekly sync", date: testNow, threadId: thread.threadId))
    try await h.sync.pollHistory()
    #expect(try !h.inInbox(thread.threadId))
    try await h.sync.drainOps()
    #expect(await h.fake.labels(of: reply.id)?.contains(SystemLabel.inbox) == false)
    #expect(await h.fake.labels(of: reply.id)?.contains(label) == true)

    // Other threads are untouched; muting another one reuses the label.
    #expect(try h.inInbox(other.threadId))
    try await h.coordinator.mute([ThreadKey(accountId: testEmail, threadId: other.threadId)])
    #expect(await h.fake.callCount(.createLabel) == 1)
}

@MainActor
@Test func unmuteAndUndo() async throws {
    let h = try MuteHarness()
    let thread = await h.fake.deliver(FakeEmail(subject: "Newsletter thread", date: testNow.addingTimeInterval(-600)))
    try await h.sync.initialSync()
    let key = ThreadKey(accountId: testEmail, threadId: thread.threadId)

    // Undo right away puts it back; nothing reaches Gmail.
    let token = try await h.coordinator.mute([key])
    #expect(try !h.inInbox(thread.threadId))
    try h.store.undo(token)
    #expect(try h.inInbox(thread.threadId))
    try await h.sync.drainOps()
    #expect(await h.fake.modifyCalls.isEmpty)

    try await h.coordinator.mute([key])
    try await h.sync.drainOps()
    try await h.coordinator.unmute([key])
    try await h.sync.drainOps()
    let label = try #require(try h.muteLabel())
    #expect(await h.fake.labels(of: thread.id)?.contains(label) == false)

    // Unmuted: new mail comes to the inbox again.
    await h.fake.deliver(FakeEmail(subject: "Re: Newsletter thread", date: testNow, threadId: thread.threadId))
    try await h.sync.pollHistory()
    #expect(try h.inInbox(thread.threadId))
}

@MainActor
@Test func anExistingOrDeletedMutedLabelIsHandled() async throws {
    let h = try MuteHarness()
    let own = try await h.fake.createLabel(name: "Muted")
    let thread = await h.fake.deliver(FakeEmail(subject: "Hi", date: testNow.addingTimeInterval(-60)))
    try await h.sync.initialSync()
    let key = ThreadKey(accountId: testEmail, threadId: thread.threadId)

    try await h.coordinator.mute([key])
    try await h.sync.drainOps()
    #expect(try h.muteLabel() == own.id, "the label the user already had")
    #expect(await h.fake.callCount(.createLabel) == 1)

    // Deleted in Gmail: the next mute makes a new one.
    try await h.fake.deleteLabel(id: own.id)
    try await h.sync.syncLabels()
    try await h.coordinator.mute([key])
    try await h.sync.drainOps()
    let fresh = try #require(try h.muteLabel())
    #expect(fresh != own.id)
    #expect(await h.fake.labels(of: thread.id)?.contains(fresh) == true)
    #expect(try !h.labels(thread.id).contains(MailStore.pendingMuteLabel))
}

@MainActor
@Test func aMutedLabelDeletedInGmailDoesNotHoldUpTheQueue() async throws {
    let h = try MuteHarness()
    let thread = await h.fake.deliver(FakeEmail(subject: "Old thread", date: testNow.addingTimeInterval(-600)))
    try await h.sync.initialSync()
    try await h.coordinator.mute([ThreadKey(accountId: testEmail, threadId: thread.threadId)])
    try await h.sync.drainOps()
    let label = try #require(try h.muteLabel())

    try await h.fake.deleteLabel(id: label)
    try await h.sync.syncLabels()
    let reply = await h.fake.deliver(FakeEmail(subject: "Re: Old thread", date: testNow, threadId: thread.threadId))
    try await h.sync.pollHistory()
    #expect(try h.inInbox(thread.threadId), "no longer muted in Gmail: left in the inbox")
    #expect(try await h.store.database.reader.read { db in try PendingOp.fetchCount(db) } == 0)
    #expect(await h.fake.labels(of: reply.id)?.contains(SystemLabel.inbox) == true)
}

@MainActor
@Test func theFirstMuteWorksOffline() async throws {
    let h = try MuteHarness()
    let thread = await h.fake.deliver(FakeEmail(subject: "Standup notes", date: testNow.addingTimeInterval(-600)))
    try await h.sync.initialSync()
    let key = ThreadKey(accountId: testEmail, threadId: thread.threadId)
    await h.fake.failNext(1_000, with: .network("The Internet connection appears to be offline."))

    try await h.coordinator.mute([key])
    #expect(try !h.inInbox(thread.threadId), "archived at once, with no label lookup first")
    #expect(try h.labels(thread.id).contains(MailStore.pendingMuteLabel))
    try await h.sync.drainOps()
    #expect(try h.ops().map(\.state) == [.pending], "kept until Gmail is reachable")
    #expect(try !h.inInbox(thread.threadId))

    await h.fake.clearFailures()
    h.clock.advance(600)
    try await h.sync.drainOps()
    let label = try #require(try h.muteLabel())
    #expect(await h.fake.labels(of: thread.id).map(Set.init) == [label, SystemLabel.unread])
    #expect(try Set(h.labels(thread.id)) == [label, SystemLabel.unread], "the stand-in is replaced locally too")
    #expect(try h.ops().isEmpty)

    // A reply is kept out of the inbox like for any muted thread.
    let reply = await h.fake.deliver(FakeEmail(subject: "Re: Standup notes", date: testNow, threadId: thread.threadId))
    try await h.sync.pollHistory()
    try await h.sync.drainOps()
    #expect(try !h.inInbox(thread.threadId))
    #expect(await h.fake.labels(of: reply.id)?.contains(SystemLabel.inbox) == false)
}

@MainActor
@Test func anOfflineFirstMuteCanBeUndone() async throws {
    let h = try MuteHarness()
    let thread = await h.fake.deliver(FakeEmail(subject: "Raffle", date: testNow.addingTimeInterval(-600)))
    try await h.sync.initialSync()
    let key = ThreadKey(accountId: testEmail, threadId: thread.threadId)
    await h.fake.failNext(1_000, with: .network("offline"))

    // Undone before it was tried: nothing ever reaches Gmail.
    let early = try await h.coordinator.mute([key])
    try h.store.undo(early)
    #expect(try h.inInbox(thread.threadId))
    #expect(try h.ops().isEmpty)
    #expect(try !h.labels(thread.id).contains(MailStore.pendingMuteLabel))

    // Undone after a try that failed offline: the reverse follows it once Gmail is reachable.
    let late = try await h.coordinator.mute([key])
    try await h.sync.drainOps()
    try h.store.undo(late)
    #expect(try h.inInbox(thread.threadId))
    await h.fake.clearFailures()
    h.clock.advance(600)
    try await h.sync.drainOps()
    #expect(try h.ops().isEmpty)
    #expect(await h.fake.labels(of: thread.id).map(Set.init) == [SystemLabel.inbox, SystemLabel.unread])
    #expect(try Set(h.labels(thread.id)) == [SystemLabel.inbox, SystemLabel.unread])
    try await h.sync.pollHistory()
    #expect(try h.inInbox(thread.threadId))
}
