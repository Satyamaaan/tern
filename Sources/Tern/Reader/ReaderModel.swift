import AppKit
import Observation
import os
import Quartz
import SwiftUI
import TernCore
import WebKit

/// The link under the pointer: where it really goes, and a warning when its text names another site.
struct ReaderHoverLink: Equatable {
    var destination: String
    var warning: String?
}

/// Drives one reader pane: follows the open thread in the database, renders it into the shared web
/// view, and turns page events into actions. AI and downloads run in the background and never hold
/// up the first paint.
@MainActor
@Observable
final class ReaderModel {
    private(set) var key: ThreadKey?
    private(set) var detail: ThreadDetail?
    var composing: ComposeRequest?
    var findVisible = false
    var findText = ""
    private(set) var findFailed = false
    private(set) var hoverLink: ReaderHoverLink?
    private(set) var toast: String?
    private(set) var quickReplies: [String] = []
    var pickingSnoozeDate = false
    /// Key change to painted, for the last thread opened.
    private(set) var lastOpenMilliseconds: Double?

    @ObservationIgnored private(set) var services: AppServices?
    @ObservationIgnored let engine = ReaderWebEngine.shared
    @ObservationIgnored private var observer: ThreadDetailObserver?
    @ObservationIgnored private var renderedSignature: String?
    @ObservationIgnored private var openStarted: CFTimeInterval?
    @ObservationIgnored private var openInterval: OSSignpostIntervalState?
    @ObservationIgnored private var summary: SummaryState = .idle
    @ObservationIgnored private var summaryOpen = false
    @ObservationIgnored private var quickReplyTask: Task<Void, Never>?
    @ObservationIgnored private var hoverText = ""
    @ObservationIgnored private var hoverHref: String?
    @ObservationIgnored private var selectedAttachment: String?
    @ObservationIgnored private var findPrepared = false
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var labelsByAccount: [String: [MailLabel]] = [:]
    /// The sender logos the page shows for the open thread, by lowercased address.
    @ObservationIgnored private var renderedLogos: [String: String] = [:]
    /// Called after each thread is painted, with its open time (snapshot harness, speed checks).
    static var renderObserver: ((ThreadKey, Double) -> Void)?
    /// Time the page spent building the last thread's DOM, in milliseconds.
    private(set) static var lastBuildMilliseconds: Double = 0
    #if DEBUG
    /// Stands in for `SenderLogos` in the snapshot harness.
    static var logoOverride: ((String) -> Data?)?
    #endif

    /// Senders whose remote images load, shared by every reader.
    private static var trustedSenders: Set<String>?
    /// Messages whose images the user loaded once, for this run of the app.
    private static var loadedMessages = Set<MessageKey>()
    private static let signposter = OSSignposter(subsystem: "dev.tern.mail", category: "Reader")
    private static let log = Logger(subsystem: "dev.tern.mail", category: "Reader")

    private enum SummaryState { case idle, loading, loaded([String]), failed }

    func attach(_ services: AppServices) {
        #if DEBUG
        ReaderSnapshot.startIfRequested()
        #endif
        engine.delegate = self
        engine.webView.openLinkFromMenu = { [weak self] in self?.openHoveredLink() }
        guard self.services == nil else { return }
        self.services = services
        services.reader.model = self
        observeLogos()
        if Self.trustedSenders == nil { Self.trustedSenders = (try? services.store.imageAllowedSenders()) ?? [] }
    }

    // MARK: Opening

    func show(_ key: ThreadKey?, prefetch: [ThreadKey] = []) {
        engine.delegate = self
        engine.webView.openLinkFromMenu = { [weak self] in self?.openHoveredLink() }
        services?.reader.model = self
        defer { self.prefetch(prefetch) }
        guard key != self.key else { return }
        observer?.cancel()
        observer = nil
        self.key = key
        resetThreadState()
        guard let key, let services else {
            detail = nil
            engine.clear()
            return
        }
        openStarted = CACurrentMediaTime()
        openInterval = Self.signposter.beginInterval("Open thread", id: Self.signposter.makeSignpostID())
        observer = ThreadDetailObserver(store: services.store, key: key) { [weak self] detail in
            MainActor.assumeIsolated { self?.receive(detail, for: key) }
        }
        // Older mail is stored without bodies; the observer re-renders when they land.
        if let fetch = services.fetchBodies {
            Task { try? await fetch(key) }
        }
    }

