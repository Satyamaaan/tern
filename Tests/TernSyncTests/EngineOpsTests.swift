import Foundation
import GRDB
import Testing
import TernCore
@testable import TernSync

@Test func pendingArchiveSurvivesRemoteChangesUntilSent() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 8)
    try await h.syncFully()
    let message = seeded[0]
    let key = h.thread(message.threadId)

    try h.store.perform(.archive, on: [key])
    // Meanwhile the user reads it on their phone.
    await h.fake.remoteModify([message.id], remove: [SystemLabel.unread])
    try await h.sync.pollHistory()

    var local = try #require(try h.message(message.id))
    #expect(!local.labelIds.contains(SystemLabel.inbox), "the local archive doesn't flicker back")
    #expect(!local.isUnread, "the remote change still applies")
    #expect(!(try h.inboxThreadIds().contains(key.threadId)))

    // A full resync and a body refetch don't revert it either, also while the op is inflight.
    try await h.sync.fullResync()
    #expect(!(try h.inboxThreadIds().contains(key.threadId)))
    try await h.store.database.writer.write { db in
        try db.execute(sql: "UPDATE pending_op SET state = 'inflight'")
        try db.execute(sql: "UPDATE message SET bodyState = 0 WHERE id = ?", arguments: [message.id])
    }
    try await h.sync.prefetchBodies()
    local = try #require(try h.message(message.id))
    #expect(local.bodyState == .full)
    #expect(!local.labelIds.contains(SystemLabel.inbox))

    try await h.store.database.writer.write { db in try db.execute(sql: "UPDATE pending_op SET state = 'pending'") }
    try await h.sync.drainOps()
    #expect(await h.fake.labels(of: message.id)?.contains(SystemLabel.inbox) == false)
    #expect(try h.ops().isEmpty)
    try await h.sync.pollHistory()
    try await h.expectMirrorsGmail()
}

@Test func labelChangesAreGroupedIntoBatchModifyCalls() async throws {
    var configuration = SyncConfiguration.test()
    configuration.maxBatchModifyIds = 2
    let h = try Harness(configuration: configuration)
    let seeded = await seed(h.fake, count: 10)
    try await h.syncFully()
    let inbox = [seeded[0], seeded[4], seeded[8]]

    try h.store.perform(.archive, on: inbox.map { h.thread($0.threadId) })
    try h.store.perform(.star, on: [h.thread(seeded[0].threadId)])
    try await h.sync.drainOps()

    let calls = await h.fake.modifyCalls
    let archives = calls.filter { $0.remove == [SystemLabel.inbox] && $0.add.isEmpty }
    #expect(archives.count == 2)
    #expect(archives.allSatisfy { $0.ids.count <= 2 })
    #expect(Set(archives.flatMap(\.ids)) == Set(inbox.map(\.id)))
    #expect(calls.last == FakeGmail.ModifyCall(ids: [seeded[0].id], add: [SystemLabel.starred], remove: []))
    #expect(try h.ops().isEmpty)
    try await h.sync.pollHistory()
    try await h.expectMirrorsGmail()
}

@Test func failedOpBacksOffThenSucceeds() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 4)
    try await h.syncFully()
    await h.fake.failNext(3, with: .server(status: 503, message: "busy"), on: .batchModify)

    try h.store.perform(.archive, on: [h.thread(seeded[0].threadId)])
    try await h.sync.drainOps()
    var op = try #require(try h.ops().first)
    #expect(op.attempts == 1)
    #expect(op.state == .pending)
    #expect(op.notBefore == h.clock.now().addingTimeInterval(2))
    #expect(await h.sync.nextOpAt == op.notBefore)

    try await h.sync.drainOps()
    #expect(await h.fake.callCount(.batchModify) == 1, "not retried before its backoff")

    h.clock.advance(2)
    try await h.sync.drainOps()
    op = try #require(try h.ops().first)
    #expect(op.attempts == 2)
    #expect(op.notBefore == h.clock.now().addingTimeInterval(4))

    for _ in 0..<2 {
        h.clock.advance(300)
        try await h.sync.drainOps()
    }
    #expect(await h.fake.callCount(.batchModify) == 4)
    #expect(try h.ops().isEmpty)
    #expect(await h.fake.labels(of: seeded[0].id)?.contains(SystemLabel.inbox) == false)
}

