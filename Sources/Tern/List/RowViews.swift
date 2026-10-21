import AppKit
import TernCore

/// Row layouts: one line when the list is wide, at 40 pt (32 pt when compact); two lines at 56 pt in a
/// narrow list (the reading pane).
enum RowStyle: Equatable {
    case compact, oneLine, twoLines

    var height: CGFloat {
        switch self {
        case .compact: 32
        case .oneLine: 40
        case .twoLines: 56
        }
    }

    /// Compact and one-line rows share a layout; only their height differs.
    var isSingleLine: Bool { self != .twoLines }

    static func resolve(_ density: Density, width: CGFloat) -> RowStyle {
        guard width >= 600 else { return .twoLines }
        return density == .compact ? .compact : .oneLine
    }
}

/// The picture at the start of a row: the sender's domain logo, or initials.
enum RowAvatar: Equatable {
    case logo(NSImage)
    /// Initials on the neutral disc.
    case letters(String)

    static func == (a: RowAvatar, b: RowAvatar) -> Bool {
        switch (a, b) {
        case (.logo(let x), .logo(let y)): x === y
        case (.letters(let x), .letters(let y)): x == y
        default: false
        }
    }
}

/// The account a row's mail is for, shown as a dot in its hue on the avatar while several accounts
/// share the list.
struct RowAccount: Equatable {
    var colorIndex: Int
    /// "Personal · maya@gmail.com", the dot's tooltip.
    var help: String
}

/// A tag on a row: a softly filled chip with a small coloured icon and the label in `text2`.
struct RowChip: Equatable {
    enum Tint: Equatable {
        case ink
        case category(MailCategory)
        case project(Int)
    }

    var text: String
    var icon: Icon
    var tint: Tint

    var color: NSColor {
        switch tint {
        case .ink: Theme.ink
        case .category(let category): Theme.categoryColor(category)
        case .project(let index): Theme.projectColor(index)
        }
    }
}

/// Everything a thread row draws, gathered by the list controller. Colours are resolved at draw time,
/// so equal models compare equal and j/k repaints only the rows that changed.
struct RowModel: Equatable {
    var row: ThreadRow
    var style: RowStyle
    var isSelected = false
    /// The cursor row while the list has the keyboard: its fill is a step stronger.
    var hasFocus = false
    var isHovered = false
    /// Selected and next to selected rows: the fills join into one block.
    var joinsAbove = false
    var joinsBelow = false
    /// This row or the one below it is filled, so the line between them goes.
    var hidesHairline = false
    var avatar = RowAvatar.letters("?")
    var account: RowAccount?
    var chips: [RowChip] = []
    /// Replaces the compact time (snoozed list shows when it wakes).
    var timeOverride: String?
    var dimmed = false
    /// While searching: the matched words, and the excerpt shown in place of the preview.
    var highlight: RowHighlight?
}

/// A message-list row, drawn in one pass (no subviews) so scrolling 50k threads stays smooth.
final class ThreadRowView: NSTableRowView {
    /// Redraws only when something visible changed, so j/k repaints two rows, not the screen.
    var model: RowModel? {
        didSet {
            guard model != oldValue else { return }
            needsDisplay = true
            if model?.account != oldValue?.account || model?.style != oldValue?.style { updateToolTip() }
        }
    }

    /// Space inside the column before the avatar and after the time.
    static let padding: CGFloat = 10
    /// The selection and hover fill sits this far inside the row's top and bottom, clear of the hairlines
    /// and the date header.
    static let fillInset: CGFloat = 2
    static let avatarSize: CGFloat = 22
    /// Width of the hover buttons that replace the tags and time.
    static let hoverWidth: CGFloat = 84

    override var isFlipped: Bool { true }
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
    override var isOpaque: Bool { false }

    /// The content is laid out against the bounds (centred column, one or two lines): redraw on resize.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed {
            needsDisplay = true
            updateToolTip()
        }
    }

    /// The avatar names the account its dot stands for.
    private func updateToolTip() {
        removeAllToolTips()
        guard let model, model.account != nil else { return }
        addToolTip(RowPainter(model: model, column: ListLayout.column(in: bounds)).avatarRect, owner: self, userData: nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        let column = ListLayout.column(in: bounds)
        if !model.hidesHairline {
            Theme.hairline.setFill()
            CGRect(x: column.minX, y: bounds.maxY - 1, width: column.width, height: 1).fill()
        }
        if model.isSelected || model.isHovered {
            (model.isSelected ? (model.hasFocus ? Theme.selectedFocus : Theme.selected) : Theme.hover).setFill()
            Self.fill(column: column, in: bounds, joinsAbove: model.joinsAbove, joinsBelow: model.joinsBelow)
        }

        let context = NSGraphicsContext.current?.cgContext
        if model.dimmed { context?.setAlpha(0.6) }
        RowPainter(model: model, column: column).draw()
        if model.dimmed { context?.setAlpha(1) }
    }
}

