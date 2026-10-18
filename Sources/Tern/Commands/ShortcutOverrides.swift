import AppKit

/// The user's changes to keyboard shortcuts, by command id: only commands whose keys differ from their
/// built-in ones, so a command the user never touched picks up new defaults in later versions. An empty
/// list means the user removed every shortcut of that command (it still runs from the menus and ⌘K).
struct ShortcutOverrides: Equatable {
    var keys: [String: [KeyShortcut]] = [:]

    static let defaultsKey = "shortcutOverrides"

    var isEmpty: Bool { keys.isEmpty }

    /// The UserDefaults form: command id → keys as `KeyShortcut.stored` strings.
    var stored: [String: [String]] { keys.mapValues { $0.map(\.stored) } }

    init(keys: [String: [KeyShortcut]] = [:]) {
        self.keys = keys
    }

    /// Entries that don't read back whole (a format from another version) are dropped, so their
    /// commands fall back to the defaults instead of losing a key. Reserved keys are dropped too, and an
    /// entry left with none falls back the same way. The registry checks the rest against its commands
    /// (`CommandRegistry.validated`) and saves what is left.
    init(stored: [String: [String]]) {
        for (id, strings) in stored {
            let shortcuts = strings.compactMap(KeyShortcut.init(stored:))
            guard shortcuts.count == strings.count else { continue }
            let allowed = shortcuts.filter { ShortcutRules.reservation($0, for: id) == nil }
            if allowed.isEmpty && !shortcuts.isEmpty { continue }
            keys[id] = allowed
        }
    }

    static func load(from defaults: UserDefaults) -> ShortcutOverrides {
        ShortcutOverrides(stored: defaults.dictionary(forKey: defaultsKey) as? [String: [String]] ?? [:])
    }

    func save(to defaults: UserDefaults) {
        if keys.isEmpty { defaults.removeObject(forKey: Self.defaultsKey) } else { defaults.set(stored, forKey: Self.defaultsKey) }
    }
}

/// Where a command's keys act. Two commands may share a bare key only when their scopes don't overlap, like
/// `p`: Move to Project in the list, Previous Message in the open conversation.
enum KeyScope {
    case anywhere, list, reader

    func overlaps(_ other: KeyScope) -> Bool { self == .anywhere || other == .anywhere || self == other }
}

/// Shortcuts the user can't take: macOS's own, the menu items Tern doesn't build from the registry, the
/// Control keys text fields edit with, and bare `g`, which starts the Go to chords. Commands whose keys
/// can't change are locked.
enum ShortcutRules {
    static let reserved: [KeyShortcut: String] = [
        .command("q"): "Quit Tern",
        .command("w"): "Close Window",
        .command("h"): "Hide Tern",
        KeyShortcut(key: .char("h"), modifiers: [.command, .option]): "Hide Others",
        .command("m"): "Minimize",
        .command(","): "Settings",
        .special(.tab, [.command]): "switching apps",
        .special(.tab, [.command, .shift]): "switching apps",
        .command("`"): "switching windows",
        .command("`", shift: true): "switching windows",
        .special(.space, [.command]): "Spotlight",
        .special(.space, [.command, .option]): "Finder search",
        .special(.space, [.control]): "switching input sources",
        .special(.space, [.control, .command]): "Emoji & Symbols",
        KeyShortcut(key: .char("f"), modifiers: [.control, .command]): "Full Screen",
        KeyShortcut(key: .char("q"), modifiers: [.control, .command]): "Lock Screen",
        .special(.escape, [.command, .option]): "Force Quit",
        .command("3", shift: true): "screenshots",
        .command("4", shift: true): "screenshots",
        .command("5", shift: true): "screenshots",
        .command("x"): "Cut",
        .command("c"): "Copy",
        .command("v"): "Paste",
        KeyShortcut(key: .char("v"), modifiers: [.command, .option, .shift]): "Paste and Match Style",
        .command("z"): "Undo",
        .command("z", shift: true): "Redo",
        .command("a"): "Select All",
        .key("g"): "the g shortcuts (g i, g s…)",
    ]

