import AppKit

/// How a logo fills a rounded avatar. Many site icons are drawn as their own tile: an opaque rounded
/// square with see-through corners, sometimes inside a transparent margin (GitHub's, most app icons).
/// Clipped as they are onto white, the white shows in their corners and the avatar gets two sets of
/// corners. Such a logo is cropped to just inside its tile (its own corners, soft edge and any border
/// fall outside the avatar) and backed with the tile's own colour, so only the avatar's corners show.
/// Other logos fill the avatar on white.
struct LogoTile {
    /// The part of the image to draw, in the image's own coordinates (origin bottom left).
    let source: NSRect
    /// What goes behind it.
    let backdrop: NSColor
    /// The logo is its own tile: it has a solid edge and needs no ring.
    var isTile = false
    /// The picture's outer edge is near white (on its white backing): on a light list it needs a faint
    /// ring to hold its edge. Elsewhere a ring only reads as a border.
    var edgeIsLight = false

    /// How far inside the tile the crop sits, as a share of its side: past the tile's own rounded
    /// corners, soft edge and border.
    static let zoom: CGFloat = 0.06

    /// The fit for `image`, worked out once per image.
    static func fit(_ image: NSImage) -> LogoTile {
        if let known = cache.object(forKey: image) { return known.value }
        let fit = measure(image) ?? LogoTile(source: .zero, backdrop: .white, edgeIsLight: true)
        cache.setObject(Box(fit), forKey: image)
        return fit
    }

    /// The logo as the avatar shows it, square and unclipped, for the reader page (which rounds it in CSS).
    static func squarePNG(_ image: NSImage, side: Int = 56) -> Data? {
        let fit = fit(image)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let rect = NSRect(x: 0, y: 0, width: side, height: side)
        fit.backdrop.setFill()
        rect.fill()
        image.draw(in: rect, from: fit.source, operation: .sourceOver, fraction: 1, respectFlipped: false,
                   hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: Measuring

    private final class Box: @unchecked Sendable {
        let value: LogoTile
        init(_ value: LogoTile) { self.value = value }
    }

    /// NSCache is thread-safe; images can be drawn off the main thread (menu item images).
    nonisolated(unsafe) private static let cache: NSCache<NSImage, Box> = {
        let cache = NSCache<NSImage, Box>()
        cache.countLimit = 2_000
        return cache
    }()

    /// Samples the image at 64 × 64: how light its outer edge is, then whether it is a tile (its opaque
    /// area is a rounded square: solid middles and shoulders, see-through corners). Nil when the image
    /// can't be drawn.
    private static func measure(_ image: NSImage) -> LogoTile? {
        let side = 64
        guard image.size.width > 0, image.size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        // Rows from the top, as the bitmap stores them.
        func alpha(_ x: Int, _ y: Int) -> CGFloat { rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 }
        // The edge as it shows on the white backing: see-through counts as white.
        var light: CGFloat = 0, count: CGFloat = 0
        for i in stride(from: 0, to: side, by: 2) {
            for (x, y) in [(i, 0), (i, side - 1), (0, i), (side - 1, i)] {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
                light += color.alphaComponent * luminance + (1 - color.alphaComponent)
                count += 1
            }
        }
        let plain = LogoTile(source: .zero, backdrop: .white, edgeIsLight: count == 0 || light / count > 0.88)

        var minX = side, minY = side, maxX = -1, maxY = -1
        for y in 0..<side {
            for x in 0..<side where alpha(x, y) > 0.5 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let width = maxX - minX + 1, height = maxY - minY + 1
        // A tile is roughly square and most of the picture.
        guard maxX >= 0, width >= side / 2, abs(width - height) <= 3 else { return plain }

        // Sampled well inside the edge, past a drawn border.
        let inset = max(2, width / 14)
        let midX = (minX + maxX) / 2, midY = (minY + maxY) / 2
        let middles = [(midX, minY + inset), (midX, maxY - inset), (minX + inset, midY), (maxX - inset, midY)]
        let corners = [(minX, minY), (maxX, minY), (minX, maxY), (maxX, maxY)]
        // A tenth of the way in along the diagonals a rounded square is already solid; a circle (a round
        // logo, best left whole on white) isn't yet.
        let diagonal = width / 10
        let shoulders = [(minX + diagonal, minY + diagonal), (maxX - diagonal, minY + diagonal),
                         (minX + diagonal, maxY - diagonal), (maxX - diagonal, maxY - diagonal)]
        guard middles.allSatisfy({ alpha($0.0, $0.1) > 0.9 }), corners.allSatisfy({ alpha($0.0, $0.1) < 0.6 }),
              shoulders.allSatisfy({ alpha($0.0, $0.1) > 0.9 }) else { return plain }

        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        for (x, y) in middles {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return plain }
            red += color.redComponent; green += color.greenComponent; blue += color.blueComponent
        }
        let backdrop = NSColor(deviceRed: red / 4, green: green / 4, blue: blue / 4, alpha: 1)

        // Back to the image's coordinates, bottom-left origin.
        let scaleX = image.size.width / CGFloat(side), scaleY = image.size.height / CGFloat(side)
        let tile = NSRect(x: CGFloat(minX) * scaleX, y: CGFloat(side - 1 - maxY) * scaleY,
                          width: CGFloat(width) * scaleX, height: CGFloat(height) * scaleY)
        let source = tile.insetBy(dx: tile.width * zoom, dy: tile.height * zoom)
        return LogoTile(source: source, backdrop: backdrop, isTile: true)
    }
}
