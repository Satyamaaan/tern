import SwiftUI

struct GroqKeyItem: View {
    let state: SettingsState
    @State private var key = ""
    @State private var hasKey = false
    @State private var saving = false
    @State private var status: String?

    var body: some View {
        SettingsRow(title: "Groq API key", detail: saving ? "Saving…" : status ?? (hasKey ? "Stored in Keychain. Enter a key to replace it." : "Stored only in this Mac's Keychain.")) {
            HStack(spacing: 8) {
                SecureField("API key", text: $key)
                    .textFieldStyle(.plain)
                    .font(.ui(12))
                    .frame(width: 150)
                    .onSubmit { if !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { save(key) } }
                Button("Save") { save(key) }
                    .buttonStyle(TernButtonStyle(.secondary))
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasKey {
                    Button("Remove") { save("") }.buttonStyle(TernButtonStyle(.quiet))
                }
            }
            .disabled(saving)
        }
        .task {
            guard !LaunchOptions.current().isHeadless else { return }
            hasKey = await Task.detached { GroqCredential.read() != nil }.value
        }
    }

    private func save(_ value: String) {
        guard !saving else { return }
        saving = true
        // Keychain work and the database notification both stay off the main thread.
        let store = state.model.store
        let board = state.board
        let availability = state.model.services.aiAvailability
        Task {
            defer { saving = false }
            do {
                try await Task.detached {
                    try GroqCredential.save(value)
                    try store.setSetting("ai.groqCredentialRevision", UUID().uuidString)
                }.value
                key = ""
                hasKey = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                status = hasKey ? "Saved in Keychain." : "Key removed."
                board.check(availability, refresh: true)
            } catch { status = "Couldn't update the Keychain. Try again." }
        }
    }
}
