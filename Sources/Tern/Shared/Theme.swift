import AppKit
import CoreText
import SwiftUI
import TernCore

/// Design tokens from design/DESIGN.md. Colors resolve per appearance (light / dark).
enum Theme {
    static let bg = dynamic(light: 0xFFFFFF, dark: 0x141414)
    static let sidebar = dynamic(light: 0xF6F6F5, dark: 0x0E0E0E)
    static let raised = dynamic(light: 0xFFFFFF, dark: 0x1A1A1A)
    static let hover = dynamic(light: 0xF1F1EF, dark: 0x1F1F1F)
    static let selected = dynamic(light: 0xEBEBE8, dark: 0x272727)
    static let hairline = dynamic(light: 0xE6E6E2, dark: 0x2A2A2A)
    static let hairlineStrong = dynamic(light: 0xD6D6D1, dark: 0x3A3A3A)
    static let text1 = dynamic(light: 0x161616, dark: 0xECECEA)
    static let text2 = dynamic(light: 0x5F5F5A, dark: 0xA3A39E)
    static let text3 = dynamic(light: 0x74746E, dark: 0x85857F)
    /// The one strong colour: near-black in light, near-white in dark. Primary button fill, unread and
    /// needs-reply dots, the Flock, focus rings, links. The UI has no hue of its own.
    static let ink = dynamic(light: 0x18181B, dark: 0xEDEDEA)
    /// `ink` under the pointer.
    static let inkHover = dynamic(light: 0x2E2E33, dark: 0xD9D9D5)
    /// `ink` while pressed.
    static let inkPressed = dynamic(light: 0x45454B, dark: 0xC4C4BF)
    /// Soft neutral fill for "needs you" chips and other soft states.
    static let inkSoft = dynamic(light: 0xE4E4E0, dark: 0x303030)
    /// Label on an `ink` fill.
    static let onInk = dynamic(light: 0xFFFFFF, dark: 0x141414)

    static let accountHues: [UInt32] = [0x4F7CAC, 0x8A6FB3, 0x3E9A86, 0x8F7F62, 0xB05C7A, 0x6B7F4A]
    static let projectHues: [UInt32] = [0x6B6B66, 0x2F6FD8, 0x23764A, 0x8A6FB3, 0x8F7F62, 0xB05C7A, 0x3E9A86, 0x5E6B7A]

    static func accountColor(_ index: Int) -> NSColor { rgb(accountHues[abs(index) % accountHues.count]) }
    static func projectColor(_ index: Int) -> NSColor { rgb(projectHues[abs(index) % projectHues.count]) }

    /// Letter avatars: initials on a soft neutral disc.
    static let avatarFill = dynamic(light: 0xE8E8E4, dark: 0x2E2E2E)
    static let avatarText = dynamic(light: 0x55554F, dark: 0xB4B4AE)

    /// The small colour on tab and tag icons, the only hue in the chrome. Labels stay `text2`; "needs
    /// reply" stays `ink`, because what needs you reads through ink, not colour.
    static func categoryColor(_ category: MailCategory) -> NSColor {
        switch category {
        case .people: dynamic(light: 0x2F6FD8, dark: 0x6EA2FF)
        case .newsletter: dynamic(light: 0x1E9E5A, dark: 0x4CC38A)
        case .notification: dynamic(light: 0xC98500, dark: 0xF0B429)
        case .receipt: dynamic(light: 0x138A7E, dark: 0x3CC8B4)
        case .calendar: dynamic(light: 0x4F5BD5, dark: 0x8C95FF)
        case .promotion: dynamic(light: 0xDD6B1D, dark: 0xFF9E57)
        case .security: dynamic(light: 0xC2334A, dark: 0xFF6B81)
        case .other: text3
        }
    }

    /// The Important tab's purple tag.
    static let importantColor = dynamic(light: 0x7C5CDB, dark: 0xA78BFA)

