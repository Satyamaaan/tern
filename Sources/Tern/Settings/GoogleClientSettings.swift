import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Accounts → Google client: the stored client ID, masked, with Replace… to paste a new ID
/// and secret or import the JSON file Google offers when the client is created.
struct GoogleClientSection: View {
    @Environment(AppServices.self) private var services
    /// Starts with the editor open (snapshots).
    var startEditing = false
    @State private var editing = false
    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var message: String?
    @State private var working = false
    @State private var stored: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: "Google client", detail: detail) {
                if !editing {
                    Button(stored == nil ? "Add…" : "Replace…") { editing = true }
                        .buttonStyle(TernButtonStyle(.secondary))
                }
            }
            if editing { editor }
        }
        .onAppear {
            stored = services.googleClientId()
            if startEditing { editing = true }
        }
        .googleClientFileDrop { data in importFile(data) }
    }

    private var detail: String {
        guard let stored else { return "Not set. Tern reads Gmail through a Google Cloud client of your own." }
        return "\(GoogleClientText.masked(stored)) · Desktop app · stored in your Keychain"
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            GoogleClientFields(clientId: $clientId, clientSecret: $clientSecret)
            Text(stored == nil
                 ? "Drop the client_secret_….json file Google offered when you created the client, or paste its ID and secret."
                 : "Accounts connected with the old client will ask you to sign in again.")
                .font(.ui(12))
                .foregroundStyle(Color(Theme.text3))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            HStack(spacing: 8) {
                Button("Choose file…") { chooseFile() }.buttonStyle(TernButtonStyle(.secondary))
                if let message {
                    Text(message).font(.ui(12, .medium)).foregroundStyle(Color(Theme.ink)).lineLimit(2)
                }
                Spacer()
                Button("Cancel") { close() }.buttonStyle(TernButtonStyle(.secondary))
                Button(working ? "Saving…" : "Save") { save() }
                    .buttonStyle(TernButtonStyle(.primary))
                    .disabled(working || clientId.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.vertical, 14)
            Hairline()
        }
    }

    private func save() {
        working = true
        Task {
            defer { working = false }
            do {
                try await services.saveGoogleClient(clientId, clientSecret)
                close()
            } catch {
                message = GoogleClientText.message(for: error)
            }
        }
    }

    private func chooseFile() {
        Task { if let data = await GoogleClientFile.choose() { importFile(data) } }
    }

    private func importFile(_ data: Data) {
        working = true
        Task {
            defer { working = false }
            do {
                try await services.importGoogleClient(data)
                close()
            } catch {
                editing = true
                message = GoogleClientText.message(for: error)
            }
        }
    }

    private func close() {
        editing = false
        clientId = ""
        clientSecret = ""
        message = nil
        stored = services.googleClientId()
    }
}

/// Client ID and secret, as flat rows with hairlines.
struct GoogleClientFields: View {
    @Binding var clientId: String
    @Binding var clientSecret: String
    var labelWidth: CGFloat = 100

    var body: some View {
        VStack(spacing: 0) {
            row("Client ID") {
                TextField("1234567890-abc.apps.googleusercontent.com", text: $clientId).textFieldStyle(.plain).font(.mono(12))
            }
            row("Client secret") {
                SecureField("GOCSPX-…", text: $clientSecret).textFieldStyle(.plain).font(.mono(12))
            }
        }
    }

    private func row<Field: View>(_ title: String, @ViewBuilder field: () -> Field) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title).font(.ui(13)).foregroundStyle(Color(Theme.text2)).frame(width: labelWidth, alignment: .leading)
                field()
            }
            .frame(height: 40)
            Hairline()
        }
    }
}

enum GoogleClientText {
    /// "1234••••abcd.apps.googleusercontent.com": enough to recognise, not to copy.
    static func masked(_ clientId: String) -> String {
        let suffix = ".apps.googleusercontent.com"
        let base = clientId.hasSuffix(suffix) ? String(clientId.dropLast(suffix.count)) : clientId
        guard base.count > 8 else { return String(repeating: "•", count: max(4, base.count)) + suffix }
        return base.prefix(4) + "••••" + base.suffix(4) + suffix
    }

    static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// Reading the JSON file Google offers for a new OAuth client.
@MainActor
enum GoogleClientFile {
    static func choose() async -> Data? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Use This Client"
        panel.message = "Choose the client_secret_….json file you downloaded from Google Cloud."
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK, let url = panel.url else { return nil }
        return try? Data(contentsOf: url)
    }
}

extension View {
    /// Accepts a dropped client_secret_….json file.
    func googleClientFileDrop(_ handle: @escaping @MainActor (Data) -> Void) -> some View {
        dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "json" }),
                  let data = try? Data(contentsOf: url) else { return false }
            handle(data)
            return true
        }
    }
}
