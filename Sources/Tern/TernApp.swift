import AppKit

/// Entry point. The app is AppKit-managed (our own main window, menus and key handling) with SwiftUI
/// views inside; see `AppDelegate`.
@main
@MainActor
enum TernApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Offscreen snapshots never show a Dock icon or take focus.
        app.setActivationPolicy(CommandLine.arguments.contains("--snapshot") ? .prohibited : .regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
