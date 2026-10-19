import SwiftUI
import TernCore

/// Where the open thread sits in the list, for the "12 of 48" hover text in the reader's top bar.
struct ReaderPosition {
    /// 1-based.
    var index: Int
    var total: Int
    var previous: (() -> Void)?
    var next: (() -> Void)?

    init(index: Int, total: Int, previous: (() -> Void)? = nil, next: (() -> Void)? = nil) {
        self.index = index
        self.total = total
        self.previous = previous
        self.next = next
    }
}

/// One conversation, either full width over the list or in the side pane. Pass the neighbours in
/// `prefetch` (next and previous rows) so moving to them is instant, and `onBack` when the reader covers
/// the list. The container sets the surface; the reader itself draws no background.
struct ReaderView: View {
    let key: ThreadKey?
    var prefetch: [ThreadKey]
    var position: ReaderPosition?
    var onBack: (() -> Void)?

    @Environment(AppServices.self) private var services
    @Environment(\.colorScheme) private var colorScheme
    @State private var model = ReaderModel()

    /// The page's reading column (720 pt of content plus 32 pt each side); the bars below match it.
    static let columnWidth: CGFloat = 784
    static let columnPadding: CGFloat = 32

    init(key: ThreadKey?, prefetch: [ThreadKey] = [], position: ReaderPosition? = nil, onBack: (() -> Void)? = nil) {
        self.key = key
        self.prefetch = prefetch
        self.position = position
        self.onBack = onBack
    }

    var body: some View {
        VStack(spacing: 0) {
            ReaderTopBar(model: model, position: position, onBack: onBack)
            if model.findVisible, key != nil {
                ReaderFindBar(model: model)
                    .readerColumn()
                    .padding(.bottom, 8)
            }
            ZStack(alignment: .bottomLeading) {
                ReaderWebHost(webView: model.engine.webView)
                    .opacity(key == nil ? 0 : 1)
                if key == nil {
                    Text("No conversation selected")
                        .font(.display(18))
                        .foregroundStyle(Color(Theme.text3))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let link = model.hoverLink {
                    ReaderLinkPill(link: link)
                }
                if let toast = model.toast {
                    ReaderToast(text: toast)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 14)
                        .transition(.opacity)
                }
            }
            if key != nil {
                if let request = model.composing {
                    // The card takes the reply pill's place and grows with its text.
                    InlineComposerView(request: request, onClose: { model.composing = nil })
                        .fixedSize(horizontal: false, vertical: true)
                        .readerColumn()
                        .padding(.top, 10)
                        .padding(.bottom, 18)
                } else {
                    ReaderReplyBar(model: model)
                        .readerColumn()
                        .padding(.top, 10)
                        .padding(.bottom, 18)
                }
            }
        }
        .onChange(of: key, initial: true) {
            model.attach(services)
            model.show(key, prefetch: prefetch)
        }
        .onChange(of: prefetch) { model.prefetch(prefetch) }
        .onChange(of: colorScheme, initial: true) { model.setTheme(dark: colorScheme == .dark) }
        .animation(.easeOut(duration: 0.12), value: model.toast)
    }
}

/// Hosts the shared web view, moving it here if another reader had it.
struct ReaderWebHost: NSViewRepresentable {
    let webView: ReaderWebView

    func makeNSView(context: Context) -> ReaderWebContainer {
        let container = ReaderWebContainer()
        container.host(webView)
        return container
    }

    func updateNSView(_ container: ReaderWebContainer, context: Context) {
        container.host(webView)
    }
}

extension View {
    /// Centres the view in the reader's reading column, so the bars line up with the page.
    func readerColumn() -> some View {
        padding(.horizontal, ReaderView.columnPadding)
            .frame(maxWidth: ReaderView.columnWidth)
            .frame(maxWidth: .infinity)
    }
}

final class ReaderWebContainer: NSView {
    func host(_ webView: NSView) {
        guard webView.superview !== self else { return }
        webView.removeFromSuperview()
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
    }
}

// MARK: - Top bar

struct ReaderTopBar: View {
    @Bindable var model: ReaderModel
    let position: ReaderPosition?
    var onBack: (() -> Void)?
    /// Shows the "12 of 48" controls without hovering (snapshot harness).
    static var alwaysShowPosition = false

