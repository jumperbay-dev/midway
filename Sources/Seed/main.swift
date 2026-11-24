import Foundation
import MidwayCore
let store = try Store.open(at: URL(filePath: CommandLine.arguments[1]))
let a = try store.add(Account(email: "me@fastmail.com", imapHost: "imap.fastmail.com"))
_ = try store.prepareMailbox(account: a.id!, name: "INBOX", uidValidity: 1)
func mail(_ from: String, _ subj: String, _ date: String, _ ct: String, _ body: String) -> Data {
  Data("From: \(from)\r\nTo: me@fastmail.com\r\nSubject: \(subj)\r\nDate: \(date)\r\nContent-Type: \(ct)\r\n\r\n\(body)".utf8)
}
let html = "<html><body style='font-family:sans-serif'><h1 style='color:#0E8580'>Your booking to Bergen</h1><p>Train 63 departs Oslo S at 08:25 on 3 December, seat 14A.</p><img src='https://tracker.example.com/pixel.gif' width=1 height=1><p id=js>JavaScript is OFF</p><script>document.getElementById('js').textContent='JAVASCRIPT RAN'</script><form action='https://evil.example.com'><input name=q></form><p><a href='https://nordicrail.example/booking'>Manage booking</a></p></body></html>"
let msgs: [(Int64, Bool, Data)] = [
  (5, false, mail("Nordic Rail <booking@nordicrail.example>", "Your booking to Bergen", "Tue, 24 Nov 2026 09:14:00 +0100", "text/html; charset=utf-8", html)),
  (4, false, mail("Kestrel Bank <statements@kestrel.example>", "Your November statement is ready", "Tue, 24 Nov 2026 08:02:00 +0100", "text/plain; charset=utf-8", "Statement period 1–30 November. Balance and transactions are in the app.")),
  (3, false, mail("\"Ada Lind\" <ada@example.com>", "Dinner on Friday?", "Mon, 23 Nov 2026 17:48:00 +0100", "text/plain; charset=utf-8", "Mira: I can bring dessert if someone books the table.\n\nSomething with cardamom, obviously.")),
  (2, true, mail("Mum <mum@example.com>", "Photos from the coast", "Sun, 22 Nov 2026 12:00:00 +0100", "text/plain; charset=utf-8", "The boat trip ones turned out lovely, I put them in the shared album.")),
  (1, true, mail("Jonas <jonas@example.com>", "Christmas plans", "Wed, 18 Nov 2026 19:00:00 +0100", "text/plain; charset=utf-8", "Are we doing the cabin again this year or somewhere new?")),
]
for (uid, seen, raw) in msgs { try store.insert(raw: raw, uid: uid, seen: seen, account: a.id!, mailbox: "INBOX") }
print("seeded")
