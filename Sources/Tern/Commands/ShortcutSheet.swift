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
                                            Text(row.shortcut).font(.mono(12)).foregroundStyle(Color(Theme.text3))
                                        }
                                        .frame(height: 24)
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

/// Rows for the shortcut sheet and the Settings → Shortcuts table.
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
                  let shortcut = command.chord ?? command.keys.map(\.display).joined(separator: " ").nilIfEmpty
            else { return nil }
            return Row(id: command.id, title: command.title, shortcut: shortcut, group: command.group)
        } + [Row(id: "scope.n", title: "Account 1–9", shortcut: "⌘1–⌘9", group: .accounts)]
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
