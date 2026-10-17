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
    static let accent = dynamic(light: 0xE5461E, dark: 0xFF6B3F)
    static let accentInk = dynamic(light: 0xC23A16, dark: 0xFF8C66)
    static let accentSoft = dynamic(light: 0xFDECE6, dark: 0x2E1913)
    /// Label on a primary (accent) button.
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x141414)
    /// Primary button fill.
    static let primaryFill = dynamic(light: 0xC23A16, dark: 0xFF6B3F)

    static let accountHues: [UInt32] = [0x4F7CAC, 0x8A6FB3, 0x3E9A86, 0xC08A3E, 0xB05C7A, 0x6B7F4A]
    static let projectHues: [UInt32] = [0xE5461E, 0x2F6FD8, 0x23764A, 0x8A6FB3, 0xC08A3E, 0xB05C7A, 0x3E9A86, 0x5E6B7A]

    static func accountColor(_ index: Int) -> NSColor { rgb(accountHues[abs(index) % accountHues.count]) }
    static func projectColor(_ index: Int) -> NSColor { rgb(projectHues[abs(index) % projectHues.count]) }

    /// Chip text color for a category; the chip background is this color at 12%.
    static func categoryColor(_ category: MailCategory) -> NSColor {
        switch category {
        case .newsletter: dynamic(light: 0x6E5BD0, dark: 0xA89BF5)
        case .receipt: dynamic(light: 0x23764A, dark: 0x5CCB91)
        case .notification: dynamic(light: 0x5E6B7A, dark: 0x94A3B3)
        case .calendar: dynamic(light: 0x2F6FD8, dark: 0x78A8FF)
        case .promotion: dynamic(light: 0x96620E, dark: 0xE0B04F)
        case .security: dynamic(light: 0xB4232F, dark: 0xFF8A93)
        case .people, .other: text2
        }
    }

    enum Radius {
        static let row: CGFloat = 8
        static let card: CGFloat = 12
        static let chip: CGFloat = 6
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

    static func ui(_ size: CGFloat, _ weight: Weight = .regular) -> NSFont {
        let name = switch weight {
        case .regular: "Geist-Regular"
        case .medium: "Geist-Medium"
        case .semibold: "Geist-SemiBold"
        }
        return NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight == .regular ? .regular : weight == .medium ? .medium : .semibold)
    }

    static func mono(_ size: CGFloat = 12, _ weight: Weight = .regular) -> NSFont {
        NSFont(name: weight == .regular ? "GeistMono-Regular" : "GeistMono-Medium", size: size)
            ?? .monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    /// The serif voice: open-thread subject and empty states only.
    static func serif(_ size: CGFloat, italic: Bool = false) -> NSFont {
        NSFont(name: italic ? "Newsreader16pt-Italic" : "Newsreader16pt-Medium", size: size)
            ?? NSFont(name: "Georgia", size: size) ?? .systemFont(ofSize: size)
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
    static func mono(_ size: CGFloat = 12, _ weight: Theme.Weight = .regular) -> Font { Font(Theme.mono(size, weight)) }
    static func serif(_ size: CGFloat, italic: Bool = false) -> Font { Font(Theme.serif(size, italic: italic)) }
}
