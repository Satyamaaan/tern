import AppKit
import SwiftUI

extension Snapshotter {
    /// Live compositor captures use a synthetic desktop, never the user's windows, behind the glass.
    /// Run only with a disposable fake database. Live mode briefly activates the fixture; it sends no input.
    func glassShots(_ window: MainWindow, _ directory: URL) -> Bool {
        guard model.isFake else {
            print("Glass snapshots require --fake")
            return false
        }
        var failures = 0
        let live = ProcessInfo.processInfo.environment["TERN_SNAPSHOT_LIVE"] == "1"
        let backdrop = NSWindow(contentRect: window.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        backdrop.ignoresMouseEvents = true
        backdrop.contentView = NSHostingView(rootView:
            LinearGradient(colors: [Color(red: 0.22, green: 0.36, blue: 0.52),
                                    Color(red: 0.55, green: 0.36, blue: 0.36),
                                    Color(red: 0.28, green: 0.42, blue: 0.38)],
                           startPoint: .topLeading, endPoint: .bottomTrailing))
        defer {
            window.orderOut(nil)
            backdrop.orderOut(nil)
        }
        showForWebKit(window)
        if live {
            backdrop.setFrame(window.frame, display: true)
            backdrop.orderFrontRegardless()
            window.alphaValue = 1
            window.level = .floating
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }

        func both(_ name: String) {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let url = directory.appendingPathComponent("\(name)-\(suffix).png")
                try? FileManager.default.removeItem(at: url)
                if live {
                    NSApp.appearance = NSAppearance(named: appearance)
                    window.appearance = NSApp.appearance
                    settle(window)
                    window.orderFrontRegardless()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    // Isolated window captures omit behind-window materials. Capture the visible region instead.
                    let rect = window.frame
                    let screenHeight = NSScreen.screens.first?.frame.height ?? rect.maxY
                    let region = "\(Int(rect.minX)),\(Int(screenHeight - rect.maxY)),\(Int(rect.width)),\(Int(rect.height))"
                    capture.arguments = ["-x", "-R", region, url.path]
                    do {
                        try capture.run()
                        capture.waitUntilExit()
                        print("Live capture \(name)-\(suffix): \(capture.terminationStatus)")
                        if capture.terminationStatus != 0 { failures += 1 }
                    } catch {
                        print("Live capture failed: \(error)")
                        failures += 1
                    }
                } else {
                    render(window, appearance: appearance, to: url)
                }
                if !FileManager.default.fileExists(atPath: url.path) { failures += 1 }
            }
        }

        model.prefs.sidebarOpen = true
        model.prefs.readingPane = false
        model.show(.inbox)
        model.back()
        both("inbox")
        model.palette = .commands
        both("palette")
        model.palette = nil
        if let thread = model.snapshot.order.first {
            model.select(thread)
            model.open()
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            both("reader")
            model.services.reader.reply(all: false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            both("composer")
            model.services.reader.model?.composing = nil
            model.back()
        } else {
            print("Glass snapshots require a populated fake inbox")
            failures += 1
        }
        model.openSettings(.appearance)
        both("settings")
        model.closeSettings()
        window.setContentSize(NSSize(width: 980, height: 700))
        backdrop.setFrame(window.frame, display: true)
        both("narrow")
        print("Glass snapshots written to \(directory.path); \(failures) failures")
        return failures == 0
    }
}
