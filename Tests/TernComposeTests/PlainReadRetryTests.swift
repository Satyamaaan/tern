import AppKit
import Foundation
import GRDB
import SQLite3
import Testing
@testable import Tern
import TernCore

@MainActor
@Test func failedPlainReadsRetryWithoutAnotherDatabaseChange() async throws {
    _ = NSApplication.shared
    let failures = ReadInterruptions()
    var configuration = Configuration()
    configuration.prepareDatabase { db in
        let connection = db.sqliteConnection
        db.trace { event in
            if case .statement(let statement) = event, failures.interrupt(statement.sql) {
                sqlite3_interrupt(connection)
            }
        }
    }
    let database = try AppDatabase(DatabaseQueue(configuration: configuration))
    let account = Account(email: "synthetic@example.com")
    try await database.writer.write { db in
        try account.insert(db)
        try MailLabel(accountId: account.id, id: "custom", name: "Custom").insert(db)
        try MailStore.upsertMessages(db, [MailMessage(accountId: account.id, id: "m", threadId: "t",
            date: Date(), fromEmail: "sender@example.com", subject: "Synthetic", labelIds: [SystemLabel.inbox, SystemLabel.unread])])
    }
    let model = AppModel(services: AppServices(store: MailStore(database)), isFake: true,
                         databaseURL: URL(fileURLWithPath: "/dev/null"))
    // Keep observations quiet so only the navigation reads can deliver these values.
    model.rowsObservation = AnyDatabaseCancellable { }
    model.countsObservation = AnyDatabaseCancellable { }
    model.labelsObservation = AnyDatabaseCancellable { }
    model.scope = .account(account.id)
    failures.arm()
    model.observeScope()
    model.show(.allMail)
    #expect(!model.listLoaded)
    for _ in 0..<200 {
        if model.listLoaded, model.counts.inboxUnread == 1, model.labels.count == 1 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(failures.remaining.isEmpty)
    #expect(model.snapshot.order.map(\.threadId) == ["t"])
    #expect(model.counts.inboxUnread == 1)
    #expect(model.labels.map(\.id) == ["custom"])
}

private final class ReadInterruptions: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Set<String> = []

    var remaining: Set<String> { lock.withLock { pending } }

    func arm() {
        lock.withLock { pending = ["FROM thread t", "FROM setting", "FROM \"label\""] }
    }

    func interrupt(_ sql: String) -> Bool {
        lock.withLock {
            guard let match = pending.first(where: sql.contains) else { return false }
            pending.remove(match)
            return true
        }
    }
}
