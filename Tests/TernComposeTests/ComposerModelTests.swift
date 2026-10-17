import AppKit
import GRDB
import Testing
@testable import Tern
@testable import TernCore

@MainActor
private func makeServices() throws -> (AppServices, ThreadKey) {
    let database = try AppDatabase.inMemory()
    let account = Account(email: "me@example.com")
    let key = ThreadKey(accountId: account.id, threadId: "t1")
    try database.writer.write { db in
        try account.insert(db)
        try MailStore.upsertMessages(db, [
            MailMessage(accountId: account.id, id: "m1", threadId: "t1", date: Date(timeIntervalSince1970: 100),
                        fromName: "Maya Chen", fromEmail: "maya@lumen.io", toList: [Participant(email: account.email)],
                        ccList: [Participant(name: "Jonas", email: "jonas@lumen.io")], subject: "Venues",
                        bodyText: "Which one?", bodyState: .full, labelIds: ["INBOX", "UNREAD"]),
        ])
    }
    let services = AppServices(store: MailStore(database))
    services.accounts = [account]
    services.draftFilesDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("tern-compose-tests-\(UUID().uuidString)")
    return (services, key)
}

@MainActor
private func ops(_ services: AppServices) throws -> [PendingOp] {
    try services.store.database.reader.read { db in try PendingOp.order(Column("id")).fetchAll(db) }
}

@MainActor
@Test func typingSavesTheDraftAndQueuesOneGmailSave() async throws {
    let (services, _) = try makeServices()
    let model = try #require(ComposerModel(request: .new(accountId: nil, to: [Participant(email: "maya@lumen.io")]), services: services, mode: .window))
    model.setSubject("Hello")
    model.editor.textView.insertText("Hi Maya", replacementRange: model.editor.textView.selectedRange())
    model.persist()
    await model.waitForWrites()
    let draft = try #require(try services.drafts.draft(id: model.id))
    #expect(draft.subject == "Hello")
    #expect(draft.bodyHtml == "<div>Hi Maya</div>")
    #expect(try ops(services).map(\.kind) == [.saveDraft])
}

@MainActor
@Test func closingABlankDraftLeavesNothing() async throws {
    let (services, _) = try makeServices()
    let model = try #require(ComposerModel(request: .new(accountId: nil), services: services, mode: .window))
    var closed = false
    model.onClose = { closed = true }
    model.close()
    await model.waitForWrites()
    #expect(closed)
    #expect(try await services.store.database.reader.read { db in try Draft.fetchCount(db) } == 0)
}

@MainActor
@Test func sendRefusesInvalidRecipientsThenQueuesAndArchives() async throws {
    let (services, key) = try makeServices()
    var notices: [SendUndoNotice] = []
    services.showSendUndo = { notices.append($0) }
    let model = try #require(ComposerModel(request: .reply(key, all: true), services: services, mode: .inline))
    #expect(model.to.map(\.email) == ["maya@lumen.io"])
    #expect(model.cc.map(\.email) == ["jonas@lumen.io"])
    #expect(model.showCc)
    var closed = false
    model.onClose = { closed = true }

    model.setRecipients(model.cc + [Participant(email: "ops@lumen")], for: .cc)
    model.send()
    #expect(!closed)
    #expect(model.notice == "Check “ops@lumen” in Cc")

    model.setRecipients([Participant(name: "Jonas", email: "jonas@lumen.io")], for: .cc)
    model.editor.textView.insertText("Casa do Rio", replacementRange: model.editor.textView.selectedRange())
    model.send(archive: true)
    #expect(closed)
    await model.waitForWrites()
    #expect(notices.count == 1)
    #expect(notices.first?.message == "Sending")
    let draft = try #require(try services.drafts.draft(id: model.id))
    #expect(draft.state == .queued)
    #expect(draft.bodyHtml.hasPrefix("<div>Casa do Rio</div><br><div class=\"gmail_quote\">"))
    try await Task.sleep(for: .milliseconds(100))
    // The send, plus the archive's label change.
    #expect(try Set(ops(services).map(\.kind)) == [.sendDraft, .modifyLabels])
    #expect(try services.store.threadRows(in: .unifiedInbox).isEmpty)
}

@MainActor
@Test func draggingAPillMovesItBetweenFields() throws {
    let (services, key) = try makeServices()
    let model = try #require(ComposerModel(request: .reply(key, all: true), services: services, mode: .window))
    let jonas = Participant(name: "Jonas", email: "jonas@lumen.io")
    model.drop(RecipientDrag(participant: jonas, kind: .cc, composerId: model.id), into: .to)
    #expect(model.to.map(\.email) == ["maya@lumen.io", "jonas@lumen.io"])
    #expect(model.cc.isEmpty)
    // From another composer it is copied, never duplicated.
    model.drop(RecipientDrag(participant: Participant(email: "MAYA@lumen.io"), kind: .to, composerId: "other"), into: .to)
    #expect(model.to.count == 2)
}

@MainActor
@Test func discardAsksOnceWhenThereIsText() async throws {
    let (services, key) = try makeServices()
    let model = try #require(ComposerModel(request: .reply(key, all: false), services: services, mode: .inline))
    var closed = false
    model.onClose = { closed = true }
    model.editor.textView.insertText("Draft text", replacementRange: model.editor.textView.selectedRange())
    model.persist()
    model.requestDiscard()
    #expect(model.confirmingDiscard)
    #expect(!closed)
    model.requestDiscard()
    #expect(closed)
    await model.waitForWrites()
    #expect(try services.drafts.draft(id: model.id) == nil)
}

@MainActor
@Test func shortcutsRouteToActions() throws {
    let (services, key) = try makeServices()
    let model = try #require(ComposerModel(request: .reply(key, all: false), services: services, mode: .window))
    func press(_ characters: String, _ flags: NSEvent.ModifierFlags, keyCode: UInt16 = 0) -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                     context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                     isARepeat: false, keyCode: keyCode)!
        return model.handleKeyEquivalent(event)
    }
    #expect(press("b", [.command, .shift]))
    #expect(model.showBcc)
    #expect(press("l", [.command, .shift]))
    #expect(model.sendLaterOpen)
    #expect(!press("j", .command)) // AI is off
    #expect(!press("x", .command))
}
