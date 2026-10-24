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
        .glassSurface(radius: Self.height / 2)
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
                .background {
                    if on { GlassControlFill(highlighted: true) }
                }
        }
        .buttonStyle(IconButtonStyle())
        .help(help)
    }
}
