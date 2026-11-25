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
for (uid, seen, raw) in msgs { try store.insert(raw: raw, uid: uid, state: .init(seen: seen, labels: [Label.inbox]), account: a.id!, mailbox: "INBOX") }

let g = try store.add(.gmail("me@gmail.com"))
let all = "[Gmail]/All Mail"
_ = try store.prepareMailbox(account: g.id!, name: all, uidValidity: 1)
let gmail: [(Int64, Bool, [String], Data)] = [
  (12, false, [Label.inbox, "Family"], mail("Mira <mira@example.com>", "Cardamom buns recipe", "Tue, 24 Nov 2026 07:30:00 +0100", "text/plain; charset=utf-8", "Here it is. Use less salt than it says.")),
  (11, false, [Label.inbox, "Travel", "\\Important"], mail("Fjord Air <no-reply@fjordair.example>", "Check-in is open for BGO → OSL", "Mon, 23 Nov 2026 10:00:00 +0100", "text/plain; charset=utf-8", "Flight FA 612 departs Bergen 18:05 on 4 December.")),
  (10, true, ["Travel"], mail("Hotel Bryggen <stay@bryggen.example>", "Booking confirmed", "Fri, 20 Nov 2026 14:00:00 +0100", "text/plain; charset=utf-8", "Two nights from 3 December. Breakfast included.")),
  (9, true, ["\\Sent"], mail("Me <me@gmail.com>", "Re: Dinner on Friday?", "Mon, 23 Nov 2026 12:05:00 +0100", "text/plain; charset=utf-8", "Sounds great, count me in.")),
]
for (uid, seen, labels, raw) in gmail { try store.insert(raw: raw, uid: uid, state: .init(seen: seen, labels: labels), account: g.id!, mailbox: all) }
print("seeded")

// Quick access: a fresh code, a parcel, key links and a booking.
let f = DateFormatter()
f.locale = Locale(identifier: "en_US_POSIX")
f.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
func ago(_ s: TimeInterval) -> String { f.string(from: Date.now.addingTimeInterval(-s)) }
let plain = "text/plain; charset=utf-8"
let quick: [(Int64, Data)] = [
  (6, mail("Example <security@example.com>", "Your sign-in code", ago(60), plain, "Your verification code is 482913. It expires in 15 minutes.")),
  (7, mail("Lumen Studio <orders@lumen.example>", "Your order #2291 has shipped", ago(7200), plain, "Good news! Tracking number: 1Z999AA10123456784\nThanks for shopping with us.")),
  (8, mail("Tidewater Review <hello@tidewater.example>", "Issue 49: spring tides", ago(10800), "text/html; charset=utf-8\r\nList-Unsubscribe: <https://tidewater.example/u/1>",
           "<p>This week: spring tides.</p><p><a href='https://tidewater.example/confirm?t=9'>Confirm your email</a> · <a href='https://tidewater.example/u/1'>Unsubscribe</a></p>")),
  (9, mail("Marta Ek <marta@ek.example>", "Standup moved to 10:30", ago(14400), plain, "Join here: https://us02web.zoom.us/j/123456789?pwd=abc\nSee you then.")),
  (10, mail("Fjord Hotels <stay@fjordhotels.example>", "Your stay in Bergen, 3-5 Dec", ago(20000), plain, "Booking reference: KXPTQR\nCheck-in from 15:00.")),
]
for (uid, raw) in quick { try store.insert(raw: raw, uid: uid, state: .init(seen: false, labels: [Label.inbox]), account: a.id!, mailbox: "INBOX") }
print("seeded quick access")