@Test func opFailsForGoodAfterEightAttemptsAndRollsBack() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 4)
    try await h.syncFully()
    await h.fake.failNext(100, with: .server(status: 400, message: "Invalid request"), on: .batchModify)

    try h.store.perform(.archive, on: [h.thread(seeded[0].threadId)])
    #expect(!(try h.inboxThreadIds().contains(seeded[0].threadId)))
    for _ in 0..<12 {
        try await h.sync.drainOps()
        h.clock.advance(1000)
    }

    let op = try #require(try h.ops().first)
    #expect(op.state == .failed)
    #expect(op.attempts == 8)
    #expect(op.lastError?.contains("Invalid request") == true)
    #expect(await h.fake.callCount(.batchModify) == 8)
    #expect(try h.inboxThreadIds().contains(seeded[0].threadId), "the local change is rolled back to Gmail's state")
}

@Test func laterLabelOpsWaitBehindOneThatIsBackingOff() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 4)
    try await h.syncFully()
    let key = h.thread(seeded[0].threadId)
    await h.fake.failNext(1, with: .server(status: 500, message: "oops"), on: .batchModify)

    try h.store.perform(.archive, on: [key])
    try h.store.perform(.moveToInbox, on: [key])
    try await h.sync.drainOps()
    #expect(await h.fake.callCount(.batchModify) == 1, "the second op waits for the first")
    #expect(try h.ops().count == 2)

    h.clock.advance(5)
    try await h.sync.drainOps()
    #expect(await h.fake.callCount(.batchModify) == 3)
    let calls = await h.fake.modifyCalls
    #expect(calls.map(\.remove) == [[SystemLabel.inbox], []], "the archive lands before the move back")
    #expect(calls.last?.add == [SystemLabel.inbox])
    #expect(await h.fake.labels(of: seeded[0].id)?.contains(SystemLabel.inbox) == true)
}

@Test func offlineAndRateLimitsDontUseUpAttempts() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 4)
    try await h.syncFully()
    await h.fake.failNext(1, with: .network("offline"), on: .batchModify)
    await h.fake.failNext(1, with: .rateLimited(retryAfter: 30), on: .batchModify)

    try h.store.perform(.markRead, on: [h.thread(seeded[0].threadId)])
    try await h.sync.drainOps()
    var op = try #require(try h.ops().first)
    #expect(op.attempts == 0 && op.state == .pending && op.lastError != nil)

    h.clock.advance(10)
    try await h.sync.drainOps()
    op = try #require(try h.ops().first)
    #expect(op.attempts == 0)
    #expect(op.notBefore == h.clock.now().addingTimeInterval(30))

    h.clock.advance(15)
    try await h.sync.drainOps()
    #expect(await h.fake.callCount(.batchModify) == 2, "waits for Retry-After")
    h.clock.advance(16)
    try await h.sync.drainOps()
    #expect(try h.ops().isEmpty)
}

@Test func unauthorizedPausesTheAccountUntilSignIn() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 4)
    try await h.syncFully()
    await h.fake.failNext(1, with: .unauthorized, on: .batchModify)

    try h.store.perform(.archive, on: [h.thread(seeded[0].threadId)])
    do {
        try await h.sync.syncOnce()
        Issue.record("expected unauthorized")
    } catch {
        await h.sync.handle(error)
    }
    #expect(try h.account().syncState == .needsAuth)
    #expect(await h.sync.status.state == .needsAuth)
    #expect(await h.sync.paused)
    let op = try #require(try h.ops().first)
    #expect(op.state == .pending && op.attempts == 0)

    await h.sync.resume(api: h.fake)
    #expect(try h.account().syncState == .live)
    try await h.sync.syncOnce()
    #expect(try h.ops().isEmpty)
    #expect(await h.fake.labels(of: seeded[0].id)?.contains(SystemLabel.inbox) == false)
}

@Test func undoBeforeSendDropsTheOp() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 4)
    try await h.syncFully()
    let token = try h.store.perform(.trash, on: [h.thread(seeded[0].threadId)])
    try h.store.undo(token)
    try await h.sync.drainOps()
    #expect(await h.fake.callCount(.batchModify) == 0)
    try await h.expectMirrorsGmail()
}

