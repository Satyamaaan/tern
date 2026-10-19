import AppKit
import SwiftUI
import TernCore

// Settings → Mail: how reading and triage behave, how images in mail load, and sending.

struct MarkReadItem: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.prefs
        SettingsRow(title: "Mark as read", detail: detail(prefs.markRead)) {
            SegmentedPicker(options: MarkReadMode.allCases, selection: $prefs.markRead) { $0.title }
        }
    }

    private func detail(_ mode: MarkReadMode) -> String {
        switch mode {
        case .instantly: "As soon as a conversation is on screen, also when moving onto it with j or k."
        case .afterDelay: "Opening marks it read. Moving onto one with j or k waits a moment, so skimming doesn't."
        case .manually: "Conversations stay unread until you mark them read."
        }
    }
}

struct AfterTriageItem: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.prefs
        SettingsRow(title: "After archive or delete", detail: detail(prefs.afterTriage)) {
            SegmentedPicker(options: AfterTriage.allCases, selection: $prefs.afterTriage) { $0.title }
        }
    }

    private func detail(_ choice: AfterTriage) -> String {
        switch choice {
        case .next: "Go to the next conversation. Also after snooze, spam or a move."
        case .previous: "Go to the previous conversation. Also after snooze, spam or a move."
        case .list: "Close the conversation and show the list, with the next one selected."
        }
    }
}

struct ImagesInMailItem: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.prefs
        SettingsRow(title: "Images in mail", detail: detail(prefs.imagesInMail)) {
            SegmentedPicker(options: ImagesInMail.allCases, selection: $prefs.imagesInMail) { $0.title }
        }
    }

    private func detail(_ choice: ImagesInMail) -> String {
        switch choice {
        case .automatic: "Images load through Tern without cookies. Tracking pixels are always blocked."
        case .ask: "Images stay hidden until you load them. Tracking pixels are always blocked."
        }
    }
}

/// With "Ask first", "Always load from…" in the reader adds a sender here, and this is the one place to take
/// them off again.
struct RemoteImagesItem: View {
    let state: SettingsState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: "Always load images from", detail: state.imageSendersError ?? (state.imageSenders.isEmpty
                ? "Choose Always load from… in a message, and its sender shows here."
                : "Images from these senders load without asking, except in Spam.")) { EmptyView() }
            ForEach(state.imageSenders, id: \.self) { sender in
                ImageSenderRow(sender: sender) { state.forgetImages(from: sender) }
            }
        }
    }
}

private struct ImageSenderRow: View {
    let sender: String
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                IconView(icon: .image, size: 14, color: Color(Theme.text3))
                Text(sender)
                    .font(.ui(12.5))
                    .foregroundStyle(Color(Theme.text2))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                Button("Remove", action: remove)
                    .buttonStyle(TernButtonStyle(.quiet, size: .small))
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
            }
            .padding(.leading, 2)
            .frame(height: 34)
            Hairline()
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct UndoSendItem: View {
    @Bindable var state: SettingsState

    var body: some View {
        // A value set some other way still shows as chosen.
        let options = Array(Set([0, 5, 10, 20, 30, state.undoSeconds])).sorted()
        SettingsRow(title: "Undo send", detail: state.undoSeconds == 0 ? "Mail goes out the moment you press Send."
                    : "Send waits \(state.undoSeconds) seconds, so you can take it back.") {
            SegmentedPicker(options: options, selection: $state.undoSeconds) { $0 == 0 ? "Off" : "\($0) s" }
        }
    }
}

struct SignaturesItem: View {
    @Bindable var state: SettingsState

    var body: some View {
        SettingsRow(title: "Add my signature", detail: "Your Gmail signature goes at the end of new mail and replies.") {
            InkToggle(isOn: $state.signatures)
        }
    }
}

/// Several accounts: which one new mail starts from while all of them show.
struct SendFromItem: View {
    @Environment(AppModel.self) private var model
    let state: SettingsState

    var body: some View {
        let chosen = model.accounts.first { $0.id == state.sendFrom } ?? model.accounts.first
        SettingsRow(title: "Send new mail from", detail: "With all accounts showing. In one account, mail comes from that account.") {
            MenuPickerButton(title: chosen.map(model.accountTitle) ?? "First account") { menu(chosen: chosen?.id) }
        }
    }

    private func menu(chosen: String?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for account in model.accounts {
            let item = ClosureMenuItem(model.accountTitle(account)) { [state] in state.sendFrom = account.id }
            item.image = AccountAvatar.image(account, size: 16)
            item.state = account.id == chosen ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
}
