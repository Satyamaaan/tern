#if DEBUG
import AppKit
import Carbon.HIToolbox
import ObjectiveC
import SwiftUI
import TernCore

/// `--typing`: types into every kind of field through the real event path and compares what each field holds
/// with what was typed. Keys are `PostedKeys`, which the app's own loop (`NSApp.run`) dispatches: the key
/// monitor, `NSApplication.sendEvent`, the menu bar, the input context and SwiftUI all run as they do for a
/// person. Windows sit in at 1 % opacity and click-through; the app isn't activated unless asked. Note that
/// input methods (Press and Hold among them) don't take part in posted keys.
///
/// - `TERN_TYPING_FIELDS=a,b` and `TERN_TYPING_MODES=burst,human,rollover,repeats` pick what runs.
/// - `TERN_TYPING_QUICK=1` types two samples per mode.
/// - `TERN_TYPING_TRACE=1` logs every dispatch, keyDown, insertText and first-responder change.
/// - `TERN_TYPING_ACTIVE=1` makes Tern the active app for the run (it takes the keyboard from the app in front,
///   which gets it back at the end); keys a person types meanwhile are dropped and only counted.
@MainActor
final class TypingCheck {
    let model: AppModel
    let registry: CommandRegistry
    let window: MainWindow
    let router: KeyRouter
    let palette: PaletteController
    private var composer: ComposerWindowController?
    private var failures = 0
    private let environment = ProcessInfo.processInfo.environment
    private var trace: Bool { environment["TERN_TYPING_TRACE"] == "1" }
    private var quick: Bool { environment["TERN_TYPING_QUICK"] == "1" }

    init(model: AppModel, registry: CommandRegistry) {
        self.model = model
        self.registry = registry
        palette = PaletteController(model: model, registry: registry)
        router = KeyRouter(registry: registry)
        router.paletteKeys = { [palette] key in palette.handle(key) }
        let hosting = NSHostingView(rootView: MainView(palette: palette).environment(model).environment(model.services))
        hosting.sizingOptions = []
        window = MainWindow(contentView: hosting)
        window.setContentSize(MainWindow.defaultSize)
        router.mainWindow = window
    }

    /// Runs on the app's own event loop, so posted events are dispatched as a person's are.
    func start() {
        Task { @MainActor in await self.run() }
    }

    private func run() async {
        TypingTrace.install()
        NSApp.setActivationPolicy(.accessory)
        show(window)
        router.install()
        let previous = NSWorkspace.shared.frontmostApplication
        let active = environment["TERN_TYPING_ACTIVE"] == "1"
        if active { NSApp.activate(ignoringOtherApps: true) }
        window.makeKeyAndOrderFront(nil)
        let pane = model.prefs.readingPane, section = model.prefs.settingsSection
        model.prefs.readingPane = false
        model.show(.inbox)
        model.showInboxTab(nil)
        model.focusList()
        await wait(0.5)
        print("app active \(NSApp.isActive), input source \(TypingTrace.inputSource())")

        let fields = environment["TERN_TYPING_FIELDS"]?.split(separator: ",").compactMap { Field(rawValue: String($0)) }
        let undo = model.undoStack.count, rows = model.snapshot.order.count
        for field in fields ?? Field.allCases { await exercise(field) }
        check("typing ran no mail command", model.undoStack.count == undo && model.snapshot.order.count == rows)
        check("typing opened no composer", NSApp.windows.filter { $0 is ComposerWindow && $0 !== composer?.window }.isEmpty)
        composer?.window?.close()
        // Keys go to the app's key window.
        window.makeKey()
        if environment["TERN_TYPING_KEYS"] != "0" { await keys() }
        model.prefs.readingPane = pane
        model.prefs.settingsSection = section
        if active, let previous, previous != NSRunningApplication.current { previous.activate() }
        if TypingTrace.foreign > 0 { print("\(TypingTrace.foreign) key event(s) from outside the harness were dropped") }
        print(failures == 0 ? "ALL TYPING CHECKS PASSED" : "\(failures) TYPING CHECK(S) FAILED")
        // exit() doesn't wait for the preferences just put back to be saved.
        UserDefaults.standard.synchronize()
        exit(failures == 0 ? 0 : 1)
    }

    private func show(_ window: NSWindow) {
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
    }

    // MARK: Fields

