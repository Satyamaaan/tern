import AppKit
import TernCore

/// Row layouts from research §F: one line at 36 px when the list is wide, two lines at 56 px when narrow.
enum RowStyle: Equatable {
    case oneLine, twoLines

    var height: CGFloat { self == .oneLine ? 36 : 56 }

    static func resolve(_ density: Density, width: CGFloat) -> RowStyle {
        switch density {
        case .compact: .oneLine
        case .comfortable: .twoLines
        case .auto: width >= 560 ? .oneLine : .twoLines
        }
    }
}

/// Everything a thread row draws, gathered by the list controller.
struct RowModel: Equatable {
    var row: ThreadRow
    var style: RowStyle
    var isSelected = false
    var hasFocusRing = false
    var isHovered = false
    var accountColor: NSColor?
    var chip: (text: String, color: NSColor)?
    /// Replaces the compact time (snoozed list shows when it wakes).
    var timeOverride: String?
    var dimmed = false
    /// While searching: the matched words, and the excerpt shown in place of the preview.
    var highlight: RowHighlight?

    static func == (a: RowModel, b: RowModel) -> Bool {
        a.row == b.row && a.style == b.style && a.isSelected == b.isSelected && a.hasFocusRing == b.hasFocusRing
            && a.isHovered == b.isHovered && a.accountColor == b.accountColor && a.chip?.text == b.chip?.text
            && a.chip?.color == b.chip?.color && a.timeOverride == b.timeOverride && a.dimmed == b.dimmed
            && a.highlight == b.highlight
    }
}

/// A message-list row, drawn in one pass (no subviews) so scrolling 50k threads stays smooth.
final class ThreadRowView: NSTableRowView {
    /// Redraws only when something visible changed, so j/k repaints two rows, not the screen.
    var model: RowModel? { didSet { if model != oldValue { needsDisplay = true } } }

    static let inset: CGFloat = 6
    static let gutter: CGFloat = 20

    override var isFlipped: Bool { true }
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        let pill = bounds.insetBy(dx: Self.inset, dy: 0)
        let shape = NSBezierPath(roundedRect: pill, xRadius: Theme.Radius.row, yRadius: Theme.Radius.row)
        if model.isSelected {
            Theme.selected.setFill()
            shape.fill()
        } else if model.isHovered {
            Theme.hover.setFill()
            shape.fill()
        }
        if model.hasFocusRing {
            let ring = NSBezierPath(roundedRect: pill.insetBy(dx: 0.75, dy: 0.75), xRadius: Theme.Radius.row - 0.5, yRadius: Theme.Radius.row - 0.5)
            ring.lineWidth = 1.5
            Theme.ink.withAlphaComponent(0.45).setStroke()
            ring.stroke()
        }

        let context = NSGraphicsContext.current?.cgContext
        if model.dimmed { context?.setAlpha(0.6) }
        RowPainter(model: model, pill: pill).draw()
        if model.dimmed { context?.setAlpha(1) }
    }
}

/// Lays out and draws the text of one row.
private struct RowPainter {
    let model: RowModel
    let pill: CGRect

    var thread: MailThread { model.row.thread }
    var unread: Bool { thread.unreadCount > 0 }
    var quiet: NSColor { model.isSelected ? Theme.text2 : Theme.text3 }

    func draw() {
        switch model.style {
        case .twoLines: drawTwoLines()
        case .oneLine: drawOneLine()
        }
    }

    // MARK: Layouts

    private func drawTwoLines() {
        let left = pill.minX + 2 + ThreadRowView.gutter
        let right = pill.maxX - 10
        let line1 = CGRect(x: left, y: pill.minY + 9, width: right - left, height: 18)
        let line2 = CGRect(x: left, y: pill.minY + 30, width: right - left, height: 18)
        drawUnreadDot(centerY: line1.midY)

        let trailing = drawTrailing(in: line1)
        drawSender(in: CGRect(x: line1.minX, y: line1.minY, width: trailing - 8 - line1.minX, height: line1.height))
        drawSubjectAndPreview(in: line2)
    }

    private func drawOneLine() {
        let left = pill.minX + 2 + ThreadRowView.gutter
        let right = pill.maxX - 10
        let line = CGRect(x: left, y: pill.midY - 9, width: right - left, height: 18)
        drawUnreadDot(centerY: line.midY)

        let trailing = drawTrailing(in: line, includeChip: false)
        let senderWidth: CGFloat = min(180, (trailing - left) * 0.4)
        let afterSender = drawSender(in: CGRect(x: left, y: line.minY, width: senderWidth, height: 18), reserveTail: false)
        var x = max(afterSender, left + senderWidth) + 12
        if let chip = model.chip, trailing - x > 160 {
            x = drawChip(chip, x: x, centerY: line.midY) + 8
        }
        drawSubjectAndPreview(in: CGRect(x: x, y: line.minY, width: max(0, trailing - 10 - x), height: 18))
    }