    private func resetThreadState() {
        composing = nil
        findVisible = false
        findText = ""
        findFailed = false
        hoverLink = nil
        quickReplies = []
        quickReplyTask?.cancel()
        quickReplyTask = nil
        summary = .idle
        summaryOpen = false
        selectedAttachment = nil
        findPrepared = false
        renderedSignature = nil
        renderedLogos = [:]
        pickingSnoozeDate = false
        if let openInterval { Self.signposter.endInterval("Open thread", openInterval) }
        openInterval = nil
        openStarted = nil
    }

    private func receive(_ detail: ThreadDetail?, for key: ThreadKey) {
        guard key == self.key else { return }
        guard let detail else {
            self.detail = nil
            renderedSignature = nil
            engine.clear()
            return
        }
        self.detail = detail
        var context = context(for: detail)
        let signature = ReaderPayload.signature(detail, context: context)
        guard signature != renderedSignature else {
            engine.run("Tern.updateHeader(h)", ["h": ReaderPayload.header(detail, context: context)])
            return
        }
        renderedSignature = signature
        let senders = ReaderPayload.logoSenders(detail)
        for sender in senders { SenderLogos.shared.want(sender) }
        context.logos = logos(for: senders)
        renderedLogos = context.logos
        let (payload, loading, deferred) = ReaderPayload.make(detail, context: context)
        engine.render(payload)
        loadBodies([loading, deferred], key: key, context: context)
        if detail.ai?.needsReply == true { requestQuickReplies(after: 1.2) }
    }

    private func context(for detail: ThreadDetail) -> ReaderContext {
        let accountId = detail.thread.accountId
        var emails = Set((services?.accounts ?? []).map { $0.email.lowercased() })
        emails.insert(accountId.lowercased())
        let names = Dictionary(labels(for: accountId).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return ReaderContext(accountEmails: emails, labelNames: names, trust: trust, summary: summaryPayload())
    }

    private var trust: ReaderTrust {
        ReaderTrust(senders: Self.trustedSenders ?? [], messages: Self.loadedMessages, remoteImages: engine.blocksRemoteLoads)
    }

    // MARK: Sender logos

    private func logos(for senders: [String]) -> [String: String] {
        #if DEBUG
        if let override = Self.logoOverride { return ReaderPayload.logos(senders, lookup: override) }
        #endif
        return ReaderPayload.logos(senders) { SenderLogos.shared.pngData(forEmail: $0) }
    }

    /// Follows `SenderLogos.revision` for as long as this model lives.
    private func observeLogos() {
        withObservationTracking {
            _ = SenderLogos.shared.revision
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshLogos()
                self.observeLogos()
            }
        }
    }

    /// Logos that arrived after the paint go to the page avatar by avatar, without a re-render.
    func refreshLogos() {
        guard let key, let detail, renderedSignature != nil else { return }
        let missing = ReaderPayload.logoSenders(detail).filter { renderedLogos[$0] == nil }
        guard !missing.isEmpty else { return }
        let arrived = logos(for: missing)
        guard !arrived.isEmpty else { return }
        renderedLogos.merge(arrived) { $1 }
        engine.run("Tern.setLogos(k, l)", ["k": key.description, "l": arrived])
    }

    func labels(for accountId: String) -> [MailLabel] {
        if let cached = labelsByAccount[accountId] { return cached }
        let labels = ((try? services?.store.labels(accountId: accountId)) ?? []).filter { !$0.isSystem && !$0.hidden }
        labelsByAccount[accountId] = labels
        return labels
    }

    /// Sanitizes bodies off the main thread, a batch at a time: large open ones first, then the collapsed
    /// ones so expanding one is instant.
    private func loadBodies(_ batches: [[MailMessage]], key: ThreadKey, context: ReaderContext) {
        let work = batches.filter { !$0.isEmpty }.map { batch in batch.map { ($0, ReaderPayload.isTrusted($0, context)) } }
        guard !work.isEmpty else { return }
        Task { [weak self] in
            for batch in work {
                let bodies = await Task.detached(priority: .userInitiated) {
                    batch.map { ($0.0.id, ReaderBodies.shared.body(for: $0.0, trusted: $0.1)) }
                }.value
                guard let self, self.key == key else { return }
                var payload: [String: Any] = [:]
                for (id, body) in bodies { payload[id] = ReaderPayload.bodyPayload(body) }
                self.engine.run("Tern.setBodies(k, b)", ["k": key.description, "b": payload])
            }
        }
    }

