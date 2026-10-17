import AppKit
import GRDB
import SwiftUI
import Testing
@testable import Tern
@testable import TernCore

/// Renders composer windows and inline composers offscreen into PNGs under /tmp/tern-shots/compose/.
/// Uses an in-memory fake mailbox; nothing is shown on screen. Run with:
///     TERN_SHOTS=1 swift test --filter ComposerSnapshots
@MainActor
@Suite struct ComposerSnapshots {
    static let output = URL(fileURLWithPath: "/tmp/tern-shots/compose", isDirectory: true)
    static let now = Date(timeIntervalSince1970: 1_792_224_000) // Fri, Oct 16 2026

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_SHOTS"] != nil))
    func renderComposers() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Theme.registerFonts()
        try FileManager.default.createDirectory(at: Self.output, withIntermediateDirectories: true)

        let database = try AppDatabase.inMemory()
        try FakeMailbox.populate(database, options: .init(messages: 4_000, seed: 7, now: Self.now))
        let services = AppServices(store: MailStore(database))
        services.accounts = try services.store.accounts()
        services.draftFilesDirectory = Self.output.appendingPathComponent("files", isDirectory: true)
        services.ai = AIActions(
            summarize: { _ in [] }, suggestReplies: { _ in [] }, draftReply: { _, _ in "" },
            naturalLanguageQuery: { $0 }, writeDraft: { _ in "" })
        let northwind = FakeMailbox.accounts[1].id
        try database.writer.write { db in
            try Setting(key: DraftStore.SettingKey.signature(northwind), value: "<div>Alex Morgan</div><div>Northwind Studio · northwind.studio</div>").upsert(db)
            try Setting(key: DraftStore.SettingKey.signature(FakeMailbox.accounts[0].id), value: "<div>— Alex</div>").upsert(db)
        }
        let threads = try Self.pickThreads(database)

        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!

            // New mail, typed into, with a selection showing the formatting bar.
            let started = Date()
            let new = try #require(ComposerModel(request: .new(accountId: northwind, to: []), services: services, mode: .window))
            let window = Composer.makeWindow(for: new)
            window.appearance = appearance
            window.contentView?.layoutSubtreeIfNeeded()
            let readyMs = Date().timeIntervalSince(started) * 1000
            new.setRecipients([
                Participant(name: "Maya Chen", email: "maya@lumen.io"),
                Participant(name: "Jonas Becker", email: "jonas@lumen.io"),
                Participant(email: "priya@lumen"),
            ], for: .to)
            new.setSubject("Lisbon offsite: venue shortlist")
            new.editor.richText = RichText([
                .init(.paragraph, [.init("Hi both,")]),
                .init(.paragraph),
                .init(.paragraph, [.init("Three venues made the cut. My favourite is "), .init("Casa do Rio", style: .bold),
                                   .init(" — see the "), .init("floor plans", link: "https://northwind.studio/plans"), .init(".")]),
                .init(.bullet, [.init("Casa do Rio — 40 people, river view")]),
                .init(.bullet, [.init("Palácio Verde — cheaper, a bit far")]),
                .init(.bullet, [.init("LX Factory loft — "), .init("only Thursdays", style: .italic)]),
                .init(.paragraph),
                .init(.paragraph, [.init("Can you both vote by Friday?")]),
            ])
            try render(window, "window-new-\(suffix)", settle: {
                window.makeFirstResponder(new.editor.textView)
                new.editor.textView.setSelectedRange(NSRange(location: 52, length: 11))
                new.editor.showFormattingBar()
            })
            print("composer ready (model + window + layout), \(suffix) pass: \(String(format: "%.1f", readyMs)) ms")

            // Reply with the quote expanded.
            let reply = try #require(ComposerModel(request: .reply(threads.reply, all: false), services: services, mode: .window))
            reply.editor.richText = RichText(plainText: "Thursday works for me. I'll bring the printed decks.\n\nAlex")
            reply.quoteExpanded = true
            let replyWindow = Composer.makeWindow(for: reply)
            replyWindow.appearance = appearance
            try render(replyWindow, "window-reply-\(suffix)")