    enum Field: String, CaseIterable {
        case settingsSearch, shortcutsFilter, aiModel, searchPill, palette, findBar, inlineReply, composerSubject, composerBody
    }

    private func exercise(_ field: Field) async {
        guard let target = await focus(field) else { return check("\(field): the field takes the keyboard", false) }
        let samples = quick ? ["search", "seaarr"] : ["search", "seaarr", "settings", "aabbccdd", "Hello World", "the quick brown fox jumps"]
        let modes = environment["TERN_TYPING_MODES"]?.split(separator: ",").compactMap { Mode(rawValue: String($0)) } ?? Mode.allCases
        for mode in modes {
            for sample in mode == .repeats ? ["r"] : samples {
                await clear(field)
                guard let text = KeyRouter.textInput(in: target), text.window === target else {
                    check("\(field) \(mode): the field still has the keyboard", false)
                    continue
                }
                // A correction bubble waits for a person in its own event loop.
                text.isAutomaticSpellingCorrectionEnabled = false
                let before = text.string as NSString, selection = text.selectedRange()
                let typed = mode == .repeats ? String(repeating: "r", count: 6) : sample
                let expected = before.replacingCharacters(in: selection, with: typed)
                TypingTrace.begin()
                switch mode {
                case .burst: burst(sample, in: target)
                case .human: await human(sample, in: target)
                case .rollover: await rollover(sample, in: target)
                case .repeats: await repeats("r", in: target)
                }
                await settle(expected: expected, in: target)
                let editor = KeyRouter.textInput(in: target)?.string
                let bound = value(field)
                let ok = editor == expected && (bound == nil || bound == editor)
                check("\(field) \(mode) “\(typed)” → “\(editor.map(Self.tail) ?? "nil")”\(bound.map { ", bound “\($0)”" } ?? "")", ok)
                if !ok || trace { TypingTrace.dump() } else { TypingTrace.end() }
            }
        }
        await leave(field)
    }

    /// Opens and focuses the field; returns the window it is in.
    private func focus(_ field: Field) async -> NSWindow? {
        switch field {
        case .settingsSearch:
            model.openSettings(.accounts)
            await wait(0.3)
            model.settings?.searchFocused = true
            return await editing("Search settings") ? window : nil
        case .shortcutsFilter:
            model.openSettings(.shortcuts)
            model.settings?.show(.shortcuts)
            await wait(0.3)
            model.settings?.filterFocused = true
            return await editing("Filter shortcuts") ? window : nil
        case .aiModel:
            model.openSettings(.ai)
            model.settings?.show(.ai)
            if model.settings?.provider == .off { model.settings?.provider = .claude }
            await wait(0.3)
            // The model field has no focus binding; a click gives it the keyboard.
            if let field = textField(in: window, placeholder: "Default") { window.makeFirstResponder(field) }
            return await editing("Default") ? window : nil
        case .searchPill:
            model.beginSearch()
            return await editing("Search mail") ? window : nil
        case .palette:
            model.palette = .commands
            return await editing(palette.placeholder) ? window : nil
        case .findBar:
            guard let key = model.snapshot.order.dropFirst(2).first else { return nil }
            model.click(key, command: false, shift: false)
            await wait(0.4)
            model.services.reader.find()
            return await editing("Find in conversation") ? window : nil
        case .inlineReply:
            guard let key = model.snapshot.order.dropFirst(3).first else { return nil }
            model.click(key, command: false, shift: false)
            await wait(0.4)
            model.focusList()
            await wait(0.1)
            // `r` through the real path: it opens the reply and must not be typed into it as well.
            post("r", down: true, in: window)
            post("r", down: false, in: window)
            guard await waitUntil(2, { KeyRouter.textInput(in: self.window).map { !$0.isFieldEditor } ?? false }),
                  let body = KeyRouter.textInput(in: window) else { return nil }
            await wait(0.2)
            let caret = body.selectedRange().location
            let stray = caret > 0 && (body.string as NSString).substring(with: NSRange(location: caret - 1, length: 1)) == "r"
            check("r opens the inline reply without typing r into it", !stray && !body.string.hasPrefix("r"))
            return window
        case .composerSubject, .composerBody:
            if composer == nil {
                guard let model = ComposerModel(request: .new(accountId: nil), services: model.services, mode: .window) else { return nil }
                let controller = ComposerWindowController(model: model, offset: 0)
                composer = controller
                if let window = controller.window { show(window) }
                await wait(0.4)
            }
            guard let target = composer?.window else { return nil }
            target.makeKey()
            if field == .composerSubject {
                guard let subject = textField(in: target, label: "Subject") else { return nil }
                target.makeFirstResponder(subject)
                guard await waitUntil(1, { KeyRouter.textInput(in: target)?.isFieldEditor == true }) else { return nil }
            } else {
                composer?.model.focus(.body)
                guard await waitUntil(1, { KeyRouter.textInput(in: target).map { !$0.isFieldEditor } ?? false }) else { return nil }
            }
            return target
        }
    }

