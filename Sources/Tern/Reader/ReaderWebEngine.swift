import AppKit
import Quartz
import TernCore
import WebKit

/// Events the reader page posts back, and requests the web view can't answer itself.
@MainActor
protocol ReaderWebDelegate: AnyObject {
    func readerWeb(received message: [String: Any])
    func readerWebDidReload()
    /// Data and MIME type for an inline `cid:` image.
    func readerWeb(contentId: String, messageId: String, accountId: String) async throws -> (Data, String)
    func readerWeb(openURL url: URL, text: String)
}

/// The one long-lived web view every reader shares. Created and loaded once (call `prewarm()` at
/// launch), its background is transparent before the first paint, and threads are shown by injecting
/// content into the loaded page, never by navigating. Mail can't run script (page CSP plus
/// `allowsContentJavaScript = false`), can't navigate, and can't load remote content unless the
/// current thread's sender is trusted (`WKContentRuleList`).
@MainActor
final class ReaderWebEngine: NSObject {
    static let shared = ReaderWebEngine()

    let webView: ReaderWebView
    let world = WKContentWorld.world(name: "tern-reader")
    weak var delegate: ReaderWebDelegate?
    private(set) var isReady = false
    private var queued: [() -> Void] = []
    private var blockAll: WKContentRuleList?
    private var allowImages: WKContentRuleList?
    private var remoteImagesAllowed = false
    private let schemes = ReaderSchemeHandler()

    /// Creates the shared web view and starts loading the reader page.
    static func prewarm() { _ = shared }

    private override init() {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.setURLSchemeHandler(schemes, forURLScheme: "tern-app")
        configuration.setURLSchemeHandler(schemes, forURLScheme: MailSanitizer.contentIdScheme)
        webView = ReaderWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 800), configuration: configuration)
        super.init()
        schemes.engine = self
        configuration.userContentController.addUserScript(WKUserScript(
            source: ReaderResources.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        configuration.userContentController.add(MessageProxy(self), contentWorld: world, name: "tern")
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        compileRuleLists()
        loadPage()
    }

    private func loadPage() {
        isReady = false
        webView.loadHTMLString(ReaderResources.page(), baseURL: URL(string: "tern-app://reader/"))
    }

    // MARK: Calling the page

    /// Runs `body` (with `arguments` bound as JS variables) in the reader's content world once the page is ready.
    func run(_ body: String, _ arguments: [String: Any] = [:], completion: ((Result<Any, any Error>) -> Void)? = nil) {
        guard isReady else {
            queued.append { [weak self] in self?.run(body, arguments, completion: completion) }
            return
        }
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: world) { result in
            completion?(result)
        }
    }

    func render(_ payload: [String: Any]) { run("return Tern.render(p)", ["p": payload]) }
    func setTheme(dark: Bool) {
        webView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        run("Tern.setTheme(t)", ["t": dark ? "dark" : "light"])
    }
    func clear() { run("Tern.clear()") }

    /// Swaps the content blocker; remote images load only for trusted senders.
    func setRemoteImages(allowed: Bool) {
        guard allowed != remoteImagesAllowed else { return }
        remoteImagesAllowed = allowed
        applyRuleList()
    }

    private func applyRuleList() {
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        if let list = remoteImagesAllowed ? allowImages : blockAll { controller.add(list) }
    }

    private func compileRuleLists() {
        guard let store = WKContentRuleListStore.default() else { return }
        let block = #"[{"trigger":{"url-filter":"^[hH][tT][tT][pP][sS]?:"},"action":{"type":"block"}}]"#
        let trackers = MailHTMLPolicyBridge.trackerPatterns.map {
            #"{"trigger":{"url-filter":"\#($0)"},"action":{"type":"block"}}"#
        }.joined(separator: ",")
        let images = #"[{"trigger":{"url-filter":"^[hH][tT][tT][pP][sS]?:"},"action":{"type":"block"}},"#
            + #"{"trigger":{"url-filter":"^[hH][tT][tT][pP][sS]?:","resource-type":["image"]},"action":{"type":"ignore-previous-rules"}},"#
            + trackers + "]"
        store.compileContentRuleList(forIdentifier: "tern-reader-block-1", encodedContentRuleList: block) { [weak self] list, _ in
            MainActor.assumeIsolated {
                self?.blockAll = list
                self?.applyRuleList()
            }
        }
        store.compileContentRuleList(forIdentifier: "tern-reader-images-1", encodedContentRuleList: images) { [weak self] list, _ in
            MainActor.assumeIsolated {
                self?.allowImages = list
                self?.applyRuleList()
            }
        }
    }

    // MARK: Events

    fileprivate func received(_ body: Any) {
        guard let message = body as? [String: Any] else { return }
        if message["type"] as? String == "boot" { return }
        delegate?.readerWeb(received: message)
    }

    /// Waits for the fonts, then renders and clears a throwaway thread so the first real open
    /// doesn't pay for cold script, style and layout paths.
    private func pageLoaded() {
        let warmup = """
            await Tern.fontsReady();
            Tern.render(p);
            Tern.setBodies(p.key, {});
            Tern.clear();
            return true;
            """
        webView.callAsyncJavaScript(warmup, arguments: ["p": ReaderResources.warmupPayload], in: nil, in: world) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isReady = true
                let pending = self.queued
                self.queued = []
                pending.forEach { $0() }
            }
        }
        Task.detached(priority: .utility) {
            _ = MailSanitizer.sanitize(html: ReaderResources.warmupMail)
            _ = PlainTextMail.html("Warm up https://example.com\n\nOn Mon, A wrote:\n> q")
        }
    }

    fileprivate func contentIdData(_ url: URL) async throws -> (Data, String) {
        guard let parts = MailSanitizer.parseContentIdURL(url), let delegate else { throw CocoaError(.fileNoSuchFile) }
        return try await delegate.readerWeb(contentId: parts.contentId, messageId: parts.messageId, accountId: parts.accountId)
    }
}

