import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns whatever a site served into the one picture Tern keeps: a 64×64 PNG with the icon centred on
/// transparent. Only bitmap formats are decoded (PNG, JPEG, ICO, GIF, WebP, BMP); SVG, PDF and text
/// never are. Tiny, blank, fully transparent or banner-shaped images are refused.
enum LogoImage {
    /// Side of the stored square, in pixels.
    static let side = 64
    /// Smallest usable icon side.
    static let minimumSide = 16
    /// Larger images are refused rather than decoded.
    static let maximumSide = 4096

    private static let bitmapTypes = Set([UTType.png, .jpeg, .ico, .gif, .webP, .bmp].map(\.identifier))

    /// `data` as a 64×64 PNG, or nil when it isn't a usable bitmap icon.
    static func normalized(_ data: Data) -> Data? {
        guard !looksLikeText(data),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, bitmapTypes.contains(type),
              let index = bestIndex(source),
              let image = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              let square = square(image) else { return nil }
        return png(square)
    }

    /// Decodes a stored logo. Call off the main thread.
    static func decode(_ png: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// SVG, HTML and other markup start with `<` (after any whitespace or byte-order mark).
    private static func looksLikeText(_ data: Data) -> Bool {
        let first = data.prefix(64).first { ![0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF].contains($0) }
        return first == UInt8(ascii: "<")
    }

    /// The representation that downscales best: the smallest at least 64 px, else the largest.
    private static func bestIndex(_ source: CGImageSource) -> Int? {
        var best: (index: Int, side: Int)?
        for index in 0..<min(CGImageSourceGetCount(source), 16) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { continue }
            let short = min(width, height), long = max(width, height)
            guard short >= minimumSide, long <= maximumSide, long <= short * 3 else { continue }
            if let current = best {
                let better = current.side < side ? short > current.side : (short >= side && short < current.side)
                if better { best = (index, short) }
            } else {
                best = (index, short)
            }
        }
        return best?.index
    }

    /// The image fitted into a transparent 64×64 square; nil when every pixel comes out the same
    /// (blank, single-colour or fully transparent).
    private static func square(_ image: CGImage) -> CGImage? {
        guard image.width >= minimumSide, image.height >= minimumSide,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = min(Double(side) / Double(image.width), Double(side) / Double(image.height))
        let width = (Double(image.width) * scale).rounded(), height = (Double(image.height) * scale).rounded()
        context.interpolationQuality = .high
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        context.draw(image, in: CGRect(x: ((Double(side) - width) / 2).rounded(.down), y: ((Double(side) - height) / 2).rounded(.down),
                                       width: width, height: height))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var low: [UInt8] = [255, 255, 255, 255], high: [UInt8] = [0, 0, 0, 0]
        for offset in stride(from: 0, to: side * side * 4, by: 4) {
            for channel in 0..<4 {
                let value = pixels[offset + channel]
                low[channel] = min(low[channel], value)
                high[channel] = max(high[channel], value)
            }
        }
        guard (0..<4).contains(where: { high[$0] - low[$0] > 8 }) else { return nil }
        return context.makeImage()
    }

    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
