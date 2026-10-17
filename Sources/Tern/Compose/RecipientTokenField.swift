import AppKit
import TernCore

enum RecipientKind: String, Codable, CaseIterable {
    case to, cc, bcc

    var label: String {
        switch self {
        case .to: "To"
        case .cc: "Cc"
        case .bcc: "Bcc"
        }
    }
}

extension NSPasteboard.PasteboardType {
    static let ternRecipient = NSPasteboard.PasteboardType("dev.tern.recipient")
}

/// What a dragged token carries.
struct RecipientDrag: Codable {
    var participant: Participant
    var kind: RecipientKind
    var composerId: String
}

/// One recipient row's pills plus a text input after them. Typing a separator, Return or Tab turns text
/// into pills; Backspace on an empty input takes the last pill back for editing; pasted lists split;
/// pills drag between fields. Autocomplete shows under the input with ↑↓ / Return / Tab / Esc.
final class RecipientTokenField: NSView, NSTextFieldDelegate {
    let kind: RecipientKind
    let composerId: String
    let input = TokenInputField()

    var tokens: [Participant] = [] {
        didSet {
            guard tokens != oldValue else { return }
            rebuildTokenViews()
        }
    }
    var onChange: ([Participant]) -> Void = { _ in }
    /// Suggestions for a query, leaving out the addresses already present.
    var suggest: (String) -> [Participant] = { _ in [] }
    var onDrop: (RecipientDrag) -> Void = { _ in }
    var onTab: (_ forward: Bool) -> Void = { _ in }
    var onEscape: () -> Void = {}
    var onHeightChange: () -> Void = {}

    private var tokenViews: [TokenView] = []
    private var selectedIndex: Int? {
        didSet { for (index, view) in tokenViews.enumerated() { view.isSelected = index == selectedIndex } }
    }
    private let panel = SuggestionPanel()
    private var lastHeight: CGFloat = 0

    static let tokenHeight: CGFloat = 24
    static let spacing: CGFloat = 4
    static let verticalPadding: CGFloat = 8
    static let minInputWidth: CGFloat = 120

