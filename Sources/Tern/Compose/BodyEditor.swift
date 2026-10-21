import AppKit
import SwiftUI
import TernCore

/// The composer body: a TextKit 2 `NSTextView` inside a scroll view, with the signature, quote pill and
/// attachments laid out under the text in the same scrolling document.
@MainActor
final class BodyEditorController: NSObject, NSTextViewDelegate {
    let textView: BodyTextView
    let document: EditorDocumentView
    let scrollView: EditorScrollView

    var onChange: () -> Void = {}
    var onEscape: () -> Void = {}
    var onBacktab: () -> Void = {}
    var onFiles: ([URL]) -> Void = { _ in }
    var onImage: (Data, String) -> Void = { _, _ in }
    /// Height of text plus accessory, for editors that grow with their content.
    var onHeightChange: (CGFloat) -> Void = { _ in }
    /// The picture for an inline image's `src`; nil shows a placeholder until `reloadImages()`.
    var imageSource: (String) -> NSImage? = { _ in nil }

    private let layoutDelegate = EditorLayoutDelegate()
    private let imageParagraphs = InlineImageParagraphs()
    private var formattingBar: NSHostingView<FormattingBar>?
    /// The bar's edge toward the selection (it sits above it, or below near the top).
    private var barAnchor: UnitPoint = .bottom
    private var formattingTimer: Timer?
    private var linkPopover: NSPopover?

    init(insets: NSSize, minTextHeight: CGFloat) {
        textView = BodyTextView(usingTextLayoutManager: true)
        document = EditorDocumentView(textView: textView, minTextHeight: minTextHeight)
        scrollView = EditorScrollView()
        super.init()

        textView.editor = self
        textView.delegate = self
        textView.textLayoutManager?.delegate = layoutDelegate
        textView.textContentStorage?.delegate = imageParagraphs
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = insets
        textView.isRichText = true
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.typingAttributes = EditorStyle.attributes()
        textView.insertionPointColor = Theme.text1
        textView.selectedTextAttributes = [.backgroundColor: Theme.hairlineStrong]
        textView.linkTextAttributes = [
            .foregroundColor: Theme.ink, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.iBeam,
        ]
        textView.setAccessibilityLabel("Message body")

        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.contentView.postsFrameChangedNotifications = true
        document.onHeightChange = { [weak self] in self?.onHeightChange($0) }
    }

    // MARK: Content

    var richText: RichText {
        get { RichTextBridge.richText(textView.attributedString()) }
        set {
            textView.textStorage?.setAttributedString(RichTextBridge.attributedString(newValue, images: imageSource))
            textView.typingAttributes = EditorStyle.attributes()
            textView.undoManager?.removeAllActions()
            contentDidChange()
        }
    }

    var plainText: String { textView.string }

