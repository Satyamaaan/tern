import AppKit
import Observation
import SwiftUI
import TernCore

/// State and actions behind one composer, windowed or inline. Edits autosave locally after a short
/// pause (DraftStore throttles the Gmail copy); Send closes at once and leaves an undo notice.
@MainActor
@Observable
final class ComposerModel: Identifiable {
    enum Mode { case window, inline }
    enum Field: Hashable { case to, cc, bcc, subject, body, ai }

    /// The draft id.
    let id: String
    let mode: Mode
    @ObservationIgnored let services: AppServices
    @ObservationIgnored let drafts: DraftStore
    @ObservationIgnored let editor: BodyEditorController
    /// Called when the composer should go away (after Send, Discard, Esc inline, ⌘W).
    @ObservationIgnored var onClose: () -> Void = {}

    var accountId: String
    var to: [Participant]
    var cc: [Participant]
    var bcc: [Participant]
    var subject: String
    var attachments: [DraftAttachment] { didSet { layoutAccessory() } }
    var signatureHtml: String? { didSet { layoutAccessory() } }
    var quoteHtml: String?
    var showCc: Bool
    var showBcc: Bool
    var quoteExpanded = false { didSet { layoutAccessory() } }
    /// Inline only: full fields instead of the one-line recipient summary.
    var headerExpanded = false
    /// Non-nil while the ✦ instruction field is open.
    var aiInstruction: String?
    var aiBusy = false
    /// A short message in the bottom bar (missing recipient, AI error…).
    var notice: String?
    var confirmingDiscard = false
    var sendLaterOpen = false
    /// Text plus accessory height; the inline composer grows with it.
    var bodyHeight: CGFloat = 0

    @ObservationIgnored private var base: Draft
    @ObservationIgnored private var isPersisted: Bool
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var finished = false
    @ObservationIgnored private var saveTimer: Task<Void, Never>?
    @ObservationIgnored private var writes: Task<Void, Never>?
    @ObservationIgnored private var fieldViews: [Field: WeakView] = [:]
    @ObservationIgnored private var tokenFields: [RecipientKind: WeakTokenField] = [:]
    @ObservationIgnored let signaturePreview: String?
    @ObservationIgnored private(set) lazy var quotePreview: String = quoteHtml.map(Self.preview(ofQuote:)) ?? ""

    // MARK: Opening

    /// Builds the starting draft for a request; nil when its thread or draft no longer exists.
    convenience init?(request: ComposeRequest, services: AppServices, mode: Mode) {
        let drafts = services.drafts
        guard let content = try? drafts.makeDraft(Self.intent(for: request)) else { return nil }
        self.init(content: content, services: services, mode: mode)
    }

    /// Opens a Gmail draft that exists only as a DRAFT message.
    convenience init?(draftMessage key: MessageKey, services: AppServices, mode: Mode) {
        guard let content = try? services.drafts.importDraftMessage(key) else { return nil }
        self.init(content: content, services: services, mode: mode)
    }

    init(content: DraftContent, services: AppServices, mode: Mode) {
        self.services = services
        self.drafts = services.drafts
        self.mode = mode
        self.id = content.draft.id
        self.base = content.draft
        self.accountId = content.draft.accountId
        self.to = content.draft.toList
        self.cc = content.draft.ccList
        self.bcc = content.draft.bccList
        self.subject = content.draft.subject
        self.attachments = content.draft.attachments
        self.signatureHtml = content.signatureHtml
        self.quoteHtml = content.quoteHtml
        self.showCc = !content.draft.ccList.isEmpty
        self.showBcc = !content.draft.bccList.isEmpty
        self.signaturePreview = content.signatureHtml.map { RichText.plainText(fromHTML: $0) }
        self.isPersisted = (try? services.drafts.draft(id: content.draft.id)) != nil
        self.editor = BodyEditorController(
            insets: mode == .window ? NSSize(width: 20, height: 12) : NSSize(width: 16, height: 10),
            minTextHeight: mode == .window ? 120 : 60)

        editor.richText = content.body
        if let prefill = Self.takePrefill(services, kind: content.draft.kind, thread: content.draft) {
            editor.richText = content.body.isEmpty ? prefill : RichText(content.body.blocks + [RichText.Block()] + prefill.blocks)
            dirty = true
        }
        editor.onChange = { [weak self] in self?.changed() }
        editor.onEscape = { [weak self] in self?.escape() }
        editor.onBacktab = { [weak self] in self?.focusNext(from: .body, forward: false) }
        editor.onFiles = { [weak self] in self?.addFiles($0) }
        editor.onImage = { [weak self] data, name in self?.addData(data, filename: name) }
        editor.onHeightChange = { [weak self] height in self?.bodyHeight = height }
        editor.setAccessory(ComposerAccessory(model: self))

        if content.draft.state == .failed {
            if let error = content.draft.lastError, error == DraftStore.unconfirmedSendError {
                notice = error
            } else {
                notice = content.draft.lastError.map { "Couldn't send: \($0)" } ?? "Couldn't send. Try again."
            }
        }
        if content.draft.state == .queued {
            // Opening a scheduled message to edit it takes it out of the queue.
            let id = id, drafts = drafts
            enqueue { _ = try await drafts.cancelSend(id) }
            notice = "Scheduled send cancelled. Send again when ready."
        }
    }

