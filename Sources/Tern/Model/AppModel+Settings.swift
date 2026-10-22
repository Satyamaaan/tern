import AppKit

/// Where the keyboard was when the settings page (or the palette) opened.
struct SettingsReturn {
    enum Place { case list, reader, search }

    var place = Place.list
    /// The text view or field that was being typed in (an inline reply, the find bar), to take the keyboard
    /// back if it is still there.
    weak var text: NSView?
}

// The settings page covers the mail the way an open thread covers the list. Nothing underneath changes
// while it is open (tab, selection, scroll, the open thread), so closing it is mostly taking it away and
// giving the keyboard back; only Layout can change how the open thread shows, and closing settles that.
extension AppModel {
    var settingsOpen: Bool { settings != nil }

    /// The section the page opens at when none is asked for: the one shown last.
    var lastSettingsSection: SettingsSection { SettingsSection(rawValue: prefs.settingsSection) ?? .accounts }

    /// Shows the page at `section` (else the last one), or moves an open page to it. Opened from the palette (its
    /// Settings command, or ⌘, while it shows), the keyboard goes back where it was before the palette opened.
    func openSettings(_ section: SettingsSection? = nil, updater: Updater? = nil) {
        if let settings {
            if let section { settings.show(section) }
            return
        }
        settingsReturn = paletteReturn ?? keyboardPlace()
        paletteReturn = nil
        palette = nil
        showsShortcuts = false
        chordPending = nil
        chordHUD = nil
        markReadTimer?.invalidate()
        if searchFieldFocused { searchFieldFocused = false }
        let section = section ?? lastSettingsSection
        prefs.settingsSection = section.rawValue
        settings = SettingsState(model: self, section: section, updater: updater)
    }

    /// Esc, ⌘[, the back button or ⌘, again: the mail as it was, with the keyboard where it was. If the
    /// reading pane changed meanwhile, a thread open over the list stays open (beside it with the pane), and
    /// the keyboard goes to the list when the thread it was in is no longer on screen.
    func closeSettings() {
        guard let page = settings else { return }
        page.commitEdits()
        settings = nil
        let saved = settingsReturn
        settingsReturn = SettingsReturn()
        let readerOpen = services.reader.isActive && readerKey != nil
        if readerExpanded && (!listOnly || !readerOpen) { readerExpanded = false }
        switch saved.place {
        case .search: searchFieldFocused = true
        case .reader where readerOpen && readerVisible:
            focus = .reader
            if let text = saved.text, text.window != nil, !text.isHiddenOrHasHiddenAncestor, text.window?.makeFirstResponder(text) == true {
                return
            }
            services.reader.focus()
        case .reader, .list: focusList()
        }
    }

    /// The app is quitting: saves a settings edit not yet committed, then waits for the writes queued so far (at
    /// most `timeout` seconds) so they reach the database before the process ends.
    func prepareToQuit(timeout: TimeInterval = 1) {
        settings?.commitEdits()
        let done = DispatchSemaphore(value: 0)
        writes.async { done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }

    /// Where the keyboard is now: the search pill, a text view in the mail (an inline reply, the find bar), the open
    /// thread or the list.
    func keyboardPlace() -> SettingsReturn {
        let text = searchFieldFocused ? nil : Self.textView(in: listView?.window)
        let place: SettingsReturn.Place = searchFieldFocused ? .search
            : (focus == .reader || text != nil) && services.reader.isActive ? .reader : .list
        return SettingsReturn(place: place, text: text)
    }

    /// The text view typing goes to in `window`; for a text field, the field rather than its field editor.
    static func textView(in window: NSWindow?) -> NSView? {
        guard let text = KeyRouter.textInput(in: window) else { return nil }
        return text.isFieldEditor ? text.delegate as? NSView : text
    }
}
