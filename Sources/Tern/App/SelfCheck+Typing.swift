import AppKit

/// Typing the way a person does: `PostedKeys` dispatched by `NSApplication.sendEvent`, with the router's monitor
/// installed. Every field holds exactly what was typed, in a burst, a key at a time and with auto-repeat, and a
/// key the router handles goes no further. AppKit delivers keys only to the app's key window, so the window typed
/// into is ordered in at 1 % opacity and click-through and made key, without activating the app: nothing shows.
extension SelfCheck {
    func typing() {
        router.install()
        orderIn(window)
        defer {
            router.uninstall()
            orderOut(window)
        }
        let pane = model.prefs.readingPane, section = model.prefs.settingsSection
        defer {
            model.prefs.readingPane = pane
            model.prefs.settingsSection = section
        }
        model.prefs.readingPane = false
        model.show(.inbox)
        model.showSplit(.people)
        pump(0.2)
        let undo = model.undoStack.count, rows = model.snapshot.order.count

        model.openSettings(.accounts)
        pump(0.2)
        model.settings?.searchFocused = true
        typeInto("Search settings") { self.model.settings?.query }
        model.settings?.query = ""
        model.settings?.show(.shortcuts)
        pump(0.2)
        model.settings?.filterFocused = true
        typeInto("Filter shortcuts") { self.model.settings?.shortcutFilter }
        model.settings?.shortcutFilter = ""
        model.closeSettings()
        pump(0.2)

        model.beginSearch()
        typeInto("Search mail") { self.model.searchText }
        model.endSearch(restoreFocus: true)
        model.palette = .commands
        typeInto(palette.placeholder) { self.palette.query }
        model.palette = nil
        pump(0.2)
        check("typing ran no mail command", model.undoStack.count == undo && model.snapshot.order.count == rows)

        let order = model.snapshot.order
        guard order.count > 4, let reader = model.services.reader.model else { return check("typing: a thread", false) }
        model.click(order[3], command: false, shift: false)
        pump(0.3)
        model.services.reader.find()
        typeInto("Find in conversation") { reader.findText }
        reader.closeFind()
        pump(0.2)

        // `r` opens the inline reply, and isn't typed into it as well.
        model.focusList()
        window.makeKey()
        PostedKeys.type("r", to: window)
        pump(0.3)
        func inBody() -> Bool { KeyRouter.textInput(in: window).map { !$0.isFieldEditor } ?? false }
        // Offscreen the reply's body doesn't always take the keyboard in time; put it there as a click would.
        if !pumpUntil(1, inBody), reader.composing != nil, let body = editableTextView(in: window) { window.makeFirstResponder(body) }
        if reader.composing != nil, pumpUntil(1, inBody), let body = KeyRouter.textInput(in: window) {
            check("r opens the inline reply without typing r into it", !body.string.contains("r"))
            typeInto("the inline reply", in: window)
        } else {
            check("r opens the inline reply", false)
        }
        reader.composing = nil
        pump(0.3)
        model.back()
        pump(0.2)

        guard let composer = ComposerModel(request: .new(accountId: nil), services: model.services, mode: .window) else {
            return check("typing: a composer", false)
        }
        let controller = ComposerWindowController(model: composer, offset: 0)
        guard let target = controller.window else { return }
        orderIn(target)
        defer { target.close() }
        pump(0.2)
        if let subject = editableField(in: target, label: "Subject") { target.makeFirstResponder(subject) }
        typeInto("the composer's subject", in: target) { composer.subject }
        composer.focus(.body)
        pumpUntil { KeyRouter.textInput(in: target).map { !$0.isFieldEditor } ?? false }
        typeInto("the composer's body", in: target)
    }

    /// Types into the text field with this placeholder in the main window, given the keyboard by hand if
    /// offscreen SwiftUI didn't move it there.
    private func typeInto(_ placeholder: String, value: @escaping () -> String?) {
        func editing() -> Bool { (KeyRouter.textInput(in: window)?.delegate as? NSTextField)?.placeholderString == placeholder }
        if !pumpUntil(1, editing), let field = editableField(in: window, placeholder: placeholder) { window.makeFirstResponder(field) }
        guard pumpUntil(1, editing) else { return check("“\(placeholder)” takes the keyboard", false) }
        typeInto("“\(placeholder)”", in: window, value: value)
    }

