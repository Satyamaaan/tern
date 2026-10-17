import AppKit
import SwiftUI
import TernCore

/// From, To, Cc, Bcc and Subject as flat rows separated by hairlines.
struct ComposerFields: View {
    let model: ComposerModel
    var inset: CGFloat = 20

    var body: some View {
        VStack(spacing: 0) {
            if model.hasSeveralAccounts {
                FieldRow(label: "From", inset: inset) { AccountPicker(model: model) }
                Hairline()
            }
            FieldRow(label: "To", inset: inset) {
                RecipientFieldView(model: model, kind: .to, tokens: model.to)
            } trailing: {
                HStack(spacing: 10) {
                    if !model.showCc { RevealButton(title: "Cc", help: "Add Cc  ⌘⇧C") { model.focus(.cc) } }
                    if !model.showBcc { RevealButton(title: "Bcc", help: "Add Bcc  ⌘⇧B") { model.focus(.bcc) } }
                }
            }
            Hairline()
            if model.showCc {
                FieldRow(label: "Cc", inset: inset) { RecipientFieldView(model: model, kind: .cc, tokens: model.cc) }
                Hairline()
            }
            if model.showBcc {
                FieldRow(label: "Bcc", inset: inset) { RecipientFieldView(model: model, kind: .bcc, tokens: model.bcc) }
                Hairline()
            }
            ComposerTextField(
                model: model, field: .subject, text: model.subject, placeholder: "Subject",
                font: Theme.ui(15, .semibold), onChange: { model.setSubject($0) })
                .frame(height: 22)
                .padding(.horizontal, inset)
                .frame(height: 46)
            Hairline()
        }
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle().fill(Color(Theme.hairline)).frame(height: 1)
    }
}

/// A label column and the row's content, top-aligned so the label sits on the first line of pills.
struct FieldRow<Content: View, Trailing: View>: View {
    let label: String
    var inset: CGFloat = 20
    @ViewBuilder let content: Content
    @ViewBuilder var trailing: Trailing

    init(label: String, inset: CGFloat = 20, @ViewBuilder content: () -> Content, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.label = label
        self.inset = inset
        self.content = content()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label)
                .font(.ui(13))
                .foregroundStyle(Color(Theme.text3))
                .frame(width: 40, height: 40, alignment: .leading)
            content
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            trailing
                .frame(height: 40)
        }
        .padding(.horizontal, inset)
    }
}

/// Quiet text button that reveals Cc or Bcc.
struct RevealButton: View {
    let title: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title).font(.ui(13)).foregroundStyle(Color(hovering ? Theme.text1 : Theme.text3))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// The From row: the account's dot, name and address; click to pick another account.
struct AccountPicker: View {
    let model: ComposerModel

    var body: some View {
        Menu {
            ForEach(model.services.accounts) { account in
                Button("\(account.displayName.isEmpty ? account.email : account.displayName)  —  \(account.email)") {
                    model.setAccount(account.id)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(Theme.accountColor(model.account?.colorIndex ?? 0)))
                    .frame(width: 8, height: 8)
                if let account = model.account, !account.displayName.isEmpty {
                    Text(account.displayName).font(.ui(13)).foregroundStyle(Color(Theme.text1))
                }
                Text(model.account?.email ?? model.accountId).font(.ui(13)).foregroundStyle(Color(Theme.text3))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color(Theme.text3))
            }
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - AppKit fields

/// Hosts a recipient token field; its height follows the pills.
struct RecipientFieldView: NSViewRepresentable {
    let model: ComposerModel
    let kind: RecipientKind
    let tokens: [Participant]

    func makeNSView(context: Context) -> RecipientTokenField {
        let field = RecipientTokenField(kind: kind, composerId: model.id)
        field.tokens = tokens
        let kind = kind
        field.onChange = { [weak model] in model?.setRecipients($0, for: kind) }
        field.suggest = { [weak model] in model?.suggestions(for: $0) ?? [] }
        field.onDrop = { [weak model] in model?.drop($0, into: kind) }
        field.onTab = { [weak model] forward in
            guard let model else { return }
            model.focusNext(from: model.field(for: kind), forward: forward)
        }
        field.onEscape = { [weak model] in model?.escape() }
        model.register(field)
        return field
    }

    func updateNSView(_ field: RecipientTokenField, context: Context) {
        if field.tokens != tokens { field.tokens = tokens }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RecipientTokenField, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        return CGSize(width: width, height: nsView.height(forWidth: width))
    }
}

/// A borderless one-line text field (subject, AI instruction) with composer key handling.
struct ComposerTextField: NSViewRepresentable {
    let model: ComposerModel
    let field: ComposerModel.Field
    let text: String
    let placeholder: String
    var font: NSFont = Theme.ui(13)
    var onChange: (String) -> Void
    var onSubmit: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextField {
        let view = NSTextField(string: text)
        view.isBordered = false
        view.drawsBackground = false
        view.focusRingType = .none
        view.font = font
        view.textColor = Theme.text1
        view.cell?.usesSingleLineMode = true
        view.cell?.wraps = false
        view.cell?.isScrollable = true
        view.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.font: font, .foregroundColor: Theme.text3])
        view.setAccessibilityLabel(placeholder)
        view.delegate = context.coordinator
        context.coordinator.parent = self
        model.register(view, for: field)
        return view
    }

    func updateNSView(_ view: NSTextField, context: Context) {
        context.coordinator.parent = self
        if view.currentEditor() == nil, view.stringValue != text { view.stringValue = text }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ComposerTextField?

        func controlTextDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextField else { return }
            parent?.onChange(view.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let parent else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if let submit = parent.onSubmit { submit() } else { parent.model.focusNext(from: parent.field, forward: true) }
            case #selector(NSResponder.insertTab(_:)):
                parent.model.focusNext(from: parent.field, forward: true)
            case #selector(NSResponder.insertBacktab(_:)):
                parent.model.focusNext(from: parent.field, forward: false)
            case #selector(NSResponder.cancelOperation(_:)):
                parent.model.escape()
            default:
                return false
            }
            return true
        }
    }
}

/// Catches composer shortcuts for the inline composer, but only while focus is inside it.
struct ComposerKeyCatcher: NSViewRepresentable {
    let model: ComposerModel

    func makeNSView(context: Context) -> KeyCatcherView {
        let view = KeyCatcherView()
        view.model = model
        return view
    }

    func updateNSView(_ view: KeyCatcherView, context: Context) {
        view.model = model
    }

    final class KeyCatcherView: NSView {
        weak var model: ComposerModel?

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard let model, let responder = window?.firstResponder, model.owns(responder) else { return false }
            return model.handleKeyEquivalent(event)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
