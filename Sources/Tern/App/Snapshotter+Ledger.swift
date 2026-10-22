import AppKit
import TernCore

extension Snapshotter {
    /// Renders follow-ups through the normal list and sidebar against the fake database.
    func ledgerShots(_ window: MainWindow, _ directory: URL) {
        let oldKind = model.kind
        let sidebar = model.prefs.sidebarOpen
        let pane = model.prefs.readingPane
        model.prefs.readingPane = false
        model.prefs.sidebarOpen = true
        model.show(.waitingOn)
        model.reloadList()
        render(window, appearance: .aqua, to: directory.appendingPathComponent("waiting-on-light.png"))
        model.show(.iOwe)
        model.reloadList()
        render(window, appearance: .aqua, to: directory.appendingPathComponent("i-owe-light.png"))
        model.show(.inbox)
        render(window, appearance: .aqua, to: directory.appendingPathComponent("waiting-sidebar-light.png"))
        model.show(oldKind)
        model.prefs.sidebarOpen = sidebar
        model.prefs.readingPane = pane
    }
}
