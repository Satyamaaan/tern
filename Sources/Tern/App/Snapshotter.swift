import AppKit
import SwiftUI
import TernCore

/// `--snapshot <dir>`: renders the main window offscreen at 1320×840 (light, dark, and light with the
/// ⌘K palette open) into PNGs, prints speed measurements, and quits. Nothing is shown on screen.
@MainActor
struct Snapshotter {
    let model: AppModel
    let registry: CommandRegistry

    func run(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let palette = PaletteController(model: model, registry: registry)
        let window = makeWindow(palette: palette)

        if ProcessInfo.processInfo.environment["TERN_SNAPSHOT_WIDTH"].flatMap(Double.init) == nil {
            measureKeyboard(window)
        }

        render(window, appearance: .aqua, to: directory.appendingPathComponent("main-light.png"))
        render(window, appearance: .darkAqua, to: directory.appendingPathComponent("main-dark.png"))
        model.palette = .commands
        render(window, appearance: .aqua, to: directory.appendingPathComponent("palette-light.png"))
        render(window, appearance: .darkAqua, to: directory.appendingPathComponent("palette-dark.png"))
        model.palette = nil
        print("Snapshots written to \(directory.path)")
        exit(0)
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

    private func render(_ window: MainWindow, appearance: NSAppearance.Name, to url: URL) {
        let appearance = NSAppearance(named: appearance)
        NSApp.appearance = appearance
        window.appearance = appearance
        settle(window)
        guard let frameView = window.contentView?.superview else { return }
        let bounds = frameView.bounds
        guard let bitmap = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        frameView.cacheDisplay(in: bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Lets SwiftUI and the table finish layout and the async observations deliver.
    private func settle(_ window: MainWindow) {
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
