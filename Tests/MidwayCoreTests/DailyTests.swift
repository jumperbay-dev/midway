import Foundation
import Network
import Testing
@testable import MidwayCore

func tempStore() throws -> (Store, Int64, URL) {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store = try Store.open(at: dir)
    let a = try store.add(Account(email: "me@fastmail.com", imapHost: "imap.fastmail.com"))
    _ = try store.prepareMailbox(account: a.id!, name: "INBOX", uidValidity: 1)
    return (store, a.id!, dir)
}

func eml(_ from: String, _ to: String, _ subject: String, _ body: String, extra: String = "") -> Data {
    Data("From: \(from)\r\nTo: \(to)\r\nSubject: \(subject)\r\nDate: Tue, 24 Nov 2026 09:14:00 +0100\r\n\(extra)\r\n\(body)".utf8)
}

func labels(_ store: Store, _ id: Int64) throws -> Set<String> {
    Set(try store.db.read { try String.fetchAll($0, sql: "SELECT name FROM label WHERE messageId = ?", arguments: [id]) })
}

@Test func archiveThenUndoCancelsBeforeTheServerSeesIt() throws {
    let (store, a, dir) = try tempStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    try store.insert(raw: eml("ada@example.com", "me@fastmail.com", "Hi", "x"), uid: 7, state: .init(seen: false, labels: [Label.inbox, "Family"]), account: a, mailbox: "INBOX")

    try store.apply(.archive, true, to: 1, delay: 5)
    #expect(try labels(store, 1) == ["Family"])
    #expect(try store.pendingOps(account: a, mailbox: "INBOX").isEmpty)  // held back for undo
    // A resync meanwhile must not put it back in the Inbox.
    try store.update([7: .init(seen: false, labels: [Label.inbox, "Family"])], account: a, mailbox: "INBOX")
    #expect(try labels(store, 1) == ["Family"])

    try store.apply(.archive, false, to: 1)  // undo
    #expect(try labels(store, 1) == [Label.inbox, "Family"])
    #expect(try store.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM op") } == 0)

    // Star is queued at once; starring twice is one op.
    try store.apply(.flagged, true, to: 1)
    try store.apply(.flagged, true, to: 1)
    #expect(try store.pendingOps(account: a, mailbox: "INBOX") == [PendingOp(id: 2, uid: 7, kind: .flagged, value: true)])
}

@Test func searchMatchesPrefixesAndIgnoresAccents() throws {
    let (store, a, dir) = try tempStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    try store.insert(raw: eml("Jörg <jorg@example.com>", "me@fastmail.com", "Café booking", "Table for four at the harbour."), uid: 1, state: .init(seen: true, labels: [Label.inbox]), account: a, mailbox: "INBOX")
    func hits(_ q: String) throws -> Int {
        try store.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM message_fts WHERE message_fts MATCH ?", arguments: [Store.ftsQuery(q)!]) ?? 0 }
    }
    #expect(try hits("cafe") == 1)
    #expect(try hits("harb jorg") == 1)
    #expect(try hits("harbour pizza") == 0)
    #expect(try hits("\"") == 0)  // quotes are escaped, not a syntax error
    // Deleting the message drops it from the index.
    try store.removeMissing(account: a, mailbox: "INBOX", present: [], from: 0)
    #expect(try hits("cafe") == 0)
}

@Test func addressBookRanksPeopleYouWriteTo() throws {
    let (store, a, dir) = try tempStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    try store.insert(raw: eml("Ada Lind <ada@example.com>", "me@fastmail.com", "a", "x"), uid: 1, state: .init(seen: true, labels: []), account: a, mailbox: "INBOX")
    try store.insert(raw: eml("Adam Shop <adam@shop.example>", "me@fastmail.com", "b", "x"), uid: 2, state: .init(seen: true, labels: []), account: a, mailbox: "INBOX")
    try store.insert(raw: eml("no-reply@adverts.example", "me@fastmail.com", "c", "x"), uid: 3, state: .init(seen: true, labels: []), account: a, mailbox: "INBOX")
    try store.insert(raw: eml("ads@list.example", "me@fastmail.com", "d", "x", extra: "List-Id: <ads.list.example>\r\n"), uid: 4, state: .init(seen: true, labels: []), account: a, mailbox: "INBOX")
    try store.insert(raw: eml("me@fastmail.com", "\"Lind, Ada\" <ada@example.com>, bob@example.com", "e", "x"), uid: 5, state: .init(seen: true, labels: []), account: a, mailbox: "INBOX")

    #expect(try store.contacts(matching: "ad").map(\.address) == ["ada@example.com", "adam@shop.example"])
    #expect(try store.contacts(matching: "lind").first?.sent == 1)
    #expect(try store.contacts(matching: "no-reply").isEmpty)
    #expect(try store.contacts(matching: "ads").isEmpty)
}