    /// Commands whose shortcuts stay as built: Settings is always ⌘,, and ⌘1–⌘9 follow the account order.
    static func isLocked(_ commandId: String) -> Bool {
        commandId == "settings" || (commandId.hasPrefix("scope.") && commandId != "scope.all")
    }

    /// What `shortcut` is kept for, unless it is `commandId`'s own built-in key (⌘A for Select All).
    static func reservation(_ shortcut: KeyShortcut, for commandId: String) -> String? {
        if shortcut == .command("a") && commandId == "selectAll" { return nil }
        if shortcut == .command(",") && commandId == "settings" { return nil }
        return reserved[shortcut] ?? (textEditing.contains(shortcut) ? "text editing" : nil)
    }

    /// Whether two commands can both have `shortcut`. Only bare keys are routed by where the keyboard is;
    /// a ⌘ or ⌃ key becomes a menu key equivalent, and there the first item with it would win anywhere.
    static func canShare(_ shortcut: KeyShortcut, _ a: KeyScope, _ b: KeyScope) -> Bool {
        shortcut.isBare && !a.overlaps(b)
    }

    // MARK: Text editing

    /// Control keys text fields edit with (⌃H deletes back, ⌃A goes to the start of the line, ⌃K cuts to
    /// the end): the Cocoa and Emacs bindings with and without ⇧ and ⌥, plus every Control key in the
    /// system's key bindings and the user's own `DefaultKeyBinding.dict`.
    static let textEditing: Set<KeyShortcut> = {
        var keys = Set<KeyShortcut>()
        for letter in "abdefhklnoptvy" {
            for extra: NSEvent.ModifierFlags in [[], .shift, .option, [.option, .shift]] {
                keys.insert(KeyShortcut(key: .char(String(letter)), modifiers: extra.union(.control)))
            }
        }
        keys.formUnion([
            .special(.returnKey, [.control]), .special(.tab, [.control]), .special(.tab, [.control, .shift]),
            .special(.delete, [.control]), .special(.delete, [.control, .option]),
            .special(.up, [.control]), .special(.down, [.control]),
            KeyShortcut(key: .char("/"), modifiers: .control), KeyShortcut(key: .char("'"), modifiers: .control),
            KeyShortcut(key: .char("'"), modifiers: [.control, .shift]),
        ])
        let dictionaries = [
            URL(fileURLWithPath: "/System/Library/Frameworks/AppKit.framework/Resources/StandardKeyBinding.dict"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/KeyBindings/DefaultKeyBinding.dict"),
        ]
        for url in dictionaries {
            guard let data = try? Data(contentsOf: url),
                  let bindings = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }
            keys.formUnion(controlKeys(inBindings: bindings))
        }
        return keys
    }()

    /// The Control keys (without ⌘) a key bindings dictionary binds, as shortcuts. Its keys are modifier
    /// characters (^ Control, ~ Option, $ Shift, @ Command, # keypad) then the key: "^h", "~^B", "^\u{F700}".
    static func controlKeys(inBindings bindings: [String: Any]) -> Set<KeyShortcut> {
        var keys = Set<KeyShortcut>()
        for binding in bindings.keys {
            var scalars = Array(binding.unicodeScalars)
            var modifiers: NSEvent.ModifierFlags = []
            while scalars.count > 1, let flag = bindingModifiers[scalars[0]] {
                modifiers.insert(flag)
                scalars.removeFirst()
            }
            guard scalars.count == 1, modifiers.contains(.control), !modifiers.contains(.command) else { continue }
            let scalar = scalars[0]
            let key: KeyShortcut.Key
            switch scalar.value {
            case 0x0D, 0x0A, 0x03: key = .returnKey
            case 0x09: key = .tab
            case 0x19: key = .tab; modifiers.insert(.shift)
            case 0x08, 0x7F: key = .delete
            case 0x1B: key = .escape
            case 0x20: key = .space
            case 0xF700: key = .up
            case 0xF701: key = .down
            case 0x21...0x7E, 0xA0...0xF6FF:
                let character = String(scalar)
                if character != character.lowercased() { modifiers.insert(.shift) }
                key = .char(character.lowercased())
            default: continue
            }
            keys.insert(KeyShortcut(key: key, modifiers: modifiers.subtracting(.numericPad)))
        }
        return keys
    }

