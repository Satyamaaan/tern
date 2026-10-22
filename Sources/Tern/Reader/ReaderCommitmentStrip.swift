import SwiftUI
import TernCore

/// Local commitments stay visible above the message page and follow its database observation.
struct ReaderCommitmentStrip: View {
    @Bindable var model: ReaderModel
    @Environment(AppModel.self) private var app: AppModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.stripItems, id: \.id) { item in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        if model.stripItems.count > 1 {
                            Button { model.focusedCommitmentId = item.id } label: {
                                Image(systemName: model.focusedCommitment?.id == item.id ? "circle.inset.filled" : "circle")
                            }.help(hint("Focus commitment", "commitmentNext"))
                        }
                        Text(line(item)).font(.ui(12, .medium)).lineLimit(1)
                        if item.confidence == 1 { Text("Maybe").font(.ui(10)).foregroundStyle(Color(Theme.text3)) }
                        Spacer(minLength: 4)
                        if item.state == .open {
                            Button("Done") { app?.changeCommitment(item, to: .done) }
                                .help(hint("Mark done", "commitmentDone"))
                        } else {
                            Button("Reopen") { app?.changeCommitment(item, to: .open) }
                                .help(hint("Reopen", "commitmentReopen"))
                        }
                        Menu {
                            Button(hint("Show evidence", "commitmentEvidence")) {
                                if model.focusedCommitment?.id == item.id { model.commitmentEvidence.toggle() }
                                else { model.focusedCommitmentId = item.id; model.commitmentEvidence = true }
                            }
                            Button(hint("Dismiss", "commitmentDismiss")) { app?.changeCommitment(item, to: .dismissed) }
                        } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                    if item.state == .done {
                        Text(item.completionText)
                            .font(.ui(11)).foregroundStyle(Color(Theme.text3)).lineLimit(3)
                    }
                    if model.commitmentEvidence && model.focusedCommitment?.id == item.id {
                        Text(item.sourceQuote).font(.ui(12)).textSelection(.enabled)
                        HStack {
                            Text("From \(model.detail?.messages.first(where: { $0.id == item.sourceMessageId }).map { $0.isFromMe ? "you" : $0.fromName.isEmpty ? $0.fromEmail : $0.fromName } ?? item.counterpartyEmail), \(item.sourceDate.formatted(date: .abbreviated, time: .omitted))")
                            Button(hint("Show message", "commitmentShowMessage")) { model.reveal(messageId: item.sourceMessageId) }
                        }.font(.ui(11)).foregroundStyle(Color(Theme.text3))
                        if item.state == .open && item.hintAt != nil { Text("Replied · awaiting confirmation").font(.ui(11)).foregroundStyle(Color(Theme.text3)) }
                    }
                }
                .foregroundStyle(Color(item.confidence == 1 ? Theme.text3 : Theme.text2))
            }
        }
        .buttonStyle(.plain)
    }

    private func hint(_ title: String, _ id: String) -> String { app?.registry?.hint(title, id) ?? title }
    private func line(_ item: Commitment) -> String {
        let name = item.counterpartyName.isEmpty ? item.counterpartyEmail : item.counterpartyName
        let due = item.dueAt.map { date in
            let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
            let text = (0...6).contains(days) ? date.formatted(.dateTime.weekday(.abbreviated)) : date.formatted(.dateTime.month(.abbreviated).day())
            return " · due " + text
        } ?? ""
        return "\(item.direction == .iOwe ? "You owe" : "Waiting on") \(name) · \(item.deliverable)\(due)"
    }
}