extension ReaderWebEngine: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        if url?.scheme == "tern-app", navigationAction.targetFrame?.isMainFrame == true, navigationAction.navigationType == .other {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if navigationAction.navigationType == .linkActivated, let url { delegate?.readerWeb(openURL: url, text: "") }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadPage()
        queued.append { [weak self] in self?.delegate?.readerWebDidReload() }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { delegate?.readerWeb(openURL: url, text: "") }
        return nil
    }
}

/// Keeps the user content controller from retaining the engine strongly through the handler.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var engine: ReaderWebEngine?
    init(_ engine: ReaderWebEngine) { self.engine = engine }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { engine?.received(body) }
    }
}

/// Serves the bundled fonts (`tern-app://fonts/…`) and inline mail images (`tern-cid://…`).
private final class ReaderSchemeHandler: NSObject, WKURLSchemeHandler {
    weak var engine: ReaderWebEngine?
    private var stopped = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        if url.scheme == "tern-app" {
            guard url.host == "fonts", let data = ReaderResources.font(named: url.lastPathComponent) else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            respond(task, data: data, mimeType: "font/ttf")
            return
        }
        let id = ObjectIdentifier(task)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result: (Data, String)
            do {
                result = try await self.engine?.contentIdData(url) ?? (ReaderResources.missingImage, "image/svg+xml")
            } catch {
                result = (ReaderResources.missingImage, "image/svg+xml")
            }
            guard !self.stopped.contains(id) else {
                self.stopped.remove(id)
                return
            }
            self.respond(task, data: result.0, mimeType: result.1)
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }

    private func respond(_ task: any WKURLSchemeTask, data: Data, mimeType: String) {
        guard let url = task.request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": mimeType, "Content-Length": String(data.count), "Cache-Control": "max-age=86400",
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}

/// The shared web view: trims the context menu to reading actions and hosts Quick Look.
final class ReaderWebView: WKWebView {
    /// Called with the current hovered link when the context menu opens on one.
    var openLinkFromMenu: (() -> Void)?
    /// Called when the page takes the keyboard (a click into the conversation).
    var didTakeFocus: (() -> Void)?
    var hoveredLink: String?
    let quickLook = ReaderQuickLook()

    private static let keptMenuItems: Set<String> = [
        "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierCopyLink", "WKMenuItemIdentifierCopyImage",
        "WKMenuItemIdentifierLookUp", "WKMenuItemIdentifierSearchWeb", "WKMenuItemIdentifierShareMenu",
        "WKMenuItemIdentifierSpeechMenu", "WKMenuItemIdentifierTranslate",
    ]

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.items.removeAll { item in
            guard let id = item.identifier?.rawValue, id.hasPrefix("WKMenuItemIdentifier") else { return false }
            return !Self.keptMenuItems.contains(id)
        }
        if hoveredLink != nil, menu.items.contains(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierCopyLink" }) {
            let open = NSMenuItem(title: "Open Link", action: #selector(openHoveredLink), keyEquivalent: "")
            open.target = self
            menu.insertItem(open, at: 0)
        }
        while menu.items.first?.isSeparatorItem == true { menu.removeItem(at: 0) }
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        var index = 1
        while index < menu.items.count {
            if menu.items[index].isSeparatorItem, menu.items[index - 1].isSeparatorItem { menu.removeItem(at: index) } else { index += 1 }
        }
        super.willOpenMenu(menu, with: event)
    }

    @objc private func openHoveredLink() { openLinkFromMenu?() }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { didTakeFocus?() }
        return accepted
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { !quickLook.items.isEmpty }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = quickLook
        panel.delegate = quickLook
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

/// Quick Look data source for downloaded attachments.
final class ReaderQuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var items: [URL] = []

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        items[index] as NSURL
    }
}

/// Tracker hosts the "images allowed" content blocker still refuses, as rule-list URL filters.
enum MailHTMLPolicyBridge {
    static let trackerPatterns = [
        "mailtrack\\\\.io", "t\\\\.yesware\\\\.com", "mailstat\\\\.us", "track\\\\.hubspot\\\\.com",
        "list-manage\\\\.com/track/open", "sendgrid\\\\.net/wf/open", "mandrillapp\\\\.com/track/open",
        "emltrk\\\\.com", "getnotify\\\\.com", "pixel\\\\.wp\\\\.com",
    ]
}
