import AppKit
import Observation
import SwiftUI

/// Offers to move Tern to Applications when a release build runs from somewhere else (Downloads, its disk image,
/// a path Gatekeeper translocated). Sparkle can't update a copy on a read-only disk image, and Applications is
/// where people look for it. "Not now" holds until the next version.
@MainActor
final class MovePrompt {
    static let declinedKey = "moveToApplicationsDeclinedBuild"

    let model: MovePromptModel
    private var panel: CardPanel?

    init(model: MovePromptModel) {
        self.model = model
    }

    /// Whether to ask: release builds, outside Applications, not offscreen or demo runs, and not declined for
    /// this build.
    static func shouldOffer(location: AppLocation, isRelease: Bool, options: LaunchOptions, declinedBuild: String?, build: String) -> Bool {
        isRelease && !options.isHeadless && !options.isFake && location.kind != .applications && declinedBuild != build
    }

    /// Shows the prompt when `shouldOffer` says so; the caller keeps the returned prompt alive while it is up.
    static func offerIfNeeded(options: LaunchOptions, location: AppLocation) -> MovePrompt? {
        let build = AppVersion.current.build
        guard shouldOffer(location: location, isRelease: ReleaseBuild.isCurrent, options: options,
                          declinedBuild: UserDefaults.standard.string(forKey: declinedKey), build: build) else { return nil }
        let prompt = MovePrompt(model: MovePromptModel(location: location))
        prompt.show()
        return prompt
    }

    func show() {
        model.onMove = { [weak self] in self?.move() }
        model.onNotNow = { [weak self] in self?.notNow() }
        let panel = self.panel ?? CardPanel(MovePromptCard(model: model))
        panel.onCancel = { [weak self] in self?.notNow() }
        self.panel = panel
        // Shown at launch, right after the user opened Tern, so it can take the keyboard.
        panel.present(takesFocus: true)
    }

    private func move() {
        model.isMoving = true
        model.error = nil
        Task { [model] in
            do {
                try await AppMover.move(model.location)
            } catch {
                model.isMoving = false
                model.error = error.localizedDescription
            }
        }
    }

    private func notNow() {
        UserDefaults.standard.set(AppVersion.current.build, forKey: Self.declinedKey)
        panel?.dismiss()
    }
}

@MainActor
@Observable
final class MovePromptModel {
    let location: AppLocation
    var isMoving = false
    var error: String?
    @ObservationIgnored var onMove: () -> Void = {}
    @ObservationIgnored var onNotNow: () -> Void = {}

    init(location: AppLocation) {
        self.location = location
    }

    var detail: String {
        if let error { return "Couldn't move Tern: \(error)" }
        let place = location.kind == .diskImage ? "its disk image" : location.folderName
        return "Tern is running from \(place). In Applications it keeps itself up to date."
    }
}

/// The move prompt: "Move Tern to Applications?" with "Not now" and "Move to Applications".
struct MovePromptCard: View {
    let model: MovePromptModel

    var body: some View {
        AppCard(title: "Move Tern to Applications?", detail: model.detail) {
            Button("Not now") { model.onNotNow() }
                .buttonStyle(TernButtonStyle(.secondary))
                .keyboardShortcut(.cancelAction)
                .disabled(model.isMoving)
            Button(model.isMoving ? "Moving…" : "Move to Applications") { model.onMove() }
                .buttonStyle(TernButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(model.isMoving)
        }
    }
}
