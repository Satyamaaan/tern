import AppKit
import SwiftUI

/// Line icons from the mockup, drawn on a 16×16 grid with a 1.6 stroke. Stored as SVG path data so
/// they stay identical to `design/mockup.html`.
enum Icon: String, CaseIterable {
    case inbox, needsReply, snoozed, starred, drafts, sent, allMail, more, spam, trash, label
    case compose, search, done, ellipsis, chevronDown, paperclip, plus, file, archive, pencil, person

    var svg: String {
        switch self {
        case .inbox: "M2 9l2-6h8l2 6v4H2z M2 9h3.5l1 1.5h3l1-1.5H14"
        case .needsReply: "M6 4L2 8l4 4 M2.5 8H10a4 4 0 014 4"
        case .snoozed: "M2.5 8.5a5.5 5.5 0 1011 0a5.5 5.5 0 10-11 0 M8 5.5v3l2 1.5"
        case .starred: "M8 2l1.8 3.8 4.2.5-3.1 2.9.8 4.1L8 11.3 4.3 13.3l.8-4.1L2 6.3l4.2-.5z"
        case .drafts, .compose, .pencil: "M3 13l1-3.5L11 2.5l2.5 2.5L6.5 12z M9.5 4l2.5 2.5"
        case .sent: "M2 8l12-5-5 12-2-5z"
        case .allMail: "M4 3h8a2 2 0 012 2v6a2 2 0 01-2 2H4a2 2 0 01-2-2V5a2 2 0 012-2z M2 6h12"
        case .more, .ellipsis: "M3.4 8a.6.6 0 101.2 0a.6.6 0 10-1.2 0 M7.4 8a.6.6 0 101.2 0a.6.6 0 10-1.2 0 M11.4 8a.6.6 0 101.2 0a.6.6 0 10-1.2 0"
        case .spam: "M5.5 2h5L14 5.5v5L10.5 14h-5L2 10.5v-5z M8 5v3.5 M8 10.8v.2"
        case .trash: "M2.5 4.5h11 M6 4.5V3h4v1.5 M4 4.5l.7 8.5h6.6l.7-8.5 M6.8 7v4 M9.2 7v4"
        case .label: "M2.5 3h6l5 5-5 5-6-6z M5.5 6a.5.5 0 101 0a.5.5 0 10-1 0"
        case .search: "M2.5 7a4.5 4.5 0 109 0a4.5 4.5 0 10-9 0 M10.5 10.5L14 14"
        case .done: "M3 8.5l3 3 7-7"
        case .chevronDown: "M4 6l4 4 4-4"
        case .paperclip: "M10.5 5L5.8 9.7a1.5 1.5 0 002.1 2.1L13 6.7a3 3 0 00-4.2-4.2L3.6 7.6"
        case .plus: "M8 3v10 M3 8h10"
        case .file: "M4 2h5l3 3v9H4z M9 2v3h3"
        case .archive: "M2 3h12v3H2z M3 6v7h10V6 M6.5 9h3"
        case .person: "M5.5 5.5a2.5 2.5 0 105 0a2.5 2.5 0 10-5 0 M2.5 13.5c.7-2.3 2.8-3.5 5.5-3.5s4.8 1.2 5.5 3.5"
        }
    }

    /// The icon in a 16×16 box, y down.
    var path: CGPath { Self.cache[self]! }

    private static let cache: [Icon: CGPath] = Dictionary(uniqueKeysWithValues: Icon.allCases.map { ($0, SVGPath.parse($0.svg)) })
}

extension Icon {
    /// The icon as a template image, for places that only take images (menu labels, AppKit buttons).
    func image(size: CGFloat = 15, lineWidth: CGFloat = 1.6) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            self.draw(in: rect, color: .black, lineWidth: lineWidth)
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// A stroked line icon for SwiftUI.
struct IconView: View {
    let icon: Icon
    var size: CGFloat = 15
    var color: Color = Color(Theme.text2)
    var lineWidth: CGFloat = 1.6

    var body: some View {
        IconShape(icon: icon)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth * size / 16, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

struct IconShape: Shape {
    let icon: Icon

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 16
        var transform = CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale)
        return Path(icon.path.copy(using: &transform) ?? icon.path)
    }
}

extension Icon {
    /// Strokes the icon into the current AppKit graphics context (flipped views).
    func draw(in rect: CGRect, color: NSColor, lineWidth: CGFloat = 1.6) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = rect.width / 16
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: scale, y: scale)
        context.addPath(path)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
        context.restoreGState()
    }
}

