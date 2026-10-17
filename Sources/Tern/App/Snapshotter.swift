import AppKit
import SwiftUI
import TernCore

/// `--snapshot <dir>`: renders the main window at 1320×840 (light, dark, the ⌘K palette, the reader with
/// a thread, search, an inline reply, settings and onboarding) into PNGs, prints speed measurements,
/// and quits. WebKit only paints into a window on screen, so after the launch and j/k measurements the
/// window is ordered in at 1 % opacity and click-through, without activating the app: nothing shows.
@MainActor
struct Snapshotter {
    let model: AppModel
    let registry: CommandRegistry

    func run(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
        integrationShots(window, directory)
        if ProcessInfo.processInfo.environment["TERN_SNAPSHOT_EXTRAS"] == "1" { extras(window, directory) }
        print("Snapshots written to \(directory.path)")
        exit(0)
    }

    /// More states for visual review: hover + toast, the waterline, wide one-line rows, search, one
    /// account with labels, collapsed sidebar, inbox zero, settings, onboarding and the project editor.
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


        model.toggleListOnly()
        shot("wide-one-line-light")
        shot("wide-one-line-dark", dark: true)
        model.toggleListOnly()

        model.searchText = "invoice"
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        shot("search-light")
        model.endSearch(restoreFocus: true)

        let wasExpanded = model.prefs.moreExpanded
        if let account = model.accounts.first {
            model.setScope(.account(account.id))
            model.prefs.moreExpanded = true
            shot("one-account-light")
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            if let index = model.snapshot.items.firstIndex(where: { if case .waterline = $0 { true } else { false } }), let list {
                let rect = list.table.rect(ofRow: index)
                list.scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, rect.minY - 360)))
                list.scrollView.reflectScrolledClipView(list.scrollView.contentView)
                shot("waterline-light")
                shot("waterline-dark", dark: true)
                list.scrollView.contentView.scroll(to: .zero)
            }
            model.prefs.moreExpanded = wasExpanded
            model.setScope(.all)
        }

        model.showsShortcuts = true
        shot("shortcuts-light")
        model.showsShortcuts = false
        model.chordHUD = "g"
        shot("chord-light")
        model.chordHUD = nil

        model.prefs.sidebarCollapsed = true
        shot("sidebar-collapsed-light")
        model.prefs.sidebarCollapsed = false

        standalone(InboxZeroView(cleared: 23), size: NSSize(width: 452, height: 560), to: directory.appendingPathComponent("inbox-zero-light.png"), dark: false)
        standalone(InboxZeroView(cleared: 23), size: NSSize(width: 452, height: 560), to: directory.appendingPathComponent("inbox-zero-dark.png"), dark: true)
        let settings = SettingsState(model: model, shell: nil)
        for section in [SettingsSection.accounts, .ai, .appearance] {
            settings.section = section
            standalone(SettingsView(state: settings).environment(model).environment(model.services),
                       size: NSSize(width: 760, height: 540), to: directory.appendingPathComponent("settings-\(section.rawValue)-light.png"), dark: false)
        }
        standalone(OnboardingView(onFinish: {}, onDemo: {}).environment(model).environment(model.services),
                   size: NSSize(width: 640, height: 560), to: directory.appendingPathComponent("onboarding-light.png"), dark: false)
        standalone(OnboardingView(onFinish: {}, onDemo: {}).environment(model).environment(model.services),
                   size: NSSize(width: 640, height: 560), to: directory.appendingPathComponent("onboarding-dark.png"), dark: true)
        if let project = model.projects.first {
            let draft = ProjectDraft(
                id: project.id, name: project.name, colorIndex: project.colorIndex, icon: project.icon ?? "folder",
                rules: [.init(field: .fromDomain, value: "lumen.io")], isNew: false)
            for dark in [false, true] {
                standalone(ProjectEditor(draft: draft).environment(model), size: NSSize(width: 480, height: 520),
                           to: directory.appendingPathComponent("project-editor-\(dark ? "dark" : "light").png"), dark: dark)
            }
        }
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
