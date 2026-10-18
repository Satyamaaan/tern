import Foundation

/// Where the keyboard was when the settings page opened.
enum SettingsReturn { case list, reader, search }

// The settings page covers the mail the way an open thread covers the list. Nothing underneath changes
// while it is open (tab, selection, scroll, the open thread), so closing it is just taking it away and
// giving the keyboard back.
extension AppModel {
    var settingsOpen: Bool { settings != nil }

    /// The section the page opens at when none is asked for: the one shown last.
    var lastSettingsSection: SettingsSection { SettingsSection(rawValue: prefs.settingsSection) ?? .accounts }

    /// Shows the page at `section` (else the last one), or moves an open page to it.
    func openSettings(_ section: SettingsSection? = nil, updater: Updater? = nil) {
        if let settings {
            if let section { settings.show(section) }
            return
        }
        palette = nil
        showsShortcuts = false
        chordHUD = nil
        markReadTimer?.invalidate()
        settingsReturn = searchFieldFocused ? .search : focus == .reader && services.reader.isActive ? .reader : .list
        if searchFieldFocused { searchFieldFocused = false }
        let section = section ?? lastSettingsSection
        prefs.settingsSection = section.rawValue
        settings = SettingsState(model: self, section: section, updater: updater)
    }

    /// Esc, ⌘[, the back button or ⌘, again: the mail as it was, with the keyboard where it was.
    func closeSettings() {
        guard settings != nil else { return }
        settings = nil
        switch settingsReturn {
        case .search: searchFieldFocused = true
        case .reader where services.reader.isActive:
            focus = .reader
            services.reader.focus()
        case .reader, .list: focusList()
        }
    }
}
