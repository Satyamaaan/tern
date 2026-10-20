import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Accounts → Google clients: each stored client ID, masked, with the accounts that sign in
/// through it, Add… to paste another ID and secret or import the JSON file Google offers when the client is
/// created, and Remove while there is more than one. Accounts keep the client they signed in with, so a
/// Workspace whose admin only allows its own apps can use its own client next to a personal one.
struct GoogleClientSection: View {
    @Environment(AppServices.self) private var services
    /// Starts with the editor open (snapshots).
    var startEditing = false
    @State private var editing = false
    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var message: String?
    @State private var working = false
    @State private var clients: [GoogleClientInfo] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: clients.count > 1 ? "Google clients" : "Google client", detail: detail, icon: .key) {
                if !editing {
                    Button(clients.isEmpty ? "Add…" : "Add another…") { message = nil; editing = true }
                        .buttonStyle(TernButtonStyle(.secondary))
                }
            }
            if editing { editor }
            ForEach(clients) { client in
                SettingsRow(title: GoogleClientText.masked(client.id), detail: usage(client)) {
                    if clients.count > 1 {
                        Button("Remove") { remove(client) }
                            .buttonStyle(TernButtonStyle(.secondary))
                            .disabled(working)
                    }
                }
                .padding(.leading, 26)
            }
            if !editing, let message {
                Text(message)
                    .font(.ui(12, .medium))
                    .foregroundStyle(Color(Theme.ink))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
        }
        .onAppear {
            reload()
            if startEditing { editing = true }
        }
        .onChange(of: services.accounts) { reload() }
        .onChange(of: services.googleClientsChanged) { reload() }
        .googleClientFileDrop { data in importFile(data) }
    }

    private var detail: String {
        if clients.isEmpty { return "Not set. Tern reads Gmail through your own Google Cloud client." }
        return "Desktop app · in your Keychain. Add another when a Workspace only lets in its own apps."
    }

    private func usage(_ client: GoogleClientInfo) -> String {
        let used = client.emails.isEmpty ? "No accounts yet" : client.emails.joined(separator: ", ")
        return client.id == clients.first?.id && clients.count > 1 ? "\(used) · used for new accounts first" : used
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            GoogleClientFields(clientId: $clientId, clientSecret: $clientSecret)
            Text(clients.isEmpty
                 ? "Drop the client_secret_….json file Google offered when you created the client, or paste its ID and secret."
                 : "Accounts keep the client they signed in with. Saving a client that's already here updates its secret.")
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

    private func remove(_ client: GoogleClientInfo) {
        working = true
        Task {
            defer { working = false }
            do {
                try await services.removeGoogleClient(client.id)
                message = nil
            } catch {
                message = GoogleClientText.message(for: error)
            }
            reload()
        }
    }

    private func close() {
        editing = false
        clientId = ""
        clientSecret = ""
        message = nil
        reload()
    }

    private func reload() {
        clients = services.googleClients()
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
                TextField("1234567890-abc.apps.googleusercontent.com", text: $clientId).textFieldStyle(.plain).font(.numeric(12))
            }
            row("Client secret") {
                SecureField("GOCSPX-…", text: $clientSecret).textFieldStyle(.plain).font(.numeric(12))
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

    /// "1234••••abcd": short enough for a menu item.
    static func short(_ clientId: String) -> String {
        let masked = masked(clientId)
        return masked.hasSuffix(".apps.googleusercontent.com") ? String(masked.dropLast(".apps.googleusercontent.com".count)) : masked
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
