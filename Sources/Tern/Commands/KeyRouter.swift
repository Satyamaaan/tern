import AppKit
import WebKit

/// Keyboard handling for the main window. A local event monitor sees every key first, and a key it handles
/// goes no further:
/// - while a shortcut is being recorded in Settings, every key goes to the recorder;
/// - while text is being typed, keys take their normal way to the text view (input methods and Press and
///   Hold included); the menu bar never fires a bare key (`BareKeySafeMenu`), nor the ⌘ and ⌃ keys of
///   commands that act on mail (`CommandRegistry.leavesToText`);
/// - while the palette is open, navigation keys drive it;
/// - while the settings page is open, Esc, ⌘[ and the arrows drive it, and nothing reaches the mail;
/// - while the open conversation has the keyboard, the keys of the commands it answers itself (Next and
///   Previous Message, Open, Quick Look) go to the page, which runs them by name;
/// - otherwise bare keys and `g` chords run registry commands. ⌘ shortcuts are left to the menu bar.
@MainActor
final class KeyRouter {
    private let registry: CommandRegistry
    private var model: AppModel { registry.model }
    private var monitor: Any?
    private var bare: [(KeyShortcut, Command)] = []
    /// Keys the conversation page answers itself while it has the keyboard.
    private var pageKeys: [KeyShortcut] = []
    private var chords: [String: Command] = [:]
    private var chordTimer: Timer?
    /// Shows the chord's hint after a hesitation.
    private var hudTimer: Timer?
    weak var mainWindow: NSWindow?
    /// Palette key handling, installed by the palette view while it is open.
    var paletteKeys: ((PaletteKey) -> Bool)?

    enum PaletteKey { case up, down, run, runOnSelection, close }