extension ThreadRowView: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        model?.account?.help ?? ""
    }
}

/// Lays out and draws the content of one row.
private struct RowPainter {
    let model: RowModel
    let column: CGRect

    var thread: MailThread { model.row.thread }
    var unread: Bool { thread.unreadCount > 0 }
    var quiet: NSColor { model.isSelected ? Theme.text2 : Theme.text3 }
    /// Read rows step back a level, so unread mail is what the eye lands on.
    var primary: NSColor { unread ? Theme.text1 : Theme.text2 }

    /// What shows behind the avatar: the row's fill, else the list.
    var backdrop: NSColor {
        if model.isSelected { return model.hasFocus ? Theme.selectedFocus : Theme.selected }
        return model.isHovered ? Theme.hover : Theme.bg
    }

    var left: CGFloat { column.minX + ThreadRowView.padding }

    var avatarRect: CGRect {
        let size = ThreadRowView.avatarSize
        let centerY = model.style.isSingleLine ? column.midY : column.minY + 18
        return CGRect(x: left, y: centerY - size / 2, width: size, height: size)
    }

    func draw() {
        if model.style.isSingleLine { drawOneLine() } else { drawTwoLines() }
    }

    // MARK: Layouts

    /// avatar · sender (count) · dot · subject — preview · paperclip · tags · time
    private func drawOneLine() {
        let right = column.maxX - ThreadRowView.padding
        let line = CGRect(x: left, y: column.midY - 9, width: right - left, height: 18)
        drawAvatar()

        let senderX = left + ThreadRowView.avatarSize + 10
        let senderWidth = min(max(column.width * 0.2, 160), 220)
        drawSender(in: CGRect(x: senderX, y: line.minY, width: senderWidth, height: line.height))
        let dotX = senderX + senderWidth + 2
        if unread { drawDot(centerX: dotX + 3, centerY: line.midY) }

        let subjectX = dotX + 14
        let trailing = drawTrailing(in: line, chips: model.chips.count, minimumX: subjectX + 200)
        drawSubjectAndPreview(in: CGRect(x: subjectX, y: line.minY, width: max(0, trailing - 14 - subjectX), height: line.height))
    }

    /// avatar · sender (count) · dot … tag · paperclip · time, then subject — preview below.
    private func drawTwoLines() {
        let right = column.maxX - ThreadRowView.padding
        let line1 = CGRect(x: left, y: column.minY + 9, width: right - left, height: 18)
        drawAvatar()
        let textX = left + ThreadRowView.avatarSize + 10
        let line2 = CGRect(x: textX, y: column.minY + 30, width: right - textX, height: 18)

        let trailing = drawTrailing(in: line1, chips: min(model.chips.count, 1), minimumX: textX + 120)
        let end = drawSender(in: CGRect(x: textX, y: line1.minY, width: max(0, trailing - 22 - textX), height: line1.height))
        if unread { drawDot(centerX: end + 9, centerY: line1.midY) }
        drawSubjectAndPreview(in: line2)
    }

    // MARK: Pieces

    /// The avatar, and the account's dot on its lower right while several accounts share the list.
    private func drawAvatar() {
        let rect = avatarRect
        switch model.avatar {
        case .logo(let image):
            Avatar.drawLogo(image, in: rect, shape: .square)
        case .letters(let text):
            Avatar.drawLetters(text, tint: nil, in: rect, shape: .square)
        }
        guard let account = model.account else { return }
        let size: CGFloat = 8
        let dot = CGRect(x: rect.maxX - size + 2, y: rect.maxY - size + 2, width: size, height: size)
        backdrop.setFill()
        NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
        Theme.accountColor(account.colorIndex).setFill()
        NSBezierPath(ovalIn: dot).fill()
    }

    private func drawDot(centerX: CGFloat, centerY: CGFloat) {
        Theme.ink.setFill()
        NSBezierPath(ovalIn: CGRect(x: centerX - 3, y: centerY - 3, width: 6, height: 6)).fill()
    }

