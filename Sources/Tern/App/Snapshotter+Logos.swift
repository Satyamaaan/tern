import AppKit
import TernCore

extension Snapshotter {
    /// Stand-in site icons for the demo mailbox's companies, drawn here (nothing is downloaded), so the
    /// shots show logo avatars next to initials. Personal senders keep their initials, as in real use.
    static func installDemoLogos() {
        let marks: [(domain: String, background: UInt32, glyph: String, foreground: UInt32)] = [
            ("figma.com", 0x1E1E1E, "F", 0xFFFFFF), ("linear.app", 0x5E6AD2, "L", 0xFFFFFF),
            ("github.com", 0x181717, "G", 0xFFFFFF), ("sentry.io", 0x362D59, "S", 0xFFFFFF),
            ("slack.com", 0x4A154B, "S", 0xFFFFFF), ("vercel.com", 0x000000, "▲", 0xFFFFFF),
            ("stripe.com", 0x635BFF, "S", 0xFFFFFF), ("google.com", 0xFFFFFF, "G", 0x4285F4),
            ("apple.com", 0x111111, "A", 0xFFFFFF), ("makenotion.com", 0xFFFFFF, "N", 0x111111),
            ("raycast.com", 0xFF6363, "R", 0xFFFFFF), ("substack.com", 0xFF6719, "S", 0xFFFFFF),
            ("loomwear.com", 0xD8CBB4, "L", 0x3B3226), ("airbnb.com", 0xFF5A5F, "A", 0xFFFFFF),
            ("uber.com", 0x000000, "U", 0xFFFFFF), ("amazon.com", 0x232F3E, "a", 0xFF9900),
            ("tldrnewsletter.com", 0x0B0B0B, "T", 0xFFFFFF), ("stratechery.com", 0xF3EFE6, "S", 0x1F3A5F),
        ]
        // Like many real site icons, these two are drawn as their own rounded tile with see-through
        // corners (Linear's and Figma's inside a margin too), so the shots show how such logos fill an avatar.
        let tiles: [String: CGFloat] = ["github.com": 0, "linear.app": 6, "figma.com": 5]
        for mark in marks {
            guard let png = drawMark(mark.glyph, background: mark.background, foreground: mark.foreground,
                                     tileMargin: tiles[mark.domain]) else { continue }
            SenderLogos.shared.install(png, forDomain: mark.domain)
        }
    }

    /// Stand-in profile photos for the demo accounts but the last, drawn here: a portrait-like gradient with
    /// a head and shoulders. The last account keeps its initial, as an account without a photo does.
    @MainActor
    static func installDemoAccountPhotos(_ accounts: [Account]) {
        let palettes: [(UInt32, UInt32)] = [(0xF2B38A, 0xB5523B), (0x8FB8E8, 0x34558B)]
        for (account, colours) in zip(accounts.dropLast(), palettes) {
            let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
                NSGradient(starting: Theme.rgb(colours.0), ending: Theme.rgb(colours.1))?.draw(in: rect, angle: -70)
                NSColor(white: 1, alpha: 0.85).setFill()
                NSBezierPath(ovalIn: CGRect(x: 22, y: 30, width: 20, height: 20)).fill()
                NSBezierPath(ovalIn: CGRect(x: 10, y: -14, width: 44, height: 40)).fill()
                return true
            }
            AccountPhotos.shared.install(image, for: account.id)
        }
    }

    /// A 64 px square icon with one glyph, as a PNG. With `tileMargin` it is a rounded tile that far inside
    /// a transparent square.
    private static func drawMark(_ glyph: String, background: UInt32, foreground: UInt32, tileMargin: CGFloat? = nil) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        Theme.rgb(background).setFill()
        if let margin = tileMargin {
            let tile = NSRect(x: 0, y: 0, width: 64, height: 64).insetBy(dx: margin, dy: margin)
            NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.22, yRadius: tile.width * 0.22).fill()
        } else {
            NSRect(x: 0, y: 0, width: 64, height: 64).fill()
        }
        let font = Theme.display(34)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.rgb(foreground)]
        let size = (glyph as NSString).size(withAttributes: attributes)
        (glyph as NSString).draw(at: NSPoint(x: (64 - size.width) / 2, y: 32 - font.capHeight / 2 + font.descender), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
