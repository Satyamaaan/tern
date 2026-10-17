import AppKit
import TernCore

extension NSAttributedString.Key {
    /// On an inline image's attachment character: the image's `src` (`cid:…`).
    static let ternImage = NSAttributedString.Key("tern.image")
}

/// Inline images in the body editor: a draft's `cid:` files shown as text attachments, scaled to fit.
enum InlineImages {
    static let maxSize = NSSize(width: 360, height: 360)

    /// Shown while an image's file isn't on this Mac yet, or can't be read.
    static let placeholder = NSImage(size: NSSize(width: 120, height: 80), flipped: false) { rect in
        Theme.pill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        return true
    }

    /// The attachment character for `source`, drawn with `image` (the placeholder when nil).
    static func attachment(_ source: String, image: NSImage?, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        var attributes = attributes
        attributes[.attachment] = textAttachment(image)
        attributes[.ternImage] = source
        return NSAttributedString(string: String(RichText.imageCharacter), attributes: attributes)
    }

    static func textAttachment(_ image: NSImage?) -> NSTextAttachment {
        let image = image ?? placeholder
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(origin: .zero, size: fitted(image.size))
        return attachment
    }

    /// `size` scaled down, keeping its proportions, to fit `maxSize`.
    static func fitted(_ size: NSSize) -> NSSize {
        guard size.width > 0, size.height > 0 else { return placeholder.size }
        let scale = min(1, maxSize.width / size.width, maxSize.height / size.height)
        return NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}

/// Paragraphs holding an inline image lay out without the editor's fixed line height, so the line
/// grows to the image instead of the image overlapping the lines below.
final class InlineImageParagraphs: NSObject, NSTextContentStorageDelegate {
    func textContentStorage(_ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        guard let storage = textContentStorage.textStorage, range.length > 0, NSMaxRange(range) <= storage.length else { return nil }
        var hasImage = false
        storage.enumerateAttribute(.ternImage, in: range) { value, _, stop in
            if value != nil { hasImage = true; stop.pointee = true }
        }
        guard hasImage else { return nil }
        let paragraph = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        paragraph.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: paragraph.length)) { value, subrange, _ in
            guard let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
            style.maximumLineHeight = 0
            paragraph.addAttribute(.paragraphStyle, value: style, range: subrange)
        }
        return NSTextParagraph(attributedString: paragraph)
    }
}
