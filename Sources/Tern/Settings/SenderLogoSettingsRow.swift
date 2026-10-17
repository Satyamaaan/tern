import SwiftUI

/// Settings → Appearance: the switch for sender logos.
struct SenderLogoSettingsRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.prefs
        SettingsRow(title: "Show sender logos",
                    detail: "Fetches each sender's site icon once and keeps it on this Mac. Personal addresses like Gmail always show initials.") {
            InkToggle(isOn: $prefs.showSenderLogos)
        }
    }
}