            // Reply all with Cc tokens, one of them invalid, and the ✦ bar open.
            let replyAll = try #require(ComposerModel(request: .reply(threads.replyAll, all: true), services: services, mode: .window))
            replyAll.setRecipients(replyAll.cc + [Participant(email: "ops@lumen")], for: .cc)
            replyAll.showCc = true
            replyAll.aiInstruction = "Say yes, ask for the agenda"
            let replyAllWindow = Composer.makeWindow(for: replyAll)
            replyAllWindow.appearance = appearance
            try render(replyAllWindow, "window-reply-all-\(suffix)")

            // Forward with the original's attachments listed.
            let forward = try #require(ComposerModel(request: .forward(threads.forward), services: services, mode: .window))
            forward.setRecipients([Participant(name: "Sam Ortiz", email: "sam@kiteworks.dev")], for: .to)
            forward.editor.richText = RichText(plainText: "Sam, can you sanity-check the numbers before Monday?")
            let forwardWindow = Composer.makeWindow(for: forward)
            forwardWindow.appearance = appearance
            try render(forwardWindow, "window-forward-\(suffix)")

            // A draft written in Gmail with an image in its body.
            let chart = services.draftFilesDirectory!.appendingPathComponent("chart.png")
            try FileManager.default.createDirectory(at: services.draftFilesDirectory!, withIntermediateDirectories: true)
            try Self.chartPNG().write(to: chart)
            let imaged = ComposerModel(content: DraftContent(stored: Draft(
                accountId: northwind, toList: [Participant(name: "Maya Chen", email: "maya@lumen.io")], subject: "Q3 numbers",
                bodyHtml: #"<div>Here's the chart from the review:</div><div><img src="cid:chart"></div><div>Revenue is up 18% on Q2.</div>"#,
                attachments: [DraftAttachment(path: chart.path, filename: "chart.png", mimeType: "image/png", size: 1, contentId: "chart")])),
                services: services, mode: .window)
            let imagedWindow = Composer.makeWindow(for: imaged)
            imagedWindow.appearance = appearance
            try render(imagedWindow, "window-inline-image-\(suffix)")

            // Inline: collapsed reply, expanded reply all.
            let inline = try #require(ComposerModel(request: .reply(threads.reply, all: false), services: services, mode: .inline))
            inline.editor.richText = RichText(plainText: "Sounds good — see you Thursday.")
            try renderInline(inline, "inline-reply-\(suffix)", appearance: appearance)
            let inlineAll = try #require(ComposerModel(request: .reply(threads.replyAll, all: true), services: services, mode: .inline))
            inlineAll.headerExpanded = true
            inlineAll.editor.richText = RichText(plainText: "Adding the agenda here:\n1. Venue\n2. Budget\n3. Travel")
            try renderInline(inlineAll, "inline-reply-all-\(suffix)", appearance: appearance)

