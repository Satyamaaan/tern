import AppKit
import Observation
import SwiftUI
import TernCore

enum SettingsSection: String, CaseIterable, Identifiable {
    case accounts, ai, appearance, shortcuts, notifications, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accounts: "Accounts"
        case .ai: "AI"
        case .appearance: "Appearance"
        case .shortcuts: "Shortcuts"
        case .notifications: "Notifications"
        case .advanced: "Advanced"
        }
    }
}

/// AI choices. Stored in the database `setting` table so the AI lane reads the same values.
enum AIProvider: String, CaseIterable, Identifiable {
    case codex, claude, off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .off: "Off"
        }
    }

    /// The command-line tool behind the provider.
    var executable: String? {
        switch self {
        case .codex: "codex"
        case .claude: "claude"
        case .off: nil
        }
    }
}

/// Setting keys shared with other lanes.
enum SettingKey {
    static let aiEnabled = "ai.enabled"
    static let aiProvider = "ai.provider"
    static let aiModel = "ai.model"
    static let aiAutoProjects = "ai.autoProjects"
}

@MainActor
@Observable
final class SettingsState {
    let model: AppModel
    weak var shell: ShellActions?
    var section: SettingsSection = .accounts
    var provider: AIProvider
    var aiModel: String
    var autoProjects: Bool
    var indexStatus: String?
    /// Opens the Google client editor at once (snapshots).
    var editsGoogleClient = false

    init(model: AppModel, shell: ShellActions?) {
        self.model = model
        self.shell = shell
        let store = model.store
        let enabled = (try? store.setting(SettingKey.aiEnabled)) ?? nil
        let provider = ((try? store.setting(SettingKey.aiProvider)) ?? nil).flatMap(AIProvider.init(rawValue:))
        self.provider = enabled == "false" ? .off : (provider ?? .off)
        aiModel = ((try? store.setting(SettingKey.aiModel)) ?? nil) ?? ""
        autoProjects = ((try? store.setting(SettingKey.aiAutoProjects)) ?? nil) == "true"
    }

    /// Writes AI settings off the main thread.
    func saveAI() {
        let store = model.store
        let provider = provider
        let aiModel = aiModel.trimmingCharacters(in: .whitespaces)
        let autoProjects = autoProjects
        model.writes.async {
            try? store.setSetting(SettingKey.aiEnabled, provider == .off ? "false" : "true")
            if provider != .off { try? store.setSetting(SettingKey.aiProvider, provider.rawValue) }
            try? store.setSetting(SettingKey.aiModel, aiModel.isEmpty ? nil : aiModel)
            try? store.setSetting(SettingKey.aiAutoProjects, autoProjects ? "true" : "false")
        }
    }

    func rebuildSearchIndex() {
        indexStatus = "Rebuilding…"
        let store = model.store
        model.writes.async {
            let result = (try? store.rebuildSearchIndex()) != nil ? "Search index rebuilt" : "Couldn't rebuild the index"
            DispatchQueue.main.async { MainActor.assumeIsolated { self.indexStatus = result } }
        }
    }

    func remove(_ account: Account) {
        let alert = NSAlert()
        alert.messageText = "Remove \(account.email)?"
        alert.informativeText = "Its mail is deleted from this Mac and Tern signs out of it. Nothing changes in Gmail."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let services = model.services
        Task {
            do { try await services.removeAccount(account) } catch { NSLog("Tern: removing an account failed: \(error)") }
        }
    }

    /// Demo mode only: wipe the demo mailbox and start again with a fresh one.
    func resetDemoMail() {
        UserDefaults.standard.set(true, forKey: DemoReset.key)
        (NSApp.delegate as? AppDelegate)?.relaunchWithDemoMail()
    }
}

