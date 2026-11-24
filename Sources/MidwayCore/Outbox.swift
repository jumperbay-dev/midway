import Foundation
import Network
import os

// MARK: building

/// RFC 5322 + 2045 + 2047 out: multipart/alternative with a plain-text and an HTML part.
public enum Compose {
    public static func build(
        from: MIME.Address, to: [MIME.Address], cc: [MIME.Address], subject: String,
        text: String, html: String, inReplyTo: String? = nil, references: String? = nil, date: Date = .now
    ) -> (raw: Data, messageId: String) {
        let domain = from.address.split(separator: "@").last.map(String.init) ?? "midway.local"
        let messageId = "\(UUID().uuidString.lowercased())@\(domain)"
        let boundary = "midway-\(UUID().uuidString)"
        var h = [
            "From: \(format(from))",
            "To: \(to.map(format).joined(separator: ", "))",
        ]
        if !cc.isEmpty { h.append("Cc: \(cc.map(format).joined(separator: ", "))") }
        h += [
            "Subject: \(encodeWord(subject))",
            "Date: \(rfc5322(date))",
            "Message-ID: <\(messageId)>",
        ]
        if let inReplyTo { h.append("In-Reply-To: <\(inReplyTo)>") }
        if let references { h.append("References: \(references)") }
        h += ["MIME-Version: 1.0", "Content-Type: multipart/alternative; boundary=\"\(boundary)\""]
        func part(_ type: String, _ body: String) -> String {
            "--\(boundary)\r\nContent-Type: \(type); charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
                + Data(body.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]) + "\r\n"
        }
        let raw = h.joined(separator: "\r\n") + "\r\n\r\n" + part("text/plain", text) + part("text/html", html) + "--\(boundary)--\r\n"
        return (Data(raw.utf8), messageId)
    }

    static func format(_ a: MIME.Address) -> String {
        guard !a.name.isEmpty else { return a.address }
        let ascii = a.name.allSatisfy { $0.isASCII && !$0.isNewline }
        let name = ascii ? "\"" + a.name.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\"" : encodeWord(a.name)
        return "\(name) <\(a.address)>"
    }

    /// Plain ASCII stays as it is; anything else becomes UTF-8 B-words of at most 75 characters.
    static func encodeWord(_ s: String) -> String {
        if s.allSatisfy({ $0.isASCII && !$0.isNewline }) { return s }
        var words: [String] = [], chunk = ""
        for c in s {
            if chunk.utf8.count + c.utf8.count > 45 { words.append(chunk); chunk = "" }
            chunk.append(c)
        }
        words.append(chunk)
        return words.map { "=?utf-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
    }

    static func rfc5322(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return f.string(from: d)
    }
}

// MARK: SMTP

/// Just enough SMTP submission: implicit TLS on 465 (Network.framework, system trust, hostname checked),
/// AUTH PLAIN or XOAUTH2, one message.
public enum SMTP {
    public struct Failure: Error, CustomStringConvertible {
        public let code: Int
        public let reply: String
        public var description: String { "\(code) \(reply)" }
        /// 5xx on AUTH: the login itself was refused.
        public var isAuth = false
    }

    public static func send(host: String, port: UInt16 = 465, tls: Bool = true, login: Login, from: String, to: [String], message: Data) async throws {
        let c = try await Lines.connect(host: host, port: port, tls: tls)
        defer { c.close() }
        try await c.expect(220)
        try await c.command("EHLO midway", 250)
        switch login {
        case .plain(let user, let password):
            let token = Data("\0\(user)\0\(password)".utf8).base64EncodedString()
            try await c.auth("AUTH PLAIN \(token)")
        case .xoauth2(let user, let token):
            try await c.auth("AUTH XOAUTH2 \(Data(AccountSync.xoauth2(user: user, token: token).utf8).base64EncodedString())")
        }
        try await c.command("MAIL FROM:<\(from)>", 250)
        for r in to { try await c.command("RCPT TO:<\(r)>", 250, 251) }
        try await c.command("DATA", 354)
        try await c.write(dotStuffed(message) + Data(".\r\n".utf8))
        try await c.expect(250)
        _ = try? await c.command("QUIT", 221)
    }

    /// CRLF line ends, a leading "." doubled, and a final CRLF before the terminating dot.
    static func dotStuffed(_ raw: Data) -> Data {
        var out = Data(capacity: raw.count + 64)
        var lineStart = true
        var prev: UInt8 = 0
        for b in raw {
            if b == 0x0A && prev != 0x0D { out.append(0x0D) }
            if lineStart && b == 0x2E { out.append(0x2E) }
            out.append(b)
            lineStart = b == 0x0A
            prev = b
        }
        if !lineStart { out.append(contentsOf: [0x0D, 0x0A]) }
        return out
    }

    /// A line-oriented NWConnection.
    final class Lines: @unchecked Sendable {
        let conn: NWConnection
        var buffer = Data()

        init(_ conn: NWConnection) { self.conn = conn }