    private static let bindingModifiers: [Unicode.Scalar: NSEvent.ModifierFlags] = [
        "^": .control, "~": .option, "$": .shift, "@": .command, "#": .numericPad,
    ]
}

extension KeyShortcut {
    // MARK: Storage

    /// Stable text for UserDefaults: the modifiers in display order, a bar, then the key
    /// ("⇧⌘|c:l", "|c:e", "⇧|tab").
    var stored: String {
        let mods = Self.storedModifiers.filter { modifiers.contains($0.flag) }.map(\.symbol).joined()
        let name: String = switch key {
        case .char(let c): "c:" + c
        case .returnKey: "return"
        case .escape: "escape"
        case .tab: "tab"
        case .up: "up"
        case .down: "down"
        case .delete: "delete"
        case .space: "space"
        }
        return mods + "|" + name
    }

    init?(stored: String) {
        guard let bar = stored.firstIndex(of: "|") else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        for symbol in stored[..<bar] {
            guard let flag = Self.storedModifiers.first(where: { $0.symbol == String(symbol) })?.flag else { return nil }
            modifiers.insert(flag)
        }
        let name = String(stored[stored.index(after: bar)...])
        let key: Key
        switch name {
        case "return": key = .returnKey
        case "escape": key = .escape
        case "tab": key = .tab
        case "up": key = .up
        case "down": key = .down
        case "delete": key = .delete
        case "space": key = .space
        default:
            guard name.hasPrefix("c:"), name.count == 3 else { return nil }
            key = .char(String(name.dropFirst(2)))
        }
        self.init(key: key, modifiers: modifiers)
    }

    private static let storedModifiers: [(symbol: String, flag: NSEvent.ModifierFlags)] = [
        ("⌃", .control), ("⌥", .option), ("⇧", .shift), ("⌘", .command),
    ]

    // MARK: Recording

    /// The shortcut a key press stands for, in the form the registry uses: bare keys as the character
    /// they type ("J" for ⇧J, "#" for ⇧3), others as the unmodified key plus modifiers. Nil for keys
    /// Tern can't bind (function keys, ← →, dead keys).
    init?(recording event: NSEvent) {
        let flags = event.modifierFlags.intersection(Self.relevantModifiers)
        switch event.keyCode {
        case 36, 76: self.init(key: .returnKey, modifiers: flags); return
        case 53: self.init(key: .escape, modifiers: flags); return
        case 48: self.init(key: .tab, modifiers: flags); return
        case 126: self.init(key: .up, modifiers: flags); return
        case 125: self.init(key: .down, modifiers: flags); return
        case 51, 117: self.init(key: .delete, modifiers: flags); return
        case 49: self.init(key: .space, modifiers: flags); return
        default: break
        }
        if flags.isDisjoint(with: [.command, .control, .option]) {
            guard var character = event.characters, Self.isBindable(character) else { return nil }
            // Caps Lock types capitals without Shift; the key is still the lowercase one.
            if !flags.contains(.shift) { character = character.lowercased() }
            self.init(key: .char(character), modifiers: [])
        } else {
            guard let character = event.characters(byApplyingModifiers: [])?.lowercased(), Self.isBindable(character) else { return nil }
            self.init(key: .char(character), modifiers: flags)
        }
    }

    private static func isBindable(_ text: String) -> Bool {
        guard text.count == 1, let scalar = text.unicodeScalars.first, text.unicodeScalars.count == 1 else { return false }
        return scalar.value > 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
    }
}
