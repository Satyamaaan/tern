import SwiftUI
import TernCore

struct ManualCommitmentDraft: Identifiable {
    let id = UUID()
    var key: ThreadKey
    var direction: LedgerDirection
    var deliverable: String
    var person: Participant
}

/// Uses the main window's small sheet pattern, with no network work on save.
struct ManualCommitmentSheet: View {
    let draft: ManualCommitmentDraft
    @Environment(AppModel.self) private var app
    @State private var deliverable = ""
    @State private var hasDue = false
    @State private var due = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.direction == .iOwe ? "Track as I Owe" : "Track as Waiting On").font(.ui(18, .semibold))
            Text(draft.person.name.isEmpty ? draft.person.email : draft.person.name).font(.ui(13)).foregroundStyle(Color(Theme.text3))
            TextField("Deliverable", text: $deliverable).textFieldStyle(.roundedBorder)
            Toggle("Due date", isOn: $hasDue)
            if hasDue { DatePicker("Due", selection: $due, displayedComponents: .date) }
            HStack {
                Spacer()
                Button("Cancel") { app.manualCommitment = nil }.keyboardShortcut(.cancelAction)
                Button("Track") {
                    app.saveManualCommitment(draft, deliverable: deliverable, due: hasDue ? due : nil)
                    app.manualCommitment = nil
                }.keyboardShortcut(.defaultAction).disabled(deliverable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 420)
        .onAppear { deliverable = draft.deliverable }
    }
}
