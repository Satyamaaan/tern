import QuartzCore
import SwiftUI

/// Tern's motion values (design/DESIGN.md, Motion), so every surface moves alike.
enum Motion {
    /// Quick and soft at the end: the cursor slide, sliding fills, reveals and entrances.
    static let timing = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)

    /// The house curve over `duration` seconds.
    static func ease(_ duration: Double) -> Animation { .timingCurve(0.2, 0.9, 0.25, 1, duration: duration) }

    /// The reader over the list, the sidebar, the pane, onboarding steps.
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)

    /// What Reduce Motion gets instead of movement: a short crossfade.
    static let reduced = Animation.easeOut(duration: 0.08)

    /// Cursor slide from row to row.
    static let cursor: Double = 0.13
    /// Secondary controls revealed on hover (fade in only; they hide at once).
    static let hover: Double = 0.09
    /// Content revealed by a click (a message, quoted text, a hint line).
    static let reveal: Double = 0.14
    /// A small overlay opened from the keyboard: the palette, the chord hint.
    static let overlay: Double = 0.12
    /// A toast or card coming in, and going out.
    static let enter: Double = 0.16
    static let exit: Double = 0.12
    /// Rows leaving after triage, coming back on undo or arriving at the top, and the list closing up around them.
    static let list: Double = 0.16
    /// How long a pending key chord waits before its hint shows, so fluent typing never flashes it.
    static let hesitation: Double = 0.4

    /// `animation`, or the Reduce Motion crossfade.
    static func or(reduced reduceMotion: Bool, _ animation: Animation) -> Animation {
        reduceMotion ? reduced : animation
    }
}
