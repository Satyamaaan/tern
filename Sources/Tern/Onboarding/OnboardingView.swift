import AppKit
import SwiftUI
import TernCore

/// First launch: 1) your Google client, 2) connect accounts, 3) AI, 4) done.
/// "Try it with demo mail" restarts Tern on the fake mailbox.
struct OnboardingView: View {
    let onFinish: () -> Void
    let onDemo: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(AppServices.self) private var services
    @State private var step: Int
    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var showWhy = false
    @State private var message: String?
    @State private var working = false
    @State private var board = AIStatusBoard()
    /// The AI the user picked; until then the first ready one.
    @State private var picked: AIProvider?

    private let steps = ["Google client", "Accounts", "AI", "Done"]

    /// `startStep` opens a later step (snapshots).
    init(onFinish: @escaping () -> Void, onDemo: @escaping () -> Void, startStep: Int = 0) {
        self.onFinish = onFinish
        self.onDemo = onDemo
        _step = State(initialValue: startStep)
    }

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

            Text(headline)
                .font(.display(30))
                .tracking(-0.5)
                .foregroundStyle(Color(Theme.text1))
                .padding(.top, 32)
            Text(intro)
                .font(.ui(13))
                .foregroundStyle(Color(Theme.text2))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .padding(.bottom, 20)

            Group {
                switch step {
                case 0: clientStep
                case 1: accountsStep
                case 2:
                    OnboardingAIStep(board: board, choice: provider, choose: { picked = $0 }, recheck: { recheckAI() })
                default: doneStep
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 16)

            HStack(spacing: 8) {
                DemoLink(action: onDemo)
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
        // The CLIs are asked as soon as the window opens, so the AI step has its answer when it shows.
        .task { board.check(services.aiAvailability) }
        .onChange(of: step) { if step == 2 { board.check(services.aiAvailability) } }
        // Back from Terminal after `codex login`: look again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if step == 2 && board.needsAttention { recheckAI() }
        }
    }

    private var headline: String {
        switch step {
        case 0: "Mail at the speed you think."
        case 1: "Add your accounts."
        case 2: "Choose your AI."
        default: "You're set."
        }
    }

    private var intro: String {
        switch step {
        case 0: "Tern talks to Gmail with your own Google Cloud client. Create one of type “Desktop app” with the Gmail API enabled, then paste its ID and secret."
        case 1: "Add every Gmail or Google Workspace account you use. They all land in one inbox."
        case 2: "Triage, summaries and reply drafts run through an AI app you already use, on this Mac."
        default: "Press ⌘K any time for every command and its shortcut."
        }
    }

    /// The chosen AI: what the user picked, else the first ready provider. Nil while the first check
    /// is still out.
    private var provider: AIProvider? {
        if let picked { return picked }
        if let ready = AIProvider.tools.first(where: { $0 != .groq && board.statuses[$0] == .ready }) { return ready }
        return board.statuses.isEmpty && services.aiAvailability != nil ? nil : .off
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
                        .foregroundStyle(Color(index == step ? Theme.text1 : index < step ? Theme.text2 : Theme.text3))
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
                .disabled(provider == nil)
        default:
            Button("Open Tern", action: onFinish)
                .buttonStyle(TernButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Steps

    private var clientStep: some View {
        VStack(alignment: .leading, spacing: 0) {
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
            Hairline()
            ForEach(model.accounts) { account in
                accountRow(account)
            }
            Button(working ? "Opening Google…" : model.accounts.isEmpty ? "Add Gmail account" : "Add another account") { addAccount() }
                .buttonStyle(TernButtonStyle(model.accounts.isEmpty ? .primary : .secondary))
                .disabled(working)
                .padding(.top, 16)
        }
    }

    private func accountRow(_ account: Account) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Dot(color: Theme.accountColor(account.colorIndex), size: 8)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(account.email).font(.ui(13)).foregroundStyle(Color(Theme.text1)).lineLimit(1)
                Spacer()
                Text(account.syncState == .live ? "Synced" : "Syncing…").font(.ui(12)).foregroundStyle(Color(Theme.text3))
            }
            .frame(height: 40)
            Hairline()
        }
    }

    /// What's set up: the accounts, the AI with its mark, then the keys worth knowing.
    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Hairline()
            if model.accounts.isEmpty {
                summaryRow(title: "No accounts yet", detail: "Add them in Settings → Accounts") {
                    IconView(icon: .at, size: 16, color: Color(Theme.text2))
                }
            }
            ForEach(model.accounts.prefix(3)) { account in
                accountRow(account)
            }
            if model.accounts.count > 3 {
                summaryRow(title: "\(model.accounts.count - 3) more", detail: nil) {
                    IconView(icon: .at, size: 16, color: Color(Theme.text2))
                }
            }
            let ai = provider ?? .off
            summaryRow(title: ai == .off ? "AI is off" : ai.title,
                       detail: ai == .off ? "Turn it on in Settings → AI" : "Triage, summaries and reply drafts") {
                if let logo = ai.logo {
                    BrandLogoView(logo: logo, size: 16)
                } else {
                    IconView(icon: .sparkles, size: 16, color: Color(Theme.text3))
                }
            }
            HStack(spacing: 18) {
                keyHint(["e"], "archive")
                keyHint(["z"], "undo")
                keyHint(["j", "k"], "move")
                keyHint(["/"], "search")
            }
            .padding(.top, 20)
        }
    }

    private func summaryRow<Mark: View>(title: String, detail: String?, @ViewBuilder mark: () -> Mark) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                mark().frame(width: 16)
                Text(title).font(.ui(13)).foregroundStyle(Color(Theme.text1))
                Spacer()
                if let detail { Text(detail).font(.ui(12)).foregroundStyle(Color(Theme.text3)) }
            }
            .frame(height: 40)
            Hairline()
        }
    }

    private func keyHint(_ keys: [String], _ title: String) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) { ForEach(keys, id: \.self) { Keycap(text: $0) } }
            Text(title).font(.ui(12)).foregroundStyle(Color(Theme.text2))
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
                // The client entered on step 1, even when an earlier one is the default.
                _ = try await services.connectAccountWith(services.lastSavedGoogleClientId)
                message = nil
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func recheckAI() {
        board.check(services.aiAvailability, refresh: true)
    }

    private func saveAI() {
        let store = model.store
        let provider = provider ?? .off
        model.writes.async {
            try? store.setSetting(SettingKey.aiEnabled, provider == .off ? "false" : "true")
            if provider != .off { try? store.setSetting(SettingKey.aiProvider, provider.rawValue) }
        }
    }
}

/// "Try it with demo mail": quiet `text3`, underlined under the pointer.
private struct DemoLink: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button("Try it with demo mail", action: action)
            .buttonStyle(.plain)
            .font(.ui(12))
            .foregroundStyle(Color(hovering ? Theme.text2 : Theme.text3))
            .underline(hovering)
            .onHover { hovering = $0 }
    }
}
