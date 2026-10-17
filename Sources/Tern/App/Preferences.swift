import AppKit
import Observation

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// True when the app is showing dark right now, whichever mode picked it.
    @MainActor static var showsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// The opposite of what is showing now: what ⇧⌘L and the sidebar's sun/moon switch to.
    @MainActor static var flipped: AppearanceMode { showsDark ? .light : .dark }
}

/// List row layout. Auto picks one line when the list is at least 560 px wide.
enum Density: String, CaseIterable, Identifiable {
    case auto, compact, comfortable

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Interface preferences, stored in UserDefaults so they apply before the database opens.
/// Mail-related settings shared with other lanes (AI) live in the database `setting` table.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    @ObservationIgnored private let defaults = UserDefaults.standard

    var appearance: AppearanceMode { didSet { save("appearance", appearance.rawValue); NSApp.appearance = appearance.appearance } }
    var density: Density { didSet { save("density", density.rawValue) } }
    /// Fades read mail older than a month.
    var dimReadByAge: Bool { didSet { save("dimReadByAge", dimReadByAge) } }
    /// Shows each sender's site icon (fetched once, cached on this Mac) instead of initials.
    var showSenderLogos: Bool { didSet { save("showSenderLogos", showSenderLogos) } }
    var notificationsEnabled: Bool { didSet { save("notifications", notificationsEnabled) } }
    var notifyOnlyImportant: Bool { didSet { save("notifyOnlyImportant", notifyOnlyImportant) } }
    var splitInbox: Bool { didSet { save("splitInbox", splitInbox) } }
    var sidebarCollapsed: Bool { didSet { save("sidebarCollapsed", sidebarCollapsed) } }
    var listWidth: Double { didSet { save("listWidth", listWidth) } }
    var moreExpanded: Bool { didSet { save("moreExpanded", moreExpanded) } }
    /// Palette command ids, most recent first.
    var recentCommands: [String] { didSet { save("recentCommands", recentCommands) } }

    private init() {
        appearance = AppearanceMode(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        density = Density(rawValue: defaults.string(forKey: "density") ?? "") ?? .auto
        dimReadByAge = defaults.bool(forKey: "dimReadByAge")
        showSenderLogos = defaults.object(forKey: "showSenderLogos") as? Bool ?? true
        notificationsEnabled = defaults.object(forKey: "notifications") as? Bool ?? true
        notifyOnlyImportant = defaults.object(forKey: "notifyOnlyImportant") as? Bool ?? true
        splitInbox = defaults.object(forKey: "splitInbox") as? Bool ?? true
        sidebarCollapsed = defaults.bool(forKey: "sidebarCollapsed")
        listWidth = defaults.object(forKey: "listWidth") as? Double ?? 452
        moreExpanded = defaults.bool(forKey: "moreExpanded")
        recentCommands = defaults.stringArray(forKey: "recentCommands") ?? []
    }

    func noteRecent(_ commandId: String) {
        recentCommands = Array(([commandId] + recentCommands.filter { $0 != commandId }).prefix(8))
    }

    /// Threads cleared from the inbox today (archive, snooze, trash…), for the inbox-zero line.
    var clearedToday: Int {
        get { access(keyPath: \.clearedToday); return defaults.integer(forKey: Self.clearedKey) }
        set { withMutation(keyPath: \.clearedToday) { defaults.set(newValue, forKey: Self.clearedKey) } }
    }

    private static var clearedKey: String {
        "cleared-" + Date().formatted(.iso8601.year().month().day())
    }

    private func save(_ key: String, _ value: Any) { defaults.set(value, forKey: key) }
}
