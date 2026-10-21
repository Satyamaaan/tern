import Foundation
import TernCore

/// Each account's name and colour, set in Settings → Accounts. The colour marks the account's mail in
/// lists that mix accounts.
extension AppModel {
    /// Renames an account; an empty name goes back to the address.
    func renameAccount(_ account: Account, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != account.displayName else { return }
        updateAccount(account.id) { $0.displayName = name }
    }

    func setAccountColor(_ account: Account, _ colorIndex: Int) {
        guard colorIndex != account.colorIndex else { return }
        updateAccount(account.id) { $0.colorIndex = colorIndex }
    }

    /// The accounts observation brings the change back to the list, the title bar and the menus.
    private func updateAccount(_ id: String, _ change: @escaping @Sendable (inout Account) -> Void) {
        let store = self.store
        writes.async {
            do { try store.updateAccount(id, change) } catch { NSLog("Tern: updating account failed: \(error)") }
        }
    }
}
