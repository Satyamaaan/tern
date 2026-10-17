// Renders Tern's 1024 × 1024 app icon: a white Arctic tern with a black cap and a vermilion beak, climbing
// across a charcoal macOS tile. Run: swift scripts/icon.swift <out.png>   (build.sh turns it into AppIcon.icns)
// Standalone on purpose (CoreGraphics + ImageIO only), so `TernGlyph` below is a verbatim copy of the one in
// Sources/Tern/List/TernMark.swift. Keep the two in sync.

import CoreGraphics
import Foundation
import ImageIO

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("icon.swift: \(message)\n".utf8))
    exit(1)
}

/// A rounded rect with continuous (squircle) corners, as on macOS app icons. y-down.
func squircle(_ rect: CGRect, radius r: CGFloat) -> CGPath {
    let path = CGMutablePath()
    typealias Corner = (CGFloat, CGFloat) -> CGPoint
    let tl: Corner = { CGPoint(x: rect.minX + $0 * r, y: rect.minY + $1 * r) }
    let tr: Corner = { CGPoint(x: rect.maxX - $0 * r, y: rect.minY + $1 * r) }
    let br: Corner = { CGPoint(x: rect.maxX - $0 * r, y: rect.maxY - $1 * r) }
    let bl: Corner = { CGPoint(x: rect.minX + $0 * r, y: rect.maxY - $1 * r) }
    // Each corner runs from the edge it arrives on to the edge it leaves on; `swap` flips the axes.
    func corner(_ c: Corner, swap: Bool) {
        func q(_ a: CGFloat, _ b: CGFloat) -> CGPoint { swap ? c(b, a) : c(a, b) }
        path.addLine(to: q(1.52866471, 0))
        path.addCurve(to: q(0.66993427, 0.06549600), control1: q(1.08849323, 0), control2: q(0.86840689, 0))
        path.addLine(to: q(0.63149399, 0.07491100))
        path.addCurve(to: q(0.07491100, 0.63149399), control1: q(0.37282392, 0.16905899), control2: q(0.16905899, 0.37282392))
        path.addLine(to: q(0.06549600, 0.66993427))
        path.addCurve(to: q(0, 1.52866471), control1: q(0, 0.86840689), control2: q(0, 1.08849323))
    }
    path.move(to: tl(1.52866471, 0))
    corner(tr, swap: false)
    corner(br, swap: true)
    corner(bl, swap: false)
    corner(tl, swap: true)
    path.closeSubpath()
    return path
}

guard CommandLine.arguments.count > 1 else { fail("usage: swift scripts/icon.swift <out.png>") }
let outURL = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)

let size = 1024
guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fail("could not create a bitmap context") }
// Draw y-down like SwiftUI so the glyph coordinates match the app.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

// Apple's icon grid: an 824 pt tile with a 100 pt margin and a ~185 pt continuous corner.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = squircle(tile, radius: 185.4)

// Soft drop shadow (shadow offsets are in device space, where y points up).
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: color(0x000000, 0.3))
ctx.addPath(shape)
ctx.setFillColor(color(0x1E1E1E))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
guard let tileGradient = CGGradient(colorsSpace: space, colors: [color(0x2A2A2A), color(0x161616)] as CFArray,
                                    locations: [0, 1])
else { fail("could not create the tile gradient") }
ctx.drawLinearGradient(tileGradient, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])

// The tern climbs 14°, centred on its rotated bounds and nudged down a little because the wing carries
// most of its weight above the middle.
let bird = CGRect(x: -360, y: -180, width: 720, height: 360)
var place = CGAffineTransform(rotationAngle: -14 * .pi / 180)
guard let turned = TernGlyph.silhouette(in: bird).copy(using: &place) else { fail("could not place the tern") }
let bounds = turned.boundingBoxOfPath
place = place.concatenating(CGAffineTransform(translationX: tile.midX - bounds.midX, y: tile.midY - bounds.midY + 30))
func placed(_ path: CGPath) -> CGPath {
    var t = place
    return path.copy(using: &t) ?? path
}
for (path, fill) in [(TernGlyph.silhouette(in: bird), color(0xF6F6F3)),
                     (TernGlyph.cap(in: bird), color(0x0B0B0B)),
                     (TernGlyph.beak(in: bird), color(0xFF5A2E))] {
    ctx.addPath(placed(path))
    ctx.setFillColor(fill)
    ctx.fillPath()
}
ctx.restoreGState()

// A faint 1 pt highlight along the top inner edge of the tile.
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
ctx.addPath(shape.copy(strokingWithWidth: 2, lineCap: .round, lineJoin: .round, miterLimit: 4))
ctx.clip()
guard let rimGradient = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.1), color(0xFFFFFF, 0)] as CFArray,
                                   locations: [0, 1])
