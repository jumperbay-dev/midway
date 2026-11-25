import Foundation
import GRDB
import Testing
@testable import MidwayCore

let berlin = TimeZone(identifier: "Europe/Berlin")!

func on(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ tz: TimeZone = .current) -> Date {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = tz
    return c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

let invite = """
    BEGIN:VCALENDAR\r
    METHOD:REQUEST\r
    BEGIN:VTIMEZONE\r
    TZID:Europe/Berlin\r
    END:VTIMEZONE\r
    BEGIN:VEVENT\r
    UID:retro-1@work.example\r
    DTSTART;TZID=Europe/Berlin:20261202T173000\r
    DTEND;TZID=Europe/Berlin:20261202T190000\r
    SUMMARY:Quarterly retro\\, Q4\r
    LOCATION:Room Lighthouse\r
    ORGANIZER;CN=Lena Vik:mailto:lena@work.example\r
    ATTENDEE;CN=Lena Vik;PARTSTAT=ACCEPTED:mailto:lena@work.example\r
    ATTENDEE;CN=Me;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:me@fastmail.com\r
    BEGIN:VALARM\r
    TRIGGER:-PT15M\r
    SUMMARY:not the event\r
    END:VALARM\r
    END:VEVENT\r
    END:VCALENDAR\r

    """

@Test func parsesInvites() throws {
    let p = ICal.parse(invite)
    #expect(p.method == "REQUEST")
    let e = try #require(p.events.first)
    #expect(e.summary == "Quarterly retro, Q4" && e.location == "Room Lighthouse")
    #expect(e.start == on(2026, 12, 2, 17, 30, berlin) && e.end == on(2026, 12, 2, 19, 0, berlin))
    #expect(e.organizer == "lena@work.example")
    #expect(e.attendees.map(\.partstat) == ["ACCEPTED", "NEEDS-ACTION"])

    // Folded lines, all-day dates and a duration.
    let folded = "BEGIN:VEVENT\r\nUID:b\r\nSUMMARY:Mum’s birth\r\n day\r\nDTSTART;VALUE=DATE:20261127\r\nDURATION:P1D\r\nEND:VEVENT\r\n"
    let b = try #require(ICal.parse(folded).events.first)
    #expect(b.summary == "Mum’s birthday" && b.allDay && b.start == on(2026, 11, 27) && b.end == on(2026, 11, 28))

    // The reply carries only my line, with my answer; the stored copy keeps everyone else.
    let reply = ICal.parse(ICal.reply(e, me: "me@fastmail.com", partstat: "ACCEPTED"))
    #expect(reply.method == "REPLY" && reply.events.first?.attendees == [ICal.Attendee(email: "me@fastmail.com", name: "Me", partstat: "ACCEPTED")])
    let stored = ICal.parse(ICal.setPartstat(invite, me: "me@fastmail.com", partstat: "TENTATIVE"))
    #expect(stored.method == nil && stored.events.first?.attendees.map(\.partstat) == ["ACCEPTED", "TENTATIVE"])
    #expect(stored.events.first?.summary == "Quarterly retro, Q4")
}

@Test func expandsRepeats() {
    var e = ICal.Event()
    e.uid = "standup"; e.summary = "Standup"
    e.start = on(2026, 11, 2, 9); e.end = on(2026, 11, 2, 9, 15)
    e.rrule = "FREQ=WEEKLY;BYDAY=MO,WE;COUNT=6"
    e.exdates = [on(2026, 11, 4, 9)]
    var moved = e
    moved.rrule = nil; moved.exdates = []
    moved.recurrenceId = on(2026, 11, 9, 9)
    moved.start = on(2026, 11, 9, 11); moved.end = on(2026, 11, 9, 11, 15)
    let got = ICal.expand([e, moved], from: on(2026, 11, 1), to: on(2026, 12, 31)).map(\.start)
    // Mon 2, (Wed 4 excluded), Mon 9 moved to 11:00, Wed 11, Mon 16, Wed 18: six occurrences counted, five kept.
    #expect(got == [on(2026, 11, 2, 9), on(2026, 11, 9, 11), on(2026, 11, 11, 9), on(2026, 11, 16, 9), on(2026, 11, 18, 9)])

    var monthly = ICal.Event()
    monthly.uid = "rent"; monthly.start = on(2026, 1, 31, 8); monthly.end = on(2026, 1, 31, 9)
    monthly.rrule = "FREQ=MONTHLY;UNTIL=20260430T000000Z"
    #expect(ICal.expand([monthly], from: on(2026, 1, 1), to: on(2027, 1, 1)).count == 3)

    // What midway writes, it reads back the same.
    let back = ICal.parse(ICal.write(e)).events.first
    #expect(back?.rrule == e.rrule && back?.start == e.start && back?.exdates == e.exdates)
}

@Test func quickAdd() throws {
    let now = on(2026, 11, 25, 16, 24)  // Wednesday
    let a = try #require(QuickAdd.parse("Climbing with Marta sat 3–5pm /climbing", now: now))
    #expect(a.title == "Climbing with Marta" && a.calendar == "climbing" && a.when == "sat 3–5pm")
    #expect(a.start == on(2026, 11, 28, 15) && a.end == on(2026, 11, 28, 17))
    let b = try #require(QuickAdd.parse("Lunch with Ada thu 12", now: now))
    #expect(b.title == "Lunch with Ada" && b.start == on(2026, 11, 26, 12) && b.end == on(2026, 11, 26, 13))
    let c = try #require(QuickAdd.parse("Mum's birthday dec 3", now: now))
    #expect(c.allDay && c.start == on(2026, 12, 3) && c.end == on(2026, 12, 4))
    let d = try #require(QuickAdd.parse("Retro 10:00-11:30 today", now: now))
    #expect(d.start == on(2026, 11, 25, 10) && d.end == on(2026, 11, 25, 11, 30))
    #expect(QuickAdd.parse("Read 12 chapters", now: now)?.title != "Read chapters")  // a number mid-sentence is not a time
    #expect(QuickAdd.parse("just words", now: now) == nil)
    #expect(QuickAdd.range("11-1pm")! == (11, 0, 13, 0))
}

@Test func mailInvitePart() {
    let raw = """
        From: Lena <lena@work.example>\r
        To: me@fastmail.com\r
        Subject: Invitation: Quarterly retro\r
        Content-Type: multipart/mixed; boundary="b"\r
        \r
        --b\r
        Content-Type: text/plain\r
        \r
        You are invited.\r
        --b\r
        Content-Type: application/ics; name="invite.ics"\r
        Content-Disposition: attachment; filename="invite.ics"\r
        Content-Transfer-Encoding: base64\r
        \r
        \(Data(invite.utf8).base64EncodedString())\r
        --b--\r

        """
    let p = MIME.parse(Data(raw.utf8))
    #expect(p.text?.contains("invited") == true)
    #expect(ICal.parse(p.calendar ?? "").events.first?.uid == "retro-1@work.example")
}

// MARK: CalDAV against a scripted server

final class FakeDAV: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest, String) -> (Int, [String: String], String))?
    nonisolated(unsafe) static var log: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let s = request.httpBodyStream {
            s.open()
            var buf = [UInt8](repeating: 0, count: 65536)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(buf, count: n) }
            s.close()
        }
        let text = String(decoding: body, as: UTF8.self)
        Self.log.append("\(request.httpMethod!) \(request.url!.path(percentEncoded: true)) \(request.value(forHTTPHeaderField: "If-Match") ?? request.value(forHTTPHeaderField: "If-None-Match") ?? "")")
        let (status, headers, reply) = Self.handler!(request, text)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func ms(_ responses: String) -> String { #"<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:a="http://apple.com/ns/ical/">"# + responses + "</d:multistatus>" }
func ok(_ props: String) -> String { "<d:propstat><d:prop>\(props)</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>" }

@Test(.serialized) func syncsAndWrites() async throws {
    let (store, a, dir) = try tempStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let account = try #require(try store.accounts().first)
    let event = { (uid: String, title: String) in "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:\(uid)\r\nDTSTART:20261125T170000Z\r\nDTEND:20261125T190000Z\r\nSUMMARY:\(title)\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n" }
    var server = ["/dav/cal/me/personal/a.ics": ("\"1\"", event("a", "Bouldering")), "/dav/cal/me/personal/b.ics": ("\"1\"", event("b", "Dentist"))]
    FakeDAV.log = []
    FakeDAV.handler = { r, body in
        let path = r.url!.path(percentEncoded: true)
        switch (r.httpMethod!, path) {
        case ("PROPFIND", "/dav/"):
            return (207, [:], ms("<d:response><d:href>/dav/</d:href>\(ok("<d:current-user-principal><d:href>/dav/principals/me/</d:href></d:current-user-principal>"))</d:response>"))
        case ("PROPFIND", "/dav/principals/me/"):
            return (207, [:], ms("<d:response><d:href>/dav/principals/me/</d:href>\(ok("<c:calendar-home-set><d:href>/dav/cal/me/</d:href></c:calendar-home-set>"))</d:response>"))
        case ("PROPFIND", "/dav/cal/me/"):
            let cal = ok("<d:resourcetype><d:collection/><c:calendar/></d:resourcetype><d:displayname>Personal</d:displayname><a:calendar-color>#62C792FF</a:calendar-color><c:supported-calendar-component-set><c:comp name=\"VEVENT\"/></c:supported-calendar-component-set>")
            let tasks = ok("<d:resourcetype><d:collection/><c:calendar/></d:resourcetype><d:displayname>Tasks</d:displayname><c:supported-calendar-component-set><c:comp name=\"VTODO\"/></c:supported-calendar-component-set>")
            return (207, [:], ms("<d:response><d:href>/dav/cal/me/</d:href>\(ok("<d:resourcetype><d:collection/></d:resourcetype>"))</d:response><d:response><d:href>/dav/cal/me/personal/</d:href>\(cal)</d:response><d:response><d:href>/dav/cal/me/tasks/</d:href>\(tasks)</d:response>"))
        case ("REPORT", "/dav/cal/me/personal") where body.contains("calendar-query"), ("REPORT", "/dav/cal/me/personal/") where body.contains("calendar-query"):
            return (207, [:], ms(server.map { "<d:response><d:href>\($0.key)</d:href>\(ok("<d:getetag>\($0.value.0)</d:getetag>"))</d:response>" }.joined()))
        case ("REPORT", _):
            let hrefs = body.matches(of: /<d:href>([^<]+)<\/d:href>/).map { String($0.output.1) }
            return (207, [:], ms(hrefs.compactMap { h in server[h].map { "<d:response><d:href>\(h)</d:href>\(ok("<d:getetag>\($0.0)</d:getetag><c:calendar-data>\($0.1)</c:calendar-data>"))</d:response>" } }.joined()))
        case ("PUT", _):
            if let m = r.value(forHTTPHeaderField: "If-Match"), server[path]?.0 != m { return (412, [:], "") }
            if r.value(forHTTPHeaderField: "If-None-Match") == "*", server[path] != nil { return (412, [:], "") }
            server[path] = ("\"\(Int(server[path]?.0.filter(\.isNumber) ?? "0")! + 1)\"", body)
            return (201, ["ETag": server[path]!.0], "")
        case ("DELETE", _):
            server[path] = nil
            return (204, [:], "")
        default:
            return (404, [:], "")
        }
    }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FakeDAV.self]
    var acct = account
    acct.imapHost = "imap.fastmail.com"
    let sync = CalendarSync(account: acct, login: { .plain(user: "me@fastmail.com", password: "x") }, store: store, session: URLSession(configuration: config)) { _ in }

    await sync.syncOnce()
    let cals = try store.calendars()
    #expect(cals.map(\.name) == ["Personal"] && cals.first?.colour == "#62C792" && cals.first?.accountId == a)
    let day = (on(2026, 11, 25), on(2026, 11, 26))
    #expect(try store.instances(from: day.0, to: day.1).map(\.title).sorted() == ["Bouldering", "Dentist"])

    // Only what changed is fetched again.
    server["/dav/cal/me/personal/b.ics"] = ("\"2\"", event("b", "Dentist, moved"))
    server["/dav/cal/me/personal/a.ics"] = nil
    FakeDAV.log = []
    await sync.syncOnce()
    #expect(try store.instances(from: day.0, to: day.1).map(\.title) == ["Dentist, moved"])
    #expect(FakeDAV.log.filter { $0.hasPrefix("REPORT") }.count == 2)  // the ETag list and one multiget

    // A new event is PUT with If-None-Match, an edit with If-Match; a stale ETag is a conflict and the server copy wins.
    var e = ICal.Event()
    e.uid = "new-1"; e.summary = "Climbing with Marta"; e.start = on(2026, 11, 28, 15); e.end = on(2026, 11, 28, 17)
    try await sync.save(ICal.write(e), calendar: cals[0], uid: e.uid)
    #expect(FakeDAV.log.contains("PUT /dav/cal/me/personal/new-1.ics *"))
    let id = try #require(try store.resource(uid: "new-1"))
    e.summary = "Climbing with Marta and Ada"
    try await sync.save(ICal.write(e), calendar: cals[0], resource: id, uid: e.uid)
    #expect(try store.instances(from: on(2026, 11, 28), to: on(2026, 11, 29)).map(\.title) == ["Climbing with Marta and Ada"])
    server["/dav/cal/me/personal/new-1.ics"]!.0 = "\"9\""  // someone else edited it
    await #expect(throws: CalDAV.Failure.conflict) { try await sync.save(ICal.write(e), calendar: cals[0], resource: id, uid: e.uid) }
    #expect(try store.resource(id)?.etag == "\"9\"")

    try await sync.delete(resource: id)
    #expect(server["/dav/cal/me/personal/new-1.ics"] == nil)
    #expect(try store.instances(from: on(2026, 11, 28), to: on(2026, 11, 29)).isEmpty)

    // Invitation UIDs carry an @; the file name keeps it, encoded once (a local Radicale stored "%40" literally).
    e.uid = "review@local.test"
    try await sync.save(ICal.write(e), calendar: cals[0], uid: e.uid)
    #expect(FakeDAV.log.contains("PUT /dav/cal/me/personal/review@local.test.ics *"))
    e.uid = "a/b"
    try await sync.save(ICal.write(e), calendar: cals[0], uid: e.uid)
    #expect(!FakeDAV.log.contains { $0.contains("a/b") })
}

@Test func editsKeepWhatMidwayDoesNotModel() throws {
    let stored = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:x\r\nDTSTART;TZID=Europe/Berlin:20261127T140000\r\nDTEND;TZID=Europe/Berlin:20261127T150000\r\nSUMMARY:Dentist\r\nDESCRIPTION:Bring the card\r\nBEGIN:VALARM\r\nTRIGGER:-PT30M\r\nEND:VALARM\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    var e = try #require(ICal.parse(stored).events.first)
    e.summary = "Dentist, Strandgata"
    e.start = on(2026, 11, 27, 15, 0, berlin); e.end = on(2026, 11, 27, 16, 0, berlin)
    let out = ICal.patch(stored, with: e)
    #expect(out.contains("DESCRIPTION:Bring the card") && out.contains("TRIGGER:-PT30M"))
    let back = try #require(ICal.parse(out).events.first)
    #expect(back.summary == "Dentist, Strandgata" && back.start == e.start && back.end == e.end)
    #expect(ICal.parse(out).events.count == 1)
}