// Calendars: two on Fastmail, one on Gmail, events around today, and an invitation that clashes.
let cal = Calendar.current
let today = cal.startOfDay(for: .now)
func t(_ day: Int, _ h: Int, _ m: Int = 0) -> String {
  let d = cal.date(byAdding: .minute, value: day * 1440 + h * 60 + m, to: today)!
  return ICal.stamp(d)
}
func vevent(_ uid: String, _ title: String, _ s: String, _ e: String, _ extra: String = "") -> String {
  "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:seed\r\nBEGIN:VEVENT\r\nUID:\(uid)\r\nDTSTAMP:\(s)\r\nSUMMARY:\(title)\r\nDTSTART:\(s)\r\nDTEND:\(e)\r\n\(extra)END:VEVENT\r\nEND:VCALENDAR\r\n"
}
let cals = try store.saveCalendars(account: a.id!, [
  .init(url: URL(string: "https://caldav.fastmail.com/dav/calendars/user/me@fastmail.com/personal/")!, name: "Personal", colour: "#62C792", ctag: "1", writable: true),
  .init(url: URL(string: "https://caldav.fastmail.com/dav/calendars/user/me@fastmail.com/work/")!, name: "Work", colour: "#5B8DEF", ctag: "1", writable: true),
]) + store.saveCalendars(account: g.id!, [
  .init(url: URL(string: "https://apidata.googleusercontent.com/caldav/v2/me@gmail.com/events/")!, name: "me@gmail.com", colour: "#E8A33D", ctag: "1", writable: true),
])
func res(_ c: CalendarRow, _ uid: String, _ ics: String) -> CalDAV.Resource { .init(href: URL(string: c.url)!.path(percentEncoded: true) + uid + ".ics", etag: "\"1\"", ics: ics) }
try store.storeEvents(calendar: cals[0].id!, [
  res(cals[0], "dinner", vevent("dinner", "Dinner with Ada", t(2, 19), t(2, 21, 30), "LOCATION:Lysverket\r\n")),
  res(cals[0], "run", vevent("run", "Run", t(-2, 7), t(-2, 8), "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR\r\n")),
  res(cals[0], "bergen", "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:bergen\r\nSUMMARY:Bergen\r\nDTSTART;VALUE=DATE:\(String(t(8, 0).prefix(8)))\r\nDTEND;VALUE=DATE:\(String(t(10, 0).prefix(8)))\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"),
])
try store.storeEvents(calendar: cals[1].id!, [
  res(cals[1], "standup", vevent("standup", "Standup", t(-2, 10, 30), t(-2, 10, 45), "RRULE:FREQ=DAILY;COUNT=10\r\n")),
  res(cals[1], "review", vevent("review", "Design review", t(1, 14), t(1, 15, 30), "LOCATION:Room 4\r\n")),
  res(cals[1], "oneone", vevent("oneone", "1:1 with Marta", t(1, 14, 30), t(1, 15))),
])
try store.storeEvents(calendar: cals[2].id!, [
  res(cals[2], "dentist", vevent("dentist", "Dentist", t(0, 16), t(0, 16, 45))),
])
let invite = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:offsite@ek.example\r\nDTSTAMP:\(t(0, 9))\r\nSUMMARY:Q1 planning offsite\r\nDTSTART:\(t(1, 14))\r\nDTEND:\(t(1, 16))\r\nLOCATION:Studio 2\r\nORGANIZER;CN=Marta Ek:mailto:marta@ek.example\r\nATTENDEE;CN=Marta Ek;PARTSTAT=ACCEPTED:mailto:marta@ek.example\r\nATTENDEE;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:me@fastmail.com\r\nATTENDEE;CN=Jonas;PARTSTAT=NEEDS-ACTION:mailto:jonas@example.com\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
let inviteMail = "From: Marta Ek <marta@ek.example>\r\nTo: me@fastmail.com\r\nSubject: Invitation: Q1 planning offsite\r\nMessage-ID: <offsite-1@ek.example>\r\nDate: \(ago(600))\r\nMIME-Version: 1.0\r\nContent-Type: multipart/alternative; boundary=b\r\n\r\n--b\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nYou are invited to Q1 planning offsite.\r\n--b\r\nContent-Type: text/calendar; method=REQUEST; charset=utf-8\r\n\r\n\(invite)--b--\r\n"
try store.insert(raw: Data(inviteMail.utf8), uid: 11, state: .init(seen: false, labels: [Label.inbox]), account: a.id!, mailbox: "INBOX")
print("seeded calendars")