@Test func composedMessageParsesBack() {
    let built = Compose.build(
        from: .init(name: "", address: "me@fastmail.com"),
        to: [.init(name: "Jörg Lind", address: "jorg@example.com")], cc: [.init(name: "Ada \"A\" Lind", address: "ada@example.com")],
        subject: "Grüße aus Bergen – a long subject that needs more than one encoded word to fit",
        text: "Hej\nSeat 14A", html: "<p>Hej</p>", inReplyTo: "abc@example.com", references: "<abc@example.com>")
    let p = MIME.parse(built.raw)
    #expect(p.subject == "Grüße aus Bergen – a long subject that needs more than one encoded word to fit")
    #expect(p.to == .init(name: "Jörg Lind", address: "jorg@example.com"))
    #expect(p.recipients.map(\.address) == ["jorg@example.com", "ada@example.com"])
    #expect(p.text == "Hej\nSeat 14A")
    #expect(p.html == "<p>Hej</p>")
    #expect(p.messageId == built.messageId)
    #expect(String(decoding: built.raw, as: UTF8.self).split(separator: "\r\n").allSatisfy { $0.utf8.count <= 998 })
}

@Test func dotStuffing() {
    #expect(SMTP.dotStuffed(Data(".hidden\nline\r\n..two".utf8)) == Data("..hidden\r\nline\r\n...two\r\n".utf8))
}

/// A scripted SMTP server on loopback (no TLS) checks the whole dialogue.
@Test func smtpDialogue() async throws {
    let listener = try NWListener(using: .tcp, on: .any)
    let received = OSAllocatedUnfairLockBox()
    listener.newConnectionHandler = { conn in
        conn.start(queue: .global())
        func say(_ s: String) { conn.send(content: Data((s + "\r\n").utf8), completion: .idempotent) }
        var buffer = "", inData = false
        func next() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, _ in
                buffer += String(decoding: data ?? Data(), as: UTF8.self)
                while let r = buffer.range(of: "\r\n") {
                    let line = String(buffer[..<r.lowerBound]); buffer.removeSubrange(..<r.upperBound)
                    received.append(line)
                    if inData { if line == "." { inData = false; say("250 queued") }; continue }
                    switch line.prefix(4) {
                    case "EHLO": say("250-hello"); say("250 AUTH PLAIN XOAUTH2")
                    case "AUTH": say(line == "AUTH PLAIN AG1lAHB3" ? "235 ok" : "535 no")
                    case "MAIL", "RCPT": say("250 ok")
                    case "DATA": inData = true; say("354 go")
                    case "QUIT": say("221 bye")
                    default: say("500 what")
                    }
                }
                if !done { next() }
            }
        }
        say("220 test")
        next()
    }
    listener.start(queue: .global())
    while listener.port == nil || listener.port?.rawValue == 0 { try await Task.sleep(for: .milliseconds(10)) }
    defer { listener.cancel() }

    try await SMTP.send(host: "127.0.0.1", port: listener.port!.rawValue, tls: false, login: .plain(user: "me", password: "pw"),
                        from: "me@x", to: ["a@x", "b@x"], message: Data("Subject: hi\r\n\r\n.dot\r\n".utf8))
    let lines = received.lines
    #expect(lines.contains("RCPT TO:<b@x>"))
    #expect(lines.contains("..dot"))

    await #expect(throws: SMTP.Failure.self) {
        try await SMTP.send(host: "127.0.0.1", port: listener.port!.rawValue, tls: false, login: .plain(user: "me", password: "wrong"),
                            from: "me@x", to: ["a@x"], message: Data("x".utf8))
    }
}

final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    func append(_ l: String) { lock.lock(); _lines.append(l); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
}