    /// Types a burst, a key at a time, rolled-over keys and a held key into whatever has the keyboard in `target`,
    /// and checks the text after each. A field's text is selected and deleted first; a text view keeps its text.
    /// `value` is what the field is bound to, if anything.
    private func typeInto(_ name: String, in target: NSWindow, value: (() -> String?)? = nil) {
        let runs: [(name: String, typed: String, post: () -> Void)] = [
            ("a burst", "seaarr", { PostedKeys.type("seaarr", to: target) }),
            ("a burst", "the quick brown fox", { PostedKeys.type("the quick brown fox", to: target) }),
            ("a key at a time", "search", {
                for character in "search" {
                    PostedKeys.post(character, down: true, to: target)
                    self.pump(0.03)
                    PostedKeys.post(character, down: false, to: target)
                    self.pump(0.07)
                }
            }),
            ("rolled-over keys", "settings", {
                let keys = Array("settings")
                for (index, character) in keys.enumerated() {
                    PostedKeys.post(character, down: true, to: target)
                    if index > 0 { PostedKeys.post(keys[index - 1], down: false, to: target) }
                }
                if let last = keys.last { PostedKeys.post(last, down: false, to: target) }
            }),
            ("a held key", "rrrrrr", {
                PostedKeys.post("r", down: true, to: target)
                self.pump(0.2)
                for _ in 0..<5 {
                    PostedKeys.post("r", down: true, to: target, isARepeat: true)
                    self.pump(0.035)
                }
                PostedKeys.post("r", down: false, to: target)
            }),
        ]
        for run in runs {
            // Opening the reader can leave the window no longer key, and keys only reach the key window.
            target.makeKey()
            guard let text = KeyRouter.textInput(in: target) else { return check("\(name) keeps the keyboard", false) }
            // A correction bubble waits for a person in its own event loop, and would stop the check on a typo.
            text.isAutomaticSpellingCorrectionEnabled = false
            if text.isFieldEditor {
                text.selectAll(nil)
                text.delete(nil)
            }
            let expected = (text.string as NSString).replacingCharacters(in: text.selectedRange(), with: run.typed)
            run.post()
            pumpUntil { KeyRouter.textInput(in: target)?.string == expected }
            // Long enough for a late second copy to show.
            pump(0.15)
            let shown = KeyRouter.textInput(in: target)?.string
            let ok = shown == expected && (value == nil || value?() == shown)
            check("\(run.name) of “\(run.typed)” types it once into \(name)", ok)
            if !ok { print("    expected “\(expected.suffix(60))”, shows “\((shown ?? "no text").suffix(60))”, bound “\(value?() ?? "-")”") }
        }
    }

    private func orderIn(_ window: NSWindow) {
        NSApp.setActivationPolicy(.accessory)
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        window.makeKey()
    }

    private func orderOut(_ window: NSWindow) {
        window.orderOut(nil)
        window.alphaValue = 1
        window.ignoresMouseEvents = false
    }

    /// Dispatches events the way the app's own loop does, for `seconds`.
    func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            let next = NSApp.nextEvent(matching: .any, until: min(end, Date().addingTimeInterval(0.005)), inMode: .default, dequeue: true)
            if let next { NSApp.sendEvent(next) }
        } while Date() < end
    }

    @discardableResult
    func pumpUntil(_ timeout: TimeInterval = 1, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= end { return false }
            pump(0.01)
        }
        return true
    }

    private func editableTextView(in window: NSWindow) -> NSTextView? {
        func search(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, text.isEditable, !text.isFieldEditor { return text }
            return view.subviews.lazy.compactMap(search).first
        }
        return window.contentView.flatMap(search)
    }

    private func editableField(in window: NSWindow, placeholder: String? = nil, label: String? = nil) -> NSTextField? {
        func search(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable, placeholder.map({ field.placeholderString == $0 }) ?? true,
               label.map({ field.accessibilityLabel() == $0 }) ?? true {
                return field
            }
            return view.subviews.lazy.compactMap(search).first
        }
        return window.contentView.flatMap(search)
    }
}
