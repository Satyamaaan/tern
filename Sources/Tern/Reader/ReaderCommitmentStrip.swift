import SwiftUI
import TernCore

/// Local commitments stay visible above the message page and follow its database observation.
struct ReaderCommitmentStrip: View {
    @Bindable var model: ReaderModel
    @Environment(AppModel.self) private var app: AppModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.stripItems, id: \.id) { item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        if model.stripItems.count > 1 {
                            Button { model.focusedCommitmentId = item.id } label: {
                                Image(systemName: model.focusedCommitment?.id == item.id ? "circle.inset.filled" : "circle")
                                    .frame(width: 24, height: 24)
                            }
                            .help(hint("Focus commitment", "commitmentNext"))
                            .accessibilityLabel("Focus commitment: \(item.deliverable)")
                            .accessibilityValue(model.focusedCommitment?.id == item.id ? "Selected" : "Not selected")
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.deliverable)
                                .font(.ui(12, .medium))
                                .foregroundStyle(Color(Theme.text1))
                                .lineLimit(2)
                            Text(context(item))
                                .font(.ui(11))
                                .foregroundStyle(Color(Theme.text3))
                                .lineLimit(2)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            app?.changeCommitment(item, to: item.state == .open ? .done : .open)
                        } label: {
                            Text(item.state == .open ? "Done" : "Reopen")
                                .font(.ui(11, .medium))
                                .padding(.horizontal, 9)
                                .frame(height: 24)
                                .background(Capsule().fill(Color(Theme.chipFill)))
                        }
                        .fixedSize()
                        .help(item.state == .open ? hint("Mark done", "commitmentDone") : hint("Reopen", "commitmentReopen"))
                        ReaderMenuButton(icon: .ellipsis, help: "Commitment actions") {
                            Button(hint("Show evidence", "commitmentEvidence")) {
                                if model.focusedCommitment?.id == item.id { model.commitmentEvidence.toggle() }
                                else { model.focusedCommitmentId = item.id; model.commitmentEvidence = true }
                            }
                            Button(hint("Dismiss", "commitmentDismiss")) { app?.changeCommitment(item, to: .dismissed) }
                        }
                    }
                    if item.state == .done {
                        Text(item.completionText)
                            .font(.ui(11)).foregroundStyle(Color(Theme.text3)).lineLimit(3)
                    }
                    if model.commitmentEvidence && model.focusedCommitment?.id == item.id {
                        Text(item.sourceQuote).font(.ui(12)).textSelection(.enabled)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("From \(model.detail?.messages.first(where: { $0.id == item.sourceMessageId }).map { $0.isFromMe ? "you" : $0.fromName.isEmpty ? $0.fromEmail : $0.fromName } ?? item.counterpartyEmail), \(item.sourceDate.formatted(date: .abbreviated, time: .omitted))")
                            Button(hint("Show message", "commitmentShowMessage")) { model.reveal(messageId: item.sourceMessageId) }
                        }.font(.ui(11)).foregroundStyle(Color(Theme.text3))
                        if item.state == .open && item.hintAt != nil { Text("Replied · awaiting confirmation").font(.ui(11)).foregroundStyle(Color(Theme.text3)) }
                    }
                }
                .foregroundStyle(Color(Theme.text2))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Color(Theme.chipFill)))
            }
        }
        .buttonStyle(.plain)
    }

    private func hint(_ title: String, _ id: String) -> String { app?.registry?.hint(title, id) ?? title }
    private func context(_ item: Commitment) -> String {
        let name = item.counterpartyName.isEmpty ? item.counterpartyEmail : item.counterpartyName
        let due = item.dueAt.map { date in
            let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
            let text = (0...6).contains(days) ? date.formatted(.dateTime.weekday(.abbreviated)) : date.formatted(.dateTime.month(.abbreviated).day())
            return " · due " + text
        } ?? ""
        let confidence = item.confidence == 1 ? " · Maybe" : ""
        return "\(item.direction == .iOwe ? "You owe" : "Waiting on") \(name)\(due)\(confidence)"
    }
}
