import Foundation

/// How an account logs in to IMAP. Sync code is the same for every provider.
public enum Login: Sendable {
    case plain(user: String, password: String)
    case xoauth2(user: String, token: String)
}

/// The design's CredentialBroker, one per account: hands out logins, refreshing Google tokens one at a time.
/// Access tokens stay in memory; refresh tokens and passwords stay in the Keychain.
public actor Credentials {
    enum Source {
        case password(String)
        case google(GoogleClient, refreshToken: String)
    }

    let user: String
    let source: Source
    var cached: (token: String, expires: Date)?

    public init?(account: Account) {
        guard let secret = Dev.password(account.imapHost) ?? Keychain.get(account.email) else { return nil }
        switch account.kind {
        case .password: source = .password(secret)
        case .google:
            guard let client = GoogleClient.configured else { return nil }
            source = .google(client, refreshToken: secret)
        }
        user = account.email
    }

    /// Throws `GoogleOAuth.Failure.invalidGrant` when the account must sign in again.
    public func login() async throws -> Login {
        switch source {
        case .password(let p):
            return .plain(user: user, password: p)
        case .google(let client, let refresh):
            if let cached, cached.expires > .now.addingTimeInterval(60) { return .xoauth2(user: user, token: cached.token) }
            let fresh = try await GoogleOAuth.refresh(client, refreshToken: refresh)
            cached = fresh
            return .xoauth2(user: user, token: fresh.token)
        }
    }

    /// The server refused the token: fetch a new one next time.
    public func invalidate() { cached = nil }
}
