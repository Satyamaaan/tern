import AppKit
import SwiftUI

// The update card in each phase, the move-to-Applications prompt and Settings → Advanced, as release builds show
// them. Sparkle isn't involved: the cards are fed fixed phases.
extension Snapshotter {
    func updateShots(_ directory: URL) {
        let notes = ReleaseNotes(lines: [
            .bullet("Tern now updates itself. New versions download in the background and install the next time Tern restarts."),
            .bullet("A new install window: drag Tern to Applications."),
            .bullet("The open sidebar runs the full height of the window."),
        ])
        let long = ReleaseNotes(lines: [.heading("Reading")] + (1...6).map {
            .bullet("Change number \($0): a longer note that wraps onto a second line, so the list grows taller than the card allows.")
        } + [.paragraph("Thanks to everyone who sent feedback.")])
        let release = UpdateRelease(version: "0.2.1", notes: notes)
        let phases: [(String, UpdatePhase)] = [
            ("checking", .checking),
            ("available", .available(release)),
            ("downloading", .downloading(release, received: 7_400_000, expected: 12_900_000)),
            ("ready", .ready(release)),
            ("ready-long", .ready(UpdateRelease(version: "0.3.0", notes: long))),
            ("installing", .installing(release, waitingToQuit: false)),
            ("up-to-date", .upToDate),
            ("error", .failed("Couldn't reach the update server.")),
        ]
        for (name, phase) in phases {
            let model = UpdateCardModel(current: AppVersion(name: "0.2.0", build: "2"))
            model.phase = phase
            for dark in [false, true] {
                card(UpdateCard(model: model), to: directory.appendingPathComponent("update-\(name)-\(dark ? "dark" : "light").png"), dark: dark)
            }
        }

        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Tern.app")
        let prompts: [(String, MovePromptModel)] = [
            ("move-downloads", MovePromptModel(location: AppLocation(kind: .elsewhere, bundleURL: downloads))),
            ("move-disk-image", MovePromptModel(location: AppLocation(
                kind: .diskImage, bundleURL: URL(fileURLWithPath: "/Volumes/Tern/Tern.app"), volumeURL: URL(fileURLWithPath: "/Volumes/Tern")))),
        ]
        for (name, model) in prompts {
            for dark in [false, true] {
                card(MovePromptCard(model: model), to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"), dark: dark)
            }
        }

        let settings = SettingsState(model: model, shell: nil)
        settings.section = .advanced
        standalone(SettingsView(state: settings).environment(model).environment(model.services), size: NSSize(width: 760, height: 540),
                   to: directory.appendingPathComponent("settings-advanced-dev-light.png"), dark: false)
        settings.updater = Updater.preview()
        for dark in [false, true] {
            standalone(SettingsView(state: settings).environment(model).environment(model.services), size: NSSize(width: 760, height: 540),
                       to: directory.appendingPathComponent("settings-advanced-\(dark ? "dark" : "light").png"), dark: dark)
        }
    }

    /// A card as `CardPanel` floats it, with room for its shadow, over the window background.
    private func card<V: View>(_ card: V, to url: URL, dark: Bool) {
        let margin = CardPanel.margin
        let hosting = NSHostingView(rootView: card
            .padding(EdgeInsets(top: margin.top, leading: margin.left, bottom: margin.bottom, trailing: margin.right))
            .fixedSize()
            .background(Color(Theme.bg)))
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        hosting.appearance = appearance
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
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
