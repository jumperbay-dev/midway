import Foundation
import Testing
@testable import MidwayCore

/// Tue 24 Nov 2026, 10:00 in Oslo.
let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Oslo")!; return c }()
let tuesday = cal.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 10))!
func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))! }

@Test func snoozeWords() {
    func p(_ s: String) -> Date? { Snooze.parse(s, now: tuesday, calendar: cal) }
    #expect(p("fri 9") == at(27, 9))
    #expect(p("tomorrow 14:30") == at(25, 14, 30))
    #expect(p("mon") == at(30, 8))
    #expect(p("18") == at(24, 18))
    #expect(p("9") == at(25, 9))  // already past today
    #expect(p("tue 5pm") == cal.date(from: DateComponents(year: 2026, month: 12, day: 1, hour: 17)))  // next Tuesday, not today
    #expect(p("in 3 days") == at(27, 8))
    #expect(p("in 2 hours") == tuesday.addingTimeInterval(7200))
    #expect(p("after the trip") == nil)
    #expect(p("25:00") == nil)
}

@Test func snoozePresets() {
    let c = Snooze.choices(now: tuesday, calendar: cal)
    #expect(c.map(\.title) == ["Later today", "Tomorrow morning", "This weekend", "Next week"])
    #expect(c.map(\.date) == [at(24, 18), at(25, 8), at(28, 9), at(30, 8)])
    // Late in the evening there is no "later today".
    #expect(Snooze.choices(now: at(24, 20), calendar: cal).first?.title == "Tomorrow morning")
}

@Test func pilesAndWakeOnReply() throws {
    let (store, a, dir) = try tempStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    try store.insert(raw: eml("ada@example.com", "me@fastmail.com", "Dinner?", "x", extra: "Message-ID: <dinner@example.com>\r\n"),
                     uid: 1, state: .init(seen: true, labels: [Label.inbox]), account: a, mailbox: "INBOX")
    try store.setPile(1) { $0.replyLater = true }
    try store.setPile(1) { $0.snoozedUntil = .now.addingTimeInterval(86400) }
    #expect(try store.pile(1).replyLater)
    #expect(try store.nextSnoozeEnd() != nil)

    // My own reply in the thread does not wake it; theirs does.
    try store.insert(raw: eml("me@fastmail.com", "ada@example.com", "Re: Dinner?", "y", extra: "In-Reply-To: <dinner@example.com>\r\n"),
                     uid: 2, state: .init(seen: true, labels: []), account: a, mailbox: "INBOX")
    #expect(try store.pile(1).snoozedUntil! > .now)
    try store.insert(raw: eml("ada@example.com", "me@fastmail.com", "Re: Dinner?", "z", extra: "References: <other@x> <dinner@example.com>\r\n"),
                     uid: 3, state: .init(seen: false, labels: [Label.inbox]), account: a, mailbox: "INBOX")
    #expect(try store.pile(1).snoozedUntil! <= .now)
    #expect(try store.pile(1).replyLater)

    // Emptied piles leave no row behind.
    try store.setPile(1) { $0 = Pile(messageId: 1) }
    #expect(try store.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pile") } == 0)
}