    init(kind: RecipientKind, composerId: String) {
        self.kind = kind
        self.composerId = composerId
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: 40))
        input.delegate = self
        input.owner = self
        input.setAccessibilityLabel(kind.label)
        addSubview(input)
        registerForDraggedTypes([.ternRecipient])
        panel.list.onPick = { [weak self] index in self?.pick(index) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    // MARK: Layout

    private func rebuildTokenViews() {
        tokenViews.forEach { $0.removeFromSuperview() }
        tokenViews = tokens.map { participant in
            let view = TokenView(participant: participant, field: self)
            addSubview(view)
            return view
        }
        if let selectedIndex, selectedIndex >= tokens.count { self.selectedIndex = nil }
        needsLayout = true
        reportHeight()
    }

    /// Frames for every pill and the input at a width, and the total height.
    private func arrangement(width: CGFloat) -> (tokens: [CGRect], input: CGRect, height: CGFloat) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y = Self.verticalPadding
        for view in tokenViews {
            let tokenWidth = min(view.preferredWidth, width)
            if x > 0, x + tokenWidth > width {
                x = 0
                y += Self.tokenHeight + Self.spacing
            }
            frames.append(CGRect(x: x, y: y, width: tokenWidth, height: Self.tokenHeight))
            x += tokenWidth + Self.spacing
        }
        if x > 0, width - x < Self.minInputWidth {
            x = 0
            y += Self.tokenHeight + Self.spacing
        }
        let inputHeight = input.intrinsicContentSize.height
        let inputFrame = CGRect(x: x + (x > 0 ? 2 : 0), y: y + (Self.tokenHeight - inputHeight) / 2,
                                width: max(40, width - x - 2), height: inputHeight)
        return (frames, inputFrame, y + Self.tokenHeight + Self.verticalPadding)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        arrangement(width: width).height
    }

    override func layout() {
        super.layout()
        let layout = arrangement(width: bounds.width)
        for (view, frame) in zip(tokenViews, layout.tokens) { view.frame = frame }
        input.frame = layout.input
    }

    private func reportHeight() {
        let height = height(forWidth: bounds.width)
        guard height != lastHeight else { return }
        lastHeight = height
        invalidateIntrinsicContentSize()
        onHeightChange()
    }

    override func mouseDown(with event: NSEvent) {
        selectedIndex = nil
        window?.makeFirstResponder(input)
    }

    // MARK: Editing

    /// Turns whatever is typed into pills.
    func commit() {
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input.stringValue = ""
        add(RecipientParser.parse(text))
        hideSuggestions()
    }

    func add(_ people: [Participant]) {
        var next = tokens
        for person in people where !next.contains(where: { $0.email.caseInsensitiveCompare(person.email) == .orderedSame }) {
            next.append(person)
        }
        guard next != tokens else { return }
        tokens = next
        onChange(tokens)
    }

    func remove(at index: Int) {
        guard tokens.indices.contains(index) else { return }
        tokens.remove(at: index)
        selectedIndex = nil
        onChange(tokens)
    }

    func select(_ view: TokenView) {
        selectedIndex = tokenViews.firstIndex { $0 === view }
        window?.makeFirstResponder(input)
    }

    /// Puts a pill back into the input as text.
    func edit(_ index: Int) {
        guard tokens.indices.contains(index) else { return }
        commit()
        let participant = tokens[index]
        remove(at: index)
        input.stringValue = RecipientParser.format(participant)
        window?.makeFirstResponder(input)
        input.currentEditor()?.selectedRange = NSRange(location: input.stringValue.utf16.count, length: 0)
    }

    func edit(_ view: TokenView) {
        if let index = tokenViews.firstIndex(where: { $0 === view }) { edit(index) }
    }

    func remove(_ view: TokenView) {
        if let index = tokenViews.firstIndex(where: { $0 === view }) { remove(at: index) }
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        selectedIndex = nil
        let text = input.stringValue
        if text.contains(where: RecipientParser.separators.contains) {
            let split = RecipientParser.splitCompleted(text)
            if !split.complete.isEmpty || split.remainder != text {
                input.stringValue = split.remainder
                add(split.complete.compactMap(RecipientParser.participant))
            }
        }
        updateSuggestions()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        commit()
        hideSuggestions()
        selectedIndex = nil
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let empty = input.stringValue.isEmpty
        switch selector {
        case #selector(NSResponder.moveDown(_:)) where panel.isVisible:
            panel.list.move(1)
        case #selector(NSResponder.moveUp(_:)) where panel.isVisible:
            panel.list.move(-1)
        case #selector(NSResponder.insertNewline(_:)):
            if panel.isVisible { pick(panel.list.highlighted) } else if !empty { commit() } else { onTab(true) }
        case #selector(NSResponder.insertTab(_:)):
            if panel.isVisible { pick(panel.list.highlighted) } else { commit(); onTab(true) }
        case #selector(NSResponder.insertBacktab(_:)):
            commit()
            onTab(false)
        case #selector(NSResponder.cancelOperation(_:)):
            if panel.isVisible { hideSuggestions() } else if selectedIndex != nil { selectedIndex = nil } else { onEscape() }
        case #selector(NSResponder.deleteBackward(_:)) where empty:
            if let selectedIndex { remove(at: selectedIndex) } else if !tokens.isEmpty { edit(tokens.count - 1) } else { return false }
        case #selector(NSResponder.deleteForward(_:)) where empty && selectedIndex != nil:
            remove(at: selectedIndex!)
        case #selector(NSResponder.moveLeft(_:)) where empty && !tokens.isEmpty:
            selectedIndex = max(0, (selectedIndex ?? tokens.count) - 1)
        case #selector(NSResponder.moveRight(_:)) where selectedIndex != nil:
            selectedIndex = selectedIndex! + 1 < tokens.count ? selectedIndex! + 1 : nil
        default:
            return false
        }
        return true
    }

    // MARK: Suggestions

    private func updateSuggestions() {
        let query = input.stringValue.trimmingCharacters(in: .whitespaces)
        let items = query.isEmpty ? [] : suggest(query)
        guard !items.isEmpty, let window, input.currentEditor() != nil else {
            hideSuggestions()
            return
        }
        panel.list.items = items
        let anchor = window.convertToScreen(input.convert(input.bounds, to: nil))
        panel.show(below: anchor, parent: window)
    }

    private func pick(_ index: Int) {
        guard panel.list.items.indices.contains(index) else { return }
        let person = panel.list.items[index]
        input.stringValue = ""
        hideSuggestions()
        add([person])
    }

    func hideSuggestions() {
        panel.dismiss()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { hideSuggestions() }
        super.viewWillMove(toWindow: newWindow)
    }

    // MARK: Drops

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.data(forType: .ternRecipient) == nil ? [] : .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let data = sender.draggingPasteboard.data(forType: .ternRecipient),
              let drag = try? JSONDecoder().decode(RecipientDrag.self, from: data) else { return false }
        guard drag.kind != kind || drag.composerId != composerId else { return false }
        onDrop(drag)
        return true
    }
}

/// The text input after the pills: borderless, no focus ring.
final class TokenInputField: NSTextField {
    weak var owner: RecipientTokenField?

    convenience init() {
        self.init(frame: .zero)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = Theme.ui(13)
        textColor = Theme.text1
        cell?.usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
        lineBreakMode = .byClipping
    }
}

/// One recipient token. An address that doesn't parse gets a dashed outline instead of a fill.
final class TokenView: NSView, NSDraggingSource {
    let participant: Participant
    weak var field: RecipientTokenField?
    var isSelected = false { didSet { needsDisplay = true } }
    let isValid: Bool

    private var title: NSAttributedString {
        NSAttributedString(string: participant.name.isEmpty ? participant.email : participant.name, attributes: [
            .font: Theme.ui(13), .foregroundColor: isValid ? Theme.text1 : Theme.text2,
        ])
    }

