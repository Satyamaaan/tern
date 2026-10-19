import SwiftUI

/// `?`: every shortcut from the registry, grouped like the palette.
struct ShortcutSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rows = ShortcutTable.rows(model.registry)
        let groups = Dictionary(grouping: rows, by: \.group)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard shortcuts")
                    .font(.ui(15, .semibold))
                    .foregroundStyle(Color(Theme.text1))
                Spacer()
                Keycap(text: "esc")
            }
            .padding(.horizontal, 22)
            .frame(height: 52)
            Hairline()
            ScrollView {
                HStack(alignment: .top, spacing: 28) {
                    ForEach(Self.columns, id: \.self) { column in
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(column, id: \.self) { group in
                                if let items = groups[group], !items.isEmpty {
                                    CapsLabel(text: group.rawValue)
                                        .frame(height: 30, alignment: .bottom)
                                        .padding(.bottom, 4)
                                    ForEach(items) { row in
                                        HStack {
                                            Text(row.title).font(.ui(13)).foregroundStyle(Color(Theme.text1))
                                            Spacer(minLength: 12)
                                            ShortcutKeys(shortcut: row.shortcut)
                                        }
                                        .frame(height: 26)
                                    }
                                }
                            }
                        }
                        .frame(width: 260)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 18)
            }
            .frame(maxHeight: 520)
        }
        .frame(width: 600)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color(Theme.raised)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Color(Theme.hairlineStrong), lineWidth: 1))
        .overlayShadow()
    }

    private static let columns: [[CommandGroup]] = [[.actions], [.goTo, .accounts, .settings]]
}

/// A shortcut as small keycaps, one per space-separated key ("g i", "c ⌘N").
struct ShortcutKeys: View {
    let shortcut: String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(shortcut.split(separator: " ").enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.numeric(11, .medium))
                    .foregroundStyle(Color(Theme.text2))
                    .padding(.horizontal, 4)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Color(Theme.hover)))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).strokeBorder(Color(Theme.hairline)))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Rows for the shortcut sheet, and the commands Settings → Shortcuts lists.
enum ShortcutTable {
    struct Row: Identifiable, Hashable {
        var id: String
        var title: String
        var shortcut: String
        var group: CommandGroup
    }

    @MainActor
    static func rows(_ registry: CommandRegistry?) -> [Row] {
        guard let registry else { return [] }
        return registry.commands.compactMap { command in
            guard !command.paletteOnly, command.id.hasPrefix("scope.") == false || command.id == "scope.all",
                  let shortcut = command.keys.map(\.display).joined(separator: " ").nilIfEmpty ?? command.chord
            else { return nil }
            return Row(id: command.id, title: title(command), shortcut: shortcut, group: command.group)
        } + [Row(id: "scope.n", title: "Account 1–9", shortcut: "⌘1–⌘9", group: .accounts)]
    }

    /// Commands whose keys Settings lets the user change, in registry order: everything in the menus or
    /// the palette, and keys-only commands like j and k. The account slots get one row of their own.
    @MainActor
    static func editable(_ registry: CommandRegistry) -> [Command] {
        registry.commands.filter { command in
            guard !command.paletteOnly, command.isVisible(), !(command.id.hasPrefix("scope.") && command.id != "scope.all") else { return false }
            return !command.hiddenInPalette || command.chord != nil || !(registry.defaultKeys[command.id] ?? []).isEmpty
        }
    }

    /// The command's name in shortcut lists. Toggles get one name for both directions.
    static func title(_ command: Command) -> String { toggleTitles[command.id] ?? command.title }

    /// What the shortcut filter matches: names, aliases and keys.
    static func searchText(_ command: Command) -> String {
        ([title(command), command.title] + command.aliases + command.keys.map(\.display) + [command.chord ?? ""])
            .joined(separator: " ").lowercased()
    }

    private static let toggleTitles = [
        "star": "Star or Unstar",
        "unread": "Mark Read or Unread",
        "needsReply": "Needs Reply",
        "splitInbox": "Split Inbox",
        "toggleSidebar": "Show or Hide Sidebar",
        "readingPane": "Show or Hide Reading Pane",
        "appearance.toggle": "Switch Light and Dark",
        "dimRead": "Dim Old Read Mail",
        "senderLogos": "Show or Hide Sender Logos",
        "find": "Find in Conversation or Search",
        "trash": "Move to Trash or Discard Draft",
    ]
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
