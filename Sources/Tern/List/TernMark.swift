import SwiftUI

/// Tern's mark: an Arctic tern in flight drawn as one continuous open stroke, from the tip of the lower tail
/// streamer along the belly to the beak, over the capped head, up the wing to its bent wrist and tip, back down
/// the trailing edge and out along the upper streamer. Stroke it (and animate it with `.trim`); it keeps its
/// 2:1 shape and centres itself in any rect.
struct TernMark: Shape {
    func path(in rect: CGRect) -> Path {
        Path(TernGlyph.stroke(in: rect))
    }
}

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
