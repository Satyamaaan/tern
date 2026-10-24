import AppKit
import SwiftUI
import TernCore

/// One account in Settings → Accounts: its colour (the dot that marks its mail in mixed lists), its
/// name, edited in place, the address and sync state, then Sign in again (when needed) and Remove.
struct AccountRow: View {
    @Environment(AppModel.self) private var model
    let account: Account
    let detail: String
    let reauth: () -> Void
    let remove: () -> Void

    @State private var name = ""
    @State private var hovered = false
    @State private var menuAnchor = MenuAnchor.AnchorView()
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                HStack(alignment: .center, spacing: 8) {
                    colourButton
                    VStack(alignment: .leading, spacing: 2) {
                        nameField
                        Text(detail).font(.ui(12)).foregroundStyle(Color(Theme.text3))
                    }
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    if account.syncState == .needsAuth || account.syncState == .error {
                        Button("Sign in again", action: reauth).buttonStyle(TernButtonStyle(.secondary))
                    }
                    Button("Remove", action: remove).buttonStyle(TernButtonStyle(.secondary))
                }
            }
            .padding(.vertical, 12)
            Hairline()
        }
        .onAppear { name = account.displayName }
        .onChange(of: account.displayName) { if !nameFocused { name = account.displayName } }
        .onChange(of: nameFocused) { if !nameFocused { commit() } }
    }

    /// The account's dot; a click lists the colours to choose from.
    private var colourButton: some View {
        let colourName = Theme.accountColorNames[abs(account.colorIndex) % Theme.accountColorNames.count]
        return Button(action: showColours) {
            Dot(color: Theme.accountColor(account.colorIndex), size: 10)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(IconButtonStyle())
        .background(MenuAnchor(view: menuAnchor).accessibilityHidden(true))
        .help("Colour: \(colourName)")
        .accessibilityLabel("Colour for \(account.email)")
        .accessibilityValue(colourName)
    }

    /// The name reads as the row's title; a hairline shows on hover and focus that it can be edited.
    private var nameField: some View {
        TextField(account.email, text: $name)
            .textFieldStyle(.plain)
            .font(.ui(13))
            .foregroundStyle(Color(Theme.text1))
            .focused($nameFocused)
            .onSubmit(commit)
            .frame(maxWidth: 260, alignment: .leading)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .strokeBorder(Color(nameFocused ? Theme.hairlineStrong : Theme.hairline), lineWidth: 1)
                .opacity(nameFocused || hovered ? 1 : 0))
            .padding(.horizontal, -5)
            .onHover { hovered = $0 }
            .help("Rename")
            .accessibilityLabel("Name for \(account.email)")
    }

    private func commit() {
        model.renameAccount(account, to: name)
    }

    private func showColours() {
        let model = self.model
        let account = self.account
        let menu = NSMenu()
        for index in Theme.accountHues.indices {
            let item = ClosureMenuItem(Theme.accountColorNames[index]) { model.setAccountColor(account, index) }
            item.image = Theme.swatch(Theme.accountColor(index))
            item.state = abs(account.colorIndex) % Theme.accountHues.count == index ? .on : .off
            menu.addItem(item)
        }
        menuAnchor.popUp(menu)
    }
}