else { fail("could not create the highlight gradient") }
ctx.drawLinearGradient(rimGradient, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.midY), options: [])
ctx.restoreGState()

guard let image = ctx.makeImage(),
      let destination = CGImageDestinationCreateWithURL(outURL as CFURL, "public.png" as CFString, 1, nil)
else { fail("could not create \(outURL.path)") }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fail("could not write \(outURL.path)") }

// MARK: - Verbatim copy of TernGlyph from Sources/Tern/List/TernMark.swift

/// The tern's geometry, drawn in a 132 × 66 design box (y down) and scaled uniformly into the target rect.
/// `scripts/icon.swift` runs standalone and keeps a verbatim copy of this enum for the app icon: keep both in sync.
enum TernGlyph {
    static let designSize = CGSize(width: 132, height: 66)

    /// Maps the design box into `rect`, preserving aspect ratio, centred.
    static func transform(for rect: CGRect) -> CGAffineTransform {
        let s = min(rect.width / designSize.width, rect.height / designSize.height)
        return CGAffineTransform(a: s, b: 0, c: 0, d: s,
                                 tx: rect.midX - designSize.width * s / 2,
                                 ty: rect.midY - designSize.height * s / 2)
    }

    /// The open single-stroke outline used by `TernMark`.
    static func stroke(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        outline(path, transform(for: rect))
        return path
    }

    /// The same bird as a closed, fillable silhouette: the stroke closed through the inner edges of the
    /// tail streamers, which taper to points.
    static func silhouette(in rect: CGRect) -> CGPath {
        let t = transform(for: rect)
        let path = CGMutablePath()
        outline(path, t)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y).applying(t) }
        path.addQuadCurve(to: p(46.1, 39.67), control: p(21.35, 39.27))
        path.addQuadCurve(to: p(5.51, 61.62), control: p(26.96, 46.89))
        path.closeSubpath()
        return path
    }

    /// The black cap: crown from the base of the bill back to the nape, down to eye level.
    static func cap(in rect: CGRect) -> CGPath {
        let t = transform(for: rect)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y).applying(t) }
        let region = CGMutablePath()
        region.move(to: p(113.6, 14))
        region.addLine(to: p(114.1, 26.2))
        region.addQuadCurve(to: p(96.2, 25.3), control: p(105, 26.9))
        region.addLine(to: p(93.3, 14))
        region.closeSubpath()
        return silhouette(in: rect).intersection(region)
    }

    /// The bill, from its base to the tip.
    static func beak(in rect: CGRect) -> CGPath {
        let t = transform(for: rect)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y).applying(t) }
        let region = CGMutablePath()
        region.move(to: p(113.1, 18))
        region.addLine(to: p(134, 18))
        region.addLine(to: p(134, 34))
        region.addLine(to: p(113.5, 34))
        region.closeSubpath()
        return silhouette(in: rect).intersection(region)
    }

    private static func outline(_ path: CGMutablePath, _ t: CGAffineTransform) {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y).applying(t) }
        // Lower tail streamer in to the vent, the belly, then the throat up to the gape.
        path.move(to: p(5.51, 61.62))
        path.addCurve(to: p(59, 40.13), control1: p(20.52, 52.39), control2: p(45.4, 42.9))
        path.addCurve(to: p(99.95, 33.58), control1: p(70.96, 41.26), control2: p(88.73, 40.99))
        path.addCurve(to: p(112.76, 28.6), control1: p(104.63, 30.6), control2: p(109, 29.15))
        // Lower mandible out to the tip, the culmen back to the forehead.
        path.addLine(to: p(130.6, 27.37))
        path.addQuadCurve(to: p(112.86, 23.48), control: p(121.11, 24.61))
        // Forehead, crown and nape, then down to the shoulder.
        path.addCurve(to: p(104.42, 20.3), control1: p(110.91, 22.35), control2: p(108, 20.21))
        path.addCurve(to: p(96.59, 24.03), control1: p(100.95, 20.39), control2: p(98.16, 22.05))
        path.addCurve(to: p(91.46, 27), control1: p(95.13, 25.9), control2: p(93.43, 26.83))
        // Leading edge: the arm rises to the bent wrist, the hand sweeps back to the wing tip.
        path.addCurve(to: p(84.15, 11.23), control1: p(90.98, 21.51), control2: p(88.71, 14.79))
        path.addCurve(to: p(20.33, 4.95), control1: p(71.82, 5.88), control2: p(45.87, 3.11))
        // Trailing edge back down to the body.
        path.addCurve(to: p(70.04, 30.76), control1: p(39.31, 7.25), control2: p(60.9, 16.73))
        // Rump and the upper tail streamer.
        path.addCurve(to: p(1.4, 37.26), control1: p(58.61, 35.71), control2: p(25.25, 38.63))
    }
}
