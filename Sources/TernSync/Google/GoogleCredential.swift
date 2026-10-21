import Foundation

/// What the Keychain keeps for one account (service `dev.tern.mail.google`, account = lowercased email):
/// its refresh token and the OAuth client that issued it. They share one item, so a failed or interleaved
/// write can never pair a token with a client that won't accept it. Items written before Tern kept more
/// than one client hold the bare token; those have no client and use the default one.
public struct GoogleCredential: Codable, Sendable, Hashable {
    public var refreshToken: String
    /// Nil for items from before Tern kept more than one client.
    public var clientId: String?

    public init(refreshToken: String, clientId: String?) {
        self.refreshToken = refreshToken
        self.clientId = clientId
    }

    /// Reads a stored item, JSON or a bare token. Nil when it holds no token.
    public init?(data: Data) {
        if let credential = try? JSONDecoder().decode(GoogleCredential.self, from: data) {
            self = credential
        } else if let token = String(data: data, encoding: .utf8), token.first != "{" {
            self.init(refreshToken: token, clientId: nil)
        } else {
            return nil
        }
        guard !refreshToken.isEmpty else { return nil }
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }
}
