import Foundation
import GRDB

// Mute keeps a thread archived under a "Muted" user label the sync engine finds or creates in Gmail.
// Until it has, a stand-in label id is used, so muting is instant and works offline the first time.
extension LabelChange {
    /// The change with `label` named `replacement` throughout, its intent included.
    public func replacingLabel(_ label: String, with replacement: String) -> LabelChange {
        func swap(_ ids: [String]) -> [String] { ids.map { $0 == label ? replacement : $0 } }
        var swapped = self
        swapped.add = swap(add)
        swapped.remove = swap(remove)
        swapped.intentAdd = intentAdd.map(swap)
        swapped.intentRemove = intentRemove.map(swap)
        return swapped
    }
}

extension MailStore {
    /// Stands in for an account's "Muted" label before its Gmail id is known. The sync engine swaps in
    /// the real id, in queued ops and on stored messages, before it sends anything with it.
    public static let pendingMuteLabel = "TERN_PENDING_MUTED"

    /// The `setting` key holding an account's "Muted" label id.
    public static func muteLabelKey(_ accountId: String) -> String { "mute.label.\(accountId)" }

    /// A change as it applies to a message whose labels are `labels` now: once the engine has swapped
    /// the stand-in Muted label for the real one there, the change names the real one too.
    static func resolvingPendingMute(_ change: LabelChange, muted: String?, labels: [String]?) -> LabelChange {
        guard let muted, let labels, !labels.contains(pendingMuteLabel) else { return change }
        return change.replacingLabel(pendingMuteLabel, with: muted)
    }
}