/// Minimal SVG path-data parser: M L H V C S Q A Z, absolute and relative.
enum SVGPath {
    static func parse(_ data: String) -> CGPath {
        let path = CGMutablePath()
        var scanner = Tokens(data)
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var command: Character = "M"

        while let next = scanner.peekCommandOrNumber() {
            if case .command(let c) = next {
                command = c
                scanner.advance()
            }
            let relative = command.isLowercase
            func point() -> CGPoint {
                let x = scanner.number(), y = scanner.number()
                return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            switch command.uppercased().first! {
            case "M":
                current = point()
                start = current
                path.move(to: current)
                command = relative ? "l" : "L"
                lastControl = nil
            case "L":
                current = point()
                path.addLine(to: current)
                lastControl = nil
            case "H":
                let x = scanner.number()
                current.x = relative ? current.x + x : x
                path.addLine(to: current)
                lastControl = nil
            case "V":
                let y = scanner.number()
                current.y = relative ? current.y + y : y
                path.addLine(to: current)
                lastControl = nil
            case "C":
                let c1 = point(), c2 = point(), end = point()
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2
                current = end
            case "S":
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let c2 = point(), end = point()
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2
                current = end
            case "Q":
                let c = point(), end = point()
                path.addQuadCurve(to: end, control: c)
                lastControl = c
                current = end
            case "A":
                let rx = scanner.number(), ry = scanner.number(), rotation = scanner.number()
                let large = scanner.flag(), sweep = scanner.flag()
                let end = point()
                addArc(path, from: current, to: end, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                current = end
                lastControl = nil
            case "Z":
                path.closeSubpath()
                current = start
                lastControl = nil
                // A number directly after Z would be malformed; skip to the next command.
                if case .number = scanner.peekCommandOrNumber() { scanner.advance() }
            default:
                scanner.advance()
            }
        }
        return path
    }

    /// Endpoint arc to cubic Béziers (SVG 1.1 implementation notes, F.6).
    private static func addArc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx: CGFloat, ry: CGFloat,
                               rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = sqrt(max(0, num / den))
        if large == sweep { coef = -coef }
        let cx1 = coef * rx * y1 / ry
        let cy1 = -coef * ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let t = 4 / 3 * tan(step / 4)
        var theta = theta1
        func pointAt(_ a: CGFloat) -> CGPoint {
            let x = rx * cos(a), y = ry * sin(a)
            return CGPoint(x: cosPhi * x - sinPhi * y + cx, y: sinPhi * x + cosPhi * y + cy)
        }
        func derivative(_ a: CGFloat) -> CGPoint {
            let x = -rx * sin(a), y = ry * cos(a)
            return CGPoint(x: cosPhi * x - sinPhi * y, y: sinPhi * x + cosPhi * y)
        }
        for _ in 0..<segments {
            let a = pointAt(theta), b = pointAt(theta + step)
            let da = derivative(theta), db = derivative(theta + step)
            path.addCurve(
                to: b,
                control1: CGPoint(x: a.x + t * da.x, y: a.y + t * da.y),
                control2: CGPoint(x: b.x - t * db.x, y: b.y - t * db.y))
            theta += step
        }
    }

    private struct Tokens {
        enum Token { case command(Character), number }
        let chars: [Character]
        var index = 0

        init(_ string: String) { chars = Array(string) }

        mutating func skipSeparators() {
            while index < chars.count, chars[index] == " " || chars[index] == "," || chars[index] == "\n" { index += 1 }
        }

        mutating func peekCommandOrNumber() -> Token? {
            skipSeparators()
            guard index < chars.count else { return nil }
            let c = chars[index]
            return c.isLetter ? .command(c) : .number
        }

        mutating func advance() { index += 1 }

        mutating func flag() -> Bool {
            skipSeparators()
            guard index < chars.count else { return false }
            defer { index += 1 }
            return chars[index] == "1"
        }

        mutating func number() -> CGFloat {
            skipSeparators()
            var text = ""
            var seenDot = false, seenExponent = false
            while index < chars.count {
                let c = chars[index]
                if c == "-" || c == "+" {
                    if !text.isEmpty && !(text.last == "e" || text.last == "E") { break }
                } else if c == "." {
                    if seenDot || seenExponent { break }
                    seenDot = true
                } else if c == "e" || c == "E" {
                    seenExponent = true
                } else if !c.isNumber {
                    break
                }
                text.append(c)
                index += 1
            }
            return CGFloat(Double(text) ?? 0)
        }
    }
}
