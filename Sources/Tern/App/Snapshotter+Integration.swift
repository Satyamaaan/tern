import AppKit
import SwiftUI
import TernCore
import WebKit

// The reader, search, inline replies, settings and onboarding as the shell shows them.
extension Snapshotter {
    /// WebKit paints only into a window on screen: order the window in at 1 % opacity, click-through,
    /// without activating the app or taking focus.
    func showForWebKit(_ window: MainWindow) {
        NSApp.setActivationPolicy(.accessory)
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        model.focusList()
        wait(until: { ReaderWebEngine.shared.isReady }, timeout: 5)
    }

    /// Opening threads one after another with j: key change to painted reader, as the user sees it.
    func measureOpen(_ window: MainWindow) {
        model.moveToTop()
        var times: [Double] = []
        for _ in 0..<30 {
            var painted: Double?
            ReaderModel.renderObserver = { _, milliseconds in painted = milliseconds }
            model.moveCursor(1)
            wait(until: { painted != nil }, timeout: 2)
            if let painted { times.append(painted) }
        }
        ReaderModel.renderObserver = nil
        model.moveToTop()
        guard !times.isEmpty else { return print("open: the reader didn't paint") }
        times.sort()
        print(String(format: "open (j, reader painted): median %.1f ms, p95 %.1f ms, max %.1f ms over %d threads",
                     times[times.count / 2], times[min(times.count - 1, Int(Double(times.count) * 0.95))], times.last ?? 0, times.count))
    }

    func integrationShots(_ window: MainWindow, _ directory: URL) {
        func shot(_ name: String, dark: Bool = false) {
            render(window, appearance: dark ? .darkAqua : .aqua, to: directory.appendingPathComponent("\(name).png"))
        }
        let services = model.services

        // A conversation of several messages, opened from the list.
        model.show(.inbox)
        model.showSplit(.important)
        settle(window)
        let thread = model.snapshot.order.first { (model.row($0)?.thread.messageCount ?? 0) >= 3 } ?? model.snapshot.order.first
        if let thread {
            openForShot(thread, window)
            shot("reader-light")
            shot("reader-dark", dark: true)

            services.reader.reply(all: false)
            wait(seconds: 0.8)
            shot("reply-inline-light")
            shot("reply-inline-dark", dark: true)
            services.reader.model?.composing = nil
            wait(seconds: 0.3)
        }

        // Older mail stored without its body, waiting for sync.
        if let other = model.snapshot.order.dropFirst(3).first {
            _ = try? model.store.database.writer.write { db in
                try db.execute(sql: "UPDATE message SET bodyState = 0, bodyHtml = NULL, bodyText = NULL WHERE accountId = ? AND threadId = ?",
                               arguments: [other.accountId, other.threadId])
            }
            openForShot(other, window)
            services.syncLine = SyncLine(text: "Older mail syncing in the background · 34%", tone: .quiet)
            shot("reader-loading-light")
            services.syncLine = nil
        }

        // Search: matched words marked in the results, then the dropdown with people and ✦ Ask.
        let ai = services.ai
        services.ai = AIActions(summarize: { _ in [] }, suggestReplies: { _ in [] }, draftReply: { _, _ in "" },
                                naturalLanguageQuery: { $0 })
        model.focusList()
        model.searchText = "invoice"
        wait(seconds: 0.4)
        model.suggestionsDismissed = true
        shot("search-light")
        shot("search-dark", dark: true)
        model.beginSearch()
        model.searchText = "invoice from:m"
        wait(seconds: 0.4)
        model.suggestionsDismissed = false
        model.suggestionIndex = 1
        shot("search-suggestions-light")
        shot("search-suggestions-dark", dark: true)
        model.endSearch(restoreFocus: true)
        services.ai = ai

        // Settings → Accounts with the Google client, and onboarding's first step.
        let googleClientId = services.googleClientId
        services.googleClientId = { "1234567890-abcdefghijklmnop.apps.googleusercontent.com" }
        let settings = SettingsState(model: model, shell: nil)
        settings.section = .accounts
        for dark in [false, true] {
            standalone(SettingsView(state: settings).environment(model).environment(services), size: NSSize(width: 760, height: 540),
                       to: directory.appendingPathComponent("settings-google-\(dark ? "dark" : "light").png"), dark: dark)
        }
        settings.editsGoogleClient = true
        standalone(SettingsView(state: settings).environment(model).environment(services), size: NSSize(width: 760, height: 640),
                   to: directory.appendingPathComponent("settings-google-edit-light.png"), dark: false)
        services.googleClientId = googleClientId
        for dark in [false, true] {
            standalone(OnboardingView(onFinish: {}, onDemo: {}).environment(model).environment(services), size: NSSize(width: 640, height: 560),
                       to: directory.appendingPathComponent("onboarding-\(dark ? "dark" : "light").png"), dark: dark)
        }
    }

    /// Opens a thread in the reader and waits until the page has painted it.
    private func openForShot(_ key: ThreadKey, _ window: MainWindow) {
        var painted = false
        ReaderModel.renderObserver = { rendered, _ in if rendered == key { painted = true } }
        model.select(key)
        model.open()
        wait(until: { painted }, timeout: 3)
        ReaderModel.renderObserver = nil
        wait(seconds: 0.4)
    }

    /// Runs `capture` with the reader's page shown as a still image in the web view's place. WebKit paints
    /// out of process, so `cacheDisplay` alone leaves the reader blank; the stand-in keeps the views'
    /// order, so overlays (the palette, toasts) still draw on top of the page.
    func withPageStandIn(_ window: NSWindow, _ capture: () -> Void) {
        let webView = ReaderWebEngine.shared.webView
        guard webView.window === window, window.isVisible, let container = webView.superview else { return capture() }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        var image: NSImage?
        var done = false
        webView.takeSnapshot(with: configuration) { snapshot, _ in
            image = snapshot
            done = true
        }
        wait(until: { done }, timeout: 2)
        guard let image else { return capture() }
        let standIn = NSImageView(frame: webView.frame)
        standIn.image = image
        standIn.imageScaling = .scaleAxesIndependently
        container.addSubview(standIn, positioned: .above, relativeTo: webView)
        capture()
        standIn.removeFromSuperview()
    }

    private func wait(until done: () -> Bool, timeout: TimeInterval) {
        let end = Date().addingTimeInterval(timeout)
        while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func wait(seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
