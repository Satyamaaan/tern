import SwiftUI
import TernCore

/// Follow-up tracking is a database preference, shared with background detection.
struct LedgerTrackingItem: View {
    @Environment(AppModel.self) private var model
    @State private var enabled = true
    @State private var days = 3
    @State private var loaded: LedgerSettings?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            SettingsRow(title: "Due", detail: error ?? "Track promises and requests. Decisions stay on this Mac.") {
                InkToggle(isOn: $enabled)
            }
            SettingsRow(title: "Show after", detail: "Time since your original request, even after a nudge.") {
                SegmentedPicker(options: [2, 3, 5, 7], selection: $days) { "\($0) days" }
                    .disabled(!enabled)
            }
        }
        .task {
            if let settings = try? model.store.database.reader.read({ try LedgerSettings.load($0) }) {
                loaded = settings
                enabled = settings.enabled
                days = settings.waitingDays
            }
        }
        .onChange(of: enabled) { save() }
        .onChange(of: days) { save() }
    }

    private func save() {
        guard var previous = loaded, previous.enabled != enabled || previous.waitingDays != days else { return }
        previous.enabled = enabled
        previous.waitingDays = days
        loaded = previous
        let store = model.store
        let enabled = enabled
        let days = days
        model.writes.async {
            do {
                try store.setLedgerSettings(enabled: enabled, waitingDays: days)
                DispatchQueue.main.async { self.error = nil }
            }
            catch {
                DispatchQueue.main.async { self.error = "Couldn't save follow-up settings." }
            }
        }
    }
}
