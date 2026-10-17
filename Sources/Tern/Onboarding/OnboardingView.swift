import SwiftUI
import TernCore

/// First launch: 1) your Google client, 2) connect accounts, 3) AI, 4) done.
/// "Try it with demo mail" restarts Tern on the fake mailbox.
struct OnboardingView: View {
    let onFinish: () -> Void
    let onDemo: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(AppServices.self) private var services
    @State private var step = 0
    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var showWhy = false
    @State private var message: String?
    @State private var working = false
    @State private var provider: AIProvider = CLITool.find("codex") != nil ? .codex : CLITool.find("claude") != nil ? .claude : .off

    private let steps = ["Google client", "Accounts", "AI", "Done"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                TernMark()
                    .stroke(Color(Theme.text1), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                    .frame(width: 44, height: 22)
                Spacer()
                stepper
            }
            .padding(.top, 36)

            Text("Mail at the speed you think.")
                .font(.serif(34, italic: true))
                .foregroundStyle(Color(Theme.text1))
                .padding(.top, 28)
                .padding(.bottom, 24)

            Group {
                switch step {
                case 0: clientStep
                case 1: accountsStep
                case 2: aiStep
                default: doneStep
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 16)

            HStack {
                Button("Try it with demo mail", action: onDemo)
                    .buttonStyle(.plain)
                    .font(.ui(12))
                    .foregroundStyle(Color(Theme.text3))
                Spacer()
                if let message {
                    Text(message).font(.ui(12, .medium)).foregroundStyle(Color(Theme.ink)).lineLimit(2)
                }
                if step > 0 && step < 3 {
                    Button("Back") { message = nil; step -= 1 }.buttonStyle(TernButtonStyle(.secondary))
                }
                primaryButton
            }
            .padding(.bottom, 28)
        }
        .padding(.horizontal, 44)
        .frame(width: 640, height: 560)
        .background(Color(Theme.bg))
        .tint(Color(Theme.ink))
        .googleClientFileDrop { data in if step == 0 { importClient(data) } }
    }

