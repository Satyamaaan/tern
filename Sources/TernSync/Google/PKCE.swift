import CryptoKit
import Foundation
import Security

/// Proof Key for Code Exchange (RFC 7636) with the S256 method.
struct PKCE: Sendable, Hashable {
    let verifier: String
    let challenge: String

    init(verifier: String) {
        self.verifier = verifier
        self.challenge = Self.challenge(for: verifier)
    }

    /// 32 random bytes → a 43-character verifier, the shortest the RFC allows with full entropy.
    static func generate() -> PKCE {
        PKCE(verifier: randomString(byteCount: 32))
    }

    /// BASE64URL(SHA256(ASCII(verifier))).
    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }

    /// Cryptographically random, base64url, for verifiers and `state`.
    static func randomString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes).base64URLEncodedString()
    }
}
