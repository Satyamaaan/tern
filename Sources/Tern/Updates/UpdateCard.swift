import AppKit
import Observation
import SwiftUI

/// A version on offer and what's new in it.
struct UpdateRelease: Equatable {
    var version: String
    var notes: ReleaseNotes
}

/// What the update card shows. Most phases come from Sparkle (see `UpdateUserDriver`); `ready` also comes from a
/// download that finished in the background.
enum UpdatePhase: Equatable {
    /// A check the user asked for, still running.
    case checking
    /// Found, not downloaded: automatic updates are off, so the card asks first.
    case available(UpdateRelease)
    case downloading(UpdateRelease?, received: UInt64, expected: UInt64)
    /// Downloaded; Sparkle checks the signature and unpacks it.
    case preparing(UpdateRelease?, progress: Double?)
    /// Downloaded and unpacked: restart now, or it installs when Tern quits.
    case ready(UpdateRelease)
    /// Tern quits, the new version replaces it and opens. `waitingToQuit` while Tern hasn't quit yet.
    case installing(UpdateRelease?, waitingToQuit: Bool)
    /// A check the user asked for found nothing newer.
    case upToDate
    /// One quiet line.
    case failed(String)
}

/// The update card's content and the actions of its two buttons, which change with the phase.
@MainActor
@Observable
final class UpdateCardModel {
    var phase: UpdatePhase = .checking
    let current: AppVersion
    @ObservationIgnored var primary: () -> Void = {}
    @ObservationIgnored var secondary: () -> Void = {}

    init(current: AppVersion = .current) {
        self.current = current
    }
}

/// The update card: icon, a title and one line of detail, a thin progress line while something runs, "What's new"
/// when there is a version to offer, and at most two buttons.
struct UpdateCard: View {
    let model: UpdateCardModel

    var body: some View {
        let phase = model.phase
        let titles = buttonTitles(phase)
        AppCard(title: title(phase), detail: detail(phase), quiet: phase.isFailure, hasButtons: titles.secondary != nil || titles.primary != nil) {
            if let progress = progress(phase) {
                ThinProgress(fraction: progress)
            }
            if let notes = notes(phase), !notes.isEmpty {
                ReleaseNotesView(notes: notes)
            }
        } buttons: {
            if let secondary = titles.secondary {
                Button(secondary) { model.secondary() }
                    .buttonStyle(TernButtonStyle(.secondary))
                    .keyboardShortcut(.cancelAction)
            }
            if let primary = titles.primary {
                Button(primary) { model.primary() }
                    .buttonStyle(TernButtonStyle(.primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func version(_ release: UpdateRelease?) -> String {
        release.map { "Tern \($0.version)" } ?? "the update"
    }

    private func title(_ phase: UpdatePhase) -> String {
        switch phase {
        case .checking: "Checking for updates…"
        case .available(let release): "Tern \(release.version) is available"
        case .downloading(let release, _, _): "Downloading \(version(release))"
        case .preparing(let release, _): "Getting \(version(release)) ready"
        case .ready(let release): "Tern \(release.version) is ready"
        case .installing(let release, _): "Installing \(version(release))…"
        case .upToDate: "Tern is up to date"
        case .failed(let message): message
        }
    }

    private func detail(_ phase: UpdatePhase) -> String? {
        switch phase {
        case .checking, .failed: nil
        case .available: "You have \(model.current.name)."
        case .downloading(_, let received, let expected):
            expected > 0 ? "\(Self.bytes(received)) of \(Self.bytes(expected))" : "Starting…"
        case .preparing: "Checking the download…"
        case .ready: "Restart now, or it installs when you quit Tern."
        case .installing(_, let waiting): waiting ? "Tern needs to quit to finish." : "Tern reopens in a moment."
        case .upToDate: "\(model.current.name) is the newest version."
        }
    }

    /// Nil hides the line; `.some(nil)` animates it while the length of the work isn't known.
    private func progress(_ phase: UpdatePhase) -> Double?? {
        switch phase {
        case .checking: .some(nil)
        case .downloading(_, let received, let expected): .some(expected > 0 ? Double(received) / Double(expected) : nil)
        case .preparing(_, let progress): .some(progress)
        case .installing(_, let waiting): waiting ? nil : .some(nil)
        default: nil
        }
    }

    private func notes(_ phase: UpdatePhase) -> ReleaseNotes? {
        switch phase {
        case .available(let release), .ready(let release): release.notes
        default: nil
        }
    }

    private func buttonTitles(_ phase: UpdatePhase) -> (secondary: String?, primary: String?) {
        switch phase {
        case .checking, .downloading: ("Cancel", nil)
        case .preparing: (nil, nil)
        case .available: ("Later", "Update")
        case .ready: ("Later", "Restart to update")
        case .installing(_, let waiting): (nil, waiting ? "Quit Tern" : nil)
        case .upToDate: (nil, "OK")
        case .failed: ("OK", nil)
        }
    }

    static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

extension UpdatePhase {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// "What's new": a caps label over the notes, scrolling once they are taller than the card should get.
struct ReleaseNotesView: View {
    let notes: ReleaseNotes
    static let maxHeight: CGFloat = 168

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CapsLabel(text: "What's new")
            ViewThatFits(in: .vertical) {
                lines
                ScrollView { lines.padding(.trailing, 10).padding(.bottom, 12) }
                    .scrollIndicators(.automatic)
                    // A soft bottom edge says there is more.
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
            }
            .frame(maxHeight: Self.maxHeight, alignment: .top)
        }
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(notes.lines.enumerated()), id: \.offset) { _, line in
                switch line {
                case .heading(let text):
                    Text(text).font(.ui(12.5, .semibold)).foregroundStyle(Color(Theme.text1)).padding(.top, 2)
                case .paragraph(let text):
                    body(text)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").font(.ui(12.5)).foregroundStyle(Color(Theme.text3))
                        body(text)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func body(_ text: String) -> some View {
        Text(text)
            .font(.ui(12.5))
            .lineSpacing(2.5)
            .foregroundStyle(Color(Theme.text1))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Owns the floating update card. Each `show` replaces the phase and the button actions; Esc runs the quiet
/// button (or the only one).
@MainActor
final class UpdateWindow {
    let model: UpdateCardModel
    private var panel: CardPanel?

    init(model: UpdateCardModel) {
        self.model = model
    }

    convenience init() {
        self.init(model: UpdateCardModel())
    }

    var isVisible: Bool { panel?.isShown ?? false }

    /// Shows `phase`. `focus` when the user asked for it (see `CardPanel.present(takesFocus:)`).
    func show(_ phase: UpdatePhase, focus: Bool, primary: @escaping () -> Void = {}, secondary: @escaping () -> Void = {}) {
        model.phase = phase
        model.primary = primary
        model.secondary = secondary
        let panel = self.panel ?? CardPanel(UpdateCard(model: model))
        self.panel = panel
        panel.onCancel = { [weak self] in
            guard let self else { return }
            switch self.model.phase {
            case .available, .ready, .checking, .downloading, .failed: self.model.secondary()
            case .upToDate: self.model.primary()
            case .preparing, .installing: break
            }
        }
        panel.present(takesFocus: focus)
        #if DEBUG
        UpdateTestHook.showed(phase, model)
        #endif
    }

    /// Brings the card up with the keyboard (Sparkle's "show the update in focus").
    func focus() {
        panel?.present(takesFocus: true)
    }

    func close() {
        panel?.dismiss()
    }
}