    // MARK: Pieces

    private func drawUnreadDot(centerY: CGFloat) {
        guard unread else { return }
        let x = pill.minX + 2 + ThreadRowView.gutter / 2
        Theme.ink.setFill()
        NSBezierPath(ovalIn: CGRect(x: x - 3, y: centerY - 3, width: 6, height: 6)).fill()
    }

    /// Draws the sender (or "Draft to …"), the message count and the account dot. Returns the x after them.
    @discardableResult
    private func drawSender(in rect: CGRect, reserveTail: Bool = true) -> CGFloat {
        let count = RowFormat.senders(thread)
        let draft = RowFormat.draftLine(thread)
        let nameFont = Theme.ui(13, unread ? .semibold : .medium)
        var attributes: [NSAttributedString.Key: Any] = [.font: nameFont, .foregroundColor: Theme.text1]
        var name = count.text
        if let draft {
            name = draft
            attributes = [.font: Theme.ui(13, .medium), .foregroundColor: Theme.text2, .obliqueness: 0.14]
        }

        let countText = count.count.map { String($0) }
        let countWidth = countText.map { Self.width($0, Self.countAttributes) + 7 } ?? 0
        let dotWidth: CGFloat = model.accountColor == nil ? 0 : 14
        let prefix: CGFloat = draft == nil ? 0 : 16
        let nameWidth = min(Self.width(name, attributes) + 2, max(0, rect.width - countWidth - dotWidth - prefix))
        var x = rect.minX
        if draft != nil {
            Icon.drafts.draw(in: CGRect(x: x, y: rect.midY - 6, width: 12, height: 12), color: Theme.text2)
            x += prefix
        }
        Self.drawText(name, attributes, in: CGRect(x: x, y: rect.minY, width: nameWidth, height: rect.height))
        x += nameWidth
        if let countText {
            x += 7
            var attrs = Self.countAttributes
            attrs[.foregroundColor] = quiet
            Self.drawText(countText, attrs, in: CGRect(x: x, y: rect.minY, width: countWidth, height: rect.height))
            x += countWidth - 7
        }
        if let color = model.accountColor {
            x += 7
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: x, y: rect.midY - 3.5, width: 7, height: 7)).fill()
            x += 7
        }
        return x
    }

    /// Chip, paperclip and time, right-aligned. Returns the left edge of what it drew.
    private func drawTrailing(in line: CGRect, includeChip: Bool = true) -> CGFloat {
        var x = line.maxX
        if !model.isHovered {
            let time = model.timeOverride ?? RowFormat.compactTime(thread.lastDate)
            var attrs = Self.timeAttributes
            attrs[.foregroundColor] = quiet
            let width = Self.width(time, attrs)
            x -= width
            Self.drawText(time, attrs, in: CGRect(x: x, y: line.minY + 1, width: width + 1, height: line.height))
        } else {
            x -= 80
        }
        if thread.hasAttachments {
            x -= 7 + 12
            Icon.paperclip.draw(in: CGRect(x: x, y: line.midY - 6, width: 12, height: 12), color: quiet)
        }
        if includeChip, let chip = model.chip {
            let width = Self.width(chip.text, Self.chipAttributes) + 12
            x -= 7 + width
            drawChip(chip, x: x, centerY: line.midY)
        }
        return x
    }

    @discardableResult
    private func drawChip(_ chip: (text: String, color: NSColor), x: CGFloat, centerY: CGFloat) -> CGFloat {
        var attrs = Self.chipAttributes
        attrs[.foregroundColor] = chip.color
        let width = Self.width(chip.text, attrs) + 12
        let rect = CGRect(x: x, y: centerY - 9, width: width, height: 18)
        chip.color.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: rect, xRadius: Theme.Radius.chip, yRadius: Theme.Radius.chip).fill()
        Self.drawText(chip.text, attrs, in: CGRect(x: x + 6, y: rect.minY + 1, width: width - 12, height: 16))
        return x + width
    }

    private func drawSubjectAndPreview(in rect: CGRect) {
        guard rect.width > 20 else { return }
        let subject = thread.subject.isEmpty ? "(no subject)" : thread.subject
        let subjectAttrs: [NSAttributedString.Key: Any] = [.font: Theme.ui(13, .medium), .foregroundColor: Theme.text1]
        let subjectWidth = min(Self.width(subject, subjectAttrs), rect.width * 0.72)
        let subjectRect = CGRect(x: rect.minX, y: rect.minY, width: subjectWidth, height: rect.height)
        if let highlight = model.highlight, !highlight.subject.isEmpty, !thread.subject.isEmpty {
            Self.drawMarked(NSAttributedString(string: subject, attributes: subjectAttrs), ranges: highlight.subject, in: subjectRect)
        } else {
            Self.drawText(subject, subjectAttrs, in: subjectRect)
        }

        let x = rect.minX + subjectWidth + 7
        guard rect.maxX - x > 24 else { return }
        let tailRect = CGRect(x: x, y: rect.minY, width: rect.maxX - x, height: rect.height)
        if let highlight = model.highlight {
            // While searching, the excerpt around the match replaces the preview and the summary.
            let prefix = "— "
            let text = NSMutableAttributedString(
                string: prefix + highlight.snippet.replacingOccurrences(of: "\n", with: " "),
                attributes: [.font: Theme.ui(13), .foregroundColor: quiet])
            let shift = (prefix as NSString).length
            let ranges = highlight.snippetRanges.map { NSRange(location: $0.location + shift, length: $0.length) }
            for range in ranges where NSMaxRange(range) <= text.length {
                text.addAttribute(.foregroundColor, value: Theme.text1, range: range)
            }
            Self.drawMarked(text, ranges: ranges, in: tailRect)
            return
        }
        let tail: NSAttributedString
        if let summary = model.row.summary, !summary.isEmpty {
            let text = NSMutableAttributedString(string: "✦ ", attributes: [.font: Theme.ui(12), .foregroundColor: Theme.text2])
            text.append(NSAttributedString(string: summary, attributes: [.font: Theme.ui(13), .foregroundColor: Theme.text2]))
            tail = text
        } else {
            let snippet = thread.snippet.replacingOccurrences(of: "\n", with: " ")
            tail = NSAttributedString(string: "— " + snippet, attributes: [.font: Theme.ui(13), .foregroundColor: quiet])
        }
        Self.draw(tail, in: tailRect)
    }

    // MARK: Text

    static let countAttributes: [NSAttributedString.Key: Any] = [.font: Theme.ui(13), .foregroundColor: Theme.text3]
    static let timeAttributes: [NSAttributedString.Key: Any] = [.font: Theme.numeric(12), .foregroundColor: Theme.text3]
    static let chipAttributes: [NSAttributedString.Key: Any] = [.font: Theme.ui(11, .medium)]

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

