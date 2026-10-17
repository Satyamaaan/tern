import AppKit
import WebKit

/// Keyboard handling for the main window. A local event monitor sees every key first:
/// - while text is being typed, bare keys go straight to the text view (menus never see them);
/// - while the palette is open, navigation keys drive it;
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
        for command in registry.bareKeyCommands {
            for key in command.keys where key.isBare { bare.append((key, command)) }
        }
        // ⌘ shortcuts that mean something different outside text fields.
        bare.append((.command("a"), registry["selectAll"]!))
        bare.append((.command("z"), registry["undo"]!))
        bare.append((.command("\\"), registry["readingPane"]!))
        for command in registry.chordCommands {
            if let chord = command.chord { chords[chord] = command }
        }
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

        // Typing anywhere in the app: plain keys belong to the text, never to menu shortcuts, and ⌘ keys
        // keep their text meaning (⌘A selects the query, ⌘Z undoes typing).
        if let text = Self.textInput(in: event.window) {
            if event.window === mainWindow, handleWhileTyping(event, in: text) { return nil }
            guard !hasCommand, Self.isPrintable(event) else { return event }
            text.keyDown(with: event)
            return nil
        }
        guard event.window === mainWindow, event.window?.attachedSheet == nil else { return event }
        if model.services.isComposing && !hasCommand { return event }

        if model.palette != nil, let palette = paletteKeys, let key = Self.paletteKey(event, flags), palette(key) { return nil }

        if chordTimer != nil { return finishChord(event) }

        if !hasCommand, flags.subtracting(.shift).isEmpty, event.characters == "g" {
            startChord()
            return nil
        }

        // The conversation page has the keyboard: it moves between messages and answers Enter and Space
        // on a focused link, attachment or quote itself.
        if !hasCommand, Self.readerPageKeys.contains(where: { $0.matches(event) }), Self.readerHasKeyboard(event.window) {
            return event
        }

        for (shortcut, command) in bare where shortcut.matches(event) {
            if command.yieldsToReader && model.focus == .reader { continue }
            guard model.palette == nil || command.id == "back" else { return event }
            if command.isEnabled() {
                command.run()
                return nil
            }
            // A disabled Tab or ⌘ shortcut keeps its normal meaning; a disabled letter is just ignored.
            return shortcut.key == .tab || !shortcut.isBare ? event : nil
        }
        return event
    }

    /// Keys the search pill and palette field handle themselves.
    private func handleWhileTyping(_ event: NSEvent, in text: NSTextView) -> Bool {
        let flags = event.modifierFlags.intersection(KeyShortcut.relevantModifiers)
        if model.palette != nil, let palette = paletteKeys, let key = Self.paletteKey(event, flags) {
            return palette(key)
        }
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
        if let command = chords["g \(key)"], command.isEnabled() { command.run() }
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
