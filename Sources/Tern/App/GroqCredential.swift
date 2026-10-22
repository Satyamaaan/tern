import Foundation
import TernSync

/// The Groq key stays in the login Keychain. Never copy it into database settings or defaults.
enum GroqCredential {
    static let service = "dev.tern.ai.groq"
    static let account = "default"

    private static let lock = NSLock()
    private static var cached: (value: String?, until: Date)?

    static func invalidate() { lock.withLock { cached = nil } }

    static func read() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached, cached.until > Date() { return cached.value }
        let value = load()
        cached = (value, Date().addingTimeInterval(30))
        return value
    }

    private static func load() -> String? {
        guard let data = try? KeychainSecretStore().data(service: service, account: account),
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    static func save(_ value: String) throws {
        lock.lock()
        defer { cached = nil; lock.unlock() }
        let store = KeychainSecretStore()
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { try store.remove(service: service, account: account) }
        else { try store.set(Data(value.utf8), service: service, account: account) }
    }
}