/// Settings window: section list on the left, flat rows with hairlines on the right.
struct SettingsView: View {
    @Bindable var state: SettingsState

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Spacer().frame(height: 44)
                ForEach(SettingsSection.allCases) { section in
                    SidebarRow(title: section.title, selected: state.section == section) {
                        EmptyView()
                    } action: {
                        state.section = section
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(width: 190)
            .background(Color(Theme.sidebar))
            Hairline(vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(state.section.title)
                        .font(.ui(15, .semibold))
                        .foregroundStyle(Color(Theme.text1))
                        .padding(.top, 40)
                        .padding(.bottom, 14)
                    content
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(Theme.bg))
        }
        .frame(minWidth: 720, minHeight: 500)
        .tint(Color(Theme.ink))
    }

    @ViewBuilder private var content: some View {
        switch state.section {
        case .accounts: AccountsSettings(state: state)
        case .ai: AISettings(state: state)
        case .appearance: AppearanceSettings()
        case .shortcuts: ShortcutsSettings()
        case .notifications: NotificationSettings()
        case .advanced: AdvancedSettings(state: state)
        }
    }
}

// MARK: - Rows and controls

/// A flat settings row: title (+ detail) on the left, control on the right, hairline below.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.ui(13)).foregroundStyle(Color(Theme.text1))
                    if let detail {
                        Text(detail).font(.ui(12)).foregroundStyle(Color(Theme.text3)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                control()
            }
            .padding(.vertical, 12)
            Hairline()
        }
    }
}

/// Segmented choice: a 28 pt track in `selected`; the chosen option sits on a raised segment with a
/// hairline border.
struct SegmentedPicker<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let chosen = selection == option
                Text(title(option))
                    .font(.ui(12, .medium))
                    .foregroundStyle(Color(chosen ? Theme.text1 : Theme.text2))
                    .padding(.horizontal, 10)
                    .frame(height: Theme.Control.small)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control - 2, style: .continuous)
                            .fill(Color(Theme.raised).opacity(chosen ? 1 : 0))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control - 2, style: .continuous)
                                .strokeBorder(Color(Theme.hairlineStrong).opacity(chosen ? 1 : 0), lineWidth: 1)))
                    .contentShape(Rectangle())
                    .onTapGesture { selection = option }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Color(Theme.selected)))
    }
}

/// An on/off switch in `ink`.
struct InkToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(Color(Theme.ink))
            .labelsHidden()
    }
}

// MARK: - Sections

private struct AccountsSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(AppServices.self) private var services
    let state: SettingsState
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.accounts.isEmpty {
                Text("No accounts yet.")
                    .font(.serif(18, italic: true))
                    .foregroundStyle(Color(Theme.text2))
                    .padding(.vertical, 12)
                Hairline()
            }
            ForEach(model.accounts) { account in
                SettingsRow(title: model.accountTitle(account), detail: "\(account.email) · \(syncText(account))") {
                    HStack(spacing: 8) {
                        if account.syncState == .needsAuth || account.syncState == .error {
                            Button("Sign in again") { reauth(account) }.buttonStyle(TernButtonStyle(.secondary))
                        }
                        Button("Remove") { state.remove(account) }.buttonStyle(TernButtonStyle(.secondary))
                    }
                }
            }
            HStack(spacing: 12) {
                Button("Add Gmail account") { add() }.buttonStyle(TernButtonStyle(.primary))
                if let message { Text(message).font(.ui(12)).foregroundStyle(Color(Theme.text3)) }
            }
            .padding(.top, 16)
            .padding(.bottom, 28)
            Hairline()
            GoogleClientSection(startEditing: state.editsGoogleClient)
        }
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

    private func add() {
        Task {
            do { _ = try await services.connectAccount(); message = nil } catch { message = error.localizedDescription }
        }
    }

    private func reauth(_ account: Account) {
        Task {
            do { try await services.reauthAccount(account); message = nil } catch { message = error.localizedDescription }
        }
    }
}

