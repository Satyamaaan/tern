import SwiftUI
import TernCore

/// The latest inbound message's fresh login actions, outside the untrusted mail page.
struct ReaderLoginActions: View {
    let credentials: [LoginCredential]
    let perform: (LoginCredential) -> Void
    @Environment(AppModel.self) private var app: AppModel?

    var body: some View {
        HStack(spacing: 10) {
            IconView(icon: .key, size: 15, color: Color(Theme.text3))
                .accessibilityHidden(true)
            Text("Sign in").font(.ui(12, .medium)).foregroundStyle(Color(Theme.text2))
            Spacer(minLength: 8)
            ForEach(credentials, id: \.self) { credential in
                switch credential {
                case .code(let code):
                    Button { perform(credential) } label: {
                        HStack(spacing: 6) {
                            Text(code).monospacedDigit()
                            IconView(icon: .copy, size: 13)
                        }
                    }
                    .accessibilityLabel("Copy sign-in code \(code)")
                    .help(hint("Copy sign-in code", "copyLoginCode"))
                case .magicLink(let url):
                    Button { perform(credential) } label: {
                        HStack(spacing: 6) {
                            Text(url.host ?? "Open sign-in link").lineLimit(1).truncationMode(.middle)
                            IconView(icon: .external, size: 13)
                        }
                    }
                    .accessibilityLabel("Open sign-in link on \(url.host ?? "website")")
                    .help(hint("Open sign-in link", "openLoginLink"))
                }
            }
        }
        .buttonStyle(TernButtonStyle(.secondary, size: .small))
    }

    private func hint(_ title: String, _ id: String) -> String { app?.registry?.hint(title, id) ?? title }
}
