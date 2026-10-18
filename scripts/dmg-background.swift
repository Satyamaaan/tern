// Draws the background of the install window in Tern's disk image: a light neutral surface, a thin ink arrow from
// where Tern's icon sits to where the Applications folder sits, and "Drag Tern to Applications" under them.
// Run: swift scripts/dmg-background.swift <out dir>   writes background.png (600 × 380) and background@2x.png;
// release.sh combines them into a retina TIFF with tiffutil. Keep the layout in step with scripts/dmg-settings.py.

import AppKit
import CoreText

let size = CGSize(width: 600, height: 380)
/// Icon centres in window points, y down (dmg-settings.py places the icons here).
let ternIcon = CGPoint(x: 160, y: 152)
let applicationsIcon = CGPoint(x: 440, y: 152)
let iconSize: CGFloat = 112

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("dmg-background.swift: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count > 1 else { fail("usage: swift scripts/dmg-background.swift <out dir>") }
let outDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)

let fonts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../Resources/Fonts").standardized
for name in ["Inter-Medium.ttf"] {
    CTFontManagerRegisterFontURLs([fonts.appendingPathComponent(name)] as CFArray, .process, true, nil)
}
let captionFont = NSFont(name: "Inter-Medium", size: 13) ?? .systemFont(ofSize: 13, weight: .medium)

func draw() {
    // Flipped below, so y runs down as in Finder's window coordinates.
    rgb(0xF6F6F5).setFill()
    CGRect(origin: .zero, size: size).fill()

    // The arrow: a 1.5 pt ink line with an open chevron head, clear of both icons.
    let gap: CGFloat = 30
    let start = CGPoint(x: ternIcon.x + iconSize / 2 + gap, y: ternIcon.y)
    let end = CGPoint(x: applicationsIcon.x - iconSize / 2 - gap, y: applicationsIcon.y)
    let arrow = NSBezierPath()
    arrow.move(to: start)
    arrow.line(to: end)
    arrow.move(to: CGPoint(x: end.x - 7, y: end.y - 7))
    arrow.line(to: end)
    arrow.line(to: CGPoint(x: end.x - 7, y: end.y + 7))
    arrow.lineWidth = 1.5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    rgb(0x18181B, 0.55).setStroke()
    arrow.stroke()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let caption = NSAttributedString(string: "Drag Tern to Applications", attributes: [
        .font: captionFont, .foregroundColor: rgb(0x5F5F5A), .paragraphStyle: paragraph, .kern: -0.1,
    ])
    let height = caption.size().height
    caption.draw(in: CGRect(x: 0, y: 272 - height / 2, width: size.width, height: height))
}

for scale in [1, 2] {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)
    else { fail("could not create a bitmap") }
    bitmap.size = size
    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fail("could not create a context") }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
    context.cgContext.translateBy(x: 0, y: size.height)
    context.cgContext.scaleBy(x: 1, y: -1)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    let srgb = bitmap.retagging(with: .sRGB) ?? bitmap
    let name = scale == 1 ? "background.png" : "background@2x.png"
    guard let png = srgb.representation(using: .png, properties: [:]) else { fail("could not encode \(name)") }
    do { try png.write(to: outDirectory.appendingPathComponent(name)) } catch { fail("could not write \(name): \(error)") }
}
