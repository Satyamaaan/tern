import AppKit
import WebKit

/// Keyboard handling for the main window. A local event monitor sees every key first:
/// - while a shortcut is being recorded in Settings, every key goes to the recorder;
/// - while text is being typed, bare keys go straight to the text view (menus never see them);
/// - while the palette is open, navigation keys drive it;
/// - while the settings page is open, Esc, ⌘[ and the arrows drive it, and nothing reaches the mail;
/// - otherwise bare keys and `g` chords run registry commands. ⌘ shortcuts are left to the menu bar.
@MainActor
final class KeyRouter {
    private let registry: CommandRegistry
    private var model: AppModel { registry.model }
    private var monitor: Any?
    private var bare: [(KeyShortcut, Command)] = []
    private var chords: [String: Command] = [:]
    private var chordTimer: Timer?
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

    /// Reads the keys from the registry again: bare keys, the ⌘ keys no menu item fires, and the chords.
    func rebuild() {
        bare = []
        chords = [:]
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
            MainActor.assumeIsolated { self?.handle(event) ?? event }
        }
    }

    // MARK: Routing

    func handle(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(KeyShortcut.relevantModifiers)
        let hasCommand = flags.contains(.command) || flags.contains(.control)

        if event.window === mainWindow, let settings = model.settings, settings.recording != nil {
            settings.record(event)
            return nil
        }

        // Typing anywhere in the app: plain keys belong to the text, never to menu shortcuts, and ⌘ keys
        // keep their text meaning (⌘A selects the query, ⌘Z undoes typing).
        if let text = Self.textInput(in: event.window) {
            if event.window === mainWindow, handleWhileTyping(event, in: text) { return nil }
            guard !hasCommand, Self.isPrintable(event) else { return event }
            text.keyDown(with: event)
            return nil
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

        // The conversation page has the keyboard: it moves between messages and answers Enter and Space
        // on a focused link, attachment or quote itself.
        if !hasCommand, Self.readerPageKeys.contains(where: { $0.matches(event) }), Self.readerHasKeyboard(event.window) {
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
        // A disabled Tab or ⌘ shortcut keeps its normal meaning; a disabled letter is just ignored.
        return shortcut.key == .tab || !shortcut.isBare ? event : nil
    }

    /// Keys the search pill and palette field handle themselves.
    private func handleWhileTyping(_ event: NSEvent, in text: NSTextView) -> Bool {
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

    private func startChord() {
        model.chordHUD = "g"
        chordTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelChord() }
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
        model.chordHUD = nil
    }

    // MARK: The reader

    private static let readerPageKeys: [KeyShortcut] = [
        .key("n"), .key("p"), .key("o"), .special(.returnKey), .special(.space),
    ]

    /// Whether the reader's web view (or something inside it) is the first responder.
    static func readerHasKeyboard(_ window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: ReaderWebEngine.shared.webView)
    }

    // MARK: Text input

    private static func isPrintable(_ event: NSEvent) -> Bool {
        guard let scalar = event.characters?.unicodeScalars.first else { return false }
        return scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
    }

    /// The text view receiving typing in the window, if any (field editors included).
    static func textInput(in window: NSWindow?) -> NSTextView? {
        guard let responder = window?.firstResponder as? NSTextView, responder.isEditable else { return nil }
        // A field editor left behind by a text field that has gone (the closed palette) isn't typing.
        if responder.isFieldEditor, let field = responder.delegate as? NSView, field.window == nil { return nil }
        return responder
    }
}
