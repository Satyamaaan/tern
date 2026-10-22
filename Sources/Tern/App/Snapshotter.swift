import AppKit
import SwiftUI
import TernCore

/// `--snapshot <dir>`: renders the main window at 1320×840 (the list in light and dark, the ⌘K palette, Gmail's tabs, the
/// reader over the list, search, an inline reply, the settings page and onboarding) into PNGs, prints speed measurements,
/// and quits. WebKit only paints into a window on screen, so after the launch and j/k measurements the
/// window is ordered in at 1 % opacity and click-through, without activating the app: nothing shows.
@MainActor
struct Snapshotter {
    let model: AppModel
    let registry: CommandRegistry

    func run(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.installDemoLogos()
        Self.installDemoAccountPhotos(model.accounts)
        let palette = PaletteController(model: model, registry: registry)
        let window = makeWindow(palette: palette)
        // Launch time: first layout and a full render of the window with its rows.
        if let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.layoutSubtreeIfNeeded()
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        print(String(format: "launch: list rendered %.0f ms after process start (%d rows; app code started at %.0f ms)",
                     Timing.sinceProcessStart(), model.snapshot.order.count, Timing.appStarted))

        if ProcessInfo.processInfo.environment["TERN_SNAPSHOT_WIDTH"].flatMap(Double.init) == nil {
            measureKeyboard(window)
        }
        showForWebKit(window)
        measureOpen(window)

        render(window, appearance: .aqua, to: directory.appendingPathComponent("main-light.png"))
        render(window, appearance: .darkAqua, to: directory.appendingPathComponent("main-dark.png"))
        model.palette = .commands
        render(window, appearance: .aqua, to: directory.appendingPathComponent("palette-light.png"))
        render(window, appearance: .darkAqua, to: directory.appendingPathComponent("palette-dark.png"))
        model.palette = nil
        ledgerShots(window, directory)
        tabShots(window, directory)
        integrationShots(window, directory)
        if ProcessInfo.processInfo.environment["TERN_SNAPSHOT_EXTRAS"] == "1" { extras(window, directory) }
        print("Snapshots written to \(directory.path)")
        exit(0)
    }

