#if DEBUG
import AppKit
import Observation
import SwiftUI
import TernCore
import WebKit

/// Renders the reader offscreen for design and speed checks, then quits:
///
///     swift build && mkdir -p /tmp/tern-reader-home && TERN_READER_SNAPSHOT=/tmp/tern-shots/reader \
///       CFFIXED_USER_HOME=/tmp/tern-reader-home .build/debug/Tern -ApplePersistenceIgnoreState YES --fake
///
/// The harness starts with the first reader, so the shell needs a mailbox (`--fake`); it hides the
/// shell window at once, and the temporary home keeps the shell away from the real database.
/// Uses an in-memory fake mailbox plus `ReaderSnapshotFixtures`, writes `<fixture>-<light|dark>.png`
/// and `timings.txt`. The window is click-through and 1 % opaque, so nothing shows on screen while
/// WebKit still paints at full speed.
@MainActor
enum ReaderSnapshot {
    private static var started = false
    private static let requestedPath = ProcessInfo.processInfo.environment["TERN_READER_SNAPSHOT"]

    static func startIfRequested() {
        guard !started, let path = requestedPath, !path.isEmpty else { return }
        started = true
        Task { @MainActor in
            let runner = Runner(output: URL(fileURLWithPath: path))
            await runner.run()
            exit(0)
        }
    }

    @Observable
    final class Selection {
        var key: ThreadKey?
        var prefetch: [ThreadKey] = []
    }

    /// The reader as it sits over the list: on `bg`, with Back and the hover position showing.
    struct Root: View {
        let selection: Selection
        var body: some View {
            ReaderView(key: selection.key, prefetch: selection.prefetch,
                       position: ReaderPosition(index: 12, total: 48, previous: {}, next: {}), onBack: {})
                .background(Color(Theme.bg))
        }
    }

    @MainActor
    final class Runner {
        let output: URL
        var log: [String] = []
        var rendered: (ThreadKey, Double)?
        var window: NSWindow?

        init(output: URL) { self.output = output }

        func run() async {
            NSApp.setActivationPolicy(.accessory)
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            hideOtherWindows()
            NSApp.unhideWithoutActivation()

            let now = Date()
            guard let database = try? AppDatabase.inMemory() else { return }
            let started = Date()
            _ = try? FakeMailbox.populate(database, options: .init(messages: 6_000, seed: 7, now: now))
            let store = MailStore(database)
            guard let fixtures = try? ReaderSnapshotFixtures.install(into: store, now: now) else { return }
            note("Fake mailbox ready in \(Int(Date().timeIntervalSince(started) * 1000)) ms")

            let services = AppServices(store: store)
            services.accounts = FakeMailbox.accounts
            services.projects = (try? store.projects()) ?? []
            services.perform = { action, keys in _ = try? store.perform(action, on: keys) }
            let chart = FileManager.default.temporaryDirectory.appendingPathComponent("tern-reader-chart.png")
            try? ReaderSnapshotFixtures.chartImage().write(to: chart)
            services.loadAttachment = { attachment in
                if attachment.contentId == "chart@kiteworks" { return chart }
                throw CocoaError(.featureUnsupported)
            }
            services.ai = AIActions(
                summarize: { _ in
                    try await Task.sleep(for: .milliseconds(120))
                    return ["Maya sent SOW v3 with both of your changes: 40/30/30 and a Nov 14 first milestone.",
                            "Jonas's §4 change (10 business days to accept) is included.",
                            "She needs your signature before Thursday's 9:30 kickoff."]
                },
                suggestReplies: { _ in ["Signing today", "Call Thursday?", "Looks good, thanks"] },
                draftReply: { _, _ in "" }, naturalLanguageQuery: { $0 })
            ReaderReplyBar.alwaysShowQuickReplies = true
            ReaderTopBar.alwaysShowPosition = true
            // SenderLogos only fetches in the app; two senders get a stand-in logo through the same path.
            let logos = [ReaderSnapshotFixtures.maya.email: ReaderSnapshotFixtures.logo("L", 0x111111),
                         "hello@weeklybuild.example": ReaderSnapshotFixtures.logo("W", 0x5B4BDB)]
            ReaderModel.logoOverride = { logos[$0] }

            let selection = Selection()
            let hosting = NSHostingView(rootView: Root(selection: selection).environment(services))
            let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 760, height: 1_000), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            self.window = window
            window.contentView = hosting
            window.alphaValue = 0.01
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
            window.orderFrontRegardless()
            NSApp.unhideWithoutActivation()
            try? await Task.sleep(for: .milliseconds(300))
            note("Harness window visible to WebKit: \(window.occlusionState.contains(.visible))")
            ReaderModel.renderObserver = { [weak self] key, milliseconds in self?.rendered = (key, milliseconds) }