    /// Warms the body cache for the threads the user is likely to open next, and asks sync for
    /// bodies it hasn't stored yet.
    func prefetch(_ keys: [ThreadKey]) {
        guard let services, !keys.isEmpty else { return }
        services.prefetchBodies?(keys)
        let store = services.store
        let trust = trust
        Task.detached(priority: .utility) {
            for key in keys.prefix(4) {
                guard let detail = try? store.threadDetail(key), let target = ReaderPayload.targetMessage(detail) else { continue }
                _ = ReaderBodies.shared.body(for: target, trusted: trust.allows(target))
            }
        }
    }

    // MARK: Page events

    fileprivate func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "rendered":
            rendered(message)
        case "link":
            openLink(message["href"] as? String ?? "", text: message["text"] as? String ?? "")
        case "hover":
            hover(message["href"] as? String, text: message["text"] as? String ?? "")
        case "needBody":
            if let id = message["id"] as? String { sendBody(id) }
        case "loadImages":
            if let id = message["id"] as? String { loadImages(messageId: id) }
        case "alwaysImages":
            if let sender = message["sender"] as? String { trustImages(from: sender) }
        case "attachment":
            attachmentEvent(message)
        case "summary":
            summaryClicked()
        case "key":
            switch message["key"] as? String {
            case "r": reply(all: false)
            case "a": reply(all: true)
            case "f": forward()
            default: break
            }
        default:
            break
        }
    }

    private func rendered(_ message: [String: Any]) {
        guard let key, message["key"] as? String == key.description, let started = openStarted else { return }
        let milliseconds = (CACurrentMediaTime() - started) * 1000
        openStarted = nil
        if let openInterval { Self.signposter.endInterval("Open thread", openInterval) }
        openInterval = nil
        lastOpenMilliseconds = milliseconds
        let build = message["buildMs"] as? Double ?? 0
        Self.lastBuildMilliseconds = build
        Self.log.debug("Opened \(key.description, privacy: .private) in \(milliseconds, format: .fixed(precision: 1)) ms (DOM \(build, format: .fixed(precision: 1)) ms)")
        Self.renderObserver?(key, milliseconds)
    }

    /// A body the page asked for (a collapsed message opened before its body arrived), sanitized off
    /// the main thread unless it is cached.
    private func sendBody(_ id: String) {
        guard let key, let detail, let message = detail.messages.first(where: { $0.id == id }) else { return }
        let trusted = ReaderPayload.isTrusted(message, context(for: detail))
        if let body = ReaderBodies.shared.cachedBody(for: message, trusted: trusted) {
            engine.run("Tern.setBodies(k, b)", ["k": key.description, "b": [id: ReaderPayload.bodyPayload(body)]])
            return
        }
        Task { [weak self] in
            let body = await Task.detached(priority: .userInitiated) { ReaderBodies.shared.body(for: message, trusted: trusted) }.value
            guard let self, self.key == key else { return }
            self.engine.run("Tern.setBodies(k, b)", ["k": key.description, "b": [id: ReaderPayload.bodyPayload(body)]])
        }
    }

    /// "Load images": this message only.
    private func loadImages(messageId: String) {
        guard let detail, let key, let message = detail.messages.first(where: { $0.id == messageId }) else { return }
        Self.loadedMessages.insert(message.key)
        receive(detail, for: key)
    }

    /// Settings → Mail took a sender off the list: their images are blocked again in every reader.
    static func forgetTrustedSender(_ sender: String) {
        trustedSenders?.remove(sender.lowercased())
    }

    /// "Always load from …": every message from this sender, except in Spam.
    private func trustImages(from sender: String) {
        let sender = sender.lowercased()
        guard !sender.isEmpty, let services else { return }
        Self.trustedSenders = (Self.trustedSenders ?? []).union([sender])
        let store = services.store
        Task.detached { try? store.setImagesAllowed(true, sender: sender) }
        if let detail, let key { receive(detail, for: key) }
    }

    // MARK: Links

    private func hover(_ href: String?, text: String) {
        engine.webView.hoveredLink = href
        hoverHref = href
        hoverText = text
        guard let href, let url = URL(string: href) else {
            hoverLink = nil
            return
        }
        switch url.scheme?.lowercased() {
        case "mailto":
            hoverLink = ReaderHoverLink(destination: String(href.dropFirst("mailto:".count)).components(separatedBy: "?")[0].removingPercentEncoding ?? href)
        case "http", "https", "tel":
            let warning = LinkSafety.mismatch(text: text, href: href).map { "Opens \($0.actual), not \($0.shown)" }
            // Through a known redirector (Google, Safe Links, Proofpoint…) the pill shows where it leads.
            let destination = url.scheme?.lowercased() == "tel" ? href : LinkSafety.destination(of: url).absoluteString
            hoverLink = ReaderHoverLink(destination: destination, warning: warning)
        default:
            hoverLink = nil
        }
    }

    func openHoveredLink() {
        if let hoverHref { openLink(hoverHref, text: hoverText) }
    }

    func openLink(_ href: String, text: String) {
        guard let url = URL(string: href) else { return }
        switch url.scheme?.lowercased() {
        case "mailto":
            let addresses = String(href.dropFirst("mailto:".count)).components(separatedBy: "?")[0]
                .split(separator: ",").compactMap { $0.removingPercentEncoding?.trimmingCharacters(in: .whitespaces) }
                .filter { $0.contains("@") }
            services?.compose(.new(accountId: key?.accountId, to: addresses.map { Participant(email: $0) }))
        case "http", "https":
            guard let mismatch = LinkSafety.mismatch(text: text, href: href) else {
                NSWorkspace.shared.open(url)
                return
            }
            confirmOpen(url, mismatch: mismatch)
        case "tel":
            NSWorkspace.shared.open(url)
        default:
            break
        }
    }

    private func confirmOpen(_ url: URL, mismatch: LinkSafety.Mismatch) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This link opens \(mismatch.actual)"
        alert.informativeText = "The link text says \(mismatch.shown), but it goes to a different site. Open it only if you trust the sender.\n\n\(url.absoluteString)"
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open Anyway")
        if let window = engine.webView.window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertSecondButtonReturn { NSWorkspace.shared.open(url) }
            }
        } else if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Attachments

    private func attachment(_ id: String) -> MailAttachment? {
        detail?.attachments.values.lazy.flatMap { $0 }.first { $0.id == id }
    }

    private func attachmentEvent(_ message: [String: Any]) {
        guard let id = message["id"] as? String, let attachment = attachment(id) else { return }
        selectedAttachment = id
        switch message["action"] as? String {
        case "open": withFile(attachment) { NSWorkspace.shared.open($0) }
        case "quicklook": withFile(attachment) { [weak self] in self?.quickLook($0) }
        case "menu":
            let point = NSPoint(x: message["x"] as? Double ?? 0, y: message["y"] as? Double ?? 0)
            attachmentMenu(attachment).popUp(positioning: nil, at: point, in: engine.webView)
        default: break
        }
    }

    private func attachmentMenu(_ attachment: MailAttachment) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ReaderMenuItem("Open") { [weak self] in self?.withFile(attachment) { NSWorkspace.shared.open($0) } })
        menu.addItem(ReaderMenuItem("Quick Look") { [weak self] in self?.withFile(attachment) { self?.quickLook($0) } })
        menu.addItem(.separator())
        menu.addItem(ReaderMenuItem("Save to Downloads") { [weak self] in
            self?.withFile(attachment) { self?.saveToDownloads($0, name: attachment.filename) }
        })
        menu.addItem(ReaderMenuItem("Copy") { [weak self] in
            self?.withFile(attachment) { url in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([url as NSURL])
            }
        })
        return menu
    }

    /// Space on the selected attachment.
    func quickLookSelectedAttachment() {
        guard let id = selectedAttachment, let attachment = attachment(id) else { return }
        withFile(attachment) { [weak self] in self?.quickLook($0) }
    }

    private func withFile(_ attachment: MailAttachment, _ then: @escaping (URL) -> Void) {
        if let path = attachment.localPath, FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            // Files cached before Tern quarantined them get the flag now, before they open.
            AttachmentQuarantine.mark(url)
            then(url)
            return
        }
        guard let services else { return }
        engine.run("Tern.setAttachmentBusy(i, true)", ["i": attachment.id])
        Task { [weak self] in
            do {
                let url = try await services.loadAttachment(attachment)
                then(url)
            } catch {
                self?.showToast("Couldn’t download “\(attachment.filename)”")
            }
            self?.engine.run("Tern.setAttachmentBusy(i, false)", ["i": attachment.id])
        }
    }

    private func quickLook(_ url: URL) {
        let webView = engine.webView
        webView.quickLook.items = [url]
        if let window = webView.window, window.firstResponder !== webView { window.makeFirstResponder(webView) }
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.reloadData() } else { panel.makeKeyAndOrderFront(nil) }
    }

    private func saveToDownloads(_ url: URL, name: String) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var destination = downloads.appendingPathComponent(name.isEmpty ? url.lastPathComponent : name)
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = downloads.appendingPathComponent(ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
            counter += 1
        }
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            AttachmentQuarantine.mark(destination)
            showToast("Saved to Downloads")
        } catch {
            showToast("Couldn’t save “\(name)”")
        }
    }

    fileprivate func contentIdImage(_ contentId: String, messageId: String) async throws -> (Data, String) {
        guard let services, let attachment = detail?.attachments[messageId]?.first(where: {
            $0.contentId?.trimmingCharacters(in: CharacterSet(charactersIn: "<>")).caseInsensitiveCompare(contentId) == .orderedSame
        }) else { throw CocoaError(.fileNoSuchFile) }
        let url: URL
        if let path = attachment.localPath, FileManager.default.fileExists(atPath: path) {
            url = URL(fileURLWithPath: path)
        } else {
            url = try await services.loadAttachment(attachment)
        }
        let data = try await Task.detached { try Data(contentsOf: url) }.value
        return (data, attachment.mimeType)
    }

    // MARK: AI

    private func summaryPayload() -> [String: Any] {
        let line = detail?.ai?.summary
        let canSummarize = services?.ai != nil
        let worthIt = (detail?.messages.count ?? 0) > 1
            || (detail?.messages.reduce(0) { $0 + ReaderPayload.bodyLength($1) } ?? 0) > 2_400
        switch summary {
        case .loading:
            return ["state": "loading", "text": line ?? ""]
        case .loaded(let bullets) where summaryOpen:
            return ["state": "bullets", "bullets": bullets, "expandable": true]
        case .loaded(let bullets):
            return ["state": "line", "text": line ?? bullets.first ?? "", "expandable": true]
        case .idle, .failed:
            if let line, !line.isEmpty { return ["state": "line", "text": line, "expandable": canSummarize] }
            return canSummarize && worthIt ? ["state": "action", "label": "Summarize"] : ["state": "none"]
        }
    }

    private func pushSummary() {
        guard let key else { return }
        engine.run("Tern.setSummary(k, s)", ["k": key.description, "s": summaryPayload()])
    }

    /// The summary line: summarize on first click (2–4 bullets), then fold and unfold.
    func summaryClicked() {
        guard let key else { return }
        switch summary {
        case .loaded:
            summaryOpen.toggle()
            pushSummary()
        case .loading:
            return
        case .idle, .failed:
            guard let ai = services?.ai else { return }
            summary = .loading
            pushSummary()
            Task { [weak self] in
                let bullets = try? await ai.summarize(key)
                guard let self, self.key == key else { return }
                let cleaned = (bullets ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                if cleaned.isEmpty {
                    self.summary = .failed
                    self.showToast("Couldn’t summarize this conversation")
                } else {
                    self.summary = .loaded(Array(cleaned.prefix(4)))
                    self.summaryOpen = true
                }
                self.pushSummary()
            }
        }
    }

    /// Fetches up to three quick replies, once per thread. Never blocks the reader.
    func requestQuickReplies(after delay: Double = 0) {
        guard quickReplyTask == nil, quickReplies.isEmpty, let key, let ai = services?.ai else { return }
        quickReplyTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, self?.key == key else { return }
            let replies = (try? await ai.suggestReplies(key)) ?? []
            guard let self, !Task.isCancelled, self.key == key else { return }
            self.quickReplies = Array(replies.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(3))
        }
    }

    // MARK: Commands

    /// First name for "Reply to Maya…".
    var replyName: String? {
        guard let detail else { return nil }
        let accountId = detail.thread.accountId.lowercased()
        let mine = Set((services?.accounts ?? []).map { $0.email.lowercased() }).union([accountId])
        guard let last = detail.messages.last(where: { !$0.isDraft }) else { return nil }
        let person = detail.ai.map { $0.category == .people } ?? true
        let recipient = mine.contains(last.fromEmail.lowercased())
            ? last.toList.first { !mine.contains($0.email.lowercased()) } : last.from
        return person ? recipient?.firstName : recipient?.displayName
    }

    /// Opens the inline composer, reopening the reply already being written in this thread.
    func reply(all: Bool) {
        guard let key else { return }
        if let draft = try? services?.drafts.editingDraft(inThread: key), draft.kind == .reply || draft.kind == .replyAll {
            composing = .draft(id: draft.id)
        } else if let services, let gmailDraft = try? services.drafts.gmailReplyDraft(inThread: key) {
            services.openDraftMessage(gmailDraft)
        } else {
            composing = .reply(key, all: all)
        }
    }

    func forward() {
        guard let key else { return }
        composing = .forward(key)
    }

    func quickReply(_ text: String) {
        guard let key else { return }
        services?.replyPrefill[key] = text
        reply(all: false)
    }

    func perform(_ action: MailAction) {
        guard let key else { return }
        services?.perform(action, [key])
    }

    func setLabel(_ id: String, on: Bool) { perform(on ? .addLabel(id) : .removeLabel(id)) }

    func setProject(_ id: String, on: Bool) {
        guard let key, let store = services?.store else { return }
        Task.detached { try? store.setProject(id, on: [key], assigned: on) }
    }

    func mute() {
        guard let key, let mute = services?.mute else { return }
        mute([key])
    }

    func nextMessage() { engine.run("Tern.next()") }
    func previousMessage() { engine.run("Tern.previous()") }
    func toggleMessage() { engine.run("Tern.toggleFocused()") }

    func openFind() {
        findVisible = true
    }

    /// ⌘G / ⇧⌘G: the next or previous match, opening the find bar when there is nothing to find yet.
    func findAgain(backwards: Bool) {
        if findText.isEmpty { openFind() } else { find(backwards: backwards) }
    }

    /// Gives the page the keyboard, so n/p, Enter, Space and arrows work inside the conversation.
    func focusPage() {
        let webView = engine.webView
        guard let window = webView.window, window.firstResponder !== webView else { return }
        window.makeFirstResponder(webView)
    }

    func find(backwards: Bool = false) {
        let text = findText
        guard !text.isEmpty else {
            findFailed = false
            return
        }
        let search = { [weak self] in
            let configuration = WKFindConfiguration()
            configuration.backwards = backwards
            configuration.wraps = true
            configuration.caseSensitive = false
            self?.engine.webView.find(text, configuration: configuration) { result in
                MainActor.assumeIsolated { self?.findFailed = !result.matchFound }
            }
        }
        if findPrepared { search() } else {
            findPrepared = true
            engine.run("Tern.expandAll()") { _ in MainActor.assumeIsolated { search() } }
        }
    }

    func closeFind() {
        findVisible = false
        findText = ""
        findFailed = false
        engine.run("window.getSelection().removeAllRanges()")
    }

    func printThread() {
        engine.run("Tern.expandAll()") { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.engine.webView.window else { return }
                let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
                info.horizontalPagination = .fit
                info.verticalPagination = .automatic
                info.isVerticallyCentered = false
                let operation = self.engine.webView.printOperation(with: info)
                operation.view?.frame = self.engine.webView.bounds
                operation.showsPrintPanel = true
                operation.showsProgressPanel = true
                operation.jobTitle = self.detail?.thread.subject ?? "Conversation"
                operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            }
        }
    }

    func showOriginal() {
        guard let detail, let message = ReaderPayload.targetMessage(detail) else { return }
        ReaderOriginalWindow.show(message, attachments: detail.attachments[message.id] ?? [])
    }

    func setTheme(dark: Bool) { engine.setTheme(dark: dark) }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}

extension ReaderModel: ReaderWebDelegate {
    func readerWeb(received message: [String: Any]) { handle(message) }

    func readerWebDidReload() {
        renderedSignature = nil
        if let detail, let key { receive(detail, for: key) }
    }

    func readerWeb(contentId: String, messageId: String, accountId: String) async throws -> (Data, String) {
        try await contentIdImage(contentId, messageId: messageId)
    }

    func readerWeb(openURL url: URL, text: String) { openLink(url.absoluteString, text: text) }
}

/// A menu item that runs a closure.
final class ReaderMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}