/// A sticky caps group header. Gets the list background and a hairline while it floats over rows.
final class HeaderRowView: NSTableRowView {
    var title = "" { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
    override var isFloating: Bool { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        if isFloating {
            Theme.bg.setFill()
            bounds.fill()
            Theme.hairline.setFill()
            CGRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.ui(11, .medium), .foregroundColor: Theme.text3, .kern: 0.6,
        ]
        let font = Theme.ui(11, .medium)
        let height = ceil(font.ascender - font.descender)
        (title as NSString).draw(
            at: CGPoint(x: ThreadRowView.inset + 12, y: bounds.maxY - 7 - height),
            withAttributes: attributes)
    }
}

/// The dashed line under the needs-reply group, with the group's size at its right end.
final class WaterlineRowView: NSTableRowView {
    var count = 0 { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}

    override func draw(_ dirtyRect: NSRect) {
        let text = "\(count)"
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.numeric(12), .foregroundColor: Theme.text3]
        let size = (text as NSString).size(withAttributes: attributes)
        let right = bounds.maxX - ThreadRowView.inset - 12
        (text as NSString).draw(at: CGPoint(x: right - size.width, y: bounds.midY - size.height / 2), withAttributes: attributes)

        let line = NSBezierPath()
        line.move(to: CGPoint(x: ThreadRowView.inset + 12, y: bounds.midY + 0.5))
        line.line(to: CGPoint(x: right - size.width - 8, y: bounds.midY + 0.5))
        line.lineWidth = 1
        line.setLineDash([3, 3], count: 2, phase: 0)
        Theme.text3.withAlphaComponent(0.4).setStroke()
        line.stroke()
    }
}

/// The quiet last row of search results: "Search older mail on Gmail", then what that found.
final class ServerSearchRowView: NSTableRowView {
    var text = "" { didSet { if text != oldValue { needsDisplay = true } } }
    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}

    override func draw(_ dirtyRect: NSRect) {
        let pill = CGRect(x: ThreadRowView.inset, y: 4, width: bounds.width - 2 * ThreadRowView.inset, height: bounds.height - 8)
        if isHovered {
            Theme.hover.setFill()
            NSBezierPath(roundedRect: pill, xRadius: Theme.Radius.row, yRadius: Theme.Radius.row).fill()
        }
        let left = pill.minX + 2 + ThreadRowView.gutter
        Icon.search.draw(in: CGRect(x: left, y: pill.midY - 6, width: 12, height: 12), color: Theme.text3)
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.ui(13), .foregroundColor: Theme.text3]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: left + 20, y: pill.midY - size.height / 2), withAttributes: attributes)
    }
}
