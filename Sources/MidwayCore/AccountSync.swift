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
public actor AccountSync {
    let account: Account
    let password: String
    let store: Store
    let onState: @Sendable (SyncState) -> Void
    let mailbox = "INBOX"
    /// ponytail: newest 200 messages only; backfill in batches of 500 comes with the Daily driver milestone.
    let window = 200
    let (wakes, waker) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

    public init(account: Account, password: String, store: Store, onState: @escaping @Sendable (SyncState) -> Void) {
        self.account = account
        self.password = password
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
            } catch is LoginFailed {
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

    func session() async throws {
        let config = IMAPConnection.Configuration(hostname: account.imapHost, port: UInt16(account.imapPort), useTLS: true, logging: .noLogging)
        try await IMAPConnection.withConnection(configuration: config) { _, conn in
            let login = try await conn.send(.login(username: account.email, password: password)) { _, r in
                try await r.waitForCompletion()
            }
            guard (try? login.checkOK()) != nil else { throw LoginFailed() }

            while !Task.isCancelled {
                try await syncOnce(conn)
                onState(.synced(.now))
                try await idle(conn)
            }
        }
    }

    func syncOnce(_ conn: IMAPConnection) async throws {
        let accountId = account.id!
        var exists = 0
        var validity: Int64 = 0
        let selected = try await conn.send(.select(.inbox)) { _, responses in
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
        _ = selected

        let known = try store.prepareMailbox(account: accountId, name: mailbox, uidValidity: validity)

        // Push local seen changes first.
        let dirty = try store.dirtySeen(account: accountId, mailbox: mailbox)
        if let set = uidSet(dirty) {
            _ = try await conn.send(.uidStore(.set(set), [], .flags(.add(silent: true, list: [.seen])))) { _, r in
                try await r.waitForCompletion().checkOK()
            }
            try store.clearDirty(dirty, account: accountId, mailbox: mailbox)
        }
        guard exists > 0 else { return }

        // UID + FLAGS for the window, by sequence number.
        let lo = SequenceNumber(rawValue: UInt32(max(1, exists - window + 1)))
        let hi = SequenceNumber(rawValue: UInt32(exists))
        var flags: [Int64: Bool] = [:]
        var uid: Int64?, seen = false
        _ = try await conn.send(.fetch(.set(MessageIdentifierSetNonEmpty(range: MessageIdentifierRange(lo...hi))), [.uid, .flags], [])) { _, responses in
            try await responses.forEach { r in
                guard case .fetch(let f) = r else { return }
                switch f {
                case .start: uid = nil; seen = false
                case .simpleAttribute(.uid(let u)): uid = Int64(u.rawValue)
                case .simpleAttribute(.flags(let fl)): seen = fl.contains(.seen)
                case .finish: if let uid { flags[uid] = seen }
                default: break
                }
            }
        }
        try store.updateSeen(flags, account: accountId, mailbox: mailbox)

        // Bodies for new UIDs, newest first, 25 per round trip.
        let missing = flags.keys.filter { !known.contains($0) }.sorted(by: >)
        for chunk in stride(from: 0, to: missing.count, by: 25).map({ Array(missing[$0..<min($0 + 25, missing.count)]) }) {
            guard let set = uidSet(chunk) else { continue }
            var body = Data()
            _ = try await conn.send(.uidFetch(.set(set), [.uid, .flags, .bodySection(peek: true, .complete, nil)], [])) { _, responses in
                try await responses.forEach { r in
                    guard case .fetch(let f) = r else { return }
                    switch f {
                    case .start: uid = nil; seen = false; body = Data()
                    case .simpleAttribute(.uid(let u)): uid = Int64(u.rawValue)
                    case .simpleAttribute(.flags(let fl)): seen = fl.contains(.seen)
                    case .streamingBytes(let buf): body.append(contentsOf: buf.readableBytesView)
                    case .finish:
                        if let uid, !body.isEmpty {
                            try store.insert(raw: body, uid: uid, seen: seen, account: accountId, mailbox: mailbox)
                        }
                    default: break
                    }
                }
            }
        }
    }

    /// Returns on new mail, a local change, or after 25 minutes (RFC 2177 asks to re-IDLE within 29).
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

    /// Checks an app password before it is saved.
    public static func checkLogin(_ account: Account, password: String) async throws -> Bool {
        let config = IMAPConnection.Configuration(hostname: account.imapHost, port: UInt16(account.imapPort), useTLS: true, logging: .noLogging)
        return try await IMAPConnection.withConnection(configuration: config) { _, conn in
            let tagged = try await conn.send(.login(username: account.email, password: password)) { _, r in
                try await r.waitForCompletion()
            }
            return (try? tagged.checkOK()) != nil
        }
    }
}