    private func leave(_ field: Field) async {
        switch field {
        case .settingsSearch:
            model.settings?.query = ""
            model.settings?.takeKeyboard()
        case .shortcutsFilter:
            model.settings?.shortcutFilter = ""
            model.settings?.takeKeyboard()
        case .aiModel:
            // Emptied as a person would, then let go of: the field saves what it holds when it loses the keyboard.
            KeyRouter.textInput(in: window)?.selectAll(nil)
            KeyRouter.textInput(in: window)?.delete(nil)
            model.settings?.takeKeyboard()
            await wait(0.1)
            model.closeSettings()
        case .searchPill: model.endSearch(restoreFocus: true)
        case .palette: model.palette = nil
        case .findBar:
            model.services.reader.model?.closeFind()
            model.back()
        case .inlineReply:
            model.services.reader.model?.composing = nil
            await wait(0.3)
            model.back()
        case .composerSubject, .composerBody: break
        }
        await wait(0.3)
    }

    /// Empties fields with a binding, so samples don't pile up; text views keep their text.
    private func clear(_ field: Field) async {
        switch field {
        case .settingsSearch: model.settings?.query = ""
        case .shortcutsFilter: model.settings?.shortcutFilter = ""
        case .searchPill: model.searchText = ""
        case .palette: palette.query = ""
        case .findBar: model.services.reader.model?.findText = ""
        case .aiModel:
            KeyRouter.textInput(in: window)?.selectAll(nil)
            KeyRouter.textInput(in: window)?.delete(nil)
        case .composerSubject:
            // As a person would: select all and delete, which tells the field and the model.
            KeyRouter.textInput(in: composer?.window)?.selectAll(nil)
            KeyRouter.textInput(in: composer?.window)?.delete(nil)
        case .inlineReply, .composerBody: return
        }
        await wait(0.15)
    }

    /// The model value a field is bound to, to compare with what its editor shows.
    private func value(_ field: Field) -> String? {
        switch field {
        case .settingsSearch: model.settings?.query
        case .shortcutsFilter: model.settings?.shortcutFilter
        case .searchPill: model.searchText
        case .palette: palette.query
        case .findBar: model.services.reader.model?.findText
        case .composerSubject: composer?.model.subject
        // The model field saves on Return or when it loses the keyboard, not as it is typed.
        case .aiModel, .inlineReply, .composerBody: nil
        }
    }

    /// Waits until the text field with this placeholder has the keyboard in the main window.
    private func editing(_ placeholder: String) async -> Bool {
        func editing() -> Bool {
            guard let text = KeyRouter.textInput(in: window), let field = text.delegate as? NSTextField else { return false }
            return field.placeholderString == placeholder
        }
        if await waitUntil(1, editing) { return true }
        // Offscreen SwiftUI doesn't always move focus; put it there as a click would.
        guard let field = textField(in: window, placeholder: placeholder) else { return false }
        print("  (\(placeholder): given the keyboard by hand)")
        window.makeFirstResponder(field)
        return await waitUntil(1, editing)
    }

    private func textField(in window: NSWindow, placeholder: String? = nil, label: String? = nil) -> NSTextField? {
        func search(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable,
               placeholder.map({ field.placeholderString == $0 }) ?? true, label.map({ field.accessibilityLabel() == $0 }) ?? true {
                return field
            }
            return view.subviews.lazy.compactMap(search).first
        }
        return window.contentView.flatMap(search)
    }

    private static func tail(_ text: String) -> String {
        text.count > 40 ? "…" + text.suffix(40) : text
    }

    // MARK: Keys

