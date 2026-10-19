import AppKit
import Foundation
import GRDB
import Testing
@testable import Tern
@testable import TernCore

// Discard Draft in the shell: which rows are drafts, the trash keys and ⌘K on them, several at once, a
// draft being sent, and undo.

private let me = Account(email: "me@example.com")
private let news = ThreadKey(accountId: me.id, threadId: "news")
private let solo = ThreadKey(accountId: me.id, threadId: "solo")

/// The inbox's newsletter with a reply drafted on the phone, a new message drafted on the web, and a
/// note written here that Gmail has no copy of.
@MainActor
private func makeModel() throws -> (AppModel, CommandRegistry, local: ThreadKey) {
    let database = try AppDatabase.inMemory()
    let local = Draft(id: "note", accountId: me.id, subject: "Note to self", bodyHtml: "<p>Milk</p>")
    try database.writer.write { db in
        try me.insert(db)
        try MailStore.upsertMessages(db, [
            MailMessage(accountId: me.id, id: "m1", threadId: "news", date: Date(timeIntervalSince1970: 1_000),
                        fromName: "Google AI Studio", fromEmail: "news@google.com", toList: [Participant(email: me.email)],
                        subject: "What's new", bodyText: "Hello", bodyState: .full, labelIds: ["INBOX"]),
            MailMessage(accountId: me.id, id: "d1", threadId: "news", date: Date(timeIntervalSince1970: 2_000),
                        fromEmail: me.email, toList: [Participant(email: "news@google.com")], subject: "Re: What's new",
                        bodyText: "Thanks", bodyState: .full, labelIds: ["DRAFT"], isFromMe: true, rfcMessageId: "<d1@phone>"),
            MailMessage(accountId: me.id, id: "d2", threadId: "solo", date: Date(timeIntervalSince1970: 3_000),
                        fromEmail: me.email, toList: [Participant(email: "billing@example.com")], subject: "Subscription",
                        bodyText: "Cancel", bodyState: .full, labelIds: ["DRAFT"], isFromMe: true, rfcMessageId: "<d2@web>"),
        ])
        try local.insert(db)
    }
    let services = AppServices(store: MailStore(database))
    services.accounts = [me]
    services.draftFilesDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("tern-discard-\(UUID().uuidString)")
    let model = AppModel(services: services, isFake: true, databaseURL: URL(fileURLWithPath: "/dev/null"))
    let registry = CommandRegistry(model: model, shell: nil, overrides: ShortcutOverrides(), keyBindings: KeyBindingFiles(urls: []))
    model.registry = registry
    services.discardDraft = { [weak model] message, thread in model?.discardDraft(message, in: thread) }
    model.reloadList()
    return (model, registry, ThreadKey(accountId: me.id, threadId: MailThread.localDraftPrefix + local.id))
}

