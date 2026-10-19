import AppKit

/// Key events for the self-checks that take the way a person's keys do. They are posted into Tern's own event
/// queue (never to the system) as HID-state CGEvents for a window, with the keyboard type and the current
/// layout's characters, so `NSApplication.sendEvent`, the key monitors, the menu bar, the input context and
/// SwiftUI all handle them.
@MainActor
enum PostedKeys {
    /// Marks posted events, in their CGEvent's source user data.
    static let tag: Int64 = 0x7E54_7E54

    static let returnKey: UInt16 = 36, tab: UInt16 = 48, escape: UInt16 = 53, down: UInt16 = 125, up: UInt16 = 126

    /// Key codes of the ABC layout's letters and space.
    static let codes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45,
        "m": 46, " ": 49,
    ]

    private static let source = CGEventSource(stateID: .hidSystemState)
    /// The CGEvent field NSEvent reads its window number from.
    private static let windowNumber = CGEventField(rawValue: 51)!

    /// A letter or space going down or up; capitals hold Shift.
    static func post(_ character: Character, down: Bool, to window: NSWindow, isARepeat: Bool = false) {
        guard let code = codes[Character(character.lowercased())] else { return assertionFailure("no key code for \(character)") }
        post(code, down: down, flags: character.isUppercase ? .maskShift : [], to: window, isARepeat: isARepeat)
    }

    /// Each character down and up, all queued at once.
    static func type(_ text: String, to window: NSWindow) {
        for character in text {
            post(character, down: true, to: window)
            post(character, down: false, to: window)
        }
    }

    /// A key by its code, down and up. Arrows carry the keypad and fn flags, as a keyboard sends them.
    static func press(_ code: UInt16, flags: CGEventFlags = [], to window: NSWindow) {
        post(code, down: true, flags: flags, to: window)
        post(code, down: false, flags: flags, to: window)
    }

    static func post(_ code: UInt16, down: Bool, flags: CGEventFlags, to window: NSWindow, isARepeat: Bool = false) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        event.flags = code == Self.down || code == up ? flags.union([.maskNumericPad, .maskSecondaryFn]) : flags
        event.timestamp = CGEventTimestamp(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        event.setIntegerValueField(windowNumber, value: Int64(window.windowNumber))
        event.setIntegerValueField(.eventSourceUserData, value: tag)
        if isARepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        // Posted events come back as new NSEvents made from their CGEvent, as the window server's do.
        guard let posted = NSEvent(cgEvent: event) else { return }
        NSApp.postEvent(posted, atStart: false)
    }

    static func isPosted(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) == tag
    }
}
