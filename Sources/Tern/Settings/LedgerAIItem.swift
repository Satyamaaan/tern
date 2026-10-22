import SwiftUI
import TernCore

struct LedgerAIItem: View {
    @Environment(AppModel.self) private var model
    @State private var ai = true
    @State private var maybe = false
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            SettingsRow(title: "Find promises and requests in mail", detail: error ?? "Track concrete deliverables with evidence from the conversation.") { InkToggle(isOn: Binding(get: { ai }, set: { ai = $0; save() })) }
            SettingsRow(title: "Show uncertain items", detail: "Include commitments the model is less sure about.") { InkToggle(isOn: Binding(get: { maybe }, set: { maybe = $0; save() })).disabled(!ai) }
        }
        .task {
            if let settings = try? model.store.database.reader.read({ try LedgerSettings.load($0) }) {
                ai = settings.ai; maybe = settings.showMaybe; loaded = true
            }
        }
    }

    private func save() {
        guard loaded else { return }
        let database = model.store.database; let ai = ai; let maybe = maybe
        model.writes.async {
            do {
                try database.writer.write { db in
                    try Setting(key: "ledger.ai", value: ai ? "true" : "false").upsert(db)
                    try Setting(key: "ledger.showMaybe", value: maybe ? "true" : "false").upsert(db)
                }
                DispatchQueue.main.async { self.error = nil }
            } catch { DispatchQueue.main.async { self.error = "Couldn't save commitment settings." } }
        }
    }
}