    /// Draws the sender (or "Draft to …") and the message count. Returns the x after them.
    @discardableResult
    private func drawSender(in rect: CGRect) -> CGFloat {
        let senders = RowFormat.senders(thread)
        let draft = RowFormat.draftLine(thread)
        var attributes: [NSAttributedString.Key: Any] = [.font: Theme.ui(13, unread ? .semibold : .regular), .foregroundColor: primary]
        var name = senders.text
        if let draft {
            name = draft
            attributes = [.font: Theme.ui(13, .medium), .foregroundColor: Theme.text2, .obliqueness: 0.14]
        }
        let countText = senders.count.map { "(\($0))" }
        var countAttributes = Self.countAttributes
        countAttributes[.foregroundColor] = quiet
        let countWidth = countText.map { Self.width($0, countAttributes) + 5 } ?? 0
        let prefix: CGFloat = draft == nil ? 0 : 18
        let nameWidth = min(Self.width(name, attributes) + 1, max(0, rect.width - countWidth - prefix))
        var x = rect.minX
        if draft != nil {
            Icon.drafts.draw(in: CGRect(x: x, y: rect.midY - 7, width: 14, height: 14), color: Theme.text2)
            x += prefix
        }
        Self.drawText(name, attributes, in: CGRect(x: x, y: rect.minY, width: nameWidth, height: rect.height))
        x += nameWidth
        if let countText {
            Self.drawText(countText, countAttributes, in: CGRect(x: x + 5, y: rect.minY, width: countWidth, height: rect.height))
            x += countWidth
        }
        return x
    }

    /// Time, tags and paperclip from the right (or the room for the hover buttons). Returns the left
    /// edge of what it drew. Tags are dropped before they would squeeze the subject under `minimumX`.
    private func drawTrailing(in line: CGRect, chips count: Int, minimumX: CGFloat) -> CGFloat {
        var x = line.maxX
        if model.isHovered {
            x -= ThreadRowView.hoverWidth - 6
        } else {
            let time = model.timeOverride ?? RowFormat.compactTime(thread.lastDate)
            var attrs = Self.timeAttributes
            attrs[.foregroundColor] = quiet
            let width = Self.width(time, attrs)
            x -= width
            Self.drawText(time, attrs, in: CGRect(x: x, y: line.minY, width: width + 1, height: line.height))
            for chip in model.chips.prefix(count).reversed() {
                let width = Self.chipWidth(chip)
                guard x - 10 - width >= minimumX else { break }
                x -= 10 + width
                drawChip(chip, x: x, centerY: line.midY)
                x += 4
            }
        }
        if thread.hasAttachments {
            x -= 10 + 14
            Icon.paperclip.draw(in: CGRect(x: x, y: line.midY - 7, width: 14, height: 14), color: quiet)
        }
        return x
    }

