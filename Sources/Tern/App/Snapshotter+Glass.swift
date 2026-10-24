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
        window.hasShadow = false
        window.contentView = NSHostingView(rootView: GlassControlsPreview())
        both("controls")
        print("Glass snapshots written to \(directory.path); \(failures) failures")
        return failures == 0
    }
}

/// A fixture for the shared controls, including states that mail screenshots do not exercise.
private struct GlassControlsPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Controls").font(.display(23))
            ForEach([true, false], id: \.self) { enabled in
                VStack(alignment: .leading, spacing: 12) {
                    Text(enabled ? "Enabled" : "Disabled").font(.ui(13, .medium))
                    HStack(spacing: 12) {
                        Button("New message") {}.buttonStyle(TernButtonStyle(.primary))
                        Button("Add account") {}.buttonStyle(TernButtonStyle(.secondary))
                        Button("Cancel") {}.buttonStyle(TernButtonStyle(.quiet))
                        IconButton(icon: .settings, help: "Settings") {}
                    }
                    .disabled(!enabled)
                }
            }
            HStack(spacing: 12) {
                Button { } label: {
                    Text("Row button").font(.ui(13)).padding(8)
                }
                .buttonStyle(PressFillStyle(radius: 12))
                Button { } label: {
                    Text("Unavailable").font(.ui(13)).padding(8)
                }
                .buttonStyle(PressFillStyle(radius: 12))
                .disabled(true)
            }
            VStack(spacing: 4) {
                ForEach([false, true], id: \.self) { tracking in
                    SidebarRow(title: tracking ? "Menu tracking" : "Project at rest", count: 12, selected: false,
                               trailing: AnyView(IconButton(icon: .ellipsis, size: 24, help: "Project options") {}),
                               menuOpen: tracking) {
                        IconView(icon: .folder, size: 16)
                    } action: { }
                }
            }
            .frame(width: 260)
            VStack(alignment: .leading, spacing: 12) {
                Text("Control wash states").font(.ui(13, .medium))
                HStack(spacing: 12) {
                    wash("Rest", hovering: false, pressed: false)
                    wash("Hover", hovering: true, pressed: false)
                    wash("Pressed", hovering: true, pressed: true)
                }
            }
            Text("Mail rows and editor content remain opaque.")
                .font(.ui(12)).foregroundStyle(Color(Theme.text2))
        }
        .foregroundStyle(Color(Theme.text1))
        .padding(32)
        .glassSurface(radius: 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func wash(_ title: String, hovering: Bool, pressed: Bool) -> some View {
        Text(title)
            .font(.ui(13, .medium))
            .frame(width: 100, height: 28)
            .background(GlassControlFill(hovering: hovering, pressed: pressed))
    }
}