    private var stepper: some View {
        HStack(spacing: 14) {
            ForEach(steps.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(index <= step ? Theme.ink : Theme.hairlineStrong))
                        .frame(width: 6, height: 6)
                    Text(steps[index])
                        .font(.ui(12, index == step ? .medium : .regular))
                        .foregroundStyle(Color(index == step ? Theme.text1 : Theme.text3))
                }
            }
        }
    }

    @ViewBuilder private var primaryButton: some View {
        switch step {
        case 0:
            Button(working ? "Saving…" : "Continue") { saveClient() }
                .buttonStyle(TernButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(working)
        case 1:
            Button("Continue") { message = nil; step = 2 }
                .buttonStyle(TernButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
        case 2:
            Button("Continue") { saveAI(); step = 3 }
                .buttonStyle(TernButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
        default:
            Button("Open Tern", action: onFinish)
                .buttonStyle(TernButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Steps

    private var clientStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Tern talks to Gmail with your own Google Cloud client. Create one of type “Desktop app” with the Gmail API enabled, then paste its ID and secret.")
                .font(.ui(13))
                .foregroundStyle(Color(Theme.text2))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)
            Hairline()
            GoogleClientFields(clientId: $clientId, clientSecret: $clientSecret)
            HStack(spacing: 16) {
                Button("Choose file…") { chooseClientFile() }
                    .buttonStyle(LinkButtonStyle())
                    .font(.ui(12, .medium))
                Text("or drop the client_secret_….json file here")
                    .font(.ui(12))
                    .foregroundStyle(Color(Theme.text3))
                Spacer()
                Button(showWhy ? "Why your own client" : "Why?") { withAnimation(.easeOut(duration: 0.15)) { showWhy.toggle() } }
                    .buttonStyle(LinkButtonStyle())
                    .font(.ui(12, .medium))
            }
            .padding(.top, 12)
            if showWhy {
                Text("Tern is open source and has no servers. With your own client, your mail goes straight from Google to this Mac, and nobody else holds a key to it. The ID and secret stay in your Keychain.")
                    .font(.ui(12))
                    .foregroundStyle(Color(Theme.text3))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        }
    }

    private var accountsStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add every Gmail or Google Workspace account you use. They all land in one inbox.")
                .font(.ui(13))
                .foregroundStyle(Color(Theme.text2))
                .padding(.bottom, 14)
            Hairline()
            ForEach(model.accounts) { account in
                HStack(spacing: 10) {
                    Dot(color: Theme.accountColor(account.colorIndex), size: 8)
                    Text(account.email).font(.ui(13)).foregroundStyle(Color(Theme.text1))
                    Spacer()
                    Text(account.syncState == .live ? "Synced" : "Syncing…").font(.ui(12)).foregroundStyle(Color(Theme.text3))
                }
                .frame(height: 40)
                Hairline()
            }
            Button(working ? "Opening Google…" : "Add Gmail account") { addAccount() }
                .buttonStyle(TernButtonStyle(model.accounts.isEmpty ? .primary : .secondary))
                .disabled(working)
                .padding(.top, 16)
        }
    }

    private var aiStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Triage, summaries and reply drafts run through a command-line AI you already use, on this Mac.")
                .font(.ui(13))
                .foregroundStyle(Color(Theme.text2))
                .padding(.bottom, 14)
            Hairline()
            ForEach(AIProvider.allCases) { option in
                HStack(spacing: 12) {
                    Circle()
                        .strokeBorder(Color(provider == option ? Theme.ink : Theme.hairlineStrong), lineWidth: provider == option ? 5 : 1.5)
                        .frame(width: 16, height: 16)
                    Text(option.title).font(.ui(13)).foregroundStyle(Color(Theme.text1))
                    Spacer()
                    if let executable = option.executable {
                        Text(CLITool.find(executable) == nil ? "Not found" : "Found")
                            .font(.ui(12))
                            .foregroundStyle(Color(CLITool.find(executable) == nil ? Theme.text3 : Theme.text1))
                    }
                }
                .frame(height: 40)
                .contentShape(Rectangle())
                .onTapGesture { provider = option }
                Hairline()
            }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("You're set.")
                .font(.ui(15, .semibold))
                .foregroundStyle(Color(Theme.text1))
            Text("Press ⌘K any time for every command and its shortcut. e archives, z undoes, j and k move.")
                .font(.ui(13))
                .foregroundStyle(Color(Theme.text2))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    private func saveClient() {
        let id = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty && services.hasGoogleClient() { step = 1; return }
        working = true
        Task {
            defer { working = false }
            do {
                try await services.saveGoogleClient(id, secret)
                message = nil
                step = 1
            } catch ShellError.notAvailable {
                message = ShellError.notAvailable.localizedDescription
                step = 1
            } catch {
                message = GoogleClientText.message(for: error)
            }
        }
    }

    private func chooseClientFile() {
        Task { if let data = await GoogleClientFile.choose() { importClient(data) } }
    }

    /// The JSON file Google offers at creation carries both the ID and the secret.
    private func importClient(_ data: Data) {
        working = true
        Task {
            defer { working = false }
            do {
                try await services.importGoogleClient(data)
                message = nil
                step = 1
            } catch {
                message = GoogleClientText.message(for: error)
            }
        }
    }

    private func addAccount() {
        working = true
        Task {
            defer { working = false }
            do {
                _ = try await services.connectAccount()
                message = nil
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func saveAI() {
        let store = model.store
        let provider = provider
        model.writes.async {
            try? store.setSetting(SettingKey.aiEnabled, provider == .off ? "false" : "true")
            if provider != .off { try? store.setSetting(SettingKey.aiProvider, provider.rawValue) }
        }
    }
}