    /// Replaces the whole body as one undoable edit (AI drafts).
    /// Replaces the body with `text`. `crossfade` blends the old text into the new over 180 ms (80 ms with Reduce
    /// Motion), for an AI draft landing; edits and undo stay instant.
    func replaceBody(with text: RichText, crossfade: Bool = false) {
        if crossfade, let layer = scrollView.layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.08 : 0.18
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: kCATransition)
        }
        let range = NSRange(location: 0, length: textView.textStorage?.length ?? 0)
        let replacement = RichTextBridge.attributedString(text, images: imageSource)
        guard textView.shouldChangeText(in: range, replacementString: replacement.string) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: replacement.length, length: 0))
    }

    /// Draws the inline images again from `imageSource`, e.g. once their files have arrived. Not an edit.
    func reloadImages() {
        guard let storage = textView.textStorage else { return }
        var images: [(NSRange, NSTextAttachment)] = []
        storage.enumerateAttribute(.ternImage, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let source = value as? String else { return }
            images.append((range, InlineImages.textAttachment(imageSource(source))))
        }
        guard !images.isEmpty else { return }
        storage.beginEditing()
        for (range, attachment) in images { storage.addAttribute(.attachment, value: attachment, range: range) }
        storage.endEditing()
        if let manager = textView.textLayoutManager { manager.invalidateLayout(for: manager.documentRange) }
        document.relayout()
    }

    /// Lays the SwiftUI accessory (signature, quote, attachments) under the text.
    func setAccessory<Content: View>(_ view: Content) {
        document.setAccessory(AnyView(view))
    }

    /// Call when the accessory's content changed size.
    func accessoryChanged() {
        document.relayout()
    }

    func focus(atEnd: Bool = false) {
        textView.window?.makeFirstResponder(textView)
        if atEnd { textView.setSelectedRange(NSRange(location: textView.textStorage?.length ?? 0, length: 0)) }
    }

    var isFocused: Bool { textView.window?.firstResponder === textView }

    private func contentDidChange() {
        document.relayout()
        hideFormattingBar()
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        if textView.textStorage.map(EditorLayout.containsNumbered) == true, let manager = textView.textLayoutManager {
            manager.invalidateLayout(for: manager.documentRange)
        }
        contentDidChange()
        textView.scrollRangeToVisible(textView.selectedRange())
        onChange()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        formattingTimer?.invalidate()
        guard textView.selectedRange().length > 0, isFocused else {
            hideFormattingBar()
            return
        }
        formattingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.showFormattingBar() }
        }
        textView.needsDisplay = true
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        // Links open with ⌘-click; a plain click just places the caret, as in any editor.
        if NSEvent.modifierFlags.contains(.command), let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) {
            NSWorkspace.shared.open(url)
        }
        return true
    }

    // MARK: Formatting

    enum Trait { case bold, italic, underline }

    /// Toggles a trait on the selection, or on what is typed next.
    func toggle(_ trait: Trait) {
        let range = textView.selectedRange()
        guard let storage = textView.textStorage else { return }
        func flip(_ attributes: inout [NSAttributedString.Key: Any], on: Bool) {
            switch trait {
            case .bold: attributes[.ternBold] = on ? true : nil
            case .italic: attributes[.ternItalic] = on ? true : nil
            case .underline: attributes[.underlineStyle] = on ? NSUnderlineStyle.single.rawValue : nil
            }
            attributes = EditorStyle.normalized(attributes)
        }
        func has(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
            let style = EditorStyle.style(of: attributes)
            switch trait {
            case .bold: return style.contains(.bold)
            case .italic: return style.contains(.italic)
            case .underline: return style.contains(.underline)
            }
        }
        guard range.length > 0 else {
            var attributes = textView.typingAttributes
            flip(&attributes, on: !has(attributes))
            textView.typingAttributes = attributes
            return
        }
        var all = true
        storage.enumerateAttributes(in: range) { attributes, _, stop in
            if !has(attributes) { all = false; stop.pointee = true }
        }
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttributes(in: range) { attributes, subrange, _ in
            var attributes = attributes
            flip(&attributes, on: !all)
            storage.setAttributes(attributes, range: subrange)
        }
        storage.endEditing()
        textView.didChangeText()
        refreshFormattingBar()
    }

    /// Makes the paragraphs touched by the selection a list, a quote, or plain again (toggling back
    /// when they already are that kind).
    func toggleBlock(_ kind: RichText.BlockKind) {
        let current = currentBlock
        setBlock(current == kind ? .paragraph : kind)
    }

    var currentBlock: RichText.BlockKind {
        let storage = textView.textStorage
        let location = textView.selectedRange().location
        if let storage, location < storage.length {
            let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
            return EditorStyle.block(of: storage.attributes(at: paragraph.location, effectiveRange: nil))
        }
        return EditorStyle.block(of: textView.typingAttributes)
    }

    func setBlock(_ kind: RichText.BlockKind) {
        guard let storage = textView.textStorage else { return }
        let paragraphs = (storage.string as NSString).paragraphRange(for: textView.selectedRange())
        var typing = textView.typingAttributes
        typing[.ternBlock] = kind.rawValue
        textView.typingAttributes = EditorStyle.normalized(typing)
        if paragraphs.length > 0, textView.shouldChangeText(in: paragraphs, replacementString: nil) {
            storage.beginEditing()
            storage.enumerateAttributes(in: paragraphs) { attributes, subrange, _ in
                var attributes = attributes
                attributes[.ternBlock] = kind.rawValue
                storage.setAttributes(EditorStyle.normalized(attributes), range: subrange)
            }
            storage.endEditing()
            textView.didChangeText()
        }
        if let manager = textView.textLayoutManager { manager.invalidateLayout(for: manager.documentRange) }
        textView.needsDisplay = true
        refreshFormattingBar()
    }

    /// The link under the caret or selection, with its full range.
    private func linkAtSelection() -> (url: String, range: NSRange)? {
        guard let storage = textView.textStorage, storage.length > 0 else { return nil }
        let selection = textView.selectedRange()
        let location = min(selection.location, storage.length - 1)
        var range = NSRange()
        guard let link = EditorStyle.linkString(storage.attribute(.link, at: location, longestEffectiveRange: &range,
                                                                     in: NSRange(location: 0, length: storage.length))) else { return nil }
        return (link, range)
    }

    /// ⌘K: a small popover to add, edit or remove the link on the selection.
    func editLink() {
        hideFormattingBar()
        let existing = linkAtSelection()
        let selection = textView.selectedRange()
        let target = existing?.range ?? selection
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: LinkEditor(
            url: existing?.url ?? "",
            canRemove: existing != nil,
            apply: { [weak self, weak popover] url in
                self?.applyLink(url, range: target)
                popover?.close()
            },
            remove: { [weak self, weak popover] in
                self?.applyLink(nil, range: target)
                popover?.close()
            }))
        var rect = textView.firstRect(forCharacterRange: target, actualRange: nil)
        if let window = textView.window {
            rect = textView.convert(window.convertFromScreen(rect), from: nil)
        }
        linkPopover = popover
        popover.show(relativeTo: rect.isEmpty ? textView.bounds : rect, of: textView, preferredEdge: .maxY)
    }

    private func applyLink(_ link: String?, range: NSRange) {
        guard let storage = textView.textStorage else { return }
        var link = link?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = link, !value.isEmpty, URL(string: value)?.scheme == nil {
            link = RecipientParser.isValidEmail(value) ? "mailto:\(value)" : "https://\(value)"
        }
        let url = link.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        if range.length == 0 {
            guard let url else { return }
            var attributes = textView.typingAttributes
            attributes[.link] = url
            let text = NSAttributedString(string: url.absoluteString.replacingOccurrences(of: "mailto:", with: ""), attributes: attributes)
            textView.insertText(text, replacementRange: range)
            return
        }
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        if let url { storage.addAttribute(.link, value: url, range: range) } else { storage.removeAttribute(.link, range: range) }
        textView.didChangeText()
        textView.window?.makeFirstResponder(textView)
    }

    // MARK: Formatting bar

    private var formattingState: FormattingBar.State {
        var state = FormattingBar.State(block: currentBlock)
        if let storage = textView.textStorage, textView.selectedRange().length > 0 {
            var bold = true, italic = true, underline = true
            storage.enumerateAttributes(in: textView.selectedRange()) { attributes, _, _ in
                let style = EditorStyle.style(of: attributes)
                bold = bold && style.contains(.bold)
                italic = italic && style.contains(.italic)
                underline = underline && style.contains(.underline)
            }
            state.bold = bold
            state.italic = italic
            state.underline = underline
            state.link = linkAtSelection() != nil
        }
        return state
    }

    private func makeBar() -> FormattingBar {
        FormattingBar(state: formattingState, anchor: barAnchor) { [weak self] action in
            guard let self else { return }
            switch action {
            case .bold: toggle(.bold)
            case .italic: toggle(.italic)
            case .underline: toggle(.underline)
            case .link: editLink()
            case .bullet: toggleBlock(.bullet)
            case .numbered: toggleBlock(.numbered)
            case .quote: toggleBlock(.quote)
            }
        }
    }

    func showFormattingBar() {
        guard textView.selectedRange().length > 0, let window = textView.window else { return }
        // A bar coming back is a new view, so it fades in again; one already showing just moves, at once.
        let showing = formattingBar.flatMap { $0.superview == nil ? nil : $0 }
        let bar = showing ?? NSHostingView(rootView: makeBar())
        formattingBar = bar
        if bar.superview == nil { document.addSubview(bar) }
        let size = bar.fittingSize
        let screenRect = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
        let rect = document.convert(window.convertFromScreen(screenRect), from: nil)
        // The bar view carries `FormattingBar.shadowRoom` of transparent margin for its shadow.
        let room = FormattingBar.shadowRoom
        let x = min(max(8 - room, rect.minX - room), document.bounds.width - size.width + room - 8)
        let above = rect.minY - (size.height - room * 2) - 6
        let below = above < scrollView.documentVisibleRect.minY
        let y = below ? rect.maxY + 6 - room : above - room
        barAnchor = below ? .top : .bottom
        bar.rootView = makeBar()
        bar.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func refreshFormattingBar() {
        guard let bar = formattingBar, bar.superview != nil else { return }
        bar.rootView = makeBar()
    }

    func hideFormattingBar() {
        formattingTimer?.invalidate()
        formattingBar?.removeFromSuperview()
    }
}

