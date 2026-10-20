import Foundation

/// Google's OAuth and Gmail endpoints. Overridable so tests can point at stubs.
public struct GoogleEndpoints: Sendable, Hashable {
    public var authorization: URL
    public var token: URL
    public var revocation: URL
    public var userInfo: URL
    /// Base for REST, batch and upload URLs.
    public var gmail: URL

    public init(authorization: URL, token: URL, revocation: URL, userInfo: URL, gmail: URL) {
        self.authorization = authorization
        self.token = token
        self.revocation = revocation
        self.userInfo = userInfo
        self.gmail = gmail
    }

    public static let google = GoogleEndpoints(
        authorization: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        token: URL(string: "https://oauth2.googleapis.com/token")!,
        revocation: URL(string: "https://oauth2.googleapis.com/revoke")!,
        userInfo: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!,
        gmail: URL(string: "https://gmail.googleapis.com")!
    )
}

public enum GoogleScope {
    public static let gmailModify = "https://www.googleapis.com/auth/gmail.modify"
    /// What Tern asks for at sign-in.
    public static let signIn = [gmailModify, "openid", "email", "profile"]
}

/// Keychain service names.
public enum GoogleKeychain {
    /// The user's OAuth clients (id and secret).
    public static let clientService = "dev.tern.mail.oauth-client"
    /// Each account's `GoogleCredential` (refresh token and issuing client); the Keychain account is the
    /// lowercased email address.
    public static let tokenService = "dev.tern.mail.google"
}

enum FormEncoding {
    /// RFC 3986 unreserved characters. Everything else is percent-encoded, including "+", "&" and "=".
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func escape(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }

    /// `application/x-www-form-urlencoded` body or URL query, in the given order.
    static func encode(_ items: [(String, String)]) -> String {
        items.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }

    static func url(_ base: URL, _ items: [(String, String)]) -> URL {
        guard !items.isEmpty, var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        components.percentEncodedQuery = encode(items)
        return components.url ?? base
    }
}
