import Foundation

/// A local test server (GreenMail, Radicale) without TLS. Only for localhost, and only with MIDWAY_DEV_PLAINTEXT=1,
/// so no build can be talked into plaintext for a real host.
public enum Dev {
    static let env = ProcessInfo.processInfo.environment

    public static func plaintext(_ host: String) -> Bool {
        env["MIDWAY_DEV_PLAINTEXT"] == "1" && ["localhost", "127.0.0.1"].contains(host)
    }

    /// The local test server's password, so a throwaway account needs no Keychain item.
    static func password(_ host: String) -> String? { plaintext(host) ? env["MIDWAY_DEV_PASSWORD"] : nil }

    static func port(_ key: String, _ fallback: Int) -> Int { env[key].flatMap(Int.init) ?? fallback }
    static var imapPort: Int { port("MIDWAY_DEV_IMAP_PORT", 3143) }
    static var smtpPort: Int { port("MIDWAY_DEV_SMTP_PORT", 3025) }
    static var caldav: URL { URL(string: env["MIDWAY_DEV_CALDAV"] ?? "http://localhost:5232/")! }
}