    /// The text a ✦ quick reply chose for this thread's reply, taken out of `replyPrefill`.
    private static func takePrefill(_ services: AppServices, kind: Draft.Kind, thread draft: Draft) -> RichText? {
        guard kind == .reply || kind == .replyAll, let threadId = draft.threadId,
              let text = services.replyPrefill.removeValue(forKey: ThreadKey(accountId: draft.accountId, threadId: threadId)),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return RichText(plainText: text)
    }

    static func intent(for request: ComposeRequest) -> DraftIntent {
        switch request {
        case .new(let accountId, let to): .new(accountId: accountId, to: to)
        case .reply(let key, let all): .reply(key, all: all)
        case .forward(let key): .forward(key)
        case .draft(let id): .existing(id: id)
        }
    }

    var kind: Draft.Kind { base.kind }
    /// The conversation being answered, in the account it belongs to.
    var threadKey: ThreadKey? { base.threadId.map { ThreadKey(accountId: base.accountId, threadId: $0) } }
    var account: Account? { services.account(accountId) }
    var hasSeveralAccounts: Bool { services.accounts.count > 1 }

    /// The window title (Window menu, Mission Control): the subject, or what kind of message this is.
    var title: String {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? kindTitle : trimmed
    }

    /// "New message", "Reply", "Reply all", "Forward": the quiet label in the window's top bar.
    var kindTitle: String {
        switch kind {
        case .new: "New message"
        case .reply: "Reply"
        case .replyAll: "Reply all"
        case .forward: "Forward"
        }
    }

    /// "To Maya Chen, Jonas +2" for the inline header.
    var recipientSummary: String {
        let people = to + cc + bcc
        guard let first = people.first else { return "Add recipients" }
        var names = [first.displayName] + people.dropFirst().prefix(2).map(\.firstName)
        if people.count > 3 { names[names.count - 1] += " +\(people.count - 3)" }
        return names.joined(separator: ", ")
    }

    func recipients(_ kind: RecipientKind) -> [Participant] {
        switch kind {
        case .to: to
        case .cc: cc
        case .bcc: bcc
        }
    }

    // MARK: Editing

    func setRecipients(_ people: [Participant], for kind: RecipientKind) {
        switch kind {
        case .to: to = people
        case .cc: cc = people
        case .bcc: bcc = people
        }
        changed()
    }

    func setSubject(_ text: String) {
        guard text != subject else { return }
        subject = text
        changed()
    }

    /// Switches the From account; the signature follows unless the user removed or changed it.
    func setAccount(_ id: String) {
        guard id != accountId else { return }
        let previousSignature = try? drafts.signature(accountId: accountId)
        accountId = id
        if signatureHtml == previousSignature { signatureHtml = try? drafts.signature(accountId: id) }
        changed()
    }

    /// Moves a dragged pill between this composer's fields, or copies it in from another composer.
    func drop(_ drag: RecipientDrag, into kind: RecipientKind) {
        if drag.composerId == id {
            let filtered = recipients(drag.kind).filter { $0.email.caseInsensitiveCompare(drag.participant.email) != .orderedSame }
            setRecipients(filtered, for: drag.kind)
        }
        guard !recipients(kind).contains(where: { $0.email.caseInsensitiveCompare(drag.participant.email) == .orderedSame }) else { return }
        setRecipients(recipients(kind) + [drag.participant], for: kind)
    }

    func suggestions(for query: String) -> [Participant] {
        let present = Set((to + cc + bcc).map { $0.email.lowercased() })
        return (try? drafts.suggestRecipients(prefix: query, limit: 6, excluding: present)) ?? []
    }