private struct AISettings: View {
    @Bindable var state: SettingsState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Tern runs AI through a command-line tool you already use, signed in with your own account. The text it needs goes to that provider; Tern has no servers of its own.")
                .font(.ui(12))
                .foregroundStyle(Color(Theme.text3))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
            Hairline()
            SettingsRow(title: "Provider", detail: providerDetail) {
                SegmentedPicker(options: AIProvider.allCases, selection: $state.provider) { $0.title }
            }
            SettingsRow(title: "Model", detail: "Leave empty for the tool's default.") {
                TextField("Default", text: $state.aiModel)
                    .textFieldStyle(.plain)
                    .font(.mono(12))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 180)
                    .disabled(state.provider == .off)
            }
            SettingsRow(title: "Suggest projects", detail: "Let AI file mail into projects when no rule matches.") {
                InkToggle(isOn: $state.autoProjects).disabled(state.provider == .off)
            }
        }
        .onChange(of: state.provider) { state.saveAI() }
        .onChange(of: state.aiModel) { state.saveAI() }
        .onChange(of: state.autoProjects) { state.saveAI() }
    }

    private var providerDetail: String {
        AIProvider.allCases.compactMap { provider in
            provider.executable.map { "\(provider.title): \(CLITool.find($0) == nil ? "not found" : "found")" }
        }.joined(separator: " · ")
    }
}

private struct AppearanceSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.prefs
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: "Theme") {
                SegmentedPicker(options: AppearanceMode.allCases, selection: $prefs.appearance) { $0.title }
            }
            SettingsRow(title: "Density", detail: "Auto shows one line per thread when the list is wide, two when it's narrow.") {
                SegmentedPicker(options: Density.allCases, selection: $prefs.density) { $0.title }
            }
            SettingsRow(title: "Dim old read mail", detail: "Fade read conversations older than a month.") {
                InkToggle(isOn: $prefs.dimReadByAge)
            }
            SettingsRow(title: "Split inbox", detail: "Important, People, Notifications, Newsletters, Other.") {
                InkToggle(isOn: Binding(get: { prefs.splitInbox }, set: { model.setSplitInbox($0) }))
            }
        }
    }
}

private struct ShortcutsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ShortcutTable.rows(model.registry)) { row in
                HStack {
                    Text(row.title).font(.ui(13)).foregroundStyle(Color(Theme.text1))
                    Spacer()
                    Text(row.shortcut).font(.mono(12)).foregroundStyle(Color(Theme.text3))
                }
                .frame(height: 30)
                Hairline()
            }
        }
    }
}

private struct NotificationSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.prefs
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: "Notify about new mail") { InkToggle(isOn: $prefs.notificationsEnabled) }
            SettingsRow(title: "Only important mail", detail: "People, needs reply, calendar and security.") {
                InkToggle(isOn: $prefs.notifyOnlyImportant).disabled(!prefs.notificationsEnabled)
            }
        }
    }
}

private struct AdvancedSettings: View {
    @Environment(AppModel.self) private var model
    let state: SettingsState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: "Database", detail: model.databaseURL.path) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.databaseURL]) }
                    .buttonStyle(TernButtonStyle(.secondary))
            }
            SettingsRow(title: "Search index", detail: state.indexStatus ?? "Rebuild if search misses mail you know is there.") {
                Button("Rebuild") { state.rebuildSearchIndex() }
                    .buttonStyle(TernButtonStyle(.secondary))
                    .disabled(state.indexStatus == "Rebuilding…")
            }
            if model.isFake {
                SettingsRow(title: "Demo mail", detail: "Start over with a fresh demo mailbox. Tern restarts.") {
                    Button("Reset") { state.resetDemoMail() }.buttonStyle(TernButtonStyle(.secondary))
                }
            }
        }
    }
}

// MARK: - Helpers

/// Finds command-line tools the way a login shell would (PATH plus the usual install places).
enum CLITool {
    static func find(_ name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.claude/local"]
        for directory in directories {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
}

/// Demo-mail reset, carried across a relaunch.
enum DemoReset {
    static let key = "resetDemoMailOnLaunch"

    /// Deletes the demo database before it opens, when a reset was requested.
    static func applyIfRequested(_ options: LaunchOptions) {
        guard options.isFake, UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.removeObject(forKey: key)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: options.databaseURL.path + suffix)
        }
    }
}