/// Lets the writes finish and their follow-ups on the main queue run (the test gives the main queue up
/// while it sleeps).
@MainActor
private func settle(_ model: AppModel, _ seconds: TimeInterval = 0.05) async {
    model.writes.sync {}
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

@MainActor
private func drafts(_ model: AppModel) throws -> Set<String> {
    Set(try model.store.threadRows(in: Mailbox(.drafts), limit: 50).map(\.thread.id))
}

@MainActor
private func ops(_ model: AppModel) throws -> [PendingOp] {
    try model.store.database.reader.read { db in try PendingOp.order(Column("id")).fetchAll(db) }
}

@MainActor
@Test func inDraftsTheTrashKeysDiscardTheDraftNotTheConversation() async throws {
    let (model, registry, local) = try makeModel()
    model.show(.drafts)
    #expect(Set(model.snapshot.order) == [news, solo, local])
    #expect(model.snapshot.order.allSatisfy(model.isDraftRow))
    model.setCursor(news, open: false)
    #expect(model.targetsAreDrafts && registry["trash"]?.displayTitle == "Discard Draft")
    #expect(registry["discardDraft"]?.isVisible() == false, "⌘K shows one Discard Draft")
    #expect(registry.hint("Discard draft", "trash") == "Discard draft  #")

    let started = Date()
    registry.run("trash")
    #expect(model.snapshot.rows[news] == nil, "the row leaves in the same frame")
    #expect(model.toasts.last?.title == "Draft discarded" && model.toasts.last?.undo?.expires == true)
    await settle(model)
    #expect(try drafts(model) == [solo.threadId, local.threadId])
    #expect(try model.store.threadRows(in: .unifiedInbox).map(\.id) == [news], "the newsletter stays in the inbox")
    let held = try ops(model)
    #expect(held.map(\.kind) == [.deleteDraft])
    let wait = try #require(held.first?.notBefore).timeIntervalSince(started)
    #expect(wait >= AppModel.discardUndoSeconds + AppModel.discardHoldMargin - 1, "Gmail's copy waits out the undo window")

    model.undoLast()
    await settle(model, 0.1)
    #expect(try drafts(model) == [news.threadId, solo.threadId, local.threadId])
    #expect(try ops(model).isEmpty, "undo cancels the Gmail deletion")
    model.reloadList()
    #expect(model.snapshot.rows[news] != nil)
}

@MainActor
@Test func aConversationWithADraftIsStillTrashedButItsDraftCanBeDiscarded() async throws {
    let (model, registry, _) = try makeModel()
    model.show(.inbox)
    model.setCursor(news, open: false)
    #expect(!model.isDraftRow(news) && model.holdsDraft(news))
    #expect(registry["trash"]?.displayTitle == "Move to Trash")
    let discard = try #require(registry["discardDraft"])
    #expect(discard.isVisible() && registry.canRun(discard))
    #expect(ThreadMenu.make(registry: registry, model: model).items.contains { $0.title == "Discard Draft" })

    registry.run("discardDraft")
    #expect(model.snapshot.rows[news] != nil, "the conversation stays")
    await settle(model)
    #expect(try model.store.threadDetail(news)?.messages.map(\.id) == ["m1"])
    #expect(model.toasts.last?.title == "Draft discarded")
}

@MainActor
@Test func discardingASelectionTakesEveryDraftAndUndoBringsThemBack() async throws {
    let (model, registry, _) = try makeModel()
    model.show(.drafts)
    model.selectAll()
    #expect(model.targets.count == 3)
    registry.run("trash")
    #expect(model.snapshot.order.isEmpty)
    #expect(model.toasts.last?.title == "3 drafts discarded")
    await settle(model)
    #expect(try drafts(model).isEmpty)
    #expect(try ops(model).count == 3)
    model.undoLast()
    await settle(model, 0.1)
    #expect(try drafts(model).count == 3 && ops(model).isEmpty)
    #expect(try model.services.drafts.draft(id: "note")?.bodyHtml == "<p>Milk</p>")
}

@MainActor
@Test func aDraftBeingSentStaysAndSaysSo() async throws {
    let (model, registry, local) = try makeModel()
    // Send pressed, and the engine has picked it up.
    try await model.store.database.writer.write { db in
        try db.execute(sql: "UPDATE draft SET state = 'queued' WHERE id = 'note'")
        try PendingOp(accountId: me.id, kind: .sendDraft, payload: try encodeJSON(DraftOpPayload(draftId: "note")), state: .inflight,
                      dispatched: true).insert(db)
    }
    model.show(.drafts)
    model.setCursor(local, open: false)
    registry.run("trash")
    await settle(model, 0.6)
    #expect(model.toasts.last?.title == "A draft being sent can't be discarded")
    #expect(!model.toasts.contains { $0.title == "Draft discarded" } && model.undoStack.isEmpty)
    #expect(model.snapshot.rows[local] != nil, "its row comes back")
    #expect(try ops(model).map(\.kind) == [.sendDraft])
}

@MainActor
@Test func theReadersDiscardTakesOneDraftOfTheConversation() async throws {
    let (model, _, _) = try makeModel()
    model.show(.inbox)
    model.services.discardDraft(MessageKey(accountId: me.id, messageId: "d1"), news)
    #expect(model.snapshot.rows[news] != nil)
    await settle(model)
    #expect(try model.store.threadDetail(news)?.messages.map(\.id) == ["m1"])
    #expect(try drafts(model) == [solo.threadId, MailThread.localDraftPrefix + "note"])
    model.undoLast()
    await settle(model, 0.1)
    #expect(try model.store.threadDetail(news)?.messages.map(\.id) == ["m1", "d1"])
}

@MainActor
@Test func deletingDraftsAndConversationsTogetherDiscardsTheOneAndTrashesTheOtherWithOneUndo() async throws {
    let (model, registry, _) = try makeModel()
    model.show(.allMail)
    #expect(Set(model.snapshot.order) == [news, solo])
    model.selectAll()
    #expect(model.targetsMixDrafts && registry["trash"]?.displayTitle == "Trash and Discard Drafts")

    registry.run("trash")
    #expect(model.snapshot.order.isEmpty, "both leave in the same frame")
    #expect(model.toasts.map(\.title) == ["Moved 1 to Trash and discarded a draft"] && model.undoStack.count == 1)
    await settle(model)
    #expect(try model.store.threadRows(in: Mailbox(.trash)).map(\.id) == [news])
    #expect(try drafts(model) == [news.threadId, MailThread.localDraftPrefix + "note"], "trash leaves a conversation's draft alone")
    #expect(try ops(model).map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.deleteDraft, .modifyLabels])

    model.undoLast()
    await settle(model, 0.1)
    #expect(try model.store.threadRows(in: Mailbox(.trash)).isEmpty)
    #expect(try drafts(model) == [news.threadId, solo.threadId, MailThread.localDraftPrefix + "note"])
    #expect(try ops(model).isEmpty, "the trash and the Gmail deletion are both called off")
    model.reloadList()
    #expect(Set(model.snapshot.order) == [news, solo])
}

@MainActor
@Test func whenSomeDraftsAreBeingSentTheToastCountsOnlyTheOnesDiscarded() async throws {
    let (model, registry, local) = try makeModel()
    try await model.store.database.writer.write { db in
        try db.execute(sql: "UPDATE draft SET state = 'queued' WHERE id = 'note'")
        try PendingOp(accountId: me.id, kind: .sendDraft, payload: try encodeJSON(DraftOpPayload(draftId: "note")), state: .inflight,
                      dispatched: true).insert(db)
    }
    model.show(.drafts)
    model.selectAll()
    registry.run("trash")
    #expect(model.toasts.last?.title == "3 drafts discarded")
    await settle(model, 0.6)
    #expect(model.toasts.map(\.title) == ["2 drafts discarded", "A draft being sent can't be discarded"])
    #expect(model.toasts.first?.undo != nil && model.undoStack.count == 1)
    #expect(model.snapshot.rows[local] != nil)
}

@MainActor
@Test func anUndoTooLateForGmailSaysSo() async throws {
    let (model, registry, local) = try makeModel()
    model.show(.drafts)
    model.selectAll()
    registry.run("trash")
    await settle(model)
    // The engine picked the deletions up before the undo arrived (say the Mac slept through the window).
    try await model.store.database.writer.write { db in try db.execute(sql: "UPDATE pending_op SET state = 'inflight', dispatched = 1") }
    model.undoLast()
    await settle(model, 0.1)
    #expect(model.toasts.last?.title == "Too late: Gmail already deleted 2 drafts")
    #expect(try drafts(model) == [local.threadId], "the draft written here comes back, and saves itself again")
    #expect(try model.services.drafts.draft(id: "note")?.bodyHtml == "<p>Milk</p>")
}
