import AppKit
import TernCore

/// The reader page, its script and the bundled fonts. In the app they live in `Contents/Resources`
/// (`build.sh` copies `Resources/Web` and `Resources/Fonts`); `swift run` reads them from the source tree.
@MainActor
enum ReaderResources {
    static let webDirectory = directory("Web")
    static let fontsDirectory = directory("Fonts")

    /// reader.html with the design tokens and both style sheets inlined.
    static func page() -> String {
        let template = read("reader.html") ?? "<!doctype html><html><body><main id=\"thread\"></main></body></html>"
        return template
            .replacingOccurrences(of: "/*TOKENS*/", with: cssTokens())
            .replacingOccurrences(of: "/*READER_CSS*/", with: read("reader.css") ?? "")
            .replacingOccurrences(of: "/*MAIL_CSS*/", with: read("mail.css") ?? "")
    }

    static let script = read("reader.js") ?? ""

    private static var fontCache: [String: Data] = [:]

    static func font(named name: String) -> Data? {
        if let cached = fontCache[name] { return cached }
        guard !name.contains("/"), let directory = fontsDirectory,
              let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        fontCache[name] = data
        return data
    }

    /// Shown in place of an inline image whose data isn't available.
    static let missingImage = Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="120" height="80" viewBox="0 0 120 80" preserveAspectRatio="xMidYMid meet">\
        <rect width="120" height="80" rx="6" fill="#8a8a85" fill-opacity="0.12"/>\
        <g fill="none" stroke="#8a8a85" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" opacity="0.7">\
        <rect x="46" y="28" width="28" height="24" rx="3"/><circle cx="54" cy="36" r="2.5"/><path d="M47 50l9-9 6 6 4-4 7 7"/></g></svg>
        """.utf8)

    /// CSS custom properties from `Theme`, resolved for light and dark.
    static func cssTokens() -> String {
        let colors: [(String, NSColor)] = [
            ("bg", Theme.bg), ("raised", Theme.raised), ("hover", Theme.hover), ("selected", Theme.selected),
            ("hairline", Theme.hairline), ("hairlineStrong", Theme.hairlineStrong), ("text1", Theme.text1),
            ("text2", Theme.text2), ("text3", Theme.text3), ("accent", Theme.accent), ("accentInk", Theme.accentInk),
            ("accentSoft", Theme.accentSoft),
        ] + MailCategory.allCases.map { ("cat-\($0.rawValue)", Theme.categoryColor($0)) }
        func block(_ name: NSAppearance.Name) -> String {
            var css = ""
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                for (token, color) in colors { css += "--\(token): \(hex(color)); " }
            }
            return css
        }
        let light = block(.aqua)
        return ":root { \(light)}\n:root[data-theme=\"dark\"] { \(block(.darkAqua))}\n"
            + "@media print { :root, :root[data-theme=\"dark\"] { color-scheme: light; \(light)} }"
    }

    nonisolated static func hex(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#000000" }
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }

    private static func read(_ name: String) -> String? {
        guard let directory = webDirectory else { return nil }
        return try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    private static func directory(_ name: String) -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../../Resources/\(name)").standardized,
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