enum EditorLayout {
    static func containsNumbered(_ storage: NSAttributedString) -> Bool {
        var found = false
        storage.enumerateAttribute(.ternBlock, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            if value as? String == RichText.BlockKind.numbered.rawValue { found = true; stop.pointee = true }
        }
        return found
    }
}

// MARK: - Text view

final class BodyTextView: NSTextView {
    weak var editor: BodyEditorController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let editor else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if modifiers == .command {
            switch key {
            case "b": editor.toggle(.bold); return true
            case "i": editor.toggle(.italic); return true
            case "u": editor.toggle(.underline); return true
            case "k": editor.editLink(); return true
            default: break
            }
        }
        if modifiers == [.command, .shift] {
            switch event.keyCode {
            case 26: editor.toggleBlock(.numbered); return true // 7
            case 28: editor.toggleBlock(.bullet); return true // 8
            case 25: editor.toggleBlock(.quote); return true // 9
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    private var paragraphRange: NSRange {
        (string as NSString).paragraphRange(for: NSRange(location: selectedRange().location, length: 0))
    }

    private var paragraphIsEmpty: Bool {
        let range = paragraphRange
        return (string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Return in an empty list item or quote line leaves the list; otherwise the paragraph's kind carries on.
    override func insertNewline(_ sender: Any?) {
        if let editor, editor.currentBlock != .paragraph, paragraphIsEmpty, selectedRange().length == 0 {
            editor.setBlock(.paragraph)
            return
        }
        super.insertNewline(sender)
    }

    /// Backspace at the start of a list item or quote turns it back into a paragraph first.
    override func deleteBackward(_ sender: Any?) {
        if let editor, selectedRange().length == 0, selectedRange().location == paragraphRange.location,
           editor.currentBlock != .paragraph {
            editor.setBlock(.paragraph)
            return
        }
        super.deleteBackward(sender)
    }

    /// "- ", "* ", "1. " and "> " at the start of a paragraph start a list or a quote.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string
        guard typed?.hasSuffix(" ") == true, let editor, editor.currentBlock == .paragraph else { return }
        let caret = selectedRange().location
        let start = paragraphRange.location
        guard caret > start, caret - start <= 3 else { return }
        let prefixRange = NSRange(location: start, length: caret - start)
        let prefix = (self.string as NSString).substring(with: prefixRange)
        let kind: RichText.BlockKind? = switch prefix {
        case "- ", "* ": .bullet
        case "1. ": .numbered
        case "> ": .quote
        default: nil
        }
        guard let kind, shouldChangeText(in: prefixRange, replacementString: "") else { return }
        textStorage?.replaceCharacters(in: prefixRange, with: "")
        didChangeText()
        setSelectedRange(NSRange(location: start, length: 0))
        editor.setBlock(kind)
    }

    override func cancelOperation(_ sender: Any?) {
        editor?.hideFormattingBar()
        editor?.onEscape()
    }

    /// The formatting bar goes when another field takes the caret (clicks on the bar itself don't).
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        DispatchQueue.main.async { [weak self] in
            guard let self, let responder = self.window?.firstResponder, responder !== self, responder is NSText else { return }
            self.editor?.hideFormattingBar()
        }
        return resigned
    }

    override func insertBacktab(_ sender: Any?) {
        editor?.onBacktab()
    }

    // MARK: Paste and drops

    override func paste(_ sender: Any?) {
        pasteContents(of: .general)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string) { insertPlain(text) }
    }

    /// Files become attachments, images too; HTML and RTF keep only text, links and emphasis.
    func pasteContents(of pasteboard: NSPasteboard) {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            editor?.onFiles(urls)
            return
        }
        let hasText = pasteboard.availableType(from: [.html, .rtf, .string]) != nil
        if !hasText, let image = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff).flatMap(Self.pngData) {
            editor?.onImage(image, "Pasted image.png")
            return
        }
        var rich: RichText?
        if let html = pasteboard.string(forType: .html) {
            rich = RichText(html: html)
        } else if let rtf = pasteboard.data(forType: .rtf), let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            rich = RichTextBridge.richText(fromForeign: attributed)
        }
        if let rich, !rich.isEmpty {
            insertRich(rich)
        } else if let text = pasteboard.string(forType: .string) {
            insertPlain(text)
        }
    }

    private func insertPlain(_ text: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        insertText(NSAttributedString(string: normalized, attributes: EditorStyle.normalized(typingAttributes)), replacementRange: selectedRange())
    }

    /// The first pasted block joins the current paragraph; the rest keep their own kinds.
    private func insertRich(_ text: RichText) {
        guard let editor else { return }
        var blocks = text.blocks
        while blocks.last?.runs.isEmpty == true, blocks.count > 1 { blocks.removeLast() }
        if !blocks.isEmpty { blocks[0].kind = editor.currentBlock }
        insertText(RichTextBridge.attributedString(RichText(blocks)), replacementRange: selectedRange())
    }

    static func pngData(_ tiff: Data) -> Data? {
        NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL]
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.fileURLs(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.fileURLs(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        editor?.onFiles(urls)
        return true
    }

    static func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    // MARK: Drawing

    /// The trailing empty line has no characters to carry a list fragment, so its marker is drawn here.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let storage = textStorage, let manager = textLayoutManager else { return }
        let length = storage.length
        guard selectedRange().location == length,
              length == 0 || (storage.string as NSString).character(at: length - 1) == 10 else { return }
        let kind = EditorStyle.block(of: typingAttributes)
        guard kind == .bullet || kind == .numbered else { return }
        var marker = "•"
        if kind == .numbered {
            var number = 1
            var cursor = length
            let text = storage.string as NSString
            while cursor > 0 {
                let previous = text.paragraphRange(for: NSRange(location: cursor - 1, length: 0))
                guard EditorStyle.block(of: storage.attributes(at: previous.location, effectiveRange: nil)) == .numbered else { break }
                number += 1
                cursor = previous.location
            }
            marker = "\(number)."
        }
        var lineTop: CGFloat?
        manager.enumerateTextLayoutFragments(
            from: manager.documentRange.endLocation, options: [.ensuresExtraLineFragment, .ensuresLayout, .reverse]
        ) { fragment in
            lineTop = fragment.layoutFragmentFrame.minY + (fragment.textLineFragments.last?.typographicBounds.minY ?? 0)
            return false
        }
        guard let lineTop else { return }
        ListMarkerDrawing.draw(marker, textStart: CGPoint(x: textContainerOrigin.x + EditorStyle.listIndent, y: lineTop + textContainerOrigin.y))
    }

    /// Height the text needs at the current width.
    var contentHeight: CGFloat {
        guard let manager = textLayoutManager else { return 0 }
        manager.ensureLayout(for: manager.documentRange)
        var height = manager.usageBoundsForTextContainer.maxY
        manager.enumerateTextLayoutFragments(
            from: manager.documentRange.endLocation, options: [.ensuresExtraLineFragment, .ensuresLayout, .reverse]
        ) { fragment in
            height = max(height, fragment.layoutFragmentFrame.maxY)
            return false
        }
        return ceil(max(height, EditorStyle.lineHeight)) + textContainerInset.height * 2
    }
}