        static func connect(host: String, port: UInt16, tls: Bool) async throws -> Lines {
            let conn = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: tls ? .tls : .tcp)
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let done = OSAllocatedUnfairLock(initialState: false)
                let finish: @Sendable (Error?) -> Void = { e in
                    guard done.withLock({ let first = !$0; $0 = true; return first }) else { return }
                    if let e { conn.cancel(); cont.resume(throwing: e) } else { cont.resume() }
                }
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready: finish(nil)
                    case .failed(let e), .waiting(let e): finish(e)
                    case .cancelled: finish(CancellationError())
                    default: break
                    }
                }
                conn.start(queue: DispatchQueue(label: "midway.smtp"))
            }
            return Lines(conn)
        }

        func close() { conn.cancel() }

        func write(_ data: Data) async throws {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                conn.send(content: data, completion: .contentProcessed { e in e.map { cont.resume(throwing: $0) } ?? cont.resume() })
            }
        }

        func line() async throws -> String {
            while true {
                if let r = buffer.range(of: Data("\r\n".utf8)) {
                    let l = String(decoding: buffer[..<r.lowerBound], as: UTF8.self)
                    buffer.removeSubrange(..<r.upperBound)
                    return l
                }
                let chunk: Data = try await withCheckedThrowingContinuation { cont in
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                        if let error { cont.resume(throwing: error) }
                        else if let data, !data.isEmpty { cont.resume(returning: data) }
                        else { cont.resume(throwing: Failure(code: 0, reply: complete ? "connection closed" : "no data")) }
                    }
                }
                buffer.append(chunk)
            }
        }

        /// One reply, joining "250-…" continuation lines.
        func reply() async throws -> (Int, String) {
            var text: [String] = []
            while true {
                let l = try await line()
                text.append(String(l.dropFirst(4)))
                if l.count < 4 || l[l.index(l.startIndex, offsetBy: 3)] != "-" {
                    return (Int(l.prefix(3)) ?? 0, text.joined(separator: " "))
                }
            }
        }

        func expect(_ codes: Int...) async throws {
            let (code, text) = try await reply()
            guard codes.contains(code) else { throw Failure(code: code, reply: text) }
        }

        @discardableResult
        func command(_ s: String, _ codes: Int...) async throws -> String {
            try await write(Data((s + "\r\n").utf8))
            let (code, text) = try await reply()
            guard codes.contains(code) else { throw Failure(code: code, reply: text) }
            return text
        }

        /// 235 is in. Gmail answers a refused XOAUTH2 token with a 334 challenge; an empty line gets the 535.
        func auth(_ s: String) async throws {
            try await write(Data((s + "\r\n").utf8))
            var (code, text) = try await reply()
            if code == 334 {
                try await write(Data("\r\n".utf8))
                (code, text) = try await reply()
            }
            guard code == 235 else { throw Failure(code: code, reply: text, isAuth: code >= 500) }
        }
    }
}

// MARK: outbox

/// Sends due outbox rows. Compose puts a row in with sendAt 10 seconds ahead (the undo window);
/// failures stay in the outbox with the error and retry with backoff, or sooner when sync reconnects.
public actor Outbox {
    let store: Store
    let login: @Sendable (Int64) async throws -> (Account, Credentials)
    let (wakes, waker) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

    public init(store: Store, login: @escaping @Sendable (Int64) async throws -> (Account, Credentials)) {
        self.store = store
        self.login = login
    }

    public nonisolated func wake() { waker.yield() }

    public func run() async {
        while !Task.isCancelled {
            for item in (try? store.dueOutbox()) ?? [] { await send(item) }
            let next = (try? store.nextOutboxDue()).flatMap { $0 }
            let wait = min(max(next.map { $0.timeIntervalSinceNow } ?? 3600, 0.5), 3600)
            let wakes = self.wakes
            await withTaskGroup(of: Void.self) { g in
                g.addTask { try? await Task.sleep(for: .seconds(wait)) }
                g.addTask { for await _ in wakes { return } }
                await g.next()
                g.cancelAll()
            }
        }
    }

    func send(_ item: OutboxItem) async {
        do {
            let (account, credentials) = try await login(item.accountId)
            let l = try await credentials.login()
            do {
                try await SMTP.send(host: account.smtpHost, login: l, from: account.email,
                                   to: item.recipients.split(separator: "\n").map(String.init), message: item.raw)
            } catch let f as SMTP.Failure where f.isAuth {
                await credentials.invalidate()
                throw f
            }
            // ponytail: Gmail files sent mail itself and Fastmail does by default for SMTP; APPEND to Sent if a provider doesn't
            try store.sent(item)
            try? store.noteSent(item.raw, account: account.email)
        } catch {
            // 30 s, 1, 2, 4 … minutes, capped at 30.
            let retry = Date.now.addingTimeInterval(min(30 * pow(2, Double(item.attempts)), 1800))
            try? store.failed(item, error: (error as? LocalizedError)?.errorDescription ?? String(describing: error), retryAt: retry)
        }
    }
}