@Test func undoAfterALostResponseStillPutsTheThreadBackInGmail() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 4)
    try await h.syncFully()
    let thread = h.thread(seeded[0].threadId)
    await h.fake.loseNextResponse(on: .batchModify)
    let token = try h.store.perform(.archive, on: [thread])
    try await h.sync.drainOps()
    #expect(await h.fake.labels(of: seeded[0].id)?.contains(SystemLabel.inbox) == false, "Gmail archived it")
    #expect(try h.ops().first?.state == .pending, "but the answer was lost")

    try h.store.undo(token)
    #expect(try h.inboxThreadIds().contains(thread.threadId))
    h.clock.advance(60)
    try await h.sync.drainOps()
    try await h.sync.pollHistory()
    #expect(await h.fake.labels(of: seeded[0].id)?.contains(SystemLabel.inbox) == true)
    #expect(try h.inboxThreadIds().contains(thread.threadId), "history doesn't archive it again")
    #expect(try h.ops().isEmpty)
    try await h.expectMirrorsGmail()
}

@Test func anOpUndoneAfterTheQueueWasReadIsNeverSent() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 4)
    try await h.syncFully()
    let token = try h.store.perform(.trash, on: [h.thread(seeded[0].threadId)])
    // The drain has read the queue; undo lands before the op goes out.
    let read = try #require(try h.ops().first)
    try h.store.undo(token)
    _ = try await h.sync.execute(read, now: h.clock.now())

    #expect(await h.fake.callCount(.batchModify) == 0)
    #expect(try h.ops().isEmpty)
    try await h.sync.pollHistory()
    try await h.expectMirrorsGmail()
    #expect(try h.inboxThreadIds().contains(seeded[0].threadId))
}

@Test func labelOpsSkipMessagesGmailDeletedMeanwhile() async throws {
    let h = try Harness()
    let first = await h.fake.deliver(FakeEmail(subject: "Thread", date: Date(timeIntervalSince1970: 1_700_000_000)))
    let second = await h.fake.deliver(FakeEmail(subject: "Re: Thread", date: Date(timeIntervalSince1970: 1_700_000_100),
                                                threadId: first.threadId))
    try await h.syncFully()

    try h.store.perform(.archive, on: [h.thread(first.threadId)])
    await h.fake.remoteDelete([first.id])
    try await h.sync.pollHistory()
    try await h.sync.drainOps()

    #expect(await h.fake.modifyCalls.map(\.ids) == [[second.id]])
    #expect(try h.ops().isEmpty)
    try await h.expectMirrorsGmail()
}

@Test func batchModifyRecoversWhenGmailRejectsDeletedIds() async throws {
    let h = try Harness()
    let first = await h.fake.deliver(FakeEmail(subject: "Thread", date: Date(timeIntervalSince1970: 1_700_000_000)))
    let second = await h.fake.deliver(FakeEmail(subject: "Re: Thread", date: Date(timeIntervalSince1970: 1_700_000_100),
                                                threadId: first.threadId))
    try await h.syncFully()
    await h.fake.setRejectsUnknownIds(true)

    try h.store.perform(.archive, on: [h.thread(first.threadId)])
    // Deleted on the phone; history hasn't told us yet.
    await h.fake.remoteDelete([first.id])
    try await h.sync.drainOps()

    #expect(try h.ops().isEmpty)
    #expect(await h.fake.labels(of: second.id)?.contains(SystemLabel.inbox) == false)
    try await h.sync.pollHistory()
    try await h.expectMirrorsGmail()
}

@Test func aLostBatchModifyResponseIsRetriedHarmlessly() async throws {
    let h = try Harness()
    let seeded = await seed(h.fake, count: 4)
    try await h.syncFully()
    await h.fake.loseNextResponse(on: .batchModify)
    try h.store.perform(.markRead, on: [h.thread(seeded[0].threadId)])
    try await h.sync.drainOps()
    h.clock.advance(60)
    try await h.sync.drainOps()
    #expect(try h.ops().isEmpty)
    try await h.sync.pollHistory()
    try await h.expectMirrorsGmail()
}