    @Environment(AppServices.self) private var services
    /// Missing in the reader's own snapshot harness.
    @Environment(AppModel.self) private var app: AppModel?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 2) {
            if let onBack {
                ReaderIconButton(icon: .back, help: hint("Back to list", "back"), action: onBack)
                    .padding(.trailing, 4)
            }
            if let position, hovering || Self.alwaysShowPosition, model.key != nil {
                ReaderIconButton(icon: .chevronLeft, help: hint("Previous conversation", "previous")) { position.previous?() }
                    .disabled(position.previous == nil)
                Text("\(position.index) of \(position.total)")
                    .font(.numeric(12))
                    .foregroundStyle(Color(Theme.text3))
                    .padding(.horizontal, 4)
                ReaderIconButton(icon: .chevronRight, help: hint("Next conversation", "next")) { position.next?() }
                    .disabled(position.next == nil)
            }
            Spacer(minLength: 0)
            if let key = model.key {
                if app?.inArchive == true {
                    ReaderIconButton(icon: .inbox, help: hint("Move to Inbox", "moveToInbox")) { model.perform(.moveToInbox) }
                } else {
                    ReaderIconButton(icon: .archive, help: hint("Archive", "archive")) { model.perform(.archive) }
                }
                ReaderMenuButton(icon: .snoozed, help: hint("Snooze", "snooze")) {
                    SnoozeMenuItems(threads: [key]) { model.pickingSnoozeDate = true }
                }
                .popover(isPresented: $model.pickingSnoozeDate, arrowEdge: .bottom) {
                    ReaderSnoozePicker { date in
                        model.pickingSnoozeDate = false
                        model.perform(.snooze(until: date))
                    }
                }
                ReaderMenuButton(icon: .ellipsis, help: "More") { moreMenu }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func hint(_ title: String, _ id: String) -> String { app?.registry?.hint(title, id) ?? title }

    @ViewBuilder private var moreMenu: some View {
        let thread = model.detail?.thread
        Button("Reply All") { model.reply(all: true) }
        Button("Forward") { model.forward() }
        Divider()
        if let thread {
            let labels = model.labels(for: thread.accountId)
            Menu("Label") {
                if labels.isEmpty { Text("No labels") }
                ForEach(labels, id: \.id) { label in
                    Toggle(label.name, isOn: Binding(
                        get: { thread.labelIds.contains(label.id) },
                        set: { model.setLabel(label.id, on: $0) }))
                }
            }
            Menu("Project") {
                if services.projects.isEmpty { Text("No projects") }
                ForEach(services.projects) { project in
                    Toggle(project.name, isOn: Binding(
                        get: { model.detail?.projects.contains { $0.id == project.id } ?? false },
                        set: { model.setProject(project.id, on: $0) }))
                }
            }
            if app?.prefs.splitInbox == true {
                let current = thread.gmailTab ?? InboxTab(fallback: model.detail?.ai?.category)
                Menu("Move to Tab") {
                    ForEach(InboxTab.allCases) { tab in
                        Toggle(tab.title, isOn: Binding(get: { current == tab }, set: { if $0 { model.perform(.moveToTab(tab)) } }))
                    }
                }
            }
            Button(thread.isStarred ? "Unstar" : "Star") { model.perform(thread.isStarred ? .unstar : .star) }
        }
        Button("Mark Unread") { model.perform(.markUnread) }
        Button("Mute") { model.mute() }.disabled(services.mute == nil)
        Divider()
        if services.ai != nil { Button("Summarize") { model.summaryClicked() } }
        Button("Find in Conversation") { model.openFind() }
        Button("Print…") { model.printThread() }
        Button("Show Original") { model.showOriginal() }
        Divider()
        Button("Report Spam") { model.perform(.markSpam) }
        Button("Move to Trash") { model.perform(.trash) }
    }
}

/// A 28 px icon button with a 16 px glyph in `text2` and a hover fill.
struct ReaderIconButton: View {
    let icon: Icon
    let help: String
    let action: () -> Void

    var body: some View {
        IconButton(icon: icon, size: Theme.Control.regular, iconSize: 16, help: help, action: action)
    }
}

/// A 28 px icon button that opens a menu. Menu labels drop custom views on macOS, so the glyph is a
/// template image.
struct ReaderMenuButton<Items: View>: View {
    let icon: Icon
    let help: String
    @ViewBuilder let items: () -> Items

    @State private var hovering = false

    var body: some View {
        Menu(content: items) {
            Image(nsImage: icon.image(size: 16))
                .foregroundStyle(Color(Theme.text2))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(width: Theme.Control.regular, height: Theme.Control.regular)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(hovering ? Color(Theme.hover) : .clear))
        .contentShape(Rectangle())
        .help(help)
        .onHover { hovering = $0 }
    }
}

struct ReaderSnoozePicker: View {
    let onPick: (Date) -> Void

    @State private var date = Calendar.current.date(
        bySettingHour: 8, minute: 0, second: 0, of: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()) ?? Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Snooze until").font(.ui(13, .semibold)).foregroundStyle(Color(Theme.text1))
            DatePicker("", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                Spacer()
                Button("Snooze") { onPick(date) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(TernButtonStyle(.primary, size: .small))
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

// MARK: - Find, link pill, toast

struct ReaderFindBar: View {
    @Bindable var model: ReaderModel
    @FocusState private var focused: Bool
    @Environment(AppModel.self) private var app: AppModel?

    private func hint(_ title: String, _ id: String) -> String { app?.registry?.hint(title, id) ?? title }

    var body: some View {
        HStack(spacing: 6) {
            IconView(icon: .search, size: 15, color: Color(Theme.text3))
            TextField("Find in conversation", text: $model.findText)
                .textFieldStyle(.plain)
                .font(.ui(13))
                .focused($focused)
                .onSubmit { model.find() }
                .onChange(of: model.findText) { model.find() }
                .onKeyPress(.escape) {
                    model.closeFind()
                    return .handled
                }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    model.find(backwards: true)
                    return .handled
                }
            if model.findFailed {
                Text("No matches").font(.ui(12)).foregroundStyle(Color(Theme.text3))
            }
            IconButton(icon: .chevronUp, size: Theme.Control.small, iconSize: 15, help: hint("Previous match", "findPrevious")) { model.find(backwards: true) }
            IconButton(icon: .chevronDown, size: Theme.Control.small, iconSize: 15, help: hint("Next match", "findNext")) { model.find() }
            IconButton(icon: .close, size: Theme.Control.small, iconSize: 15, help: "Close  Esc") { model.closeFind() }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Color(Theme.hover)))
        .onAppear { focused = true }
    }
}

struct ReaderLinkPill: View {
    let link: ReaderHoverLink

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let warning = link.warning {
                HStack(spacing: 5) {
                    IconView(icon: .warning, size: 13, color: Color(Theme.ink))
                    Text(warning)
                }
                .font(.ui(11, .medium))
                .foregroundStyle(Color(Theme.ink))
            }
            Text(link.destination)
                .font(.ui(11))
                .foregroundStyle(Color(Theme.text2))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.overlay, style: .continuous)
                .fill(Color(Theme.raised))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.overlay, style: .continuous).strokeBorder(Color(Theme.hairlineStrong), lineWidth: 1)))
        .frame(maxWidth: 520, alignment: .leading)
        .padding(8)
        .allowsHitTesting(false)
    }
}