    init(participant: Participant, field: RecipientTokenField) {
        self.participant = participant
        self.field = field
        self.isValid = RecipientParser.isValidEmail(participant.email)
        super.init(frame: .zero)
        toolTip = isValid ? RecipientParser.format(participant) : "“\(participant.email)” doesn't look like an address"
        setAccessibilityRole(.button)
        setAccessibilityLabel(RecipientParser.format(participant))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var preferredWidth: CGFloat { ceil(title.size().width) + 20 }

    override func draw(_ dirtyRect: NSRect) {
        if isValid {
            let path = NSBezierPath(roundedRect: bounds, xRadius: Theme.Radius.chip, yRadius: Theme.Radius.chip)
            (isSelected ? Theme.hairlineStrong : Theme.pill).setFill()
            path.fill()
        } else {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Theme.Radius.chip, yRadius: Theme.Radius.chip)
            if isSelected {
                Theme.pill.setFill()
                path.fill()
            }
            path.lineWidth = 1
            path.setLineDash([3, 2], count: 2, phase: 0)
            Theme.text2.setStroke()
            path.stroke()
        }
        let text = title
        let size = text.size()
        let rect = CGRect(x: 10, y: (bounds.height - size.height) / 2, width: bounds.width - 20, height: size.height)
        text.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { field?.edit(self) } else { field?.select(self) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let field, let data = try? JSONEncoder().encode(RecipientDrag(participant: participant, kind: field.kind, composerId: field.composerId)) else { return }
        let item = NSPasteboardItem()
        item.setData(data, forType: .ternRecipient)
        item.setString(RecipientParser.format(participant), forType: .string)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        dragging.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : .copy
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Edit", action: #selector(editToken), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy Address", action: #selector(copyAddress), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Remove", action: #selector(removeToken), keyEquivalent: "").target = self
        return menu
    }

    @objc private func editToken() { field?.edit(self) }
    @objc private func removeToken() { field?.remove(self) }
    @objc private func copyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(RecipientParser.format(participant), forType: .string)
    }
}

// MARK: - Autocomplete

/// A borderless child panel under the input; it never takes focus, so typing continues in the field.
final class SuggestionPanel: NSPanel {
    let list = SuggestionListView()

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 320, height: 100), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = Theme.Radius.card
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        contentView = container
        container.addSubview(list)
        list.autoresizingMask = [.width, .height]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(below anchor: CGRect, parent: NSWindow) {
        appearance = parent.effectiveAppearance
        contentView?.layer?.backgroundColor = Theme.raised.resolved(for: parent.effectiveAppearance).cgColor
        contentView?.layer?.borderColor = Theme.hairline.resolved(for: parent.effectiveAppearance).cgColor
        let size = list.fittingHeight
        let frame = CGRect(x: anchor.minX - 10, y: anchor.minY - size - 8, width: 320, height: size)
        setFrame(frame, display: true)
        list.frame = contentView?.bounds ?? .zero
        list.needsDisplay = true
        if parent.childWindows?.contains(self) != true { parent.addChildWindow(self, ordered: .above) }
        orderFront(nil)
        invalidateShadow()
    }

    func dismiss() {
        guard isVisible else { return }
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

/// Rows of "Name  address", one highlighted; click or Return picks.
final class SuggestionListView: NSView {
    var items: [Participant] = [] {
        didSet {
            highlighted = 0
            needsDisplay = true
        }
    }
    private(set) var highlighted = 0
    var onPick: (Int) -> Void = { _ in }

    static let rowHeight: CGFloat = 34
    static let inset: CGFloat = 6

    var fittingHeight: CGFloat { CGFloat(items.count) * Self.rowHeight + Self.inset * 2 }

    override var isFlipped: Bool { true }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        highlighted = (highlighted + delta + items.count) % items.count
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, person) in items.enumerated() {
            let row = CGRect(x: Self.inset, y: Self.inset + CGFloat(index) * Self.rowHeight, width: bounds.width - Self.inset * 2, height: Self.rowHeight)
            if index == highlighted {
                Theme.selected.setFill()
                NSBezierPath(roundedRect: row, xRadius: Theme.Radius.row, yRadius: Theme.Radius.row).fill()
            }
            let line = NSMutableAttributedString(string: person.name.isEmpty ? person.email : person.name, attributes: [
                .font: Theme.ui(13, .medium), .foregroundColor: Theme.text1,
            ])
            if !person.name.isEmpty {
                line.append(NSAttributedString(string: "  \(person.email)", attributes: [.font: Theme.ui(12), .foregroundColor: Theme.text3]))
            }
            let size = line.size()
            line.draw(with: CGRect(x: row.minX + 10, y: row.minY + (row.height - size.height) / 2, width: row.width - 20, height: size.height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = Int((point.y - Self.inset) / Self.rowHeight)
        if items.indices.contains(index) { onPick(index) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension NSColor {
    /// The colour as it resolves under an appearance, for CALayer use.
    func resolved(for appearance: NSAppearance) -> NSColor {
        var color = self
        appearance.performAsCurrentDrawingAppearance { color = self.usingColorSpace(.sRGB) ?? self }
        return color
    }
}