    init(registry: CommandRegistry) {
        self.registry = registry
        rebuild()
        NotificationCenter.default.addObserver(forName: CommandRegistry.shortcutsDidChange, object: registry, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    /// Reads the keys from the registry again: bare keys, the ⌘ keys no menu item fires, the reader page's
    /// keys and the chords.
    func rebuild() {
        bare = []
        chords = [:]
        pageKeys = Self.pageActions(registry).map(\.0)
        for command in registry.commands {
            for key in command.keys where key.isBare || Self.routesOutsideMenus(command, key) { bare.append((key, command)) }
            if let chord = command.chord { chords[chord] = command }
        }
        // Outside text fields ⌘Z undoes the last mail action; while typing, Edit ▸ Undo undoes the typing.
        if let undo = registry["undo"] { bare.append((.command("z"), undo)) }
    }

    /// ⌘ shortcuts that mean something different outside text fields (⌘A, ⌘\), and those no menu item
    /// fires: a command that isn't in the menu bar, or a command's second ⌘ key.
    private static func routesOutsideMenus(_ command: Command, _ key: KeyShortcut) -> Bool {
        command.menu == nil || command.paletteOnly || command.id == "readingPane" || key != command.menuKey
    }

    func install() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                // nil from `handle` means the key was handled: AppKit must not deliver it again.
                guard let self else { return event }
                return self.handle(event)
            }
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    // MARK: Routing

    func handle(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(KeyShortcut.relevantModifiers)
        let hasCommand = flags.contains(.command) || flags.contains(.control)

        if event.window === mainWindow, let settings = model.settings, settings.recording != nil {
            settings.record(event)
            return nil
        }

        // Typing anywhere in the app: keys belong to the text, never to list commands, and ⌘ keys keep their
        // text meaning (⌘A selects the query, ⌘Z undoes typing).
        if Self.textInput(in: event.window) != nil {
            if event.window === mainWindow, handleWhileTyping(event) { return nil }
            return event
        }
        guard event.window === mainWindow, event.window?.attachedSheet == nil else { return event }
        if let settings = model.settings, model.palette == nil, settings.handleKey(event, registry: registry) { return nil }
        if model.services.isComposing && !hasCommand && !model.settingsOpen { return event }

        if model.palette != nil, let palette = paletteKeys, let key = Self.paletteKey(event, flags), palette(key) { return nil }

        if chordTimer != nil { return finishChord(event) }

        if !hasCommand, flags.subtracting(.shift).isEmpty, event.characters == "g", !model.settingsOpen {
            startChord()
            return nil
        }

        // The conversation page has the keyboard: it moves between messages and answers Open and Quick Look
        // on a focused link, attachment or quote itself, with whatever keys those commands have now.
        if !hasCommand, pageKeys.contains(where: { $0.matches(event) }), Self.readerHasKeyboard(event.window) {
            return event
        }

        // A key can belong to a list command and a reader command (`p`); the one that can run here wins.
        let matches = bare.filter { $0.0.matches(event) && !($0.1.yieldsToReader && model.focus == .reader) }
        guard let (shortcut, first) = matches.first else { return event }
        guard model.palette == nil || first.id == "back" else { return event }
        if let command = matches.map(\.1).first(where: registry.canRun) {
            command.run()
            return nil
        }
        // Space activates a focused settings control when its mail command cannot run here.
        if model.settingsOpen, shortcut.key == .space { return event }
        // A disabled Tab or ⌘ shortcut keeps its normal meaning; a disabled letter is just ignored.
        return shortcut.key == .tab || !shortcut.isBare ? event : nil
    }

    /// Keys the search pill and palette field handle themselves.
    private func handleWhileTyping(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(KeyShortcut.relevantModifiers)
        if model.palette != nil, let palette = paletteKeys, let key = Self.paletteKey(event, flags) {
            return palette(key)
        }
        if let settings = model.settings, settings.handleKeyWhileTyping(event) { return true }
        if model.searchFieldFocused {
            switch event.keyCode {
            case 53:
                if !model.dismissSuggestions() { model.endSearch(restoreFocus: true) }
                return true
            case 125:
                if !model.moveSuggestion(1) { model.focusResults(open: false) }
                return true
            case 126:
                return model.moveSuggestion(-1)
            case 48 where flags.isEmpty:
                return model.completeSuggestion()
            case 36, 76:
                model.submitSearch()
                return true
            default:
                return false
            }
        }
        return false
    }

    private static func paletteKey(_ event: NSEvent, _ flags: NSEvent.ModifierFlags) -> PaletteKey? {
        switch event.keyCode {
        case 126: return .up
        case 125: return .down
        case 36, 76: return flags.contains(.command) ? .runOnSelection : .run
        case 53: return .close
        default: break
        }
        if flags == .control, let c = event.charactersIgnoringModifiers {
            if c == "p" { return .up }
            if c == "n" { return .down }
        }
        return nil
    }

    // MARK: Chords

    /// Starts a `g` chord. Its hint shows only if the second key doesn't follow within `Motion.hesitation`,
    /// so fluent typing never flashes it, and stays up for `Motion.chordHint` before the chord gives up.
    private func startChord() {
        model.chordPending = "g"
        chordTimer = Timer.scheduledTimer(withTimeInterval: Motion.hesitation + Motion.chordHint, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelChord() }
        }
        hudTimer = Timer.scheduledTimer(withTimeInterval: Motion.hesitation, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let model = self?.model, let chord = model.chordPending else { return }
                model.chordHUD = chord
            }
        }
    }

    private func finishChord(_ event: NSEvent) -> NSEvent? {
        let key = event.characters ?? ""
        cancelChord()
        if let command = chords["g \(key)"], registry.canRun(command) { command.run() }
        return nil
    }

    private func cancelChord() {
        chordTimer?.invalidate()
        chordTimer = nil
        hudTimer?.invalidate()
        hudTimer = nil
        model.chordPending = nil
        model.chordHUD = nil
    }

    // MARK: The reader

    /// The commands the reader page runs itself, by the action name it knows them by.
    private static let pageCommands: [(id: String, action: String)] = [
        ("nextMessage", "next"), ("previousMessage", "previous"), ("open", "open"), ("quickLook", "quicklook"),
    ]

    /// The current keys of the commands the page runs itself, with the page's action for each. Only keys
    /// the page sees as typed (no ⌘, ⌃ or ⌥); a page command with another key runs through the registry.
    static func pageActions(_ registry: CommandRegistry) -> [(KeyShortcut, String)] {
        pageCommands.flatMap { entry in
            (registry[entry.id]?.keys ?? []).filter { $0.pageKeyName != nil }.map { ($0, entry.action) }
        }
    }

    /// `pageActions` as the page reads them: `event.key` name → action ("n": "next", "Enter": "open").
    static func pageKeyMap(_ registry: CommandRegistry) -> [String: String] {
        pageActions(registry).reduce(into: [:]) { map, entry in
            if let name = entry.0.pageKeyName, map[name] == nil { map[name] = entry.1 }
        }
    }

    /// Whether the reader's web view (or something inside it) is the first responder.
    static func readerHasKeyboard(_ window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: ReaderWebEngine.shared.webView)
    }

    // MARK: Text input

    /// The text view receiving typing in the window, if any (field editors included).
    static func textInput(in window: NSWindow?) -> NSTextView? {
        guard let responder = window?.firstResponder as? NSTextView, responder.isEditable else { return nil }
        // A field editor left behind by a text field that has gone (the closed palette) isn't typing.
        if responder.isFieldEditor, let field = responder.delegate as? NSView, field.window == nil { return nil }
        return responder
    }
}