    /// More states for visual review: hover + toast, the waterline, wide one-line rows, the slide-over, search, one
    /// account with labels, collapsed sidebar, the Archive mailbox, inbox zero, settings, onboarding, the
    /// project editor, and the update card, move prompt and update settings.
    private func extras(_ window: MainWindow, _ directory: URL) {
        func shot(_ name: String, dark: Bool = false) {
            render(window, appearance: dark ? .darkAqua : .aqua, to: directory.appendingPathComponent("\(name).png"))
        }
        let list = model.listView as? MessageListController

        list?.setHovered(2)
        model.showToast("Archived", undo: UndoEntry(change: .project("", [], assigned: true), threads: []))
        shot("hover-toast-light")
        shot("hover-toast-dark", dark: true)
        list?.setHovered(nil)
        model.toasts = []


        selectionShots(window, directory)

        model.toggleReadingPane()
        shot("reading-pane-light")
        shot("reading-pane-dark", dark: true)
        model.toggleReadingPane()

        // The slide-over: the open conversation from the right with the list beside it, then expanded over all of it.
        let overlay = model.prefs.readerOverlay, cursor = model.cursor
        model.prefs.readerOverlay = .panel
        // A conversation with several people and files, so the top bar shows its pictures and paperclip.
        let busy = model.snapshot.order.prefix(300).first { key in
            guard let detail = try? model.store.threadDetail(key) else { return false }
            return Set(detail.messages.map(\.fromEmail)).count > 1 && !detail.attachments.values.joined().isEmpty
        }
        if let busy { model.setCursor(busy, open: false) }
        model.open()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        shot("slide-over-light")
        shot("slide-over-dark", dark: true)
        model.toggleReaderWide()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        shot("slide-over-wide-light")
        model.back()
        model.prefs.readerOverlay = overlay
        if let cursor { model.setCursor(cursor, open: false) }

        model.searchText = "invoice"
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        shot("search-light")
        model.endSearch(restoreFocus: true)

        let wasExpanded = model.prefs.moreExpanded
        if let account = model.accounts.first {
            model.setScope(.account(account.id))
            model.prefs.moreExpanded = true
            shot("one-account-light")
            shot("one-account-dark", dark: true)
            model.prefs.moreExpanded = wasExpanded
            model.setScope(.all)
        }

        model.showsShortcuts = true
        shot("shortcuts-light")
        model.showsShortcuts = false
        model.chordHUD = "g"
        shot("chord-light")
        model.chordHUD = nil

        model.prefs.sidebarOpen = true
        shot("sidebar-open-light")
        shot("sidebar-open-dark", dark: true)
        // The Archive mailbox, a row hovered: Move to Inbox stands where Archive does elsewhere.
        model.show(.archive)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        list?.setHovered(2)
        shot("archive-sidebar-light")
        shot("archive-sidebar-dark", dark: true)
        list?.setHovered(nil)
        model.show(.inbox)
        model.prefs.sidebarOpen = false
        draftShots(window, directory)

        // The search field revealed above the list, before typing: suggestions only.
        model.beginSearch()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        shot("search-open-light")
        shot("search-open-dark", dark: true)
        model.endSearch(restoreFocus: true)

        // A narrow window: tabs that don't fit move into `…`, rows take two lines.
        let size = window.contentView?.frame.size ?? MainWindow.defaultSize
        window.setContentSize(NSSize(width: 980, height: 700))
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        shot("narrow-light")
        shot("narrow-dark", dark: true)
        model.toggleReadingPane()
        // The reader's page lays out again at its new width before WebKit's snapshot of it is taken.
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        shot("narrow-pane-light")
        model.toggleReadingPane()
        window.setContentSize(size)

        settingsShots(window, directory)

        standalone(InboxZeroView(cleared: 23), size: NSSize(width: 452, height: 560), to: directory.appendingPathComponent("inbox-zero-light.png"), dark: false)
        standalone(InboxZeroView(cleared: 23), size: NSSize(width: 452, height: 560), to: directory.appendingPathComponent("inbox-zero-dark.png"), dark: true)
        standalone(OnboardingView(onFinish: {}, onDemo: {}).environment(model).environment(model.services),
                   size: NSSize(width: 640, height: 560), to: directory.appendingPathComponent("onboarding-light.png"), dark: false)
        standalone(OnboardingView(onFinish: {}, onDemo: {}).environment(model).environment(model.services),
                   size: NSSize(width: 640, height: 560), to: directory.appendingPathComponent("onboarding-dark.png"), dark: true)
        onboardingShots(directory)
        if let project = model.projects.first {
            let draft = ProjectDraft(
                id: project.id, name: project.name, colorIndex: project.colorIndex, icon: project.icon ?? "folder",
                rules: [.init(field: .fromDomain, value: "lumen.io")], isNew: false)
            for dark in [false, true] {
                standalone(ProjectEditor(draft: draft).environment(model), size: NSSize(width: 480, height: 520),
                           to: directory.appendingPathComponent("project-editor-\(dark ? "dark" : "light").png"), dark: dark)
            }
        }
        updateShots(directory)
    }

    func standalone<V: View>(_ view: V, size: NSSize, to url: URL, dark: Bool) {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color(Theme.bg)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        window.appearance = appearance
        for _ in 0..<4 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        }
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    private func makeWindow(palette: PaletteController) -> MainWindow {
        let root = MainView(palette: palette)
            .environment(model)
            .environment(model.services)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        let window = MainWindow(contentView: hosting)
        let width = ProcessInfo.processInfo.environment["TERN_SNAPSHOT_WIDTH"].flatMap(Double.init) ?? 1320
        window.setContentSize(NSSize(width: width, height: 840))
        return window
    }

    func render(_ window: MainWindow, appearance: NSAppearance.Name, to url: URL) {
        let appearance = NSAppearance(named: appearance)
        NSApp.appearance = appearance
        window.appearance = appearance
        settle(window)
        guard let frameView = window.contentView?.superview else { return }
        let bounds = frameView.bounds
        guard let bitmap = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        withPageStandIn(window) { frameView.cacheDisplay(in: bounds, to: bitmap) }
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Lets SwiftUI and the table finish layout and the async observations deliver.
    func settle(_ window: MainWindow) {
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.placeTrafficLights()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// j/k cost: model update + table refresh + a full redraw of the window, averaged over 100 steps.
    private func measureKeyboard(_ window: MainWindow) {
        settle(window)
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        var model = 0.0, draw = 0.0
        let steps = 100
        for step in 0..<steps {
            let start = DispatchTime.now().uptimeNanoseconds
            self.model.moveCursor(step < steps / 2 ? 1 : -1)
            let moved = DispatchTime.now().uptimeNanoseconds
            view.layoutSubtreeIfNeeded()
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let drawn = DispatchTime.now().uptimeNanoseconds
            model += Double(moved - start) / 1_000_000
            draw += Double(drawn - moved) / 1_000_000
        }
        print(String(format: "j/k: %.2f ms model+list per step, %.2f ms full-window layout+render per step (%d steps)",
                     model / Double(steps), draw / Double(steps), steps))
        self.model.moveToTop()
    }
}