    private func drawChip(_ chip: RowChip, x: CGFloat, centerY: CGFloat) {
        let rect = CGRect(x: x, y: centerY - 10, width: Self.chipWidth(chip), height: 20)
        Theme.chipFill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: Theme.Radius.chip, yRadius: Theme.Radius.chip).fill()
        chip.icon.draw(in: CGRect(x: x + 6, y: centerY - 6, width: 12, height: 12), color: chip.color, weight: 1.1)
        var attrs = Self.chipAttributes
        attrs[.foregroundColor] = model.isSelected ? Theme.text1 : Theme.text2
        Self.drawText(chip.text, attrs, in: CGRect(x: x + 22, y: rect.minY, width: rect.width - 28, height: rect.height))
    }

    private func drawSubjectAndPreview(in rect: CGRect) {
        guard rect.width > 20 else { return }
        let subject = thread.subject.isEmpty ? "(no subject)" : thread.subject
        let subjectAttrs: [NSAttributedString.Key: Any] = [.font: Theme.ui(13, unread ? .medium : .regular), .foregroundColor: primary]
        let subjectWidth = min(Self.width(subject, subjectAttrs), rect.width * 0.7)
        let subjectRect = CGRect(x: rect.minX, y: rect.minY, width: subjectWidth, height: rect.height)
        if let highlight = model.highlight, !highlight.subject.isEmpty, !thread.subject.isEmpty {
            Self.drawMarked(NSAttributedString(string: subject, attributes: subjectAttrs), ranges: highlight.subject, in: subjectRect)
        } else {
            Self.drawText(subject, subjectAttrs, in: subjectRect)
        }

        var x = rect.minX + subjectWidth + 6
        guard rect.maxX - x > 24 else { return }
        let preview: [NSAttributedString.Key: Any] = [.font: Theme.ui(13), .foregroundColor: quiet]
        if let highlight = model.highlight {
            // While searching, the excerpt around the match replaces the preview and the summary.
            let prefix = "— "
            let text = NSMutableAttributedString(string: prefix + highlight.snippet.replacingOccurrences(of: "\n", with: " "), attributes: preview)
            let shift = (prefix as NSString).length
            let ranges = highlight.snippetRanges.map { NSRange(location: $0.location + shift, length: $0.length) }
            for range in ranges where NSMaxRange(range) <= text.length {
                text.addAttribute(.foregroundColor, value: Theme.text1, range: range)
            }
            Self.drawMarked(text, ranges: ranges, in: CGRect(x: x, y: rect.minY, width: rect.maxX - x, height: rect.height))
            return
        }
        if let summary = model.row.summary, !summary.isEmpty {
            // The AI summary replaces the preview, after a small sparkle.
            Self.drawText("—", preview, in: CGRect(x: x, y: rect.minY, width: 14, height: rect.height))
            x += 17
            Icon.sparkles.draw(in: CGRect(x: x, y: rect.midY - 6, width: 12, height: 12), color: quiet)
            x += 17
            Self.drawText(summary, preview, in: CGRect(x: x, y: rect.minY, width: rect.maxX - x, height: rect.height))
        } else {
            let snippet = ThreadRowView.preview(thread.snippet, subject: thread.subject)
            Self.drawText("— " + snippet, preview, in: CGRect(x: x, y: rect.minY, width: rect.maxX - x, height: rect.height))
        }
    }

    // MARK: Text

    static let countAttributes: [NSAttributedString.Key: Any] = [.font: Theme.numeric(12), .foregroundColor: Theme.text3]
    static let timeAttributes: [NSAttributedString.Key: Any] = [.font: Theme.numeric(12), .foregroundColor: Theme.text3]
    static let chipAttributes: [NSAttributedString.Key: Any] = [.font: Theme.ui(11.5, .medium)]

    static func chipWidth(_ chip: RowChip) -> CGFloat {
        22 + width(chip.text, chipAttributes) + 7
    }

    static func width(_ text: String, _ attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        ceil((text as NSString).size(withAttributes: attributes).width)
    }

    static let truncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    /// Draws `text` with a soft ink mark behind each range (search matches). Marks past the visible
    /// width are clipped with the text.
    static func drawMarked(_ text: NSAttributedString, ranges: [NSRange], in rect: CGRect) {
        guard rect.width > 4 else { return }
        let font = (text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont) ?? Theme.ui(13)
        let lineHeight = ceil(font.ascender - font.descender)
        let y = rect.minY + (rect.height - lineHeight) / 2
        let line = CTLineCreateWithAttributedString(text)
        Theme.ink.withAlphaComponent(0.13).setFill()
        for range in ranges where range.location < text.length {
            let start = CTLineGetOffsetForStringIndex(line, range.location, nil)
            let end = CTLineGetOffsetForStringIndex(line, min(NSMaxRange(range), text.length), nil)
            let mark = CGRect(x: rect.minX + start - 2, y: y - 1, width: end - start + 4, height: lineHeight + 2)
                .intersection(rect.insetBy(dx: -2, dy: -2))
            guard mark.width > 3 else { continue }
            NSBezierPath(roundedRect: mark, xRadius: Theme.Radius.chip, yRadius: Theme.Radius.chip).fill()
        }
        draw(text, in: rect)
    }

    static func drawText(_ text: String, _ attributes: [NSAttributedString.Key: Any], in rect: CGRect) {
        guard rect.width > 4 else { return }
        draw(NSAttributedString(string: text, attributes: attributes), in: rect)
    }

    static func draw(_ text: NSAttributedString, in rect: CGRect) {
        guard rect.width > 4 else { return }
        let string = NSMutableAttributedString(attributedString: text)
        string.addAttribute(.paragraphStyle, value: truncating, range: NSRange(location: 0, length: string.length))
        let font = (text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont) ?? Theme.ui(13)
        let lineHeight = ceil(font.ascender - font.descender)
        let y = rect.minY + (rect.height - lineHeight) / 2
        string.draw(with: CGRect(x: rect.minX, y: y, width: rect.width, height: lineHeight + 2),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// A sticky date header, left in line with the avatars: Today, Yesterday, This week, month names. Gets
/// the list background while it floats over rows.
final class HeaderRowView: NSTableRowView {
    var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
    /// The row under the header is filled: no line between them.
    var hidesHairline = false { didSet { if hidesHairline != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
    override var isFloating: Bool { didSet { needsDisplay = true } }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsDisplay = true }
    }

    static let attributes: [NSAttributedString.Key: Any] = [.font: Theme.ui(12, .medium), .foregroundColor: Theme.text3]

    override func draw(_ dirtyRect: NSRect) {
        let column = ListLayout.column(in: bounds)
        if isFloating {
            Theme.bg.setFill()
            bounds.fill()
        }
        if !hidesHairline {
            Theme.hairline.setFill()
            CGRect(x: column.minX, y: bounds.maxY - 1, width: column.width, height: 1).fill()
        }
        let text = title as NSString
        let size = text.size(withAttributes: Self.attributes)
        text.draw(at: CGPoint(x: column.minX + ThreadRowView.padding, y: floor(bounds.midY - size.height / 2)), withAttributes: Self.attributes)
    }
}

/// The quiet last row of search results: "Search older mail on Gmail", then what that found.
final class ServerSearchRowView: NSTableRowView {
    var text = "" { didSet { if text != oldValue { needsDisplay = true } } }
    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsDisplay = true }
    }

    override var isFlipped: Bool { true }
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}

    override func draw(_ dirtyRect: NSRect) {
        let column = ListLayout.column(in: bounds)
        if isHovered {
            // As tall as a one-line row's fill, in the middle of the row.
            Theme.hover.setFill()
            ThreadRowView.fill(column: column, in: bounds.insetBy(dx: 0, dy: (bounds.height - RowStyle.oneLine.height) / 2))
        }
        let left = column.minX + ThreadRowView.padding + 3
        Icon.search.draw(in: CGRect(x: left, y: bounds.midY - 7, width: 14, height: 14), color: Theme.text3)
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.ui(13), .foregroundColor: Theme.text3]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: left + 27, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
}

