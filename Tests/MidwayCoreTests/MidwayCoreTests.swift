import Foundation
import Testing
@testable import MidwayCore

let sample = """
From: =?UTF-8?Q?J=C3=B6rg?= Lind <jorg@example.com>
To: Me <me@fastmail.com>
Subject: =?utf-8?B?R3LDvMOfZQ==?= =?utf-8?Q?_aus_Bergen?=
Date: Tue, 25 Nov 2026 09:14:00 +0100 (CET)
Message-ID: <abc@example.com>
Content-Type: multipart/alternative;
 boundary="b1"

--b1
Content-Type: text/plain; charset=utf-8
Content-Transfer-Encoding: quoted-printable

Train 63 departs Oslo S at 08:25 =E2=80=93 seat 14A.=
 See you.
--b1
Content-Type: text/html; charset="iso-8859-1"
Content-Transfer-Encoding: base64

PHA+U2l0eiAxNEE8L3A+
--b1--
""".replacing("\n", with: "\r\n")

@Test func parsesHeadersAndParts() {
    let p = MIME.parse(Data(sample.utf8))
    #expect(p.from == MIME.Address(name: "Jörg Lind", address: "jorg@example.com"))
    #expect(p.to.address == "me@fastmail.com")
    #expect(p.subject == "Grüße aus Bergen")
    #expect(p.messageId == "abc@example.com")
    #expect(p.date == Date(timeIntervalSince1970: 1_795_594_440))
    #expect(p.text?.hasPrefix("Train 63 departs Oslo S at 08:25 – seat 14A. See you.") == true)
    #expect(p.html == "<p>Sitz 14A</p>")
    #expect(p.preview.hasPrefix("Train 63"))
}

@Test func skipsAttachmentsAndPlainAddresses() {
    let raw = "From: a@b.c\nContent-Type: multipart/mixed; boundary=x\n\n--x\nContent-Type: text/plain\n\nhi\n--x\nContent-Type: text/plain\nContent-Disposition: attachment; filename=a.txt\n\nsecret\n--x--\n"
    let p = MIME.parse(Data(raw.utf8))
    #expect(p.from.address == "a@b.c")
    #expect(p.text == "hi")
}

@Test func storeDedupesBlobsAndKeepsLocalSeen() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try Store.open(at: dir)
    let a = try store.add(Account(email: "me@fastmail.com", imapHost: "imap.fastmail.com"))
    let id = a.id!

    #expect(try store.prepareMailbox(account: id, name: "INBOX", uidValidity: 7).isEmpty)
    try store.insert(raw: Data(sample.utf8), uid: 1, state: .init(seen: false, labels: [Label.inbox]), account: id, mailbox: "INBOX")
    try store.insert(raw: Data(sample.utf8), uid: 2, state: .init(seen: false, labels: [Label.inbox]), account: id, mailbox: "INBOX")
    let blobs = try FileManager.default.subpathsOfDirectory(atPath: dir.appending(path: "messages").path).filter { $0.hasSuffix(".eml") }
    #expect(blobs.count == 1)

    try store.apply(.seen, true, to: 1)
    try store.update([1: .init(seen: false, labels: [Label.inbox]), 2: .init(seen: true, labels: [Label.inbox])], account: id, mailbox: "INBOX")  // server still says unread
    #expect(try store.db.read { try Message.fetchOne($0, key: 1)!.seen })
    #expect(try store.pendingOps(account: id, mailbox: "INBOX").map(\.uid) == [1])

    // UIDVALIDITY reset drops the mailbox's rows.
    #expect(try store.prepareMailbox(account: id, name: "INBOX", uidValidity: 7) == [1, 2])
    #expect(try store.prepareMailbox(account: id, name: "INBOX", uidValidity: 8).isEmpty)
}
