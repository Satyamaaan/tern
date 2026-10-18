import SwiftUI

/// Settings → Advanced: "Update automatically" and the version with "Check Now". Development builds don't update,
/// so they only show their version.
struct UpdateSettingsRows: View {
    let updater: Updater?

    var body: some View {
        if let updater {
            SettingsRow(title: "Update automatically", detail: "Download new versions in the background. They install when Tern restarts.") {
                InkToggle(isOn: Binding(get: { updater.automaticallyUpdates }, set: { updater.automaticallyUpdates = $0 }))
            }
            SettingsRow(title: "Version \(updater.version.name)", detail: checked(updater.lastChecked)) {
                Button("Check Now") { updater.checkForUpdates() }
                    .buttonStyle(TernButtonStyle(.secondary))
                    .disabled(!updater.canCheck)
            }
        } else {
            SettingsRow(title: "Version \(AppVersion.current.name)", detail: "A development build. It doesn't update itself.") {
                EmptyView()
            }
        }
    }

    private func checked(_ date: Date?) -> String {
        guard let date else { return "Not checked yet." }
        return "Checked \(date.formatted(.relative(presentation: .named)))."
    }
}
