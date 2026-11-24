import CryptoKit
import Foundation
import Network
import os

/// The desktop OAuth client from the Google Cloud setup in the design doc. Google treats a desktop
/// client secret as public, but it still stays out of git: bundle.sh copies it into Info.plist.
public struct GoogleClient: Sendable {
    public let id: String
    public let secret: String

    /// Info.plist (bundled app) first, then the environment (`swift run`).
    public static var configured: GoogleClient? {
        let env = ProcessInfo.processInfo.environment
        let id = Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String ?? env["MIDWAY_GOOGLE_CLIENT_ID"]
        let secret = Bundle.main.object(forInfoDictionaryKey: "GoogleClientSecret") as? String ?? env["MIDWAY_GOOGLE_CLIENT_SECRET"]
        guard let id, let secret, !id.isEmpty, !secret.isEmpty else { return nil }
        return GoogleClient(id: id, secret: secret)
    }
}

/// Authorization code with PKCE, opened in the default browser, redirected to a loopback port.
public enum GoogleOAuth {
    static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    /// Mail and calendars. Accounts added before calendars sign in again once to grant the calendar scope.
    static let scopes = "https://mail.google.com/ https://www.googleapis.com/auth/calendar openid email"

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case invalidGrant
        case denied(String)
        case stateMismatch
        case badResponse(String)

        public var description: String {
            switch self {
            case .invalidGrant: "Google no longer accepts this sign-in. Sign in again."
            case .denied(let e): "Google sign-in was not completed (\(e))."
            case .stateMismatch: "The sign-in reply did not match this request."
            case .badResponse(let s): "Unexpected reply from Google: \(s)"
            }
        }
    }

    struct TokenReply: Decodable {
        let access_token: String
        let expires_in: Double
        let refresh_token: String?
        let id_token: String?
    }

    /// Runs the whole browser flow. Returns the account's address and its refresh token.
    public static func signIn(_ client: GoogleClient, loginHint: String?, open: @escaping @Sendable (URL) -> Void) async throws -> (email: String, refreshToken: String) {
        let verifier = randomURLSafe(32)
        let state = randomURLSafe(16)
        let redirect = try await receiveRedirect { port in
            open(authorizationURL(client, redirect: "http://127.0.0.1:\(port)/", challenge: challenge(for: verifier), state: state, loginHint: loginHint))
        }
        let q = Dictionary(redirect.components.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { a, _ in a })
        guard q["state"] == state else { throw Failure.stateMismatch }
        if let error = q["error"] { throw Failure.denied(error) }
        guard let code = q["code"] else { throw Failure.badResponse("no code") }

        let reply = try await token([
            "grant_type": "authorization_code", "code": code, "code_verifier": verifier,
            "redirect_uri": redirect.uri, "client_id": client.id, "client_secret": client.secret,
        ])
        guard let refresh = reply.refresh_token else { throw Failure.badResponse("no refresh token") }
        guard let email = reply.id_token.flatMap(email(fromIDToken:)) else { throw Failure.badResponse("no email") }
        return (email, refresh)
    }

    public static func refresh(_ client: GoogleClient, refreshToken: String) async throws -> (token: String, expires: Date) {
        let reply = try await token([
            "grant_type": "refresh_token", "refresh_token": refreshToken,
            "client_id": client.id, "client_secret": client.secret,
        ])
        return (reply.access_token, .now.addingTimeInterval(reply.expires_in))
    }

    // MARK: pieces

    static func authorizationURL(_ client: GoogleClient, redirect: String, challenge: String, state: String, loginHint: String?) -> URL {
        var c = URLComponents(url: authEndpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "client_id", value: client.id),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),  // always returns a refresh token
        ] + (loginHint.map { [.init(name: "login_hint", value: $0)] } ?? [])
        return c.url!
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func randomURLSafe(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes, &b) == errSecSuccess)
        return base64URL(Data(b))
    }

    static func base64URL(_ d: Data) -> String {
        d.base64EncodedString().replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: "")
    }

    /// The id_token comes straight from Google's token endpoint over TLS, so its payload is read, not verified.
    static func email(fromIDToken jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1]).replacing("-", with: "+").replacing("_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["email"] as? String
    }

    static func token(_ form: [String: String]) async throws -> TokenReply {
        var req = URLRequest(url: tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = Data(form.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw error == "invalid_grant" ? Failure.invalidGrant : Failure.badResponse("HTTP \(status) \(error ?? "")")
        }
        return try JSONDecoder().decode(TokenReply.self, from: data)
    }

    /// Listens on 127.0.0.1 at a random port for the one redirect, answers it, and stops.
    static func receiveRedirect(_ onReady: @escaping @Sendable (UInt16) -> Void) async throws -> (uri: String, components: URLComponents) {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        let queue = DispatchQueue(label: "midway.oauth-loopback")
        defer { listener.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(uri: String, components: URLComponents), Error>) in
                let done = OSAllocatedUnfairLock(initialState: false)
                let finish: @Sendable (Result<(uri: String, components: URLComponents), Error>) -> Void = { r in
                    if done.withLock({ let first = !$0; $0 = true; return first }) { cont.resume(with: r) }
                }
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: onReady(listener.port!.rawValue)
                    case .failed(let e): finish(.failure(e))
                    case .cancelled: finish(.failure(CancellationError()))
                    default: break
                    }
                }
                listener.newConnectionHandler = { conn in
                    conn.start(queue: queue)
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, _ in
                        // "GET /?state=…&code=… HTTP/1.1"
                        let line = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first ?? ""
                        let target = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                        guard let port = listener.port?.rawValue,
                              let c = URLComponents(string: "http://127.0.0.1:\(port)\(target)"), c.path == "/", c.queryItems != nil
                        else { conn.cancel(); return }  // favicon and friends
                        let body = "<!doctype html><title>midway</title><body style=\"font:15px -apple-system,sans-serif;padding:48px;background:#0B1620;color:#DCE7EC\">midway is signed in. You can close this tab.</body>"
                        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
                        conn.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in conn.cancel() })
                        finish(.success(("http://127.0.0.1:\(port)/", c)))
                    }
                }
                listener.start(queue: queue)
            }
        } onCancel: {
            listener.cancel()
        }
    }
}
