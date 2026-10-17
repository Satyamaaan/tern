import Foundation
import Testing
import TernCore
@testable import TernSync

/// FakeGmail behind the HTTP client's rate limiter, on the engine's test clock, recording what each
/// call cost and what an interactive call arriving right after it would wait.
private actor LimitedGmail: GmailAPI {
    let base: FakeGmail
    let limiter: GmailRateLimiter
    private let quota = GmailQuota()
    /// Set after the engine is built, so samples can include its budget.
    var budget: QuotaBudget?
    private(set) var backgroundRequests: [Int] = []
    /// What a typical interactive call (an opened thread, 120 units) and the largest one (a history
    /// poll's 16 full messages, 960 units) would wait after each bulk or background call.
    private(set) var typicalWaits: [Double] = []
    private(set) var largestWaits: [Double] = []

    init(base: FakeGmail, limiter: GmailRateLimiter) {
        self.base = base
        self.limiter = limiter
    }

    func setBudget(_ budget: QuotaBudget) { self.budget = budget }

    private func call<T>(_ units: Int, _ body: () async throws -> T) async throws -> T {
        try await limiter.acquire(units)
        let result = try await body()
        if QuotaPriority.current != .interactive {
            backgroundRequests.append(units)
            let budgetTypical = await budget?.delay(for: 120, priority: .interactive) ?? 0
            let budgetLargest = await budget?.delay(for: 960, priority: .interactive) ?? 0
            typicalWaits.append(max(await limiter.delay(for: 120), budgetTypical))
            largestWaits.append(max(await limiter.delay(for: 960), budgetLargest))
        }
        return result
    }

    func profile() async throws -> GmailProfile { try await call(quota.profile) { try await base.profile() } }
    func labels() async throws -> [GmailLabel] { try await call(quota.labels) { try await base.labels() } }
    func createLabel(name: String) async throws -> GmailLabel { try await call(quota.changeLabel) { try await base.createLabel(name: name) } }
    func deleteLabel(id: String) async throws { try await call(quota.changeLabel) { try await base.deleteLabel(id: id) } }
    func messageIds(query: String?, labelIds: [String], pageToken: String?, maxResults: Int) async throws -> GmailIdPage {
        try await call(quota.list) { try await base.messageIds(query: query, labelIds: labelIds, pageToken: pageToken, maxResults: maxResults) }
    }
    func messages(ids: [String], format: GmailMessageFormat) async throws -> [GmailMessage] {
        try await call(ids.count * quota.messageCost(format)) { try await base.messages(ids: ids, format: format) }
    }
    func threads(ids: [String], format: GmailMessageFormat) async throws -> [GmailThread] {
        try await call(ids.count * quota.threadCost(format)) { try await base.threads(ids: ids, format: format) }
    }
    func history(startHistoryId: String, pageToken: String?) async throws -> GmailHistoryPage {
        try await call(quota.history) { try await base.history(startHistoryId: startHistoryId, pageToken: pageToken) }
    }
    func batchModify(messageIds: [String], add: [String], remove: [String]) async throws {
        try await call(quota.batchModify) { try await base.batchModify(messageIds: messageIds, add: add, remove: remove) }
    }
    func trashThread(id: String) async throws { try await call(quota.trashThread) { try await base.trashThread(id: id) } }
    func untrashThread(id: String) async throws { try await call(quota.trashThread) { try await base.untrashThread(id: id) } }
    func attachment(messageId: String, attachmentId: String) async throws -> Data {
        try await call(quota.attachment) { try await base.attachment(messageId: messageId, attachmentId: attachmentId) }
    }
    func send(raw: Data, threadId: String?) async throws -> GmailMessageRef { try await call(quota.send) { try await base.send(raw: raw, threadId: threadId) } }
    func createDraft(raw: Data, threadId: String?) async throws -> GmailDraft {
        try await call(quota.createDraft) { try await base.createDraft(raw: raw, threadId: threadId) }
    }
    func updateDraft(id: String, raw: Data, threadId: String?) async throws -> GmailDraft {
        try await call(quota.updateDraft) { try await base.updateDraft(id: id, raw: raw, threadId: threadId) }
    }
    func deleteDraft(id: String) async throws { try await call(quota.deleteDraft) { try await base.deleteDraft(id: id) } }
    func sendDraft(id: String) async throws -> GmailMessageRef { try await call(quota.send) { try await base.sendDraft(id: id) } }
    func sendAs() async throws -> [GmailSendAs] { try await call(quota.sendAs) { try await base.sendAs() } }
}

