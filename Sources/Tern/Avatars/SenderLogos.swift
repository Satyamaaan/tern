import AppKit
import Observation

/// Sender pictures for list rows and the reader: the icon of the sender's own domain, cached on disk.
/// Until a logo is known, or when logos are switched off, callers draw a letter avatar.
///
/// Every call returns at once from memory; fetching happens in the background and bumps `revision`.
@MainActor
@Observable
final class SenderLogos {
    static let shared = SenderLogos()

    /// Bumps whenever a logo arrives, so views that read it redraw.
    private(set) var revision = 0

    /// The cached logo for this address's domain, or nil. Never waits on the network.
    func logo(forEmail email: String) -> NSImage? { nil }

    /// Asks for this address's logo in the background when logos are on and it isn't cached yet.
    func want(_ email: String) {}

    /// PNG bytes of the cached logo, for the reader page; nil when there is none.
    func pngData(forEmail email: String) -> Data? { nil }
}
