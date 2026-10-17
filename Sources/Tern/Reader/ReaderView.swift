import SwiftUI
import TernCore

// Placeholder: the reader lane replaces this file.
/// The right-hand pane: one conversation.
struct ReaderView: View {
    let key: ThreadKey?

    @Environment(AppServices.self) private var services

    var body: some View {
        if let key, let detail = try? services.store.threadDetail(key) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(detail.thread.subject).font(.serif(24))
                    ForEach(detail.messages, id: \.id) { message in
                        Text(message.bodyText ?? message.snippet).font(.ui(14))
                    }
                }
                .padding(32)
            }
        } else {
            Text("No conversation selected").font(.serif(22, italic: true)).foregroundStyle(Color(Theme.text3))
        }
    }
}
