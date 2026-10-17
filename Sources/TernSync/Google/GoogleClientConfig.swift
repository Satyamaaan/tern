import Foundation

/// The user's own Google Cloud OAuth client, of type "Desktop app". Tern is open source and ships
/// without a client; each user creates one (see docs/google-setup.md) and enters it in onboarding.
/// A Desktop client's secret is not confidential, but Google still requires it at the token endpoint.
public struct GoogleClientConfig: Codable, Sendable, Hashable {
    public var clientId: String
    public var clientSecret: String

    public init(clientId: String, clientSecret: String) {
        self.clientId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads the JSON file the Cloud console offers when the client is created
    /// (`{"installed": {"client_id": …, "client_secret": …}}`).
    public init(downloadedJSON data: Data) throws {
        struct File: Decodable {
            struct Client: Decodable {
                var client_id: String
                var client_secret: String?
            }
            var installed: Client?
            var web: Client?
        }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else {
            throw GoogleClientConfigError.unreadableFile
        }
        guard let client = file.installed else {
            throw file.web == nil ? GoogleClientConfigError.unreadableFile : GoogleClientConfigError.notDesktopClient
        }
        self.init(clientId: client.client_id, clientSecret: client.client_secret ?? "")
        try validate()
    }

    /// `<number>-<hash>.apps.googleusercontent.com`.
    public static func isValidClientId(_ id: String) -> Bool {
        let suffix = ".apps.googleusercontent.com"
        guard id.hasSuffix(suffix) else { return false }
        let prefix = id.dropLast(suffix.count)
        guard let first = prefix.first, first.isASCII, first.isLetter || first.isNumber else { return false }
        return prefix.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
    }

    public func validate() throws {
        guard Self.isValidClientId(clientId) else { throw GoogleClientConfigError.invalidClientId }
        guard !clientSecret.isEmpty, !clientSecret.contains(where: \.isWhitespace) else {
            throw GoogleClientConfigError.invalidClientSecret
        }
    }
}

public enum GoogleClientConfigError: Error, Equatable, Sendable {
    /// Not of the form `….apps.googleusercontent.com`.
    case invalidClientId
    case invalidClientSecret
    /// The downloaded JSON belongs to a "Web application" client; Tern needs "Desktop app".
    case notDesktopClient
    case unreadableFile
}

/// Saves the OAuth client in the Keychain (service `dev.tern.mail.oauth-client`).
public struct GoogleClientConfigStore: Sendable {
    static let account = "default"
    private let secrets: any SecretStore

    public init(secrets: any SecretStore = KeychainSecretStore()) {
        self.secrets = secrets
    }

    public func load() throws -> GoogleClientConfig? {
        guard let data = try secrets.data(service: GoogleKeychain.clientService, account: Self.account) else { return nil }
        return try? JSONDecoder().decode(GoogleClientConfig.self, from: data)
    }

    /// Validates, then saves.
    public func save(_ config: GoogleClientConfig) throws {
        try config.validate()
        let data = try JSONEncoder().encode(config)
        try secrets.set(data, service: GoogleKeychain.clientService, account: Self.account)
    }

    public func delete() throws {
        try secrets.remove(service: GoogleKeychain.clientService, account: Self.account)
    }
}
