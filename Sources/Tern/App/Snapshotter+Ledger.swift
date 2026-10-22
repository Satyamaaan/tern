import AppKit
import SwiftUI
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
        let demoKey = model.snapshot.order.first
        model.show(.iOwe)
        model.reloadList()
        render(window, appearance: .aqua, to: directory.appendingPathComponent("i-owe-light.png"))
        if let key = model.snapshot.order.first ?? demoKey,
           let detail = try? model.store.threadDetail(key),
           let person = detail.messages.flatMap({ [Participant(name: $0.fromName, email: $0.fromEmail)] + $0.toList }).first(where: { person in !model.accounts.contains { $0.email.lowercased() == person.email.lowercased() } }),
           let undo = try? model.store.trackCommitment(on: key, direction: .iOwe, deliverable: "Send revised launch deck", counterparty: person, dueAt: Date().addingTimeInterval(2 * 86_400)) {
            model.show(.iOwe)
            model.reloadList()
            render(window, appearance: .aqua, to: directory.appendingPathComponent("i-owe-light.png"))
            model.setCursor(key, open: true)
            model.focus = .list
            model.open()
            settle(window)
            render(window, appearance: .aqua, to: directory.appendingPathComponent("reader-commitment-light.png"))
            if let reader = model.services.reader.model { stripShot(reader, to: directory.appendingPathComponent("strip-collapsed-light.png")) }
            model.services.reader.model?.commitmentEvidence = true
            render(window, appearance: .aqua, to: directory.appendingPathComponent("reader-evidence-light.png"))
            if let reader = model.services.reader.model { stripShot(reader, to: directory.appendingPathComponent("strip-evidence-light.png")) }
            _ = try? model.store.setCommitmentState(undo.created, to: .done)
            model.back()
            model.searchText = "is:done"
            settle(window)
            model.setCursor(key, open: true)
            model.focus = .list
            model.open()
            render(window, appearance: .aqua, to: directory.appendingPathComponent("done-light.png"))
            model.back()
            model.endSearch(restoreFocus: false)
            try? model.store.restoreCommitments(undo)
        }
        model.show(.inbox)
        render(window, appearance: .aqua, to: directory.appendingPathComponent("waiting-sidebar-light.png"))
        model.show(oldKind)
        model.prefs.sidebarOpen = sidebar
        model.prefs.readingPane = pane
    }
    private func stripShot(_ reader: ReaderModel, to url: URL) {
        let hosting = NSHostingView(rootView: ReaderCommitmentStrip(model: reader).environment(model)
            .padding(20).frame(width: 784).fixedSize(horizontal: false, vertical: true)
            .background(Color(Theme.bg)).preferredColorScheme(.light))
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        for _ in 0..<3 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

}