            // Pieces that live in their own panels.
            let list = SuggestionListView()
            list.items = [
                Participant(name: "Maya Chen", email: "maya@lumen.io"),
                Participant(name: "Max Okafor", email: "max@brightpath.co"),
                Participant(email: "marketing@lumen.io"),
            ]
            try renderPanel(list, size: NSSize(width: 320, height: list.fittingHeight), "suggestions-\(suffix)", appearance: appearance)
            try renderSwiftUI(SendLaterPopover(model: replyAll), width: 270, "send-later-\(suffix)", appearance: appearance)
            let toast = ToastState(message: "Sending", deadline: Date().addingTimeInterval(4.5), undo: {})
            try renderSwiftUI(SendToastView(state: toast, dismiss: {}), width: nil, "undo-toast-\(suffix)", appearance: appearance, background: Theme.bg)
        }
        print("snapshots in \(Self.output.path)")
    }

    // MARK: Fixtures

    struct Threads {
        var reply: ThreadKey
        var replyAll: ThreadKey
        var forward: ThreadKey
    }

    /// People threads: one long conversation, one with Cc'd people, one with an attachment.
    static func pickThreads(_ database: AppDatabase) throws -> Threads {
        try database.reader.read { db in
            func key(_ sql: String) throws -> ThreadKey {
                let row = try #require(try Row.fetchOne(db, sql: sql))
                return ThreadKey(accountId: row["accountId"], threadId: row["threadId"])
            }
            let people = "SELECT accountId, threadId FROM thread_ai WHERE category = 'people'"
            let reply = try key("""
                SELECT t.accountId, t.id AS threadId FROM thread t JOIN (\(people)) p ON p.accountId = t.accountId AND p.threadId = t.id
                WHERE t.messageCount >= 3 AND t.accountId = 'alex@northwind.studio' ORDER BY t.lastDate DESC LIMIT 1
                """)
            let replyAll = try key("""
                SELECT m.accountId, m.threadId FROM message m JOIN (\(people)) p ON p.accountId = m.accountId AND p.threadId = m.threadId
                WHERE m.ccList != '[]' AND m.isFromMe = 0 AND m.id = (SELECT id FROM message x WHERE x.accountId = m.accountId AND x.threadId = m.threadId ORDER BY date DESC LIMIT 1)
                ORDER BY m.date DESC LIMIT 1
                """)
            let forward = try key("""
                SELECT m.accountId, m.threadId FROM message m JOIN attachment a ON a.accountId = m.accountId AND a.messageId = m.id
                JOIN (\(people)) p ON p.accountId = m.accountId AND p.threadId = m.threadId
                WHERE m.id = (SELECT id FROM message x WHERE x.accountId = m.accountId AND x.threadId = m.threadId AND x.isDraft = 0 ORDER BY date DESC LIMIT 1)
                ORDER BY m.date DESC LIMIT 1
                """)
            return Threads(reply: reply, replyAll: replyAll, forward: forward)
        }
    }

    /// A small bar chart, as a PNG.
    static func chartPNG() throws -> Data {
        let image = NSImage(size: NSSize(width: 480, height: 220), flipped: false) { rect in
            NSColor(white: 0.96, alpha: 1).setFill()
            rect.fill()
            for (index, height) in [90.0, 130, 110, 170].enumerated() {
                NSColor(red: 0.25, green: 0.45, blue: 0.85, alpha: 1).setFill()
                NSBezierPath(roundedRect: CGRect(x: 50 + Double(index) * 105, y: 20, width: 70, height: height), xRadius: 4, yRadius: 4).fill()
            }
            return true
        }
        return try #require(image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) })
    }

    // MARK: Rendering

    /// Lets SwiftUI and TextKit settle, then draws the window's content into a PNG.
    func render(_ window: NSWindow, _ name: String, settle: () -> Void = {}) throws {
        guard let view = window.contentView else { return }
        pump()
        settle()
        pump()
        try write(view, name)
        window.close()
    }

    func renderInline(_ model: ComposerModel, _ name: String, appearance: NSAppearance) throws {
        let card = InlineComposerCard(model: model)
            .padding(24)
            .frame(width: 720)
            .background(Color(Theme.raised))
            .environment(model.services)
        let window = offscreenWindow(NSHostingView(rootView: card), size: NSSize(width: 720, height: 600), appearance: appearance)
        pump()
        let fitting = window.contentView!.fittingSize
        window.setContentSize(NSSize(width: 720, height: fitting.height))
        pump()
        try write(window.contentView!, name)
        window.close()
    }

    func renderSwiftUI<V: View>(_ view: V, width: CGFloat?, _ name: String, appearance: NSAppearance, background: NSColor = Theme.raised) throws {
        let host = NSHostingView(rootView: view.frame(width: width).background(Color(background)))
        let window = offscreenWindow(host, size: NSSize(width: 400, height: 400), appearance: appearance)
        pump()
        window.setContentSize(host.fittingSize)
        pump()
        try write(host, name)
        window.close()
    }

    func renderPanel(_ view: NSView, size: NSSize, _ name: String, appearance: NSAppearance) throws {
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = Theme.raised.resolved(for: appearance).cgColor
        view.frame = container.bounds
        container.addSubview(view)
        let window = offscreenWindow(container, size: size, appearance: appearance)
        pump()
        try write(container, name)
        window.close()
    }

    func offscreenWindow(_ content: NSView, size: NSSize, appearance: NSAppearance) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = content
        return window
    }

    func pump() {
        for _ in 0..<6 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            NSApp.windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
        }
    }

    func write(_ view: NSView, _ name: String) throws {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.window?.appearance?.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: bounds, to: rep)
        }
        let url = Self.output.appendingPathComponent("\(name).png")
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
