import AppKit
import SwiftUI
import TernCore

extension Snapshotter {
    /// Gmail's tabs: the window on Primary and on Promotions (its unread count in the title bar), the title bar
    /// alone for each, ⌘K offering Move to … for a Promotions thread, and one account's tabs, in light and dark.
    func tabShots(_ window: MainWindow, _ directory: URL) {
        let splitInbox = model.prefs.splitInbox
        defer { if model.prefs.splitInbox != splitInbox { model.setSplitInbox(splitInbox) } }
        if !splitInbox { model.setSplitInbox(true) }
        for tab in [InboxTab.primary, .promotions] {
            model.showInboxTab(tab)
            for dark in [false, true] {
                let name = "tabs-\(tab.rawValue)-\(dark ? "dark" : "light")"
                render(window, appearance: dark ? .darkAqua : .aqua, to: directory.appendingPathComponent("\(name).png"))
                renderTitleBar(window, to: directory.appendingPathComponent("\(name)-bar.png"))
            }
        }
        // Still on Promotions, with its first thread under the cursor.
        for dark in [false, true] {
            paletteShot("move to", to: directory.appendingPathComponent("tabs-move-palette-\(dark ? "dark" : "light").png"), dark: dark)
        }
        model.showInboxTab(.primary)
        // The last account alone: in the demo mailbox, Kiteworks has no Gmail categories, so no Social or Forums.
        if let account = model.accounts.last {
            model.setScope(.account(account.id))
            for dark in [false, true] {
                render(window, appearance: dark ? .darkAqua : .aqua, to: directory.appendingPathComponent("tabs-one-account-\(dark ? "dark" : "light").png"))
                renderTitleBar(window, to: directory.appendingPathComponent("tabs-one-account-\(dark ? "dark" : "light")-bar.png"))
            }
            model.setScope(.all)
        }
    }

    /// The title bar strip of the last appearance rendered.
    private func renderTitleBar(_ window: MainWindow, to url: URL) {
        guard let frameView = window.contentView?.superview,
              let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        withPageStandIn(window) { frameView.cacheDisplay(in: frameView.bounds, to: bitmap) }
        let scale = CGFloat(bitmap.pixelsHigh) / frameView.bounds.height
        let strip = CGRect(x: 0, y: 0, width: CGFloat(bitmap.pixelsWide), height: MainWindow.headerHeight * scale)
        guard let image = bitmap.cgImage?.cropping(to: strip) else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    /// The ⌘K palette alone with `query` typed, cut after its first group. Offscreen, its lazy list keeps the
    /// rows it built first, so they are built with the query in, the query goes back in after the palette's
    /// open-time reset, and rows past the first group (built while the query was empty) are left out.
    private func paletteShot(_ query: String, to url: URL, dark: Bool) {
        let controller = PaletteController(model: model, registry: registry)
        controller.query = query
        let rows = controller.sections.first?.items.count ?? 0
        let size = NSSize(width: 680, height: 20 + 52 + 1 + 34 + CGFloat(rows) * 34 + 14)
        let view = PaletteView(controller: controller).environment(model).environment(model.services)
            .padding(20)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color(Theme.bg))
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        window.appearance = appearance
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        controller.query = query
        for _ in 0..<4 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
