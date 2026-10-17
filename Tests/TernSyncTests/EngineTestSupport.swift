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
        configuration.recentCount = 30
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

/// Seeds `count` messages, oldest first, one minute apart; every `inboxEvery`th stays in the inbox.
@discardableResult
func seed(_ fake: FakeGmail, count: Int, inboxEvery: Int = 4, start: Date = Date(timeIntervalSince1970: 1_700_000_000)) async -> [GmailMessage] {
    var messages: [GmailMessage] = []
    for index in 0..<count {
        let inInbox = index % inboxEvery == 0
        let labels = inInbox ? [SystemLabel.inbox, SystemLabel.unread] : [SystemLabel.categoryUpdates]
        messages.append(await fake.deliver(FakeEmail(
            subject: "Message \(index)", text: "Body of message \(index)",
            date: start.addingTimeInterval(Double(index) * 60), labels: labels)))
    }
    return messages
}
