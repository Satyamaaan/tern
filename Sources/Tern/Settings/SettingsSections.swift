import AppKit
import SwiftUI
import TernCore

// The rows of Accounts, Appearance, Notifications, AI and Advanced. Mail and Layout have files of their
// own, as does Shortcuts.

// MARK: - Accounts

struct AccountsItem: View {
    @Environment(AppModel.self) private var model
    @Environment(AppServices.self) private var services
    let state: SettingsState
    @State private var message: String?
    /// The stored Google clients, read from the Keychain when the page opens and when accounts change.
    @State private var clients: [GoogleClientInfo] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.accounts.isEmpty {
                Text("No accounts yet.")
                    .font(.display(16))
                    .foregroundStyle(Color(Theme.text2))
                    .padding(.vertical, 12)
                Hairline()
            }
            ForEach(model.accounts) { account in
                AccountRow(account: account, detail: "\(account.email) · \(syncText(account))",
                           reauth: { reauth(account) }, remove: { state.remove(account) })
            }
            HStack(spacing: 12) {
                if clients.count > 1 {
                    MenuPickerButton(title: "Add Gmail account", kind: .primary, size: .regular) { clientMenu() }
                } else {
                    Button("Add Gmail account") { add(nil) }.buttonStyle(TernButtonStyle(.primary))
                }
                if let message { Text(message).font(.ui(12)).foregroundStyle(Color(Theme.text3)) }
            }
            .padding(.top, 16)
            .padding(.bottom, 12)
        }
        .onAppear { clients = services.googleClients() }
        .onChange(of: services.accounts) { clients = services.googleClients() }
        .onChange(of: services.googleClientsChanged) { clients = services.googleClients() }
    }

    private func syncText(_ account: Account) -> String {
        switch account.syncState {
        case .new: "Waiting to sync"
        case .backfilling: "Syncing"
        case .live: account.lastSyncAt.map { "Synced \($0.formatted(.relative(presentation: .named)))" } ?? "Up to date"
        case .error: "Sync error"
        case .needsAuth: "Needs sign-in"
        }
    }

    private func add(_ clientId: String?) {
        Task {
            do { _ = try await services.connectAccountWith(clientId); message = nil } catch { message = error.localizedDescription }
        }
    }

    /// Which Google client to sign in through, named by its masked ID and the accounts already using it.
    private func clientMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Sign in through", enabled: false) {})
        for client in clients {
            let used = client.emails.isEmpty ? "" : "  ·  " + client.emails.joined(separator: ", ")
            menu.addItem(ClosureMenuItem(GoogleClientText.short(client.id) + used) { add(client.id) })
        }
        return menu
    }

    private func reauth(_ account: Account) {
        Task {
            do { try await services.reauthAccount(account); message = nil } catch { message = error.localizedDescription }
        }
    }
}

// MARK: - Appearance

struct ThemeItem: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.prefs
        SettingsRow(title: "Theme") {
            SegmentedPicker(options: AppearanceMode.allCases, selection: $prefs.appearance) { $0.title }
        }
    }
}

struct DensityItem: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.prefs
        SettingsRow(title: "Density", detail: "One line per thread when the list is wide, two when it's narrow.") {
            SegmentedPicker(options: Density.allCases, selection: $prefs.density) { $0.title }
        }
    }
}

struct DimReadItem: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.prefs
        SettingsRow(title: "Dim old read mail", detail: "Fade read conversations older than a month.") {
            InkToggle(isOn: $prefs.dimReadByAge)
        }
    }
}

// MARK: - Notifications

struct NotificationsItem: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.prefs
        SettingsRow(title: "Notify about new mail", detail: "Only while Tern isn't the app in front.") {
            InkToggle(isOn: $prefs.notificationsEnabled)
        }
    }
}

struct NotifyImportantItem: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.prefs
        SettingsRow(title: "Only important mail", detail: "People, needs reply, calendar and security.") {
            InkToggle(isOn: $prefs.notifyOnlyImportant).disabled(!prefs.notificationsEnabled)
        }
    }
}

// MARK: - AI

struct AIAboutItem: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Tern uses your Groq API key or a signed-in Codex or Claude Code CLI. Mail context goes directly to the chosen provider. Tern has no servers of its own.")
                .font(.ui(12))
                .foregroundStyle(Color(Theme.text3))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
            Hairline()
        }
    }
}

struct AIProviderItem: View {
    @Environment(AppServices.self) private var services
    @Bindable var state: SettingsState

    var body: some View {
        AIProviderRow(selection: $state.provider, board: state.board) { state.board.check(services.aiAvailability, refresh: true) }
            .task { state.board.check(services.aiAvailability) }
    }
}

/// The model name is saved on Return and when the field lets go of the keyboard, not on every key. Text not yet
/// saved is with `SettingsState`, which saves it when settings, the window or the app close.
struct AIModelItem: View {
    @Bindable var state: SettingsState
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        SettingsRow(title: "Model", detail: "Leave empty for the provider's default.") {
            TextField("Default", text: $text)
                .textFieldStyle(.plain)
                .font(.numeric(12))
                .multilineTextAlignment(.trailing)
                .frame(width: 180)
                .autocorrectionDisabled()
                .disabled(state.provider == .off)
                .focused($focused)
                .onChange(of: text) { state.editAIModel(text) }
                .onSubmit { state.commitAIModel(text) }
                .onChange(of: focused) { if !focused { state.commitAIModel(text) } }
                .onChange(of: state.aiModel, initial: true) { if !focused { text = state.aiModel } }
                .onDisappear { state.commitAIModel(text) }
        }
    }
}

struct AIProjectsItem: View {
    @Bindable var state: SettingsState

    var body: some View {
        SettingsRow(title: "Suggest projects", detail: "Let AI file mail into projects when no rule matches.") {
            InkToggle(isOn: $state.autoProjects).disabled(state.provider == .off)
        }
    }
}

// MARK: - Advanced

struct DatabaseItem: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsRow(title: "Database", detail: model.databaseURL.path) {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.databaseURL]) }
                .buttonStyle(TernButtonStyle(.secondary))
        }
    }
}

struct SearchIndexItem: View {
    let state: SettingsState

    var body: some View {
        SettingsRow(title: "Search index", detail: state.indexStatus ?? "Rebuild if search misses mail you know is there.") {
            Button("Rebuild") { state.rebuildSearchIndex() }
                .buttonStyle(TernButtonStyle(.secondary))
                .disabled(state.indexStatus == "Rebuilding…")
        }
    }
}

struct DemoMailItem: View {
    let state: SettingsState

    var body: some View {
        SettingsRow(title: "Demo mail", detail: "Start over with a fresh demo mailbox. Tern restarts.") {
            Button("Reset") { state.resetDemoMail() }.buttonStyle(TernButtonStyle(.secondary))
        }
    }
}