    /// Keys that mean something while typing, through the real path: the search pill's, the palette's and the
    /// settings page's own keys, a mail command's ⌃ key (left to the text), ⌘K (still opens the palette) and a
    /// dead-key accent, which the input context composes.
    private func keys() async {
        model.beginSearch()
        guard await editing("Search mail") else { return check("keys: the search pill takes the keyboard", false) }
        type("from")
        await waitUntil(1) { self.model.showsSuggestions }
        press(PostedKeys.down)
        await waitUntil(0.5) { self.model.suggestionIndex == 0 }
        check("↓ in the search pill moves into the suggestions", model.suggestionIndex == 0 && model.searchText == "from" && model.searchFieldFocused)
        press(PostedKeys.tab)
        await waitUntil(0.5) { self.model.searchText != "from" }
        await wait(0.2)
        check("Tab completes the suggestion and keeps the keyboard in the pill",
              model.searchText != "from" && model.searchText.hasPrefix("from") && editingNow("Search mail"))
        for _ in 0..<3 where model.searchFieldFocused {
            press(PostedKeys.escape)
            await wait(0.2)
        }
        check("Esc closes the suggestions, then the search", !model.searchFieldFocused && model.searchText.isEmpty)

        model.beginSearch()
        guard await editing("Search mail") else { return check("keys: the search pill takes the keyboard again", false) }
        type("invoice")
        await waitUntil(1) { self.model.searchText == "invoice" }
        press(PostedKeys.returnKey)
        await waitUntil(1) { !self.model.searchFieldFocused }
        check("↩ in the search pill searches and moves into the results",
              !model.searchFieldFocused && model.searchText == "invoice" && KeyRouter.textInput(in: window) == nil)
        model.endSearch(restoreFocus: true)
        await wait(0.2)

        // A mail command's ⌃ key and ⌘K while typing.
        let saved = registry.overrides
        registry.assign(KeyShortcut(key: .char("g"), modifiers: .control), to: "trash", replacing: nil)
        model.beginSearch()
        guard await editing("Search mail") else { return check("keys: the search pill takes the keyboard for ⌃", false) }
        let undo = model.undoStack.count, rows = model.snapshot.order.count
        press(5, flags: .maskControl)
        await wait(0.3)
        check("a mail command's ⌃ key doesn't fire while typing", model.undoStack.count == undo && model.snapshot.order.count == rows)
        registry.restore(saved)
        // ⌥E then E: the layout's dead key, composed by the input context.
        model.searchText = ""
        await wait(0.15)
        press(14, flags: .maskAlternate)
        press(14)
        await waitUntil(1) { self.model.searchText == "é" }
        check("⌥E E types é", model.searchText == "é" && KeyRouter.textInput(in: window)?.string == "é")
        press(40, flags: .maskCommand)
        await waitUntil(1) { self.model.palette == .commands }
        check("⌘K opens the palette while typing", model.palette == .commands)

        // The palette's own keys.
        guard await editing(palette.placeholder) else { return check("keys: the palette takes the keyboard", false) }
        type("arch")
        await waitUntil(1) { self.palette.query == "arch" }
        let selection = palette.selection
        press(PostedKeys.down)
        await waitUntil(0.5) { self.palette.selection != selection }
        let moved = palette.selection
        press(PostedKeys.up)
        await waitUntil(0.5) { self.palette.selection != moved }
        check("↓ and ↑ move through the palette and leave its text", moved == selection + 1 && palette.selection == selection
              && palette.query == "arch" && KeyRouter.textInput(in: window)?.string == "arch")
        press(PostedKeys.escape)
        await waitUntil(1) { self.model.palette == nil }
        check("Esc closes the palette", model.palette == nil)
        model.endSearch(restoreFocus: true)
        await wait(0.2)

        // The settings page: Esc clears the search, then leaves the field, then the page; ↩ opens the first result.
        model.openSettings(.accounts)
        await wait(0.3)
        model.settings?.searchFocused = true
        guard await editing("Search settings") else { return check("keys: settings search takes the keyboard", false) }
        type("dark")
        await waitUntil(1) { self.model.settings?.query == "dark" }
        press(PostedKeys.escape)
        await wait(0.2)
        check("Esc clears the settings search", model.settings?.query == "" && editingNow("Search settings"))
        press(PostedKeys.escape)
        await wait(0.2)
        check("…then leaves the field", model.settingsOpen && KeyRouter.textInput(in: window) == nil)
        press(PostedKeys.escape)
        await waitUntil(1) { !self.model.settingsOpen }
        check("…then closes the page", !model.settingsOpen)

        model.openSettings(.accounts)
        await wait(0.3)
        model.settings?.searchFocused = true
        guard await editing("Search settings") else { return check("keys: settings search takes the keyboard again", false) }
        type("dark")
        await waitUntil(1) { self.model.settings?.query == "dark" }
        let first = SettingsCatalog.results(for: "dark", model: model).first?.section
        press(PostedKeys.returnKey)
        await wait(0.3)
        check("↩ in settings search opens the first result's section", first != nil && model.settings?.section == first
              && model.settings?.query == "" && KeyRouter.textInput(in: window) == nil)
        model.closeSettings()
        await wait(0.2)
    }