struct ReaderToast: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.ui(13))
            .foregroundStyle(Color(Theme.bg))
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.overlay, style: .continuous).fill(Color(Theme.ink)))
            .shadow(color: .black.opacity(0.14), radius: 15, y: 8)
            .allowsHitTesting(false)
    }
}

// MARK: - Reply bar

struct ReaderReplyBar: View {
    let model: ReaderModel
    /// Shows quick replies without hovering (snapshot harness).
    static var alwaysShowQuickReplies = false
    @Environment(AppModel.self) private var app: AppModel?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button { model.reply(all: false) } label: {
                HStack(spacing: 8) {
                    IconView(icon: .reply, size: 15, color: Color(Theme.text3))
                    Text(model.replyName.map { "Reply to \($0)…" } ?? "Reply…")
                        .lineLimit(1)
                }
                .font(.ui(13))
                .foregroundStyle(Color(Theme.text3))
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Color(Theme.hover)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(app?.registry?.hint("Reply", "reply") ?? "Reply")
            if hovering || Self.alwaysShowQuickReplies {
                ForEach(model.quickReplies, id: \.self) { reply in
                    ReaderQuickReply(text: reply) { model.quickReply(reply) }
                        .transition(.opacity)
                }
            }
        }
        .onHover { inside in
            hovering = inside
            if inside { model.requestQuickReplies() }
        }
        .animation(.easeOut(duration: 0.09), value: hovering)
    }
}

struct ReaderQuickReply: View {
    let text: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                IconView(icon: .sparkles, size: 13, color: Color(Theme.text3))
                Text(text).foregroundStyle(Color(hovering ? Theme.text1 : Theme.text2)).lineLimit(1)
            }
            .font(.ui(13))
            .frame(maxWidth: 200)
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(TernButtonStyle(.secondary))
        .onHover { hovering = $0 }
    }
}