    func removeSignature() {
        signatureHtml = nil
        changed()
    }

    func removeAttachment(_ attachment: DraftAttachment) {
        attachments.removeAll { $0 == attachment }
        if attachment.remote == nil, !attachment.path.isEmpty { try? FileManager.default.removeItem(atPath: attachment.path) }
        changed()
    }

    /// Attached sizes in bytes (inline images included).
    var attachmentBytes: Int { attachments.reduce(0) { $0 + $1.size } }
    static let gmailLimit = 25 * 1024 * 1024

    func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            self?.addFiles(panel.urls)
        }
        if let window = hostWindow { panel.beginSheetModal(for: window, completionHandler: handler) } else { panel.begin(completionHandler: handler) }
    }

    func addFiles(_ urls: [URL]) {
        for url in urls where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            Task { [weak self, drafts, id] in
                guard let attachment = try? await drafts.addFile(url, to: id) else { return }
                self?.attachments.append(attachment)
                self?.changed()
            }
        }
    }

    func addData(_ data: Data, filename: String) {
        Task { [weak self, drafts, id] in
            guard let attachment = try? await drafts.addData(data, filename: filename, to: id) else { return }
            self?.attachments.append(attachment)
            self?.changed()
        }
    }

    // MARK: Saving

    /// The draft as it stands, with the body assembled from editor, signature and quote.
    func currentContent() -> DraftContent {
        var draft = base
        draft.accountId = accountId
        draft.toList = to
        draft.ccList = cc
        draft.bccList = bcc
        draft.subject = subject
        draft.attachments = attachments
        draft.scheduledAt = nil
        return DraftContent(draft: draft, body: editor.richText, signatureHtml: signatureHtml, quoteHtml: quoteHtml)
    }

    /// Something changed: save locally after a short pause.
    func changed() {
        guard !finished else { return }
        dirty = true
        notice = nil
        confirmingDiscard = false
        saveTimer?.cancel()
        saveTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    /// Writes now if anything changed. Blank new drafts never reach the database.
    func persist() {
        saveTimer?.cancel()
        guard dirty else { return }
        dirty = false
        let content = currentContent()
        guard !(content.isBlank && !isPersisted) else { return }
        isPersisted = true
        let draft = content.assembledDraft()
        enqueue { [drafts] in try await drafts.save(draft) }
    }

    /// Waits for every write asked for so far (tests, prewarm).
    func waitForWrites() async {
        await writes?.value
    }

    /// Runs database writes one after another, in the order they were asked for.
    @discardableResult
    private func enqueue(_ work: @escaping @Sendable () async throws -> Void) -> Task<Void, Never> {
        let previous = writes
        let task = Task {
            await previous?.value
            do { try await work() } catch { NSLog("Tern compose: draft write failed: \(error)") }
        }
        writes = task
        return task
    }

    // MARK: Closing

    /// ⌘W, the close button, or Esc inline: keeps the draft, or drops it when nothing was written.
    func close() {
        guard !finished else { return }
        saveOrDrop()
        onClose()
    }

    /// The window is closing by itself (close button): save, but the window handles closing.
    func saveOrDrop() {
        guard !finished else { return }
        commitTypedRecipients()
        editor.hideFormattingBar()
        if currentContent().isBlank {
            saveTimer?.cancel()
            if isPersisted { enqueue { [drafts, id] in _ = try await drafts.discard(id) } }
        } else {
            dirty = true
            persist()
        }
        finished = true
    }

    /// Trash icon / ⌘⇧D: asks once when there is something to lose.
    func requestDiscard() {
        if confirmingDiscard || currentContent().isBlank { discard() } else { confirmingDiscard = true }
    }

    func discard() {
        finished = true
        saveTimer?.cancel()
        editor.hideFormattingBar()
        if isPersisted { enqueue { [drafts, id] in _ = try await drafts.discard(id) } } else {
            try? FileManager.default.removeItem(at: drafts.folder(for: id))
        }
        onClose()
    }

    func escape() {
        if sendLaterOpen { sendLaterOpen = false; return }
        if aiInstruction != nil { aiInstruction = nil; focus(.body); return }
        if confirmingDiscard { confirmingDiscard = false; return }
        if mode == .inline { close() }
    }

    /// Breaks the editor → accessory → model reference once the composer is gone.
    func tearDown() {
        editor.hideFormattingBar()
        editor.setAccessory(EmptyView())
        for field in tokenFields.values { field.view?.hideSuggestions() }
    }

    // MARK: Sending

    func send(archive: Bool = false) { queue(at: nil, archive: archive) }

    func scheduleSend(at date: Date) { queue(at: date, archive: false) }

    /// Validates, closes the composer at once and queues the send; the undo notice can take it back.
    private func queue(at date: Date?, archive: Bool) {
        commitTypedRecipients()
        guard validateRecipients() else { return }
        finished = true
        saveTimer?.cancel()
        sendLaterOpen = false
        editor.hideFormattingBar()
        let draft = currentContent().assembledDraft()
        let drafts = drafts, services = services, id = id
        let seconds = (try? drafts.undoSeconds()) ?? DraftStore.defaultUndoSeconds
        let sending = enqueue {
            if let date { try await drafts.scheduleSend(draft, at: date) } else { try await drafts.send(draft, undoSeconds: seconds) }
        }
        var archiving: Task<UndoToken?, Never>?
        if archive, let threadKey {
            if let archiveSent = services.archiveSent {
                archiving = Task { await archiveSent(threadKey) }
            } else {
                let store = services.store
                archiving = Task.detached { try? store.perform(.archive, on: [threadKey]) }
            }
        }
        let window = hostWindow
        onClose()

        let notice = SendUndoNotice(
            draftId: id,
            message: date.map { "Scheduled for \(SnoozeOption.detailText($0))" } ?? "Sending",
            deadline: date == nil ? Date().addingTimeInterval(TimeInterval(seconds)) : nil,
            duration: date == nil ? TimeInterval(seconds) + 0.8 : 6,
            undo: {
                Task { @MainActor in
                    await sending.value
                    guard (try? await drafts.cancelSend(id)) == true else {
                        SendToast.show(message: "Already sent", over: nil)
                        return
                    }
                    if let token = await archiving?.value {
                        let store = services.store
                        Task.detached { try? store.undo(token) }
                    }
                    Composer.open(.draft(id: id), services: services)
                }
            })
        if let show = services.showSendUndo { show(notice) } else { SendToast.show(notice, over: window) }
    }

    /// Recipients must exist and look like addresses; otherwise say which one and go there.
    private func validateRecipients() -> Bool {
        if (to + cc + bcc).isEmpty {
            notice = "Add a recipient"
            focus(.to)
            return false
        }
        for kind in RecipientKind.allCases {
            if let bad = recipients(kind).first(where: { !RecipientParser.isValidEmail($0.email) }) {
                notice = "Check “\(bad.email)” in \(kind.label)"
                if kind == .cc { showCc = true }
                if kind == .bcc { showBcc = true }
                if mode == .inline { headerExpanded = true }
                focus(field(for: kind))
                return false
            }
        }
        return true
    }

    private func commitTypedRecipients() {
        for field in tokenFields.values { field.view?.commit() }
    }

    // MARK: AI

    /// ✦ is offered for replies when AI is on, and for new mail when the provider can write one.
    var aiAvailable: Bool {
        guard let ai = services.ai else { return false }
        return (threadKey != nil && kind != .new) || ai.writeDraft != nil
    }

    func toggleAI() {
        guard aiAvailable else { return }
        if aiInstruction == nil {
            aiInstruction = ""
            DispatchQueue.main.async { self.focus(.ai) }
        } else {
            aiInstruction = nil
            focus(.body)
        }
    }

    func runAI() {
        guard let ai = services.ai, let instruction = aiInstruction?.trimmingCharacters(in: .whitespacesAndNewlines),
              !instruction.isEmpty, !aiBusy else { return }
        let current = editor.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        var prompt = instruction
        if !current.isEmpty { prompt += "\n\nRewrite this draft:\n\(current)" }
        let key = threadKey
        let isReply = kind == .reply || kind == .replyAll
        let header = "To: \((to + cc).map(RecipientParser.format).joined(separator: ", "))\nSubject: \(subject)\n\n"
        aiBusy = true
        notice = nil
        Task { [weak self] in
            do {
                let text: String
                if isReply, let key {
                    text = try await ai.draftReply(key, prompt)
                } else if let write = ai.writeDraft {
                    text = try await write(header + prompt)
                } else if let key {
                    text = try await ai.draftReply(key, prompt)
                } else {
                    return
                }
                guard let self else { return }
                let looksLikeHTML = text.range(of: #"<(p|div|br|ul|ol)[\s>/]"#, options: [.regularExpression, .caseInsensitive]) != nil
                // The same allow-list as pasted HTML, and no link the user can't see the destination of.
                let body = looksLikeHTML ? RichText(html: text) : RichText(plainText: text)
                editor.replaceBody(with: body.revealingLinks())
                aiBusy = false
                aiInstruction = nil
                editor.focus(atEnd: true)
            } catch {
                self?.aiBusy = false
                self?.notice = "AI couldn't write this draft."
            }
        }
    }

    // MARK: Focus

    var hostWindow: NSWindow? { editor.textView.window }

    /// True when the focused responder is one of this composer's fields (or a field's editor).
    func owns(_ responder: NSResponder) -> Bool {
        if responder === editor.textView { return true }
        var view = responder as? NSView
        if let fieldEditor = responder as? NSTextView, fieldEditor.isFieldEditor { view = fieldEditor.delegate as? NSView }
        guard let view else { return false }
        return fieldViews.values.contains { $0.view === view }
    }

    func register(_ view: NSView, for field: Field) {
        fieldViews[field] = WeakView(view: view)
    }

    func register(_ tokenField: RecipientTokenField) {
        tokenFields[tokenField.kind] = WeakTokenField(view: tokenField)
        register(tokenField.input, for: field(for: tokenField.kind))
    }

    func field(for kind: RecipientKind) -> Field {
        switch kind {
        case .to: .to
        case .cc: .cc
        case .bcc: .bcc
        }
    }

    /// Fields in Tab order, as currently shown.
    var fieldOrder: [Field] {
        var order: [Field] = []
        if mode == .window || headerExpanded {
            order.append(.to)
            if showCc { order.append(.cc) }
            if showBcc { order.append(.bcc) }
            order.append(.subject)
        }
        order.append(.body)
        return order
    }

    func focus(_ field: Field) {
        switch field {
        case .body:
            editor.focus()
            return
        case .cc: showCc = true
        case .bcc: showBcc = true
        default: break
        }
        if mode == .inline, field != .ai { headerExpanded = true }
        // Newly shown rows exist after the next layout pass.
        DispatchQueue.main.async { [weak self] in
            guard let view = self?.fieldViews[field]?.view else { return }
            view.window?.makeFirstResponder(view)
        }
    }

    func focusNext(from field: Field, forward: Bool) {
        if mode == .inline, !forward, field == .body, !headerExpanded {
            headerExpanded = true
            focus(.to)
            return
        }
        let order = fieldOrder
        guard let index = order.firstIndex(of: field) else { return focus(.body) }
        let next = index + (forward ? 1 : -1)
        if order.indices.contains(next) { focus(order[next]) }
    }

    /// Where the caret starts: To for new mail without recipients, otherwise the body.
    func focusInitialField() {
        if to.isEmpty, kind == .new || kind == .forward {
            focus(.to)
        } else {
            DispatchQueue.main.async { [weak self] in self?.editor.focus() }
        }
    }

    // MARK: Keys

    /// Composer shortcuts. Returns true when handled.
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard !finished else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch modifiers {
        case .command:
            if isReturn { send(); return true }
            if key == "j", aiAvailable { toggleAI(); return true }
            if key == "w", mode == .window { hostWindow?.performClose(nil); return true }
        case [.command, .shift]:
            if isReturn { send(archive: threadKey != nil); return true }
            switch key {
            case "l": sendLaterOpen.toggle(); return true
            case "c": focus(.cc); return true
            case "b": focus(.bcc); return true
            case "a": attach(); return true
            case "d": requestDiscard(); return true
            default: break
            }
        default:
            break
        }
        return false
    }

    // MARK: Helpers

    private func layoutAccessory() {
        DispatchQueue.main.async { [weak self] in self?.editor.accessoryChanged() }
    }

    /// The quote as readable text for the expanded `•••` view, kept short. Quote levels are flattened.
    static func preview(ofQuote html: String) -> String {
        let text = RichText(html: html).blocks.map { block in
            block.text.replacingOccurrences(of: String(RichText.lineBreak), with: "\n")
        }.joined(separator: "\n")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var kept = Array(lines.prefix(60))
        while kept.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { kept.removeLast() }
        return kept.joined(separator: "\n") + (lines.count > 60 ? "\n…" : "")
    }
}

struct WeakView {
    weak var view: NSView?
}

struct WeakTokenField {
    weak var view: RecipientTokenField?
}
