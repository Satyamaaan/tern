import Foundation
import GRDB
import Testing
import TernCore
@testable import TernSync

private let work = "me@work.example"

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

private func count(_ store: MailStore, _ sql: String, _ accountId: String) throws -> Int {
    try store.database.reader.read { db in try Int.fetchOne(db, sql: sql, arguments: [accountId]) ?? 0 }
}

@MainActor
@Test func removingAnAccountLeavesNothingOfItBehind() async throws {
    let store = MailStore(try AppDatabase.inMemory())
    var configuration = SyncConfiguration.test()
    configuration.activePollInterval = 0.05
    let personal = FakeGmail(email: testEmail, sleep: { _ in })
    let office = FakeGmail(email: work, sleep: { _ in })
    await personal.deliver(FakeEmail(from: "Pat Home <pat@home.example>", subject: "Dinner", text: "Saturday?"))
    let contract = await office.deliver(FakeEmail(
        from: "Zed Client <zed@client.example>", subject: "Contract", text: "Signed copy attached, quokkalicious",
        attachments: [FakeAttachment(filename: "contract.pdf", mimeType: "application/pdf", data: Data("pdf".utf8))]))
    let coordinator = SyncCoordinator(
        store: store, accounts: [Account(email: testEmail), Account(email: work)],
        apiProvider: { $0 == work ? office : personal }, encodeDraft: testEncoder, configuration: configuration)
    coordinator.start()
    try await waitUntil { coordinator.status(for: work)?.state == .live && coordinator.status(for: testEmail)?.state == .live }

    // Things kept for the work account: a downloaded file, drafts with files, settings, its Muted label.
    let attachment = try #require(try store.threadDetail(ThreadKey(accountId: work, threadId: contract.threadId))?.attachments[contract.id]?.first)
    let downloaded = try await coordinator.downloadAttachment(attachment)
    let drafts = DraftStore(store.database, filesDirectory: configuration.draftFilesDirectory)
    let workDraft = Draft(accountId: work, toList: [Participant(email: "zed@client.example")], subject: "Re: Contract", bodyHtml: "<p>Thanks</p>")
    let workFile = try await drafts.addData(Data("notes".utf8), filename: "notes.txt", to: workDraft.id)
    try await drafts.save(workDraft, now: Date())
    let homeDraft = Draft(accountId: testEmail, toList: [Participant(email: "pat@home.example")], subject: "Dinner", bodyHtml: "<p>Yes</p>")
    let homeFile = try await drafts.addData(Data("menu".utf8), filename: "menu.txt", to: homeDraft.id)
    try await drafts.save(homeDraft, now: Date())
    _ = try await coordinator.sync(for: work)?.muteLabelId()
    try await store.database.writer.write { db in
        for key in MailStore.accountSettingKeys(work) + MailStore.accountSettingKeys(testEmail) {
            try Setting(key: key, value: "x").upsert(db)
        }
        try Setting(key: DraftStore.SettingKey.defaultAccount, value: work).upsert(db)
        try MailStore.rebuildContacts(db)
    }
    #expect(try await store.database.reader.read { db in try Contact.fetchOne(db, key: "zed@client.example") } != nil)

    try await coordinator.removeAccount(id: work)
    #expect(coordinator.status(for: work) == nil && coordinator.sync(for: work) == nil)
    // Long enough for a sync that was still running to write the account back.
    try await Task.sleep(for: .milliseconds(300))

    for table in ["account", "label", "message", "thread", "thread_label", "attachment", "draft", "pending_op", "label_check"] {
        let column = table == "account" ? "id" : "accountId"
        #expect(try count(store, "SELECT count(*) FROM \(table) WHERE \(column) = ?", work) == 0, "\(table)")
    }
    let settings = try await store.database.reader.read { db in try Setting.fetchAll(db).map(\.key) }
    #expect(MailStore.accountSettingKeys(work).allSatisfy { !settings.contains($0) })
    #expect(MailStore.accountSettingKeys(testEmail).allSatisfy { settings.contains($0) }, "the other account's stay")
    #expect(!settings.contains(DraftStore.SettingKey.defaultAccount))
    #expect(MailStore.accountSettingKeys(work).contains(SyncSettingKey.muteLabel(work)))

    #expect(!FileManager.default.fileExists(atPath: downloaded.path))
    #expect(!FileManager.default.fileExists(atPath: configuration.attachmentFolder(for: work).path))
    #expect(!FileManager.default.fileExists(atPath: workFile.path))
    #expect(FileManager.default.fileExists(atPath: homeFile.path))

    #expect(try await store.database.reader.read { db in try Contact.fetchOne(db, key: "zed@client.example") } == nil,
            "contacts only the removed account taught are gone")
    #expect(try await store.database.reader.read { db in try Contact.fetchOne(db, key: "pat@home.example") } != nil)
    #expect(try SearchService(store.database).search("quokkalicious", accountId: nil, limit: 10).isEmpty)
    try await store.database.writer.write { db in
        try db.execute(sql: "INSERT INTO message_fts(message_fts, rank) VALUES('integrity-check', 1)")
    }
    #expect(try count(store, "SELECT count(*) FROM message WHERE accountId = ?", testEmail) == 1)

    await coordinator.shutdown()
    try? FileManager.default.removeItem(at: configuration.attachmentCacheDirectory)
}

@MainActor
@Test func aDownloadInFlightWhenItsAccountIsRemovedLeavesNoFile() async throws {
    let store = MailStore(try AppDatabase.inMemory())
    let configuration = SyncConfiguration.test()
    let fake = FakeGmail(email: testEmail, sleep: { _ in })
    let delivered = await fake.deliver(FakeEmail(subject: "Scan", attachments: [
        FakeAttachment(filename: "scan.pdf", mimeType: "application/pdf", data: Data("pdf".utf8)),
    ]))
    let coordinator = SyncCoordinator(store: store, accounts: [Account(email: testEmail)], apiProvider: { _ in fake },
                                      encodeDraft: testEncoder, configuration: configuration, clock: EngineTestClock())
    try await #require(coordinator.sync(for: testEmail)).initialSync()
    let attachment = try #require(try store.threadDetail(ThreadKey(accountId: testEmail, threadId: delivered.threadId))?.attachments[delivered.id]?.first)

    // The account is removed while the file is on its way.
    await fake.onNext(.attachment) { try? await coordinator.removeAccount(id: testEmail) }
    await #expect(throws: SyncError.unknownAccount(testEmail)) { try await coordinator.downloadAttachment(attachment) }

    #expect(!FileManager.default.fileExists(atPath: configuration.attachmentFolder(for: testEmail).path))
    #expect(try store.accounts().isEmpty)
    try? FileManager.default.removeItem(at: configuration.attachmentCacheDirectory)
}