            // Warm the page before measuring anything.
            let warmStart = CACurrentMediaTime()
            while !ReaderWebEngine.shared.isReady { try? await Task.sleep(for: .milliseconds(5)) }
            note("Web view ready (template + fonts) in \(Int((CACurrentMediaTime() - warmStart) * 1000)) ms after first reader")
            let visibility = try? await ReaderWebEngine.shared.webView.evaluateJavaScript("document.visibilityState")
            note("Page visibility: \(visibility.map { "\($0)" } ?? "?") (open times include paint only when visible)")

            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                for fixture in fixtures {
                    window.setContentSize(NSSize(width: fixture.width, height: 1_000))
                    selection.key = nil
                    _ = await waitForRender(nil)
                    selection.key = fixture.key
                    guard let milliseconds = await waitForRender(fixture.key) else {
                        note("\(fixture.name): no render")
                        continue
                    }
                    if fixture.name == "big-newsletter" { await waitForBody(since: milliseconds) }
                    try? await Task.sleep(for: .milliseconds(350))
                    if fixture.name == "reply-chain", appearance == .aqua {
                        await save(hosting, name: "\(fixture.name)-\(suffix(appearance))")
                        try? await Task.sleep(for: .milliseconds(1_200))
                        services.reader.summarize()
                        try? await Task.sleep(for: .milliseconds(400))
                        await save(hosting, name: "\(fixture.name)-summary-\(suffix(appearance))")
                        await focusShots(hosting, suffix(appearance))
                        continue
                    }
                    if fixture.name == "hostile" { await checkHostile() }
                    if fixture.name == "css-escape" { await checkCSSEscape(suffix(appearance)) }
                    await save(hosting, name: "\(fixture.name)-\(suffix(appearance))")
                    if fixture.name == "reply-chain" { await focusShots(hosting, suffix(appearance)) }
                    if fixture.name == "hostile", appearance == .aqua {
                        _ = try? await js("""
                            const link = [...document.querySelectorAll('.mbody')].map((h) => h.shadowRoot).filter(Boolean)
                              .flatMap((r) => [...r.querySelectorAll('a')]).find((a) => a.textContent.includes('paypal.com'));
                            link.dispatchEvent(new MouseEvent('mouseover', { bubbles: true, composed: true }));
                            return true;
                            """)
                        try? await Task.sleep(for: .milliseconds(250))
                        await save(hosting, name: "hostile-hover-light")
                        _ = try? await js("document.body.dispatchEvent(new MouseEvent('mouseover', { bubbles: true })); return true;")
                    }
                    if fixture.name == "remote-images", appearance == .aqua {
                        try? await Task.sleep(for: .seconds(2))
                        note("remote-images: shown blocked for 2 s, clicking Load images at \(Date().formatted(.dateTime.hour().minute().second()))")
                        _ = try? await js("document.querySelector('.imgnote .load').click(); return true;")
                        try? await Task.sleep(for: .milliseconds(1_200))
                        note("remote-images: loaded shot at \(Date().formatted(.dateTime.hour().minute().second()))")
                        await save(hosting, name: "remote-images-loaded-light")
                    }
                    note("\(fixture.name) (\(suffix(appearance))): opened in \(String(format: "%.1f", milliseconds)) ms")
                }
            }
            window.appearance = NSAppearance(named: .aqua)
            window.setContentSize(NSSize(width: 760, height: 1_000))
            if let chain = fixtures.first(where: { $0.name == "reply-chain" }) {
                await interactionChecks(chain.key, selection: selection, services: services)
            }
            ReaderModel.logoOverride = nil
            await measure(store: store, selection: selection)
            try? log.joined(separator: "\n").write(to: output.appendingPathComponent("timings.txt"), atomically: true, encoding: .utf8)
            print(log.joined(separator: "\n"))
        }

        func suffix(_ appearance: NSAppearance.Name) -> String { appearance == .aqua ? "light" : "dark" }

        func note(_ line: String) {
            log.append(line)
        }

        func hideOtherWindows() {
            Task { @MainActor in
                for _ in 0..<40 {
                    for other in NSApp.windows where other !== window && other.isVisible {
                        other.alphaValue = 0
                        other.orderOut(nil)
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        }

        /// Waits for the reader to paint `key` (or settle after clearing). Returns the open time.
        func waitForRender(_ key: ThreadKey?) async -> Double? {
            rendered = nil
            guard let key else {
                try? await Task.sleep(for: .milliseconds(30))
                return nil
            }
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if let rendered, rendered.0 == key { return rendered.1 }
                try? await Task.sleep(for: .milliseconds(2))
            }
            return nil
        }

        /// Opens inbox threads one after another, the way j/k does, and reports open times.
        func measure(store: MailStore, selection: Selection) async {
            let rows = ((try? store.threadRows(in: .unifiedInbox, limit: 60)) ?? []).map(\.id)
            guard rows.count > 2 else { return }
            for pass in ["first visit", "second visit"] {
                var times: [Double] = []
                var builds: [Double] = []
                for (index, key) in rows.enumerated() {
                    selection.prefetch = Array(rows[(index + 1)..<min(rows.count, index + 3)])
                    selection.key = key
                    if let milliseconds = await waitForRender(key) {
                        times.append(milliseconds)
                        builds.append(ReaderModel.lastBuildMilliseconds)
                    }
                }
                times.sort()
                guard !times.isEmpty else { continue }
                let median = times[times.count / 2], p95 = times[min(times.count - 1, Int(Double(times.count) * 0.95))]
                builds.sort()
                note(String(format: "j/k through %d inbox threads, %@: key change → painted frame median %.1f ms, p95 %.1f ms, max %.1f ms; DOM build median %.1f ms, max %.1f ms",
                            times.count, pass, median, p95, times.last ?? 0, builds[builds.count / 2], builds.last ?? 0))
            }
        }

        func js(_ body: String) async throws -> Any? {
            try await ReaderWebEngine.shared.webView.callAsyncJavaScript(
                body, arguments: [:], in: nil, contentWorld: ReaderWebEngine.shared.world)
        }

        /// Where the keyboard is in the thread: a collapsed message (p) and a selected attachment, then the
        /// open message (n).
        func focusShots(_ hosting: NSView, _ suffix: String) async {
            _ = try? await js("Tern.previous(); document.querySelector('.att')?.classList.add('selected'); return true;")
            try? await Task.sleep(for: .milliseconds(150))
            await save(hosting, name: "reply-chain-focus-line-\(suffix)")
            _ = try? await js("Tern.next(); window.scrollTo(0, 0); return true;")
            try? await Task.sleep(for: .milliseconds(150))
            await save(hosting, name: "reply-chain-focus-open-\(suffix)")
        }

        /// Find, n/p, quote toggles and expand-all, driven through the same entry points the UI uses.
        func interactionChecks(_ key: ThreadKey, selection: Selection, services: AppServices) async {
            selection.key = nil
            _ = await waitForRender(nil)
            selection.key = key
            _ = await waitForRender(key)
            try? await Task.sleep(for: .milliseconds(300))
            guard let model = services.reader.model else { return }
            let unread = try? services.store.threadDetail(key)?.thread.unreadCount
            note("checks: unread after open = \(unread.map(String.init) ?? "?") (marked read on open)")

            services.reader.nextMessage()
            services.reader.nextMessage()
            try? await Task.sleep(for: .milliseconds(80))
            let focused = try? await js("return document.querySelector('.msg.focused')?.dataset.id ?? 'none'")
            note("checks: n, n focuses message \(focused.map { "\($0)" } ?? "?")")

            let quote = try? await js("""
                const root = document.querySelector('.msg.open .mbody').shadowRoot;
                const toggle = root.querySelector('.tern-quote-toggle');
                const before = toggle.nextElementSibling.hidden;
                toggle.dispatchEvent(new MouseEvent('click', { bubbles: true, composed: true }));
                return `${before} -> ${toggle.nextElementSibling.hidden}`;
                """)
            note("checks: quote hidden before -> after click: \(quote.map { "\($0)" } ?? "?")")

            for text in ["40/30/30", "first draft of the statement", "no such words here"] {
                model.findText = text
                model.find()
                try? await Task.sleep(for: .milliseconds(400))
                note("checks: find “\(text)” → \(model.findFailed ? "no match" : "found")")
            }
            let open = try? await js("return document.querySelectorAll('.msg.open').length + ' of ' + document.querySelectorAll('.msg').length")
            note("checks: messages open after find (expand all) = \(open.map { "\($0)" } ?? "?")")
            model.closeFind()

            // A logo that arrives after the paint swaps only the avatars: open messages and scroll stay.
            let state = "return document.querySelectorAll('.msg.open').length + ' open, scrollTop ' + document.scrollingElement.scrollTop"
            _ = try? await js("window.scrollTo(0, 120); return true;")
            let before = try? await js(state)
            let jonas = ReaderSnapshotFixtures.logo("K", 0x2F6FD8)
            let previous = ReaderModel.logoOverride
            ReaderModel.logoOverride = { $0 == ReaderSnapshotFixtures.jonas.email ? jonas : previous?($0) }
            model.refreshLogos()
            try? await Task.sleep(for: .milliseconds(150))
            let after = try? await js(state)
            let swapped = try? await js("return document.querySelectorAll('.av.logo[data-email=\"jonas@kiteworks.dev\"] img').length")
            note("checks: late logo → \(swapped.map { "\($0)" } ?? "?") Jonas avatars swapped; \(before.map { "\($0)" } ?? "?") → \(after.map { "\($0)" } ?? "?")")
        }

        /// A body over the inline sanitize limit arrives after the first paint; notes when.
        func waitForBody(since openMilliseconds: Double) async {
            let started = CACurrentMediaTime()
            for _ in 0..<1_000 {
                let mounted = (try? await js("return !!document.querySelector('.msg.open .mbody')?.shadowRoot")) as? Bool
                if mounted == true {
                    note(String(format: "big-newsletter: header painted in %.1f ms, body mounted %.0f ms later",
                                openMilliseconds, (CACurrentMediaTime() - started) * 1000))
                    return
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
            note("big-newsletter: body never arrived")
        }

        /// Proves the hostile fixture ran nothing and kept nothing dangerous.
        func checkHostile() async {
            let webView = ReaderWebEngine.shared.webView
            let page = try? await webView.evaluateJavaScript("document.body.dataset.pwned || 'none'")
            let dangerous = try? await webView.callAsyncJavaScript("""
                let count = 0;
                for (const host of document.querySelectorAll('.mbody')) {
                  if (host.shadowRoot) count += host.shadowRoot.querySelectorAll('script,iframe,object,embed,form,input,button,meta,svg,[onerror],[onload],[onmouseover],a[href^="javascript"]').length;
                }
                return count;
                """, arguments: [:], in: nil, contentWorld: ReaderWebEngine.shared.world)
            note("hostile: page script markers = \(page.map { "\($0)" } ?? "?"), dangerous elements left = \(dangerous.map { "\($0)" } ?? "?")")
        }

        /// Proves mail CSS can't lift the card's containment: the open message's `.mbody` computes the same
        /// `contain`, `overflow` and `position` as a fresh host without mail CSS, and its sanitized sheet never
        /// names `:host`. As a control, the same reading must catch the old sanitizer's output for the
        /// combining-mark reproducer.
        func checkCSSEscape(_ suffix: String) async {
            let control = "@media all {\u{301}, :host {\n& { contain: none !important; overflow: visible !important; "
                + "position: absolute !important; inset: 0 !important }\n}\n"
            let result = try? await ReaderWebEngine.shared.webView.callAsyncJavaScript("""
                const host = document.querySelector('.msg.open .mbody');
                if (!host || !host.shadowRoot) return 'no body';
                const read = (element) => {
                  const style = getComputedStyle(element);
                  return `contain=${style.contain} overflow=${style.overflow} position=${style.position}`;
                };
                const fresh = (css) => {
                  const element = document.createElement('div');
                  element.className = host.className;
                  element.dataset.mode = host.dataset.mode;
                  host.after(element);
                  if (css !== null) {
                    const style = document.createElement('style');
                    style.textContent = css;
                    element.attachShadow({ mode: 'open' }).append(style);
                  }
                  const value = read(element);
                  element.remove();
                  return value;
                };
                const expected = fresh(null);
                const caught = fresh(control) !== expected;
                const sheet = [...host.shadowRoot.querySelectorAll('style')].map((style) => style.textContent).join('\\n');
                const named = /:host|::part|::slotted/i.test(sheet);
                return `${read(host) === expected ? 'contained' : 'ESCAPED'} (${read(host)}), :host in sheet = ${named}, `
                  + `control caught = ${caught}`;
                """, arguments: ["control": control], in: nil, contentWorld: ReaderWebEngine.shared.world)
            note("css-escape (\(suffix)): \(result.map { "\($0)" } ?? "?")")
        }

        func save(_ hosting: NSView, name: String) async {
            let webView = ReaderWebEngine.shared.webView
            let bounds = hosting.bounds
            guard let base = hosting.bitmapImageRepForCachingDisplay(in: bounds) else { return }
            hosting.cacheDisplay(in: bounds, to: base)
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = true
            let web: NSImage? = await withCheckedContinuation { continuation in
                webView.takeSnapshot(with: configuration) { image, _ in continuation.resume(returning: image) }
            }
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: base.pixelsWide, pixelsHigh: base.pixelsHigh, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { return }
            rep.size = bounds.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            base.draw(in: bounds)
            if let web, webView.window != nil {
                let frame = webView.convert(webView.bounds, to: nil)
                web.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
            }
            NSGraphicsContext.restoreGraphicsState()
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: output.appendingPathComponent("\(name).png"))
            }
        }
    }
}
#endif
