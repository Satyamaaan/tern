import Foundation
import TernSync

/// The Groq key stays in the login Keychain. Never copy it into database settings or defaults.
enum GroqCredential {
    static let service = "dev.tern.ai.groq"
    static let account = "default"

    static func read() -> String? {
        guard let data = try? KeychainSecretStore().data(service: service, account: account),
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    static func save(_ value: String) throws {
        let store = KeychainSecretStore()
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { try store.remove(service: service, account: account) }
        else { try store.set(Data(value.utf8), service: service, account: account) }
    }
}