    /// Avatar tint for an account in the unified view: the account hue, soft, readable in both themes.
    static func accountTint(_ index: Int) -> (fill: NSColor, text: NSColor) {
        let hue = accountHues[abs(index) % accountHues.count]
        let base = rgb(hue)
        return (
            NSColor(name: nil) { appearance in
                base.withAlphaComponent(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.32 : 0.18)
            },
            NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return base.blended(withFraction: dark ? 0.55 : 0.35, of: dark ? .white : .black) ?? base
            }
        )
    }

    /// Corner radii. Only avatars, status dots and the Flock are round; nothing is a pill.
    enum Radius {
        /// Chips, recipient tokens, keycaps, search marks.
        static let chip: CGFloat = 4
        /// Buttons, icon buttons, fields, segmented controls.
        static let control: CGFloat = 6
        /// List, sidebar, menu and palette rows.
        static let row: CGFloat = 6
        /// Small floating things: toasts, the chord HUD, the formatting bar, the link preview.
        static let overlay: CGFloat = 8
        /// Panels: ⌘K, dropdowns, popovers, the composer card, the shortcut sheet.
        static let card: CGFloat = 10
    }

    /// Control heights.
    enum Control {
        static let regular: CGFloat = 28
        static let small: CGFloat = 24
    }

    // MARK: Fonts

    /// Registers the bundled fonts once at launch. Falls back to system fonts if missing.
    static func registerFonts() {
        let urls = [
            Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../../Resources/Fonts").standardized,
        ].compactMap { $0 }
        for directory in urls {
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { continue }
            let fonts = files.filter { $0.pathExtension == "ttf" || $0.pathExtension == "otf" }
            guard !fonts.isEmpty else { continue }
            CTFontManagerRegisterFontURLs(fonts as CFArray, .process, true, nil)
            return
        }
    }

    enum Weight { case regular, medium, semibold }

    /// Inter, the one typeface: every label, row and the reader.
    static func ui(_ size: CGFloat, _ weight: Weight = .regular) -> NSFont {
        FontCache.font(.text, size, weight)
    }

    /// Inter with tabular figures, so times, counts and keycaps line up.
    static func numeric(_ size: CGFloat = 12, _ weight: Weight = .regular) -> NSFont {
        FontCache.font(.numeric, size, weight)
    }

    /// Inter Display SemiBold, the optical size cut for large text: the open thread's subject, empty states
    /// and headlines.
    static func display(_ size: CGFloat) -> NSFont {
        FontCache.font(.display, size, .semibold)
    }

    // MARK: Helpers

    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark) : rgb(light)
        }
    }
}

extension Color {
    init(_ color: NSColor, opacity: Double = 1) {
        self = Color(nsColor: color).opacity(opacity)
    }
}

extension Font {
    static func ui(_ size: CGFloat, _ weight: Theme.Weight = .regular) -> Font { Font(Theme.ui(size, weight)) }
    static func numeric(_ size: CGFloat = 12, _ weight: Theme.Weight = .regular) -> Font { Font(Theme.numeric(size, weight)) }
    static func display(_ size: CGFloat) -> Font { Font(Theme.display(size)) }
}

/// Fonts are made once per style, size and weight: rows ask for them on every draw.
private enum FontCache {
    enum Style { case text, numeric, display }

    private struct Key: Hashable {
        let style: Style
        let size: CGFloat
        let weight: Theme.Weight
    }

    nonisolated(unsafe) private static var fonts: [Key: NSFont] = [:]
    private static let lock = NSLock()

    static func font(_ style: Style, _ size: CGFloat, _ weight: Theme.Weight) -> NSFont {
        let key = Key(style: style, size: size, weight: weight)
        lock.lock()
        defer { lock.unlock() }
        if let font = fonts[key] { return font }
        let font = make(style, size, weight)
        fonts[key] = font
        return font
    }

    private static func make(_ style: Style, _ size: CGFloat, _ weight: Theme.Weight) -> NSFont {
        let name = switch (style, weight) {
        case (.display, _): "InterDisplay-SemiBold"
        case (_, .regular): "Inter-Regular"
        case (_, .medium): "Inter-Medium"
        case (_, .semibold): "Inter-SemiBold"
        }
        let systemWeight: NSFont.Weight = weight == .regular ? .regular : weight == .medium ? .medium : .semibold
        let base = NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: style == .display ? .semibold : systemWeight)
        guard style == .numeric else { return base }
        let tabular = base.fontDescriptor.addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]],
        ])
        return NSFont(descriptor: tabular, size: size) ?? base
    }
}

// MARK: - Shell additions

extension Theme {

    /// Names for `projectHues`, in order, for colour menus.
    static let projectColorNames = ["Graphite", "Blue", "Green", "Violet", "Sand", "Rose", "Teal", "Slate"]

    /// A small filled circle for menu items (account and project colours).
    static func swatch(_ color: NSColor, size: CGFloat = 10) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
    }
}