// MARK: - Document and scroll view

/// The scrolling document: the text view, then the accessory, then a little room.
final class EditorDocumentView: NSView {
    let textView: BodyTextView
    var minTextHeight: CGFloat
    var onHeightChange: (CGFloat) -> Void = { _ in }
    private var accessory: NSHostingController<AnyView>?
    private var lastHeight: CGFloat = -1

    init(textView: BodyTextView, minTextHeight: CGFloat) {
        self.textView = textView
        self.minTextHeight = minTextHeight
        super.init(frame: CGRect(x: 0, y: 0, width: 480, height: minTextHeight))
        addSubview(textView)
        textView.frame = bounds
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func setAccessory(_ view: AnyView) {
        if let accessory {
            accessory.rootView = view
        } else {
            let controller = NSHostingController(rootView: view)
            controller.sizingOptions = []
            addSubview(controller.view)
            accessory = controller
        }
        relayout()
    }

    /// The visible height of the enclosing scroll view.
    private var clipHeight: CGFloat { enclosingScrollView?.contentSize.height ?? 0 }

    func relayout() {
        let width = enclosingScrollView?.contentSize.width ?? frame.width
        guard width > 0 else { return }
        if textView.frame.width != width { textView.frame.size.width = width }
        var accessoryHeight: CGFloat = 0
        if let accessory {
            accessoryHeight = accessory.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        }
        let textHeight = max(textView.contentHeight, minTextHeight)
        textView.frame = CGRect(x: 0, y: 0, width: width, height: textHeight)
        accessory?.view.frame = CGRect(x: 0, y: textHeight, width: width, height: accessoryHeight)
        let natural = textHeight + accessoryHeight
        setFrameSize(NSSize(width: width, height: max(textHeight + accessoryHeight, clipHeight)))
        if natural != lastHeight {
            lastHeight = natural
            onHeightChange(natural)
        }
    }

    /// Clicks in empty space below the text put the caret at the end.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: textView.textStorage?.length ?? 0, length: 0))
    }
}

