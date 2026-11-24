import AppKit
import MidwayCore
import SwiftUI

@main
struct MidwayApp: App {
    @Local private var model = AppModel()

    init() {
        // Lets `swift run` behave like a bundled app (Dock icon, key window).
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    var body: some Scene {
        WindowGroup("midway") {
            Group {
                if let error = model.fatal {
                    Text(error).foregroundStyle(T.gold).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.accounts.isEmpty {
                    Onboarding(model: model)
                } else {
                    MailView(model: model)
                }
            }
            .frame(minWidth: 1000, minHeight: 600)
            .background(T.bg)
            .foregroundStyle(T.text)
            .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
    }
}

@MainActor @Observable
final class AppModel {
    var accounts: [Account] = []
    var sync: [Int64: SyncState] = [:]
    var adding = false
    var fatal: String?
    let store: Store?
    private var syncers: [Int64: AccountSync] = [:]
    private var tasks: [Task<Void, Never>] = []

    init() {
        do {
            store = try Store.open(at: Store.defaultDirectory)
        } catch {
            store = nil
            fatal = "Could not open the mail store: \(error)"
        }
        for a in (try? store?.accounts()) ?? [] { start(a) }
    }

    /// Fastmail by default; anything else gets imap.<domain>, editable on the Add account screen.
    static func imapHost(for email: String) -> String {
        let domain = email.split(separator: "@").last.map(String.init)?.lowercased() ?? ""
        let fastmail = ["fastmail.com", "fastmail.fm", "fastmail.net", "fastmail.org", "fastmail.to", "messagingengine.com"]
        return fastmail.contains(domain) ? "imap.fastmail.com" : "imap.\(domain)"
    }

    static func isGmail(_ email: String) -> Bool {
        ["gmail.com", "googlemail.com"].contains(email.split(separator: "@").last?.lowercased() ?? "")
    }

    func add(email: String, host: String, password: String) async throws {
        guard let store else { return }
        let draft = Account(email: email, imapHost: host)
        try ensureNew(email)
        guard try await AccountSync.checkLogin(draft, .plain(user: email, password: password)) else {
            throw AddError("The server did not accept that app password.")
        }
        try Keychain.set(password, for: email)
        start(try store.add(draft))
    }

    /// Opens Google in the browser; the address comes back from Google, so Workspace domains work too.
    func addGoogle(loginHint: String?) async throws {
        guard let store else { return }
        guard let client = GoogleClient.configured else { throw AddError("Gmail needs a Google OAuth client. See the README.") }
        let (email, refresh) = try await GoogleOAuth.signIn(client, loginHint: loginHint) { url in
            Task { @MainActor in NSWorkspace.shared.open(url) }
        }
        try ensureNew(email)
        let token = try await GoogleOAuth.refresh(client, refreshToken: refresh).token
        guard try await AccountSync.checkLogin(.gmail(email), .xoauth2(user: email, token: token)) else {
            throw AddError("Gmail did not accept the sign-in. Is IMAP allowed for this account?")
        }
        try Keychain.set(refresh, for: email)
        start(try store.add(.gmail(email)))
    }

    func ensureNew(_ email: String) throws {
        if accounts.contains(where: { $0.email.lowercased() == email.lowercased() }) {
            throw AddError("\(email) is already in midway.")
        }
    }

    func start(_ account: Account) {
        guard let id = account.id else { return }
        accounts.append(account)
        adding = false
        guard let store, let credentials = Credentials(account: account) else {
            sync[id] = .signInFailed
            return
        }
        let s = AccountSync(account: account, credentials: credentials, store: store) { [weak self] state in
            Task { @MainActor in self?.sync[id] = state }
        }
        syncers[id] = s
        tasks.append(Task { await s.run() })
    }

    func open(_ message: Message) {
        guard let id = message.id, !message.seen else { return }
        try? store?.markSeen(id)
        syncers[message.accountId]?.wake()
    }
}

struct AddError: LocalizedError {
    let errorDescription: String?
    init(_ s: String) { errorDescription = s }
}