extension ThreadRowView {
    /// Fills the column's width between the insets with the current colour, rounded at the row radius.
    /// A side that joins a selected neighbour runs to the row's edge, square.
    static func fill(column: CGRect, in bounds: CGRect, joinsAbove: Bool = false, joinsBelow: Bool = false) {
        let top = joinsAbove ? bounds.minY : bounds.minY + fillInset
        let bottom = joinsBelow ? bounds.maxY : bounds.maxY - fillInset
        let rect = CGRect(x: column.minX, y: top, width: column.width, height: bottom - top)
        let radius = Theme.Radius.row
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        if joinsAbove { CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: radius).fill() }
        if joinsBelow { CGRect(x: rect.minX, y: rect.maxY - radius, width: rect.width, height: radius).fill() }
    }

    /// The snippet on one line, without the subject when the body starts by repeating it (common in
    /// notification mail), so the row doesn't say the same thing twice.
    static func preview(_ snippet: String, subject: String) -> String {
        let text = snippet.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let title = subject.trimmingCharacters(in: .whitespaces)
        guard title.count >= 4, text.count > title.count,
              let range = text.range(of: title, options: [.anchored, .caseInsensitive]) else { return text }
        let rest = text[range.upperBound...].drop { $0.isWhitespace || $0.isPunctuation && $0 != "(" && $0 != "\"" }
        return rest.isEmpty ? text : String(rest)
    }
}

/// The list's scroll view. macOS backs a floating date header with a scroll edge "pocket" whose hard
/// edge is a line across the whole window; the header paints its own background and a hairline across
/// the column, so the pocket is hidden. (There is no public switch for it; if AppKit renames the class,
/// the line simply comes back.)
final class ListScrollView: NSScrollView {
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if Self.isEdgePocket(subview) { subview.isHidden = true }
    }

    override func layout() {
        super.layout()
        for subview in subviews where Self.isEdgePocket(subview) && !subview.isHidden { subview.isHidden = true }
    }

    private static func isEdgePocket(_ view: NSView) -> Bool {
        NSStringFromClass(type(of: view)).contains("ScrollPocket")
    }
}
