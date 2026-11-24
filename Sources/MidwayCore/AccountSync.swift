import Foundation
import IMAPCommands
import NIOCore
import NIOIMAPCore

public enum SyncState: Equatable, Sendable {
    case connecting
    case synced(Date)
    case offline(String)
    case signInFailed
}

/// One per account: owns the connection, writes into the store, and the UI only ever reads the store.
/// Fastmail syncs INBOX. Gmail syncs [Gmail]/All Mail, which covers every label, and reads X-GM-LABELS.
public actor AccountSync {
    let account: Account
    let credentials: Credentials
    let store: Store
    let onState: @Sendable (SyncState) -> Void
    /// ponytail: newest 200 messages only; backfill in batches of 500 comes with the Daily driver milestone.
    let window = 200
    let (wakes, waker) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var isGmail: Bool { account.kind == .google }

    public init(account: Account, credentials: Credentials, store: Store, onState: @escaping @Sendable (SyncState) -> Void) {
        self.account = account
        self.credentials = credentials
        self.store = store
        self.onState = onState
    }

    /// Ends IDLE early so local changes (seen) reach the server now.
    public nonisolated func wake() { waker.yield() }

    public func run() async {
        var delay: Double = 1
        while !Task.isCancelled {
            onState(.connecting)
            do {
                try await session()
            } catch is LoginFailed, GoogleOAuth.Failure.invalidGrant {
                onState(.signInFailed)
                return
            } catch {
                onState(.offline(String(describing: error)))
            }
            // Exponential backoff with jitter, capped at 5 minutes.
            try? await Task.sleep(for: .seconds(delay * .random(in: 0.8...1.2)))
            delay = min(delay * 2, 300)
        }
    }

    struct LoginFailed: Error {}
    struct TokenRejected: Error {}
    struct NoAllMail: Error {}
    /// Special-use folders by attribute (\All, \Archive, \Trash), found once per session.
    var roles: [String: String] = [:]

    static func configuration(_ account: Account) -> IMAPConnection.Configuration {
        IMAPConnection.Configuration(hostname: account.imapHost, port: UInt16(account.imapPort), useTLS: true, logging: .noLogging)
    }

    func session() async throws {
        let login = try await credentials.login()
        try await IMAPConnection.withConnection(configuration: Self.configuration(account)) { _, conn in
            guard try await Self.authenticate(conn, login) else {
                // A refused OAuth token is retried with a fresh one; a refused password needs the user.
                if case .xoauth2 = login {
                    await credentials.invalidate()
                    throw TokenRejected()
                }
                throw LoginFailed()
            }
            roles = try await Self.specialUse(conn)
            guard let mailbox = isGmail ? roles["\\All"] : "INBOX" else { throw NoAllMail() }
            while !Task.isCancelled {
                try await syncOnce(conn, mailbox: mailbox)
                onState(.synced(.now))
                try await idle(conn)
            }
        }
    }

    /// LOGIN for passwords, AUTHENTICATE XOAUTH2 for Google. True when the server accepted.
    static func authenticate(_ conn: IMAPConnection, _ login: Login) async throws -> Bool {
        switch login {
        case .plain(let user, let password):
            let tagged = try await conn.send(.login(username: user, password: password)) { _, r in try await r.waitForCompletion() }
            return (try? tagged.checkOK()) != nil
        case .xoauth2(let user, let token):
            return try await conn.sendAuthenticate(
                mechanism: AuthenticationMechanism("XOAUTH2")!,
                initialResponse: InitialResponse(ByteBuffer(string: xoauth2(user: user, token: token)))
            ) { _, responses, writer in
                for try await r in responses {
                    switch r {
                    // Gmail explains a refused token in a challenge; an empty reply gets the tagged NO.
                    case .authenticationChallenge: try await writer.writeContinuation(ByteBuffer())
                    case .tagged(let t): return (try? t.checkOK()) != nil
                    default: break
                    }
                }
                return false
            }
        }
    }

    static func xoauth2(user: String, token: String) -> String {
        "user=\(user)\u{01}auth=Bearer \(token)\u{01}\u{01}"
    }

    /// Folder names are localised ("[Gmail]/Alle Nachrichten"), so they are found by SPECIAL-USE attribute.
    static func specialUse(_ conn: IMAPConnection) async throws -> [String: String] {
        var found: [String: String] = [:]
        _ = try await conn.send(.list(nil, reference: MailboxName(ByteBuffer()), .mailbox(ByteBuffer(string: "*")))) { _, responses in
            try await responses.forEach { r in
                guard case .untagged(.mailboxData(.list(let info))) = r else { return }
                for role in ["\\All", "\\Archive", "\\Trash"] where info.attributes.contains(where: { $0 == MailboxInfo.Attribute(role) }) {
                    found[role] = String(decoding: info.path.name.bytes, as: UTF8.self)
                }
            }
        }
        return found
    }

    func syncOnce(_ conn: IMAPConnection, mailbox: String) async throws {
        let accountId = account.id!
        let name = MailboxName(ByteBuffer(string: mailbox))
        var exists = 0
        var validity: Int64 = 0
        _ = try await conn.send(.select(name)) { _, responses in
            try await responses.forEach { r in
                guard case .untagged(let payload) = r else { return }
                switch payload {
                case .mailboxData(.exists(let n)): exists = n
                case .conditionalState(.ok(let text)):
                    if case .uidValidity(let v) = text.code { validity = Int64(UInt32(v)) }
                default: break
                }
            }
        }

        let known = try store.prepareMailbox(account: accountId, name: mailbox, uidValidity: validity)

        // The offline queue goes first.
        for op in try store.pendingOps(account: accountId, mailbox: mailbox) {
            try await replay(op, conn)
        }
        guard exists > 0 else { return }

        // UID, flags (and Gmail ids and labels) for the window, by sequence number.
        let lo = SequenceNumber(rawValue: UInt32(max(1, exists - window + 1)))
        let hi = SequenceNumber(rawValue: UInt32(exists))
        var states: [Int64: Store.ServerState] = [:]
        _ = try await conn.send(.fetch(.set(MessageIdentifierSetNonEmpty(range: MessageIdentifierRange(lo...hi))), attributes, [])) { _, responses in
            var current = Fetched()
            _ = try await responses.forEach { r in
                guard case .fetch(let f) = r else { return }
                if case .start = f { current = Fetched() }
                current.apply(f)
                if case .finish = f, let uid = current.uid { states[uid] = current.state(isGmail: isGmail) }
            }
        }
        try store.update(states, account: accountId, mailbox: mailbox)

        // Deletions elsewhere: compare the UIDs we hold with the server's.
        // ponytail: one UID SEARCH from our oldest UID up; chunk it when mailboxes reach 100k+ messages
        if let oldest = known.min() {
            let present = try await Self.searchUIDs(conn, .uid(.set(MessageIdentifierSetNonEmpty(range: MessageIdentifierRange(UID(rawValue: UInt32(oldest))...)))))
            try store.removeMissing(account: accountId, mailbox: mailbox, present: Set(present), from: oldest)
        }

        // Bodies for new UIDs, newest first.
        try await fetchBodies(conn, states.keys.filter { !known.contains($0) }, mailbox: mailbox)
    }

    /// Downloads and stores whole messages, 25 per round trip.
    func fetchBodies(_ conn: IMAPConnection, _ uids: [Int64], mailbox: String) async throws {
        let accountId = account.id!
        let missing = uids.sorted(by: >)
        for chunk in stride(from: 0, to: missing.count, by: 25).map({ Array(missing[$0..<min($0 + 25, missing.count)]) }) {
            guard let set = uidSet(chunk) else { continue }
            _ = try await conn.send(.uidFetch(.set(set), attributes + [.bodySection(peek: true, .complete, nil)], [])) { _, responses in
                var current = Fetched()
                _ = try await responses.forEach { r in
                    guard case .fetch(let f) = r else { return }
                    if case .start = f { current = Fetched() }
                    current.apply(f)
                    if case .finish = f, let uid = current.uid, !current.body.isEmpty {
                        try store.insert(raw: current.body, uid: uid, state: current.state(isGmail: isGmail), account: accountId, mailbox: mailbox)
                    }
                }
            }
        }
    }

    static func searchUIDs(_ conn: IMAPConnection, _ key: SearchKey) async throws -> [Int64] {
        var uids: [Int64] = []
        _ = try await conn.send(.uidSearch(key: key)) { _, responses in
            try await responses.forEach { r in
                if case .untagged(.mailboxData(.search(let ids, _))) = r { uids += ids.map { Int64($0.rawValue) } }
            }
        }
        return uids
    }

    /// Sends one queued action. A NO from the server (message gone, folder missing) drops the op;
    /// a network error leaves it queued for the next session.
    // ponytail: one command per op; batch by kind if queues get long
    func replay(_ op: PendingOp, _ conn: IMAPConnection) async throws {
        guard let set = uidSet([op.uid]) else { return }
        let gmail = { (names: [String]) in names.map { GmailLabel(ByteBuffer(string: $0)) } }
        var leaves = false
        let command: Command? = switch (op.kind, op.value, isGmail) {
        case (.seen, let on, _): .uidStore(.set(set), [], .flags(on ? .add(silent: true, list: [.seen]) : .remove(silent: true, list: [.seen])))
        case (.flagged, let on, _): .uidStore(.set(set), [], .flags(on ? .add(silent: true, list: [.flagged]) : .remove(silent: true, list: [.flagged])))
        case (.archive, true, true): .uidStore(.set(set), [], .gmailLabels(.remove(silent: true, gmailLabels: gmail([Label.inbox]))))
        case (.archive, false, true), (.trash, false, true): .uidStore(.set(set), [], .gmailLabels(.add(silent: true, gmailLabels: gmail([Label.inbox]))))
        case (.archive, true, false): roles["\\Archive"].map { leaves = true; return .uidMove(.set(set), MailboxName(ByteBuffer(string: $0))) }
        case (.trash, true, _): roles["\\Trash"].map { leaves = true; return .uidMove(.set(set), MailboxName(ByteBuffer(string: $0))) }
        // Fastmail syncs INBOX only, so an archived or trashed message is no longer here to bring back.
        case (.archive, false, false), (.trash, false, false): nil
        }
        guard let command else { return try store.finish(op, removeMessage: false) }
        let tagged = try await conn.send(command) { _, r in try await r.waitForCompletion() }
        let ok = (try? tagged.checkOK()) != nil
        // ponytail: a refused op is dropped without rolling back the local change; add the quiet notice with the Offline screen
        try store.finish(op, removeMessage: ok && leaves)
    }

    var attributes: [FetchAttribute] {
        isGmail ? [.uid, .flags, .gmailMessageID, .gmailThreadID, .gmailLabels] : [.uid, .flags]
    }

    /// One message's FETCH, assembled from its streamed parts.
    struct Fetched {
        var uid: Int64?
        var seen = false
        var flagged = false
        var labels: [String] = []
        var gmMsgId: Int64?
        var gmThrId: Int64?
        var body = Data()

        mutating func apply(_ f: FetchResponse) {
            switch f {
            case .simpleAttribute(.uid(let u)): uid = Int64(u.rawValue)
            case .simpleAttribute(.flags(let fl)): seen = fl.contains(.seen); flagged = fl.contains(.flagged)
            case .simpleAttribute(.gmailLabels(let l)): labels = l.map { $0.makeDisplayString() }
            case .simpleAttribute(.gmailMessageID(let id)): gmMsgId = Int64(bitPattern: id)
            case .simpleAttribute(.gmailThreadID(let id)): gmThrId = Int64(bitPattern: id)
            case .streamingBytes(let buf): body.append(contentsOf: buf.readableBytesView)
            default: break
            }
        }

        /// IMAP folders have no labels, so INBOX is labelled \Inbox to match Gmail.
        func state(isGmail: Bool) -> Store.ServerState {
            Store.ServerState(seen: seen, flagged: flagged, labels: isGmail ? labels : [Label.inbox], gmMsgId: gmMsgId, gmThrId: gmThrId)
        }
    }

    /// Returns on new mail, a local change, or after 25 minutes (RFC 2177 asks to re-IDLE within 29).
    /// ponytail: Gmail sends no IDLE event for label changes made elsewhere; they arrive on the next resync.
    func idle(_ conn: IMAPConnection) async throws {
        let wakes = self.wakes
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await Task.sleep(for: .seconds(25 * 60)) }
            group.addTask { for await _ in wakes { return } }
            group.addTask {
                try await conn.sendIdle { _, responses in
                    for try await r in responses {
                        if case .untagged(.mailboxData(.exists)) = r { return }
                        if case .fetch = r { return }  // flags changed elsewhere
                        if case .untagged(.messageData(.expunge)) = r { return }
                    }
                }
            }
            try await group.next()
            group.cancelAll()
        }
    }

    func uidSet(_ uids: [Int64]) -> MessageIdentifierSetNonEmpty<UID>? {
        MessageIdentifierSetNonEmpty(set: MessageIdentifierSet(uids.map { MessageIdentifierRange(UID(rawValue: UInt32($0))) }))
    }

    /// Older mail: asks the server (X-GM-RAW on Gmail, TEXT elsewhere) on its own connection, stores the
    /// newest `limit` hits it did not have, and returns the store ids of all of them.
    public func searchServer(_ text: String, limit: Int = 20) async throws -> [Int64] {
        let login = try await credentials.login()
        return try await IMAPConnection.withConnection(configuration: Self.configuration(account)) { _, conn in
            guard try await Self.authenticate(conn, login) else { return [] }
            let roles = try await Self.specialUse(conn)
            guard let mailbox = isGmail ? roles["\\All"] : "INBOX" else { return [] }
            var validity: Int64?
            _ = try await conn.send(.examine(MailboxName(ByteBuffer(string: mailbox)))) { _, responses in
                try await responses.forEach { r in
                    if case .untagged(.conditionalState(.ok(let t))) = r, case .uidValidity(let v) = t.code { validity = Int64(UInt32(v)) }
                }
            }
            // Without UIDVALIDITY the stored UIDs cannot be trusted against these hits.
            guard let validity else { return [] }
            let key: SearchKey = isGmail ? .gmailRaw(ByteBuffer(string: text)) : .text(ByteBuffer(string: text))
            let hits = Array(try await Self.searchUIDs(conn, key).sorted(by: >).prefix(limit))
            let have = try store.prepareMailbox(account: account.id!, name: mailbox, uidValidity: validity)
            try await fetchBodies(conn, hits.filter { !have.contains($0) }, mailbox: mailbox)
            return try store.messageIds(account: account.id!, mailbox: mailbox, uids: hits)
        }
    }

    /// Checks a login before an account is saved.
    public static func checkLogin(_ account: Account, _ login: Login) async throws -> Bool {
        try await IMAPConnection.withConnection(configuration: configuration(account)) { _, conn in
            try await authenticate(conn, login)
        }
    }
}
