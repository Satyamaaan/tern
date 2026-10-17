import Foundation
import Security

/// A small store for secrets: OAuth client settings and refresh tokens. The app uses
/// `KeychainSecretStore`; tests use an in-memory double so they never touch the real Keychain.
public protocol SecretStore: Sendable {
    func data(service: String, account: String) throws -> Data?
    func set(_ data: Data, service: String, account: String) throws
    /// Deleting a missing item is not an error.
    func remove(service: String, account: String) throws
    /// Account names stored under `service`.
    func accounts(service: String) throws -> [String]
}

public struct KeychainError: Error, Equatable, CustomStringConvertible {
    public var status: OSStatus

    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "Keychain error \(status): \(message)"
    }
}

/// Generic-password items, never synced through iCloud Keychain.
///
/// By default items go in the login keychain, which works for any signed build but ties access to
/// the app's code signature: a build signed differently gets a "Tern wants to use your confidential
/// information" prompt. `useDataProtectionKeychain` avoids that (and makes items readable after first
/// unlock), but needs a Team-signed app with a keychain-access-groups entitlement.
public struct KeychainSecretStore: SecretStore {
    private let useDataProtectionKeychain: Bool

    public init(useDataProtectionKeychain: Bool = false) {
        self.useDataProtectionKeychain = useDataProtectionKeychain
    }

    public func data(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return result as? Data
    }

    public func set(_ data: Data, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let update = [kSecValueData as String: data] as CFDictionary
        var status = SecItemUpdate(query as CFDictionary, update)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Tern (\(service))"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func remove(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    public func accounts(service: String) throws -> [String] {
        var query = baseQuery(service: service, account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        let items = result as? [[String: Any]] ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    private func baseQuery(service: String, account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if useDataProtectionKeychain { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }
}
