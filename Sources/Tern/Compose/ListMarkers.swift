import AppKit
import TernCore

/// Draws "•" or "3." in front of list paragraphs. The text itself holds no marker characters, so
/// copying, serializing and caret movement only ever see the item's words.
final class ListItemLayoutFragment: NSTextLayoutFragment {
    var marker = "•"

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(CGRect(x: -EditorStyle.listIndent, y: 0, width: EditorStyle.listIndent, height: EditorStyle.lineHeight))
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        guard let line = textLineFragments.first else { return }
        // TextKit 2 starts an indented paragraph's fragment at its head indent, i.e. where the text begins.
        let indentInFrame = layoutFragmentFrame.minX >= EditorStyle.listIndent - 0.5 ? 0 : EditorStyle.listIndent
        let textStart = CGPoint(x: point.x + indentInFrame + line.typographicBounds.minX, y: point.y + line.typographicBounds.minY)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if NSGraphicsContext.current == nil {
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        }
        ListMarkerDrawing.draw(marker, textStart: textStart)
    }
}

enum ListMarkerDrawing {
    static let attributes: [NSAttributedString.Key: Any] = [
        .font: Theme.ui(EditorStyle.fontSize), .foregroundColor: Theme.text2,
    ]

    /// Right-aligns the marker 6 pt before where the item's text starts, on its first line.
    static func draw(_ marker: String, textStart: CGPoint) {
        let text = NSAttributedString(string: marker, attributes: attributes)
        let size = text.size()
        text.draw(at: CGPoint(x: textStart.x - 6 - size.width, y: textStart.y + (EditorStyle.lineHeight - size.height) / 2 + 1))
    }

    /// The marker for a list paragraph starting at `location`: a bullet, or its position among the
    /// numbered paragraphs right before it.
    static func marker(in string: NSAttributedString, paragraphAt location: Int) -> String? {
        guard location < string.length else { return nil }
        let kind = EditorStyle.block(of: string.attributes(at: location, effectiveRange: nil))
        switch kind {
        case .bullet: return "•"
        case .numbered:
            let text = string.string as NSString
            var number = 1
            var cursor = location
            while cursor > 0 {
                let previous = text.paragraphRange(for: NSRange(location: cursor - 1, length: 0))
                guard EditorStyle.block(of: string.attributes(at: previous.location, effectiveRange: nil)) == .numbered else { break }
                number += 1
                cursor = previous.location
            }
            return "\(number)."
        default: return nil
        }
    }
}

/// Hands TextKit 2 a list fragment for list paragraphs.
final class EditorLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation, in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        guard let contentStorage = textLayoutManager.textContentManager as? NSTextContentStorage,
              let storage = contentStorage.textStorage, let range = textElement.elementRange else {
            return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
        }
        let offset = contentStorage.offset(from: contentStorage.documentRange.location, to: range.location)
        guard let marker = ListMarkerDrawing.marker(in: storage, paragraphAt: offset) else {
            return NSTextLayoutFragment(textElement: textElement, range: range)
        }
        let fragment = ListItemLayoutFragment(textElement: textElement, range: range)
        fragment.marker = marker
        return fragment
    }
}
