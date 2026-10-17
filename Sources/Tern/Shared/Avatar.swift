import AppKit

/// Round pictures for senders and accounts: the sender's domain logo when `SenderLogos` has one,
/// otherwise initials on a soft disc (neutral, or the account's hue).
enum Avatar {
    /// "Maya Chen" → "M" (or "MC" with two letters); an address alone → its first letter.
    static func initials(name: String, email: String, letters: Int = 1) -> String {
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ").union(.whitespaces))
        let source = trimmed.isEmpty || trimmed.contains("@") ? String(email.split(separator: "@").first ?? "") : trimmed
        let words = source.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" || $0 == "-" })
        var result = ""
        for word in [words.first, letters > 1 && words.count > 1 ? words.last : nil].compactMap({ $0 }) {
            if let first = word.first(where: { $0.isLetter || $0.isNumber }) { result.append(first) }
        }
        return result.isEmpty ? "?" : result.uppercased()
    }

    /// Initials centred on a disc filling `rect`. `tint` nil is the neutral disc.
    static func drawLetters(_ text: String, tint: (fill: NSColor, text: NSColor)?, in rect: CGRect) {
        (tint?.fill ?? Theme.avatarFill).setFill()
        NSBezierPath(ovalIn: rect).fill()
        let font = Theme.ui((rect.width * (text.count > 1 ? 0.4 : 0.48)).rounded(), .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tint?.text ?? Theme.avatarText]
        let width = (text as NSString).size(withAttributes: attributes).width
        // Optical centre (flipped context): the cap height sits in the middle, not the line box.
        let y = rect.midY + font.capHeight / 2 - font.ascender
        (text as NSString).draw(at: CGPoint(x: rect.midX - width / 2, y: y), withAttributes: attributes)
    }

    /// A logo clipped round on a white disc (most site icons are drawn for white), with a faint ring so
    /// it holds its edge on any background.
    static func drawLogo(_ image: NSImage, in rect: CGRect) {
        let circle = NSBezierPath(ovalIn: rect)
        NSGraphicsContext.saveGraphicsState()
        circle.addClip()
        NSColor.white.setFill()
        rect.fill()
        image.draw(in: rect.insetBy(dx: rect.width * 0.08, dy: rect.width * 0.08), from: .zero, operation: .sourceOver,
                   fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.25, dy: 0.25))
        ring.lineWidth = 0.5
        Theme.avatarRing.setStroke()
        ring.stroke()
    }
}
