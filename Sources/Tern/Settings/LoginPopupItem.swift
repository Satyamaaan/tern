import SwiftUI

struct LoginPopupItem: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.prefs
        SettingsRow(
            title: "Show login popups",
            detail: "Extract verification codes and magic links locally from arriving mail. Codes are visible in a popup, even outside Tern. Off by default. Works without AI or system notification permission."
        ) {
            InkToggle(isOn: $prefs.showLoginPopups)
                .accessibilityLabel("Show login popups")
        }
    }
}