final class EditorScrollView: NSScrollView {
    override func tile() {
        super.tile()
        (documentView as? EditorDocumentView)?.relayout()
    }
}

/// Hosts the editor's scroll view in SwiftUI.
struct BodyEditorView: NSViewRepresentable {
    let controller: BodyEditorController

    func makeNSView(context: Context) -> EditorScrollView { controller.scrollView }
    func updateNSView(_ nsView: EditorScrollView, context: Context) {}
}

// MARK: - Formatting bar and link editor

struct FormattingBar: View {
    struct State {
        var block: RichText.BlockKind
        var bold = false
        var italic = false
        var underline = false
        var link = false
    }

    enum Action { case bold, italic, underline, link, bullet, numbered, quote }

    static let shadowRoom: CGFloat = 14

    let state: State
    /// The edge toward the selection, where the bar grows from.
    var anchor: UnitPoint = .bottom
    let perform: (Action) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SwiftUI.State private var shown = false

    var body: some View {
        HStack(spacing: 2) {
            button(.bold, .bold, on: state.bold, help: "Bold  ⌘B")
            button(.italic, .italic, on: state.italic, help: "Italic  ⌘I")
            button(.underline, .underline, on: state.underline, help: "Underline  ⌘U")
            button(.link, .link, on: state.link, help: "Link  ⌘K")
            Rectangle().fill(Color(Theme.hairline)).frame(width: 1, height: 16).padding(.horizontal, 3)
            button(.listBullet, .bullet, on: state.block == .bullet, help: "Bulleted list  ⌘⇧8")
            button(.listNumber, .numbered, on: state.block == .numbered, help: "Numbered list  ⌘⇧7")
            button(.quote, .quote, on: state.block == .quote, help: "Quote  ⌘⇧9")
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.overlay, style: .continuous).fill(Color(Theme.raised)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.overlay, style: .continuous).strokeBorder(Color(Theme.hairlineStrong)))
        .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
        // First show: fades in and grows from 97 % toward the selection over 120 ms (a fade with Reduce Motion).
        // Moving to a new selection and hiding are instant.
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown || reduceMotion ? 1 : 0.97, anchor: anchor)
        .padding(Self.shadowRoom)
        .fixedSize()
        .onAppear { withAnimation(Motion.or(reduced: reduceMotion, Motion.ease(Motion.popover))) { shown = true } }
    }

    private func button(_ icon: Icon, _ action: Action, on: Bool, help: String) -> some View {
        Button { perform(action) } label: {
            IconView(icon: icon, size: 15, color: Color(on ? Theme.text1 : Theme.text2))
                .frame(width: 26, height: Theme.Control.small)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Color(on ? Theme.selected : .clear)))
        }
        .buttonStyle(IconButtonStyle())
        .help(help)
    }
}

struct LinkEditor: View {
    @SwiftUI.State var url: String
    let canRemove: Bool
    let apply: (String) -> Void
    let remove: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Paste or type a link", text: $url)
                .textFieldStyle(.plain)
                .font(.ui(13))
                .frame(width: 240)
                .focused($focused)
                .onAppear { focused = true }
                .onSubmit { apply(url) }
            if canRemove {
                Button("Remove", action: remove)
                    .buttonStyle(TernButtonStyle(.quiet, size: .small))
            }
            Button("Apply") { apply(url) }
                .buttonStyle(TernButtonStyle(.primary, size: .small))
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }
}
