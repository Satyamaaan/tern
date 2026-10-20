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

/// Saves the user's OAuth clients in the Keychain (service `dev.tern.mail.oauth-client`). The first one
/// is the default, under the item `default`; each other one is under its client ID. Several clients let
/// accounts from different places sign in, e.g. a Workspace whose admin only allows its own apps.
public struct GoogleClientConfigStore: Sendable {
    static let account = "default"
    private let secrets: any SecretStore

    public init(secrets: any SecretStore = KeychainSecretStore()) {
        self.secrets = secrets
    }

    /// The default client: the one accounts use when they were connected before Tern kept more than one.
    public func load() throws -> GoogleClientConfig? {
        try config(at: Self.account)
    }

    /// Every client, the default first, then the others by client ID. A client stored twice (a removal that
    /// stopped halfway) is listed once.
    public func loadAll() throws -> [GoogleClientConfig] {
        let others = try secrets.accounts(service: GoogleKeychain.clientService).filter { $0 != Self.account }
        var seen = Set<String>()
        return try ([load()] + others.map { try config(at: $0) }).compactMap { $0 }.filter { seen.insert($0.clientId).inserted }
    }

    /// Validates, then saves as the default client, replacing the one there.
    public func save(_ config: GoogleClientConfig) throws {
        try config.validate()
        try write(config, at: Self.account)
    }

    /// Validates, then adds a client. The first one becomes the default; a client already stored under
    /// the same ID gets the new secret.
    public func add(_ config: GoogleClientConfig) throws {
        try config.validate()
        if let current = try load(), current.clientId != config.clientId {
            try write(config, at: config.clientId)
        } else {
            try write(config, at: Self.account)
        }
    }

    /// Removes a client. When it was the default, the next one takes its place. Safe to repeat after a
    /// failure partway.
    public func remove(clientId: String) throws {
        try secrets.remove(service: GoogleKeychain.clientService, account: clientId)
        guard let current = try load(), current.clientId == clientId else { return }
        let others = try secrets.accounts(service: GoogleKeychain.clientService).filter { $0 != Self.account && $0 != clientId }
        if let next = try others.compactMap({ try config(at: $0) }).first {
            try write(next, at: Self.account)
            try secrets.remove(service: GoogleKeychain.clientService, account: next.clientId)
        } else {
            try secrets.remove(service: GoogleKeychain.clientService, account: Self.account)
        }
    }

    /// Removes every client.
    public func delete() throws {
        for account in try secrets.accounts(service: GoogleKeychain.clientService) {
            try secrets.remove(service: GoogleKeychain.clientService, account: account)
        }
    }

    private func config(at account: String) throws -> GoogleClientConfig? {
        guard let data = try secrets.data(service: GoogleKeychain.clientService, account: account) else { return nil }
        return try? JSONDecoder().decode(GoogleClientConfig.self, from: data)
    }

    private func write(_ config: GoogleClientConfig, at account: String) throws {
        try secrets.set(try JSONEncoder().encode(config), service: GoogleKeychain.clientService, account: account)
    }
}