@Test func interactiveCallsNeverQueueBehindBackgroundWork() async throws {
    // Production pacing and request caps, small lists so the run is quick.
    var configuration = SyncConfiguration()
    configuration.listPageSize = 100
    configuration.attachmentCacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("tern-tests-\(UUID().uuidString)")
    configuration.observeSystemWake = false
    let clock = EngineTestClock()
    let googleClock = GoogleClock(now: { clock.now().timeIntervalSince1970 },
                                  sleep: { try await clock.sleep(seconds: $0) }, random: { 0.5 })
    let fake = FakeGmail(email: testEmail, sleep: { _ in })
    // 160 recent messages fetched in full, 240 older ones as metadata, then the body trickle.
    await seed(fake, count: 400, inboxEvery: 3, spacing: 3 * 3600)
    let limited = LimitedGmail(base: fake, limiter: GmailRateLimiter(unitsPerMinute: 6000, clock: googleClock))
    let store = try MailStore(AppDatabase.inMemory())
    let sync = AccountSync(account: Account(email: testEmail), store: store, api: limited, encodeDraft: testEncoder,
                           configuration: configuration, clock: clock)
    await limited.setBudget(sync.budget)

    var finished = false
    for _ in 0..<20_000 {
        let pending = try await store.database.reader.read { db in try MailStore.messageIdsNeedingBody(db, accountId: testEmail, limit: 1) }
        if try await store.database.reader.read({ db in try Account.fetchOne(db, key: testEmail)?.backfillDone }) == true, pending.isEmpty {
            finished = true
            break
        }
        if try await !sync.syncOnce() {
            let wakes = await [sync.nextBackgroundAt, sync.nextPollAt, sync.nextOpAt].compactMap { $0 }
            clock.advance(max(0.25, (wakes.min() ?? clock.now()).timeIntervalSince(clock.now())))
        }
    }
    #expect(finished)

    let requests = await limited.backgroundRequests
    #expect(requests.count > 100)
    #expect(requests.allSatisfy { $0 <= configuration.backgroundMaxUnitsPerRequest })
    // An opened thread, a send or a poll goes straight out; even the largest interactive request
    // waits about a second at most behind what background work took from the limiter.
    #expect(await limited.typicalWaits.allSatisfy { $0 == 0 })
    #expect(try #require(await limited.largestWaits.max()) <= 1.25)
    #expect(await fake.callCount(.messages) > 0)
}

@Test func pacingSmoothsBulkAndBackgroundButNotInteractiveCalls() async throws {
    let clock = EngineTestClock()
    let budget = QuotaBudget(unitsPerMinute: 6000, bulkReserve: 600, backgroundReserve: 1500, paceWindow: 4, clock: clock)
    #expect(budget.paceAllowance(.bulk) == 360)
    #expect(budget.paceAllowance(.background) == 300)
    #expect(budget.paceAllowance(.interactive) == nil)

    try await budget.acquire(240, priority: .background)
    #expect(await budget.delay(for: 60, priority: .background) == 0)
    #expect(await budget.delay(for: 120, priority: .background) == 4, "300 per 4 s")
    #expect(await budget.delay(for: 120, priority: .bulk) == 0, "bulk gets 360")
    #expect(await budget.delay(for: 3000, priority: .interactive) == 0)

    // Interactive spending counts against the pace too: background waits for it to age out.
    try await budget.acquire(1000, priority: .interactive)
    clock.advance(4.5)
    #expect(await budget.delay(for: 240, priority: .background) == 0)
    // A request bigger than the allowance still runs once the window is empty.
    #expect(await budget.delay(for: 400, priority: .background) == 0)
}