    private func editingNow(_ placeholder: String) -> Bool {
        (KeyRouter.textInput(in: window)?.delegate as? NSTextField)?.placeholderString == placeholder
    }

    private func type(_ text: String) { PostedKeys.type(text, to: window) }

    private func press(_ code: UInt16, flags: CGEventFlags = []) { PostedKeys.press(code, flags: flags, to: window) }

    private func post(_ character: Character, down: Bool, in target: NSWindow, isARepeat: Bool = false) {
        PostedKeys.post(character, down: down, to: target, isARepeat: isARepeat)
    }

    // MARK: Typing

    enum Mode: String, CaseIterable { case burst, human, rollover, repeats }

    /// Every keyDown and keyUp queued at once, as a burst the app reads in one go.
    private func burst(_ text: String, in target: NSWindow) {
        for character in text {
            post(character, down: true, in: target)
            post(character, down: false, in: target)
        }
    }

    /// One key at a time, 60–120 ms apart, with the app's loop turning between them.
    private func human(_ text: String, in target: NSWindow) async {
        for character in text {
            post(character, down: true, in: target)
            await wait(0.03)
            post(character, down: false, in: target)
            await wait(Double.random(in: 0.03...0.09))
        }
    }

    /// The next key goes down before the last one comes up, as fast typing does.
    private func rollover(_ text: String, in target: NSWindow) async {
        var held: Character?
        for character in text {
            post(character, down: true, in: target)
            await wait(0.02)
            if let held { post(held, down: false, in: target) }
            held = character
            await wait(0.03)
        }
        if let held { post(held, down: false, in: target) }
    }

    /// A held key: the keyDown, five auto-repeat keyDowns, the keyUp.
    private func repeats(_ character: Character, in target: NSWindow) async {
        post(character, down: true, in: target)
        await wait(0.25)
        for _ in 0..<5 {
            post(character, down: true, in: target, isARepeat: true)
            await wait(0.035)
        }
        post(character, down: false, in: target)
    }

    // MARK: Helpers

    /// Waits for the queue to drain and the field to show the text (or for half a second more, to catch a
    /// late second copy).
    private func settle(expected: String, in target: NSWindow) async {
        await waitUntil(1.5) { KeyRouter.textInput(in: target)?.string == expected }
        await wait(0.3)
    }

    func check(_ name: String, _ ok: Bool) {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)")
    }

    /// Sleeps while the app's own loop keeps dispatching events.
    func wait(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    @discardableResult
    func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= end { return false }
            await wait(0.01)
        }
        return true
    }
}

// MARK: - Trace

/// Swizzles the dispatch path to log, per key event, what ran with it.
@MainActor
enum TypingTrace {
    static var lines: [String] = []
    static var recording = false
    static var depth = 0
    /// Key events not posted by the harness (a person typing while the app is active): dropped and counted,
    /// never logged.
    static var foreign = 0

    static func begin() {
        lines = []
        recording = true
    }

    static func end() {
        recording = false
    }

    static func log(_ line: String) {
        guard recording else { return }
        lines.append(String(repeating: "  ", count: depth) + line)
    }

    static func dump() {
        end()
        for line in lines { print("    " + line) }
    }

