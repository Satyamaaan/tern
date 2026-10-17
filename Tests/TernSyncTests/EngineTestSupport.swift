import Foundation
import GRDB
import Testing
import TernCore
@testable import TernSync

/// A clock whose sleeps return at once and move time forward, so backoff and timers cost nothing.
final class TestClock: SyncClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    func now() -> Date { lock.withLock { current } }

    func advance(_ seconds: Double) { lock.withLock { current = current.addingTimeInterval(seconds) } }

    func sleep(seconds: Double) async throws {
        advance(max(0, seconds))
        await Task.yield()
    }
}

let testEmail = "me@example.com"

extension SyncConfiguration {
    /// Small pages so a few hundred messages exercise pagination, batching and resumption.
    static func test(cache: URL = FileManager.default.temporaryDirectory.appendingPathComponent("tern-tests-\(UUID().uuidString)")) -> SyncConfiguration {
        var configuration = SyncConfiguration()
        configuration.listPageSize = 25
        configuration.fetchBatchSize = 10
        configuration.writeBatchSize = 20
        configuration.backfillBatchSize = 10
        configuration.bulkStepUnits = 600
        configuration.prefetchBatchSize = 15
        configuration.attachmentCacheDirectory = cache
        configuration.observeSystemWake = false
        return configuration
    }
}

/// The trivial RFC 822 encoder tests use in place of the MIME builder.
let testEncoder: @Sendable (Draft, Account) throws -> Data = { draft, account in
    var lines = [
        "From: \(account.email)",
        "To: \(draft.toList.map(\.email).joined(separator: ", "))",
        "Subject: \(draft.subject)",
        "Content-Type: text/html; charset=UTF-8",
    ]
    if let reply = draft.replyToMessageId { lines.append("In-Reply-To: <\(reply)@fake.tern>") }
    return Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + draft.bodyHtml).utf8)
}

struct Harness {
    let store: MailStore
    let fake: FakeGmail
    let sync: AccountSync
    let clock: TestClock
    let configuration: SyncConfiguration
    var accountId: String { testEmail }

    init(configuration: SyncConfiguration = .test(), fake: FakeGmail? = nil, store: MailStore? = nil) throws {
        self.store = try store ?? MailStore(AppDatabase.inMemory())
        let clock = TestClock()
        self.clock = clock
        self.fake = fake ?? FakeGmail(email: testEmail, sleep: { _ in })
        self.configuration = configuration
        self.sync = AccountSync(account: Account(email: testEmail), store: self.store, api: self.fake,
                                encodeDraft: testEncoder, configuration: configuration, clock: clock)
    }

    /// A second engine over the same store and account, as after relaunching the app.
    func relaunched() -> AccountSync {
        AccountSync(account: Account(email: testEmail), store: store, api: fake, encodeDraft: testEncoder,
                    configuration: configuration, clock: clock)
    }

    func account() throws -> Account {
        try #require(try store.database.reader.read { db in try Account.fetchOne(db, key: testEmail) })
    }

    func messages() throws -> [String: MailMessage] {
        let all = try store.database.reader.read { db in try MailMessage.fetchAll(db) }
        return Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    }

    func message(_ id: String) throws -> MailMessage? { try messages()[id] }

    func ops() throws -> [PendingOp] {
        try store.database.reader.read { db in try PendingOp.order(Column("id")).fetchAll(db) }
    }

    func inboxThreadIds() throws -> Set<String> {
        Set(try store.threadRows(in: Mailbox(.inbox, accountId: testEmail), limit: 10_000).map(\.thread.id))
    }

    func thread(_ id: String) -> ThreadKey { ThreadKey(accountId: testEmail, threadId: id) }

    /// Local messages and their labels equal Gmail's.
    func expectMirrorsGmail(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let local = try messages()
        let remoteIds = await fake.allMessageIds
        #expect(Set(local.keys) == Set(remoteIds), sourceLocation: sourceLocation)
        for id in remoteIds {
            let remote = Set(await fake.labels(of: id) ?? [])
            #expect(Set(local[id]?.labelIds ?? []) == remote, "labels of \(id)", sourceLocation: sourceLocation)
        }
    }
}

/// The test clock's starting time; seeded mail ends just before it.
let testNow = Date(timeIntervalSince1970: 1_800_000_000)

/// Seeds `count` messages, oldest first, `spacing` apart, the newest a minute before `testNow`;
/// every `inboxEvery`th stays in the inbox. With 12-hour spacing, messages 60+ back are older than
/// the 30 days the initial sync fetches in full.
@discardableResult
func seed(_ fake: FakeGmail, count: Int, inboxEvery: Int = 4, spacing: TimeInterval = 3600) async -> [GmailMessage] {
    var messages: [GmailMessage] = []
    let newest = testNow.addingTimeInterval(-60)
    for index in 0..<count {
        let inInbox = index % inboxEvery == 0
        let labels = inInbox ? [SystemLabel.inbox, SystemLabel.unread] : [SystemLabel.categoryUpdates]
        messages.append(await fake.deliver(FakeEmail(
            subject: "Message \(index)", text: "Body of message \(index)",
            date: newest.addingTimeInterval(-Double(count - 1 - index) * spacing), labels: labels)))
    }
    return messages
}

/// Older than the 30-day window, so backfilled as metadata.
func isOld(_ message: GmailMessage) -> Bool {
    (Double(message.internalDate ?? "0") ?? 0) / 1000 <= testNow.timeIntervalSince1970 - 30 * 86_400
}

extension Harness {
    func syncFully() async throws {
        try await sync.initialSync()
        while try await sync.backfillStep() {}
    }

    /// Drives `syncOnce` like the run loop, jumping the clock to the next wake-up when idle.
    func runLoop(until done: () async throws -> Bool, limit: Int = 20_000,
                 sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<limit {
            if try await done() { return }
            if try await !sync.syncOnce() {
                let wakes = await [sync.nextBackgroundAt, sync.nextPollAt, sync.nextOpAt].compactMap { $0 }
                let next = wakes.min().map { $0.timeIntervalSince(clock.now()) } ?? 1
                clock.advance(max(0.25, next))
            }
        }
        Issue.record("the loop didn't finish", sourceLocation: sourceLocation)
    }
}
