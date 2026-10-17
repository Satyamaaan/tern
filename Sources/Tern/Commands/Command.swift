import AppKit

/// Palette groups, in display order.
enum CommandGroup: String, CaseIterable {
    case actions = "Actions"
    case goTo = "Go to"
    case threads = "Threads"
    case projects = "Projects"
    case labels = "Labels"
    case accounts = "Accounts"
    case settings = "Settings"
}

/// Main menu bar menus a command can appear in.
enum MenuName: String, CaseIterable {
    case app = "Tern", file = "File", edit = "Edit", view = "View", mailbox = "Mailbox"
    case message = "Message", go = "Go", window = "Window", help = "Help"
}

/// One thing the user can do. The registry is the single list behind the menu bar, the ⌘K palette,
/// the shortcut sheet and keyboard handling.
struct Command: Identifiable {
    let id: String
    var title: String
    var group: CommandGroup
    /// The first shortcut is the one shown; the others also trigger it.
    var keys: [KeyShortcut] = []
    /// A two-key sequence such as "g i".
    var chord: String?
    var menu: MenuName?
    /// Commands in the same menu with different sections get a separator between them.
    var section = 0
    /// Extra words the palette matches ("done" finds Archive).
    var aliases: [String] = []
    /// Shown in the palette but not in menus or the shortcut sheet.
    var paletteOnly = false
    /// Hidden from the palette (e.g. j/k, which make no sense there).
    var hiddenInPalette = false
    /// While the reader has focus, bare-key handling leaves this key to the reader (e.g. `p`).
    var yieldsToReader = false
    var isEnabled: @MainActor () -> Bool = { true }
    /// Title that changes with state ("Star" / "Unstar"); falls back to `title`.
    var currentTitle: (@MainActor () -> String)?
    /// Menu items that are only visible when this returns true (account slots).
    var isVisible: @MainActor () -> Bool = { true }
    var run: @MainActor () -> Void

    @MainActor var displayTitle: String { currentTitle?() ?? title }

    /// The shortcut text shown on keycaps: the chord or the primary key.
    var shortcutText: String? { chord ?? keys.first?.display }

    /// The key equivalent menus use: the first ⌘ shortcut (menus only fire those), else the first key.
    var menuKey: KeyShortcut? { keys.first { !$0.isBare } ?? keys.first }
}
