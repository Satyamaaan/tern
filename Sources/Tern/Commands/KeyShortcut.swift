import AppKit

/// A key plus modifiers. Bare keys use the character they type ("J" means ⇧J, "#" means ⇧3).
struct KeyShortcut: Hashable {
    enum Key: Hashable {
        case char(String)
        case returnKey, escape, tab, up, down, delete, space
    }

    var key: Key
    var modifiers: NSEvent.ModifierFlags

    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    static func == (a: KeyShortcut, b: KeyShortcut) -> Bool {
        a.key == b.key && a.modifiers.rawValue == b.modifiers.rawValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(modifiers.rawValue)
    }

    static func key(_ character: String) -> KeyShortcut { KeyShortcut(key: .char(character), modifiers: []) }
    static func command(_ character: String, shift: Bool = false) -> KeyShortcut {
        KeyShortcut(key: .char(character), modifiers: shift ? [.command, .shift] : [.command])
    }
    static func option(_ character: String) -> KeyShortcut { KeyShortcut(key: .char(character), modifiers: [.option]) }
    static func special(_ key: Key, _ modifiers: NSEvent.ModifierFlags = []) -> KeyShortcut {
        KeyShortcut(key: key, modifiers: modifiers)
    }

    /// Bare keys (no ⌘ or ⌃) are handled by `KeyRouter` and never while text is being typed.
    var isBare: Bool { modifiers.isDisjoint(with: [.command, .control]) }

    // MARK: Display

    /// How keycaps show the shortcut: "⌘K", "⇧R", "e", "esc".
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case .char(let c):
            if c.count == 1, let scalar = c.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(scalar) {
                return text + "⇧" + c
            }
            return text + (modifiers.contains(.command) || modifiers.contains(.option) ? c.uppercased() : c)
        case .returnKey: return text + "↵"
        case .escape: return text + "esc"
        case .tab: return text + "⇥"
        case .up: return text + "↑"
        case .down: return text + "↓"
        case .delete: return text + "del"
        case .space: return text + "space"
        }
    }

    // MARK: Menus

    var keyEquivalent: String {
        switch key {
        case .char(let c): c
        case .returnKey: "\r"
        case .escape: "\u{1b}"
        case .tab: "\t"
        case .up: String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case .down: String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case .delete: "\u{8}"
        case .space: " "
        }
    }

    // MARK: Matching

    func matches(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(Self.relevantModifiers)
        switch key {
        case .char(let c):
            if modifiers.isEmpty || modifiers == .shift {
                // Bare keys compare the typed character, which already carries Shift ("J", "#").
                return event.characters == c && flags.subtracting(.shift).isEmpty
            }
            // Modified keys compare the unmodified key, so ⌘⇧\ and ⌥1 match on any layout.
            return event.characters(byApplyingModifiers: [])?.lowercased() == c.lowercased() && flags == modifiers
        default:
            guard Self.keyCode(for: key).contains(event.keyCode) else { return false }
            return flags == modifiers
        }
    }

    private static func keyCode(for key: Key) -> [UInt16] {
        switch key {
        case .returnKey: [36, 76]
        case .escape: [53]
        case .tab: [48]
        case .up: [126]
        case .down: [125]
        case .delete: [51, 117]
        case .space: [49]
        case .char: []
        }
    }
}