    static func inputSource() -> String {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "?" }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    static func install() {
        swizzle(NSApplication.self, #selector(NSApplication.sendEvent(_:)), #selector(NSApplication.ternTrace_sendEvent(_:)))
        swizzle(NSWindow.self, #selector(NSWindow.sendEvent(_:)), #selector(NSWindow.ternTrace_sendEvent(_:)))
        swizzle(NSWindow.self, #selector(NSWindow.makeFirstResponder(_:)), #selector(NSWindow.ternTrace_makeFirstResponder(_:)))
        swizzle(NSTextView.self, #selector(NSTextView.keyDown(with:)), #selector(NSTextView.ternTrace_keyDown(with:)))
        swizzle(NSTextView.self, #selector(NSTextView.insertText(_:replacementRange:)), #selector(NSTextView.ternTrace_insertText(_:replacementRange:)))
        swizzle(NSTextView.self, #selector(NSTextView.setMarkedText(_:selectedRange:replacementRange:)),
                #selector(NSTextView.ternTrace_setMarkedText(_:selectedRange:replacementRange:)))
        swizzle(NSTextInputContext.self, #selector(NSTextInputContext.handleEvent(_:)), #selector(NSTextInputContext.ternTrace_handleEvent(_:)))
    }

    private static func swizzle(_ cls: AnyClass, _ original: Selector, _ replacement: Selector) {
        guard let a = class_getInstanceMethod(cls, original), let b = class_getInstanceMethod(cls, replacement) else {
            return print("trace: can't swizzle \(original)")
        }
        method_exchangeImplementations(a, b)
    }

    static func describe(_ event: NSEvent) -> String {
        guard isKey(event) else { return "\(event.type.rawValue)" }
        return "\(event.type == .keyDown ? "down" : "up") “\(event.characters ?? "")”\(event.isARepeat ? " repeat" : "")"
    }

    static func isKey(_ event: NSEvent) -> Bool { event.type == .keyDown || event.type == .keyUp }

}

extension NSApplication {
    @objc func ternTrace_sendEvent(_ event: NSEvent) {
        guard TypingTrace.isKey(event) else { return ternTrace_sendEvent(event) }
        MainActor.assumeIsolated {
            guard PostedKeys.isPosted(event) else {
                TypingTrace.foreign += 1
                return
            }
            TypingTrace.log("NSApp.sendEvent \(TypingTrace.describe(event))")
            TypingTrace.depth += 1
            ternTrace_sendEvent(event)
            TypingTrace.depth -= 1
        }
    }
}

extension NSWindow {
    @objc func ternTrace_sendEvent(_ event: NSEvent) {
        guard TypingTrace.isKey(event) else { return ternTrace_sendEvent(event) }
        MainActor.assumeIsolated {
            TypingTrace.log("window.sendEvent \(TypingTrace.describe(event)) → \(firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
            TypingTrace.depth += 1
            ternTrace_sendEvent(event)
            TypingTrace.depth -= 1
        }
    }

    @objc func ternTrace_makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let result = ternTrace_makeFirstResponder(responder)
        MainActor.assumeIsolated {
            TypingTrace.log("makeFirstResponder(\(responder.map { String(describing: type(of: $0)) } ?? "nil")) → \(result)")
        }
        return result
    }
}

extension NSTextView {
    @objc func ternTrace_keyDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            TypingTrace.log("textView.keyDown \(TypingTrace.describe(event))")
            TypingTrace.depth += 1
            ternTrace_keyDown(with: event)
            TypingTrace.depth -= 1
        }
    }

    @objc func ternTrace_insertText(_ string: Any, replacementRange: NSRange) {
        MainActor.assumeIsolated {
            let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? "?"
            TypingTrace.log("insertText “\(text)” at \(selectedRange().location)")
        }
        ternTrace_insertText(string, replacementRange: replacementRange)
    }

    @objc func ternTrace_setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        MainActor.assumeIsolated {
            let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? "?"
            TypingTrace.log("setMarkedText “\(text)”")
        }
        ternTrace_setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }
}

extension NSTextInputContext {
    @objc func ternTrace_handleEvent(_ event: NSEvent) -> Bool {
        MainActor.assumeIsolated {
            TypingTrace.log("inputContext.handleEvent \(TypingTrace.describe(event))")
            TypingTrace.depth += 1
            let result = ternTrace_handleEvent(event)
            TypingTrace.depth -= 1
            TypingTrace.log("→ handled \(result)")
            return result
        }
    }
}
#endif
