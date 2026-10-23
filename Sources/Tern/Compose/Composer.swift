import AppKit
import SwiftUI
import TernCore

/// Opens composer windows and hosts inline replies.
@MainActor
enum Composer {
    /// Open windows by draft id; opening the same draft again brings its window forward.
    private static var windows: [String: ComposerWindowController] = [:]

    /// Opens a floating composer window for the request.
    static func open(_ request: ComposeRequest, services: AppServices) {
        if case .draft(let id) = request, let open = windows[id] {
            open.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let model = ComposerModel(request: request, services: services, mode: .window) else {
            NSSound.beep()
            return
        }
        present(model)
    }

    /// Opens a Gmail draft that exists only as a DRAFT message (e.g. written in the browser). One stored
    /// without its body has the body fetched first, so saving it can't replace the draft with its snippet.
    static func openDraftMessage(_ key: MessageKey, services: AppServices) {
        do {
            guard let content = try services.drafts.importDraftMessage(key) else {
                NSSound.beep()
                return
            }
            present(ComposerModel(content: content, services: services, mode: .window))
        } catch DraftError.bodyNotFetched(let thread) {
            guard let fetchBodies = services.fetchBodies else {
                NSSound.beep()
                return
            }
            Task {
                guard (try? await fetchBodies(thread)) != nil,
                      let model = ComposerModel(draftMessage: key, services: services, mode: .window) else {
                    NSSound.beep()
                    return
                }
                present(model)
            }
        } catch {
            NSSound.beep()
        }
    }

    private static func present(_ model: ComposerModel) {
        if let open = windows[model.id] {
            open.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = ComposerWindowController(model: model, offset: windows.count)
        windows[model.id] = controller
        controller.onClosed = { windows[model.id] = nil }
        controller.showWindow(nil)
        model.focusInitialField()
    }

    /// Builds the window without showing it (snapshots, measurements).
    static func makeWindow(for model: ComposerModel) -> NSWindow {
        ComposerWindowController(model: model, offset: 0).window!
    }

    /// Builds and lays out one composer offscreen so the first `c` doesn't pay for loading TextKit 2,
    /// the spell checker and the SwiftUI views (≈120 ms cold, ≈25 ms warm). Writes nothing. Call once
    /// when the app is idle after launch.
    static func prewarm(services: AppServices) {
        guard let model = ComposerModel(request: .new(accountId: nil), services: services, mode: .window) else { return }
        let window = makeWindow(for: model)
        model.editor.richText = RichText(plainText: "Warm up")
        window.contentView?.layoutSubtreeIfNeeded()
        model.discard()
        window.close()
    }
}

/// The composer window: our own chrome on a `raised` surface, traffic lights kept.
final class ComposerWindow: NSWindow {
    weak var model: ComposerModel?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if model?.handleKeyEquivalent(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class ComposerWindowController: NSWindowController, NSWindowDelegate {
    let model: ComposerModel
    var onClosed: () -> Void = {}

    static let defaultSize = NSSize(width: 640, height: 560)

    init(model: ComposerModel, offset: Int) {
        self.model = model
        let window = ComposerWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.model = model
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbar = NSToolbar(identifier: "composer")
        window.toolbarStyle = .unifiedCompact
        window.isMovableByWindowBackground = true
        window.backgroundColor = Theme.raised
        window.minSize = NSSize(width: 480, height: 360)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.title = model.title
        window.contentView = NSHostingView(rootView: ComposerView(model: model).environment(model.services))
        super.init(window: window)
        window.delegate = self
        model.onClose = { [weak self] in self?.window?.close() }
        place(window, offset: offset)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Centred on the main window (or screen), cascading 24 pt per open composer.
    private func place(_ window: NSWindow, offset: Int) {
        let anchor = NSApp.mainWindow.flatMap { $0 is ComposerWindow ? nil : $0.frame } ?? window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? .zero
        let step = CGFloat(offset % 8) * 24
        let origin = CGPoint(x: anchor.midX - Self.defaultSize.width / 2 + step, y: anchor.midY - Self.defaultSize.height / 2 - step)
        window.setFrameOrigin(origin)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.saveOrDrop()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        model.saveOrDrop()
        model.tearDown()
        onClosed()
    }

    func windowDidResignKey(_ notification: Notification) {
        model.persist()
    }
}

/// The window's content: a quiet title, the fields, the body, the bottom bar.
struct ComposerView: View {
    let model: ComposerModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                IconView(icon: model.kindIcon, size: 14, color: Color(Theme.text3))
                Text(model.kindTitle)
                    .font(.ui(13, .medium))
                    .foregroundStyle(Color(Theme.text2))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 84)
            .padding(.trailing, 20)
            .frame(height: 38)
            Hairline()
            ComposerFields(model: model)
                .background(Color(Theme.raised))
            BodyEditorView(controller: model.editor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(Theme.raised))
            ComposerBottomArea(model: model)
        }
        .glassSurface(radius: 0, kind: .chrome)
        .tint(Color(Theme.ink))
        .acceptsFileDrops(model)
        .ignoresSafeArea()
    }
}

/// Inline reply/forward editor shown at the bottom of the reader.
struct InlineComposerView: View {
    let request: ComposeRequest
    var onClose: () -> Void = {}

    @Environment(AppServices.self) private var services
    @State private var model: ComposerModel?

    var body: some View {
        Group {
            if let model {
                InlineComposerCard(model: model)
            } else {
                // An empty Group never appears, so it would never build the composer.
                Color.clear.frame(height: 1)
            }
        }
        .onAppear(perform: start)
        .onChange(of: request) {
            model?.saveOrDrop()
            model?.tearDown()
            model = nil
            start()
        }
        .onDisappear {
            model?.saveOrDrop()
            model?.tearDown()
        }
    }

    private func start() {
        guard model == nil, let made = ComposerModel(request: request, services: services, mode: .inline) else { return }
        made.onClose = onClose
        model = made
        DispatchQueue.main.async { made.focusInitialField() }
    }
}

/// The inline card: a one-line recipient summary (expands to full fields), the body growing with its
/// content up to a limit, then the bottom bar.
///
/// It rises out of the reply field it replaces: opacity, 98 % scale from the bottom and 6 pt, over 150 ms on
/// the house curve (an 80 ms fade under Reduce Motion). Render-only, so the web view above takes its new
/// height once; focus is in the card from the first frame. Closing, it sinks back the same way over 120 ms (`ReaderView`).
struct InlineComposerCard: View {
    let model: ComposerModel
    static let minBody: CGFloat = 96
    static let maxBody: CGFloat = 380

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            if model.headerExpanded {
                ComposerFields(model: model, inset: 16)
                    .background(Color(Theme.raised))
            } else {
                Button { model.headerExpanded = true } label: {
                    HStack(spacing: 8) {
                        IconView(icon: model.kindIcon, size: 14, color: Color(Theme.text3))
                        Text("To").font(.ui(13)).foregroundStyle(Color(Theme.text3))
                        Text(model.recipientSummary).font(.ui(13)).foregroundStyle(Color(Theme.text1)).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show recipients and subject")
                Hairline()
            }
            BodyEditorView(controller: model.editor)
                .frame(height: min(max(model.bodyHeight, Self.minBody), Self.maxBody))
                .background(Color(Theme.raised))
            ComposerBottomArea(model: model)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .glassSurface()
        .acceptsFileDrops(model)
        .background(ComposerKeyCatcher(model: model))
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.98, anchor: .bottom)
        .offset(y: appeared || reduceMotion ? 0 : 6)
        .onAppear {
            withAnimation(Motion.or(reduced: reduceMotion, Motion.ease(Motion.cardRise))) { appeared = true }
        }
    }
}

extension ComposerModel {
    /// The glyph beside `kindTitle` and the inline card's recipient summary.
    var kindIcon: Icon {
        switch kind {
        case .new: .compose
        case .reply: .reply
        case .replyAll: .replyAll
        case .forward: .forward
        }
    }
}
