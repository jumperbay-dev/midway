import Foundation
import Testing
@testable import MidwayCore

func items(_ raw: Data) -> [QuickItem] {
    let p = MIME.parse(raw)
    return Quick.extract(p, message: 1, date: p.date ?? .now)
}

func values(_ raw: Data, _ kind: QuickItem.Kind) -> [String] {
    items(raw).filter { $0.kind == kind }.map(\.value)
}

@Test func oneTimeCodes() {
    #expect(values(eml("a@x", "me@x", "Sign in to Example", "Your verification code is 482913. It expires in 10 minutes."), .code) == ["482913"])
    #expect(values(eml("a@x", "me@x", "Anmeldung", "Ihr Bestätigungscode: AB12CD"), .code) == ["AB12CD"])
    #expect(values(eml("a@x", "me@x", "123456 is your Instagram code", "Don't share it."), .code) == ["123456"])
    // A year, a word in capitals, or digits far from any code word are not codes.
    #expect(values(eml("a@x", "me@x", "Code of Conduct 2026", "Please read it."), .code).isEmpty)
    #expect(values(eml("a@x", "me@x", "VERIFY your account", "Thanks for joining."), .code).isEmpty)
    #expect(values(eml("a@x", "me@x", "Invoice", "Invoice 48291 for November. We have updated the terms and conditions of our service, see our website for the login page."), .code).isEmpty)
}

@Test func parcels() {
    let dhl = items(eml("DHL <noreply@dhl.de>", "me@x", "Ihre Sendung ist unterwegs", "DHL Paket 00340434161094015902 kommt morgen."))
    #expect(dhl.map(\.label) == ["DHL"])
    #expect(dhl.first?.url?.contains("00340434161094015902") == true)
    let ups = items(eml("shop@x", "me@x", "Your order has shipped", "Tracking number: 1Z999AA10123456784"))
    #expect(ups.filter { $0.kind == .parcel }.map(\.label) == ["UPS"])
    #expect(values(eml("shop@x", "me@x", "Shipped", "Your parcel RR123456789DE is on its way."), .parcel) == ["RR123456789DE"])
    // Twelve digits are only a DHL number when the mail names DHL and is about shipping.
    #expect(values(eml("bank@x", "me@x", "Statement", "Account 123456789012, balance attached."), .parcel).isEmpty)
    // Only a "track" link: the parcel is the link.
    let html = "Content-Type: text/html\r\n"
    let link = items(eml("shop@x", "me@x", "Shipped", "<p>Your package is on its way. <a href=\"https://nolp.dhl.de/x?id=1\">Sendung verfolgen</a></p>", extra: html))
    #expect(link.filter { $0.kind == .parcel }.map(\.label) == ["DHL"])
    #expect(link.first?.url == "https://nolp.dhl.de/x?id=1")
}

@Test func keyLinksAndBookings() {
    let html = """
        <p><a href="https://example.com/verify?t=1&amp;u=2">Verify your email</a></p>
        <p><a href="https://example.com/news/unsub">Unsubscribe</a> · <a href="javascript:alert(1)">Reset password</a></p>
        """
    let found = items(eml("a@x", "me@x", "Welcome", html, extra: "Content-Type: text/html\r\n"))
    #expect(found.filter { $0.kind == .link }.map(\.label) == ["Verify", "Unsubscribe"])  // javascript: never becomes a button
    #expect(found.first { $0.label == "Verify" }?.url == "https://example.com/verify?t=1&u=2")
    #expect(found.first { $0.label == "Verify" }?.host == "example.com")

    let meet = items(eml("a@x", "me@x", "Standup", "Join here: https://us02web.zoom.us/j/123?pwd=abc\nThanks"))
    #expect(meet.map(\.label) == ["Join meeting"])
    let list = items(eml("news@x", "me@x", "Issue 48", "Tide tables", extra: "List-Unsubscribe: <mailto:u@x>, <https://news.example/u/1>\r\n"))
    #expect(list.map(\.url) == ["https://news.example/u/1"])

    #expect(items(eml("a@x", "me@x", "Your trip", "Booking reference: KXPTQR")).map(\.value) == ["KXPTQR"])
    #expect(items(eml("a@x", "me@x", "Thanks", "Your order #2291 has been received")).map { "\($0.label) \($0.value)" } == ["Order 2291"])
    #expect(items(eml("a@x", "me@x", "Your booking to Bergen", "Booking confirmed, see you soon.")).isEmpty)
}

@Test func deliveriesAndLatestCode() throws {
    let (store, a, dir) = try tempStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sent = Date(timeIntervalSince1970: 1_795_508_040)  // the eml helper's Date header, 24 Nov 2026 09:14 +0100
    try store.insert(raw: eml("shop@x", "me@fastmail.com", "Shipped", "Tracking number: 1Z999AA10123456784"),
                     uid: 1, state: .init(seen: false, labels: [Label.inbox]), account: a, mailbox: "INBOX")
    try store.insert(raw: eml("Example <a@x>", "me@fastmail.com", "Sign in", "Your code is 482913"),
                     uid: 2, state: .init(seen: false, labels: [Label.inbox]), account: a, mailbox: "INBOX")
    #expect(try store.deliveries(now: sent).map(\.item.label) == ["UPS"])
    #expect(try store.latestCode(now: sent.addingTimeInterval(300))?.code == "482913")
    #expect(try store.latestCode(now: sent.addingTimeInterval(16 * 60)) == nil)  // hidden after 15 minutes

    // A "delivered" mail about the same parcel takes it off the list.
    try store.insert(raw: eml("shop@x", "me@fastmail.com", "Delivered", "Your package 1Z999AA10123456784 has been delivered."),
                     uid: 3, state: .init(seen: false, labels: [Label.inbox]), account: a, mailbox: "INBOX")
    #expect(try store.deliveries(now: sent).isEmpty)
    #expect(try store.quickItems(1).first?.delivered == true)
}
