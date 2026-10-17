import SwiftUI
import TernCore

// Placeholder: the compose lane replaces this file.
/// Opens composer windows and hosts inline replies.
@MainActor
enum Composer {
    /// Opens a floating composer window for the request.
    static func open(_ request: ComposeRequest, services: AppServices) {}
}

/// Inline reply/forward editor shown at the bottom of the reader.
struct InlineComposerView: View {
    let request: ComposeRequest
    var onClose: () -> Void = {}

    var body: some View {
        Text("Reply").font(.ui(13)).foregroundStyle(Color(Theme.text3))
    }
}
