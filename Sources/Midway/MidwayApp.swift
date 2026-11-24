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
                } else if model.account == nil {
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
    var account: Account?
    var sync: SyncState = .connecting
    var fatal: String?
    let store: Store?
    private var syncer: AccountSync?
    private var task: Task<Void, Never>?

    init() {
        do {
            store = try Store.open(at: Store.defaultDirectory)
        } catch {
            store = nil
            fatal = "Could not open the mail store: \(error)"
        }
        if let a = try? store?.accounts().first { start(a) }
    }

    /// Fastmail by default; anything else gets imap.<domain>, editable on the Add account screen.
    static func imapHost(for email: String) -> String {
        let domain = email.split(separator: "@").last.map(String.init)?.lowercased() ?? ""
        let fastmail = ["fastmail.com", "fastmail.fm", "fastmail.net", "fastmail.org", "fastmail.to", "messagingengine.com"]
        return fastmail.contains(domain) ? "imap.fastmail.com" : "imap.\(domain)"
    }

    func add(email: String, host: String, password: String) async throws {
        guard let store else { return }
        let draft = Account(email: email, imapHost: host)
        guard try await AccountSync.checkLogin(draft, password: password) else {
            throw AddError("The server did not accept that app password.")
        }
        try Keychain.set(password, for: email)
        start(try store.add(draft))
    }

    func start(_ account: Account) {
        guard let store, let password = Keychain.get(account.email) else {
            self.account = account
            sync = .signInFailed
            return
        }
        self.account = account
        let s = AccountSync(account: account, password: password, store: store) { [weak self] state in
            Task { @MainActor in self?.sync = state }
        }
        syncer = s
        task = Task { await s.run() }
    }

    func open(_ message: Message) {
        guard let id = message.id, !message.seen else { return }
        try? store?.markSeen(id)
        syncer?.wake()
    }
}

struct AddError: LocalizedError {
    let errorDescription: String?
    init(_ s: String) { errorDescription = s }
}
