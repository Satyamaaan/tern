import AppKit
import SwiftUI
import TernCore

// The settings page in the main window: every section in light and dark, with the sidebar open behind it, a
// narrow window, search, the Google client editor, each AI provider, Advanced as release builds show it, and a
// shortcut mid-recording, in conflict and reserved. Preferences the shots change are put back at the end.
extension Snapshotter {
    func settingsShots(_ window: MainWindow, _ directory: URL) {
        func shot(_ name: String, dark: Bool = false) {
            render(window, appearance: dark ? .darkAqua : .aqua, to: directory.appendingPathComponent("\(name).png"))
        }
        func both(_ name: String) {
            shot("\(name)-light")
            shot("\(name)-dark", dark: true)
        }
        let services = model.services
        let prefs = model.prefs
        let saved = (sidebar: prefs.sidebarOpen, section: prefs.settingsSection, pinned: prefs.pinnedTabs)
        let googleClientId = services.googleClientId
        let availability = services.aiAvailability
        services.googleClientId = { "1234567890-abcdefghijklmnop.apps.googleusercontent.com" }
        services.aiAvailability = Self.fakeAvailability(claude: .ready, codex: .signedOut)
        // Rows for the lists: two pinned tabs and a sender whose images load.
        prefs.pinnedTabs = model.projects.prefix(2).compactMap { ListTab.project($0.id).pinKey } + ["search:invoice"]
        try? model.store.setImagesAllowed(true, sender: "news@figma.com")
        try? model.store.setImagesAllowed(true, sender: "receipts@stripe.com")

        prefs.sidebarOpen = false
        model.openSettings(.accounts)
        guard let settings = model.settings else { return }
        for section in SettingsSection.allCases {
            settings.show(section)
            both("settings-\(section.rawValue)")
        }

        // The mail sidebar open behind the page changes nothing.
        settings.show(.mail)
        settle(window)
        prefs.sidebarOpen = true
        both("settings-sidebar-open")
        prefs.sidebarOpen = false

        // Search across sections.
        settings.query = "undo"
        both("settings-search")
        settings.query = "zzz"
        shot("settings-search-empty-light")
        settings.query = ""

        // Accounts with the Google client editor open.
        model.closeSettings()
        model.openSettings(.accounts)
        model.settings?.editsGoogleClient = true
        shot("settings-google-edit-light")
        model.closeSettings()
        model.openSettings(.ai)
        guard let settings = model.settings else { return }
        for provider in [AIProvider.claude, .codex, .off] {
            settings.provider = provider
            both("settings-ai-\(provider.rawValue)")
        }
        model.closeSettings()

        // Advanced as release builds show it.
        model.openSettings(.advanced, updater: Updater.preview())
        both("settings-advanced-release")
        model.closeSettings()

        // Shortcuts: recording, a key another command has, a reserved key, and an edited row.
        model.openSettings(.shortcuts)
        guard let settings = model.settings, let registry = model.registry else { return }
        let overrides = registry.overrides
        settings.startRecording("archive", slot: 0)
        both("settings-shortcut-recording")
        settings.record(Self.key("R", keyCode: 15, modifiers: .shift))
        both("settings-shortcut-conflict")
        settings.record(Self.key("q", keyCode: 12, modifiers: .command))
        shot("settings-shortcut-reserved-light")
        settings.cancelRecording()
        registry.assign(.key("y"), to: "archive", replacing: 0)
        registry.assign(.command("j", shift: true), to: "go.inbox", replacing: nil)
        settings.shortcutFilter = "arch"
        shot("settings-shortcut-edited-light")
        settings.shortcutFilter = "inbox"
        shot("settings-shortcut-added-light")
        settings.shortcutFilter = ""
        registry.resetAllKeys()
        if !overrides.isEmpty { registry.restore(overrides) }

        // A narrow window: the column gives way, nothing clips.
        let size = window.contentView?.frame.size ?? MainWindow.defaultSize
        window.setContentSize(NSSize(width: 980, height: 700))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        settings.show(.mail)
        both("settings-narrow")
        settings.show(.shortcuts)
        shot("settings-narrow-shortcuts-light")
        settings.show(.layout)
        settle(window)
        prefs.sidebarOpen = true
        shot("settings-narrow-sidebar-light")
        window.setContentSize(size)

        model.closeSettings()
        prefs.sidebarOpen = saved.sidebar
        prefs.settingsSection = saved.section
        prefs.pinnedTabs = saved.pinned
        services.googleClientId = googleClientId
        services.aiAvailability = availability
    }

    /// A key press for the shortcut recorder.
    static func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters.lowercased(), isARepeat: false, keyCode: keyCode)!
    }
}
