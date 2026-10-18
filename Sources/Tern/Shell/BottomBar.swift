import SwiftUI

/// The small floating toolbar under the list: search, the sidebar and settings.
struct BottomBar: View {
    @Environment(AppModel.self) private var model

    static let height: CGFloat = 36

    var body: some View {
        HStack(spacing: 2) {
            BarButton(icon: .search, help: hint("Search", "search"), on: model.searchShown) {
                if model.searchShown { model.endSearch(restoreFocus: true) } else { model.beginSearch() }
            }
            BarButton(icon: .sidebar, help: hint(model.prefs.sidebarOpen ? "Hide sidebar" : "Show sidebar", "toggleSidebar"),
                      on: model.prefs.sidebarOpen) {
                model.toggleSidebar()
            }
            BarButton(icon: .settings, help: hint("Settings", "settings"), on: model.settingsOpen) {
                model.registry?.run("settings")
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Color(Theme.raised)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Color(Theme.hairlineStrong), lineWidth: 1))
        .barShadow()
        .frame(height: Self.height)
    }

    /// Tooltips name the shortcut as it is now.
    private func hint(_ title: String, _ id: String) -> String { model.registry?.hint(title, id) ?? title }
}

private struct BarButton: View {
    let icon: Icon
    let help: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            IconView(icon: icon, size: 16, color: Color(on ? Theme.text1 : Theme.text2))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Color(Theme.selected).opacity(on ? 1 : 0)))
        }
        .buttonStyle(IconButtonStyle())
        .help(help)
    }
}

private struct BarShadow: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.compositingGroup().shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.12), radius: 12, y: 4)
    }
}

extension View {
    /// A softer shadow than the overlay one: the bar rests on the list, it doesn't pop over it.
    fileprivate func barShadow() -> some View { modifier(BarShadow()) }
}
