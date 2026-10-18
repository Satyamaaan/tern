import AppKit

/// The Control keys the system's key bindings and the user's own `~/Library/KeyBindings/DefaultKeyBinding.dict`
/// give text fields, which Tern's shortcuts mustn't take. Launch never reads them: they are read once, off the main
/// thread, after the window is up or when the shortcut recorder starts, and the registry then drops saved changes
/// that use one (`CommandRegistry.loadKeyBindings`). A file larger than `maxFileSize`, an entry longer than
/// `maxBindingLength` and anything that isn't a key bindings dictionary are ignored.
@MainActor
final class KeyBindingFiles {
    static let shared = KeyBindingFiles(urls: [
        URL(fileURLWithPath: "/System/Library/Frameworks/AppKit.framework/Resources/StandardKeyBinding.dict"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/KeyBindings/DefaultKeyBinding.dict"),
    ])

    /// Key bindings people write are a few KB; the system's is under 5 KB.
    nonisolated static let maxFileSize = 256 * 1024
    /// Modifier characters then one key: "~^$B" is four.
    nonisolated static let maxBindingLength = 16

    let urls: [URL]
    /// The keys, once read; nil before.
    private(set) var keys: Set<KeyShortcut>?
    /// How many times the files were read: once at most.
    private(set) var reads = 0
    private var waiting: [@MainActor (Set<KeyShortcut>) -> Void] = []

    init(urls: [URL]) {
        self.urls = urls
    }

    /// Calls `done` with the keys: at once when they're read already, else after one background read that every
    /// caller shares.
    func load(_ done: @escaping @MainActor (Set<KeyShortcut>) -> Void) {
        if let keys { return done(keys) }
        waiting.append(done)
        guard waiting.count == 1 else { return }
        reads += 1
        let urls = urls
        Task {
            let keys = await Task.detached(priority: .utility) { Self.read(urls) }.value
            self.keys = keys
            let callers = self.waiting
            self.waiting = []
            for caller in callers { caller(keys) }
        }
    }

    /// The Control keys every readable dictionary in `urls` binds.
    nonisolated static func read(_ urls: [URL]) -> Set<KeyShortcut> {
        var keys = Set<KeyShortcut>()
        for url in urls {
            guard let bindings = dictionary(at: url) else { continue }
            keys.formUnion(controlKeys(in: bindings))
        }
        return keys
    }

    /// The dictionary in a regular file (links followed) of at most `maxFileSize` bytes.
    nonisolated static func dictionary(at url: URL) -> [String: Any]? {
        let file = url.resolvingSymlinksInPath()
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
              let size = values.fileSize, size <= maxFileSize,
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        // The file can grow between the check and the read; never take more than the cap.
        guard let data = try? handle.read(upToCount: maxFileSize + 1), data.count <= maxFileSize else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// The Control keys (without ⌘) a key bindings dictionary binds, as shortcuts. Its keys are modifier
    /// characters (^ Control, ~ Option, $ Shift, @ Command, # keypad) then the key: "^h", "~^B", "^\u{F700}".
    /// Each entry is scanned once, and no further than `maxBindingLength` scalars.
    nonisolated static func controlKeys(in bindings: [String: Any]) -> Set<KeyShortcut> {
        var keys = Set<KeyShortcut>()
        for binding in bindings.keys {
            let scalars = Array(binding.unicodeScalars.prefix(maxBindingLength + 1))
            guard (1...maxBindingLength).contains(scalars.count) else { continue }
            let last = scalars.count - 1
            var modifiers: NSEvent.ModifierFlags = []
            var index = 0
            while index < last, let flag = bindingModifiers[scalars[index]] {
                modifiers.insert(flag)
                index += 1
            }
            guard index == last, modifiers.contains(.control), !modifiers.contains(.command) else { continue }
            let scalar = scalars[last]
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

    private nonisolated static let bindingModifiers: [Unicode.Scalar: NSEvent.ModifierFlags] = [
        "^": .control, "~": .option, "$": .shift, "@": .command, "#": .numericPad,
    ]
}
