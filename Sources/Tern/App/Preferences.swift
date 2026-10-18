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

/// Where the cursor goes when the open conversation leaves the list (archive, delete, snooze, move).
enum AfterTriage: String, CaseIterable, Identifiable {
    /// The conversation below it, else the one above.
    case next
    /// The conversation above it, else the one below.
    case previous
    /// Like `next`, and the conversation open over the list closes.
    case list

    var id: String { rawValue }

    var title: String {
        switch self {
        case .next: "Next"
        case .previous: "Previous"
        case .list: "Back to list"
        }
    }
}

/// When a conversation on screen counts as read.
enum MarkReadMode: String, CaseIterable, Identifiable {
    /// As soon as it is on screen, also when moving onto it with j or k.
    case instantly
    /// Opening marks it read at once; moving onto it with j or k waits a moment, so skimming doesn't.
    case afterDelay
    /// Never by itself; the user marks it read.
    case manually

    var id: String { rawValue }

    var title: String {
        switch self {
        case .instantly: "Instantly"
        case .afterDelay: "After a moment"
        case .manually: "Manually"
        }
    }

    /// How long a conversation reached with j or k stays on screen before it is marked read.
    static let dwell: TimeInterval = 1.5
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
    /// The mailbox sidebar, hidden behind the bottom bar's toggle by default.
    var sidebarOpen: Bool { didSet { save("sidebarOpen", sidebarOpen) } }
    /// ⌘\: list and reader side by side instead of the reader opening over the list.
    var readingPane: Bool { didSet { save("readingPane", readingPane) } }
    /// Width of the list next to the reading pane.
    var listWidth: Double { didSet { save("listWidth", listWidth) } }
    /// Tabs the user pinned after the inbox tabs, as `ListTab.pinKey` strings.
    var pinnedTabs: [String] { didSet { save("pinnedTabs", pinnedTabs) } }
    var moreExpanded: Bool { didSet { save("moreExpanded", moreExpanded) } }
    /// Palette command ids, most recent first.
    var recentCommands: [String] { didSet { save("recentCommands", recentCommands) } }
    var afterTriage: AfterTriage { didSet { save("afterTriage", afterTriage.rawValue) } }
    var markRead: MarkReadMode { didSet { save("markRead", markRead.rawValue) } }

    private init() {
        appearance = AppearanceMode(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        density = Density(rawValue: defaults.string(forKey: "density") ?? "") ?? .auto
        dimReadByAge = defaults.bool(forKey: "dimReadByAge")
        showSenderLogos = defaults.object(forKey: "showSenderLogos") as? Bool ?? true
        notificationsEnabled = defaults.object(forKey: "notifications") as? Bool ?? true
        notifyOnlyImportant = defaults.object(forKey: "notifyOnlyImportant") as? Bool ?? true
        splitInbox = defaults.object(forKey: "splitInbox") as? Bool ?? true
        sidebarOpen = defaults.bool(forKey: "sidebarOpen")
        readingPane = defaults.bool(forKey: "readingPane")
        listWidth = defaults.object(forKey: "listWidth") as? Double ?? 452
        pinnedTabs = defaults.stringArray(forKey: "pinnedTabs") ?? []
        moreExpanded = defaults.bool(forKey: "moreExpanded")
        recentCommands = defaults.stringArray(forKey: "recentCommands") ?? []
        afterTriage = AfterTriage(rawValue: defaults.string(forKey: "afterTriage") ?? "") ?? .next
        markRead = MarkReadMode(rawValue: defaults.string(forKey: "markRead") ?? "") ?? .afterDelay
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
