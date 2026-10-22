import SwiftUI
import TernCore

struct PrimarySummariesItem: View {
    @Environment(AppModel.self) private var model
    @State private var enabled = true
    @State private var error: String?

    var body: some View {
        SettingsRow(title: "Summarise Primary mail automatically", detail: error ?? "Recent Primary mail, newest first. Up to 200 summaries a day while AI is on.") {
            InkToggle(isOn: Binding(get: { enabled }, set: { value in
                enabled = value
                let database = model.store.database
                model.writes.async {
                    do {
                        try database.writer.write { try Setting(key: "ai.autoPrimarySummaries", value: value ? "true" : "false").upsert($0) }
                        DispatchQueue.main.async { error = nil }
                    } catch { DispatchQueue.main.async { self.error = "Couldn't save summary settings." } }
                }
            }))
        }
        .task {
            enabled = (try? model.store.database.reader.read { try Setting.fetchOne($0, key: "ai.autoPrimarySummaries")?.value }) != "false"
        }
    }
}
