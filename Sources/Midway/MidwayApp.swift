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
        .commands { TextFormattingCommands() }

        // Compose opens as its own window, one per draft.
        WindowGroup("New message", id: "compose", for: Int64.self) { $draft in
            if let draft = draft { ComposeView(model: model, draftId: draft) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 720, height: 600)
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
    private var credentials: [Int64: Credentials] = [:]
    private var outbox: Outbox?
    /// The last archive, delete, star or read change, for ⌘Z.
    var last: (kind: OpKind, value: Bool, message: Int64, accountId: Int64)?
    private var tasks: [Task<Void, Never>] = []

    init() {
        do {
            store = try Store.open(at: Store.defaultDirectory)
        } catch {
            store = nil
            fatal = "Could not open the mail store: \(error)"
        }
        for a in (try? store?.accounts()) ?? [] { start(a) }
        if let store {
            let o = Outbox(store: store) { [weak self] id in
                try await MainActor.run {
                    guard let self, let a = self.accounts.first(where: { $0.id == id }), let c = self.credentials[id] else { throw AddError("Sign in to this account again.") }
                    return (a, c)
                }
            }
            outbox = o
            tasks.append(Task { await o.run() })
        }
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
        self.credentials[id] = credentials
        let s = AccountSync(account: account, credentials: credentials, store: store) { [weak self] state in
            Task { @MainActor in
                self?.sync[id] = state
                // Back online: failed sends get another go now, not at their backoff time.
                if case .synced = state { self?.outbox?.wake() }
            }
        }
        syncers[id] = s
        tasks.append(Task { await s.run() })
    }

    func open(_ message: Message) {
        guard let id = message.id, !message.seen else { return }
        try? store?.apply(.seen, true, to: id)
        syncers[message.accountId]?.wake()
    }

    /// Archive and delete wait 5 seconds before reaching the server, so ⌘Z can still take them back.
    func act(_ kind: OpKind, _ value: Bool, _ message: Message) {
        guard let id = message.id else { return }
        let delay: TimeInterval = kind == .archive || kind == .trash ? 5 : 0
        try? store?.apply(kind, value, to: id, delay: delay)
        last = (kind, value, id, message.accountId)
        wake(message.accountId, after: delay)
    }

    func undo() {
        guard let l = last else { return }
        try? store?.apply(l.kind, !l.value, to: l.message)
        last = nil
        wake(l.accountId, after: 0)
    }

    func wake(_ account: Int64, after delay: TimeInterval) {
        let s = syncers[account]
        Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay + 0.5)) }
            s?.wake()
        }
    }

    /// Asks every account's server; returns the store ids of its hits, which are now stored locally too.
    func searchServer(_ text: String) async -> [Int64] {
        var ids: [Int64] = []
        for s in syncers.values { ids += (try? await s.searchServer(text)) ?? [] }
        return ids
    }

    // MARK: compose

    func newDraft(replyingTo m: Message? = nil) -> Int64? {
        guard let store, let account = m?.accountId ?? accounts.first?.id else { return nil }
        var d = Draft(accountId: account)
        if let m, let raw = try? store.raw(m) {
            let p = MIME.parse(raw)
            let to = p.replyTo ?? p.from
            d.toList = to.name.isEmpty ? to.address : "\(to.name) <\(to.address)>"
            d.subject = m.subject.lowercased().hasPrefix("re:") ? m.subject : "Re: \(m.subject)"
            d.inReplyTo = m.messageId
            d.refs = ([p.references].compactMap { $0 } + (m.messageId.map { ["<\($0)>"] } ?? [])).joined(separator: " ")
            let quoted = (p.text ?? p.html.map(MIME.stripTags) ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
            let who = m.fromName.isEmpty ? m.fromAddr : m.fromName
            d.rtf = RichText.rtf("\n\nOn \(m.date.formatted(date: .abbreviated, time: .shortened)), \(who) wrote:\n\(quoted)")
        }
        return (try? store.save(d))?.id
    }

    /// Builds the message and leaves it in the outbox for the 10-second undo window.
    func send(_ draft: Draft, body: NSAttributedString) throws {
        guard let store, let account = accounts.first(where: { $0.id == draft.accountId }), let id = draft.id else { return }
        let to = MIME.addresses(draft.toList), cc = MIME.addresses(draft.ccList), bcc = MIME.addresses(draft.bccList)
        guard !(to + cc + bcc).isEmpty else { throw AddError("Add at least one recipient.") }
        let built = Compose.build(
            from: MIME.Address(name: "", address: account.email), to: to, cc: cc, subject: draft.subject,
            text: body.string, html: RichText.html(body), inReplyTo: draft.inReplyTo, references: draft.refs)
        try store.enqueue(draft: id, account: account.id!, raw: built.raw, recipients: (to + cc + bcc).map(\.address), sendAt: .now.addingTimeInterval(10))
        outbox?.wake()
    }

    func unsend(_ draft: Int64) {
        try? store?.unqueue(draft: draft)
        outbox?.wake()
    }
}

struct AddError: LocalizedError {
    let errorDescription: String?
    init(_ s: String) { errorDescription = s }
}
