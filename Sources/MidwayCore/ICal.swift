import Foundation

// ponytail: a hand-rolled iCalendar subset (VEVENT, TZID via Foundation time zones, RRULE without BYSETPOS/ordinal BYDAY);
// swap in libical if real-world calendars trip over it
/// iCalendar (RFC 5545) as far as midway needs it: read events, expand repeats, write events and replies.
public enum ICal {
    public struct Attendee: Sendable, Hashable, Codable {
        public var email: String
        public var name: String
        /// NEEDS-ACTION, ACCEPTED, TENTATIVE, DECLINED
        public var partstat: String
        public init(email: String, name: String = "", partstat: String = "NEEDS-ACTION") {
            self.email = email; self.name = name; self.partstat = partstat
        }
    }

    public struct Event: Sendable, Hashable {
        public var uid = ""
        public var summary = ""
        public var location = ""
        public var start = Date.distantPast
        public var end = Date.distantPast
        public var allDay = false
        public var rrule: String?
        public var exdates: [Date] = []
        /// Set on an override of one occurrence of a repeating event.
        public var recurrenceId: Date?
        public var organizer: String?
        public var attendees: [Attendee] = []
        public var sequence = 0
        public var status: String?
        public init() {}
    }

    public struct Parsed: Sendable {
        /// REQUEST, REPLY, CANCEL for mail invitations; nil in a calendar resource.
        public var method: String?
        public var events: [Event] = []
    }

    struct Prop {
        var name: String
        var params: [String: String]
        var value: String
    }

    /// Lines with folding undone (a line starting with a space or tab continues the one before).
    static func lines(_ text: String) -> [String] {
        var out: [String] = []
        for raw in text.replacing("\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: true) {
            if (raw.first == " " || raw.first == "\t"), !out.isEmpty { out[out.count - 1] += raw.dropFirst() } else { out.append(String(raw)) }
        }
        return out
    }

    static func prop(_ line: String) -> Prop? {
        // The value starts at the first colon outside quotes.
        var quoted = false, colon: String.Index?
        for i in line.indices {
            if line[i] == "\"" { quoted.toggle() } else if line[i] == ":" && !quoted { colon = i; break }
        }
        guard let colon else { return nil }
        let head = line[..<colon].split(separator: ";").map(String.init)
        var params: [String: String] = [:]
        for p in head.dropFirst() {
            let kv = p.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { params[kv[0].uppercased()] = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return Prop(name: head.first?.uppercased() ?? "", params: params, value: String(line[line.index(after: colon)...]))
    }

    public static func parse(_ text: String) -> Parsed {
        var out = Parsed()
        var cur: Event?
        var depth = 0  // inside VALARM and friends
        for line in lines(text) {
            guard let p = prop(line) else { continue }
            if p.name == "BEGIN" {
                if p.value == "VEVENT" { cur = Event() } else if cur != nil { depth += 1 }
                continue
            }
            if p.name == "END" {
                if p.value == "VEVENT", let e = cur { out.events.append(e); cur = nil } else if cur != nil { depth -= 1 }
                continue
            }
            if cur == nil { if p.name == "METHOD" { out.method = p.value.uppercased() }; continue }
            guard depth == 0 else { continue }
            switch p.name {
            case "UID": cur!.uid = p.value
            case "SUMMARY": cur!.summary = unescape(p.value)
            case "LOCATION": cur!.location = unescape(p.value)
            case "DTSTART":
                if let (d, allDay) = date(p.value, p.params) { cur!.start = d; cur!.allDay = allDay }
            case "DTEND":
                if let (d, _) = date(p.value, p.params) { cur!.end = d }
            case "DURATION":
                if let s = duration(p.value) { cur!.end = cur!.start.addingTimeInterval(s) }
            case "RRULE": cur!.rrule = p.value
            case "EXDATE":
                cur!.exdates += p.value.split(separator: ",").compactMap { date(String($0), p.params)?.0 }
            case "RECURRENCE-ID": cur!.recurrenceId = date(p.value, p.params)?.0
            case "ORGANIZER": cur!.organizer = mailto(p.value)
            case "ATTENDEE":
                cur!.attendees.append(Attendee(email: mailto(p.value), name: p.params["CN"] ?? "", partstat: p.params["PARTSTAT"]?.uppercased() ?? "NEEDS-ACTION"))
            case "SEQUENCE": cur!.sequence = Int(p.value) ?? 0
            case "STATUS": cur!.status = p.value.uppercased()
            default: break
            }
        }
        // An event without an end lasts an hour, or a day when it is all-day.
        out.events = out.events.map { e in
            var e = e
            if e.end <= e.start { e.end = e.start.addingTimeInterval(e.allDay ? 86400 : 3600) }
            return e
        }
        return out
    }

    static func mailto(_ v: String) -> String {
        (v.lowercased().hasPrefix("mailto:") ? String(v.dropFirst(7)) : v).lowercased()
    }

    /// 20261128T193000Z, 20261128T193000 with TZID (or floating, read as local), 20261128 (all-day, local midnight).
    static func date(_ v: String, _ params: [String: String]) -> (Date, Bool)? {
        let s = v.trimmingCharacters(in: .whitespaces)
        var c = DateComponents()
        let digits = s.filter(\.isNumber)
        guard digits.count >= 8, let y = Int(digits.prefix(4)), let mo = Int(digits.dropFirst(4).prefix(2)), let d = Int(digits.dropFirst(6).prefix(2)) else { return nil }
        c.year = y; c.month = mo; c.day = d
        var cal = Calendar(identifier: .gregorian)
        if params["VALUE"] == "DATE" || !s.contains("T") {
            cal.timeZone = .current
            return cal.date(from: c).map { ($0, true) }
        }
        guard digits.count >= 14 else { return nil }
        c.hour = Int(digits.dropFirst(8).prefix(2)); c.minute = Int(digits.dropFirst(10).prefix(2)); c.second = Int(digits.dropFirst(12).prefix(2))
        cal.timeZone = s.hasSuffix("Z") ? TimeZone(identifier: "UTC")! : params["TZID"].flatMap(zone) ?? .current
        return cal.date(from: c).map { ($0, false) }
    }

    /// Olson names, plus the Windows names Outlook sends for the common European and US zones.
    static func zone(_ id: String) -> TimeZone? {
        if let z = TimeZone(identifier: id) { return z }
        let windows = ["W. Europe Standard Time": "Europe/Berlin", "Central Europe Standard Time": "Europe/Budapest",
                       "Romance Standard Time": "Europe/Paris", "GMT Standard Time": "Europe/London",
                       "Eastern Standard Time": "America/New_York", "Pacific Standard Time": "America/Los_Angeles",
                       "Central Standard Time": "America/Chicago", "UTC": "UTC"]
        return windows[id].flatMap { TimeZone(identifier: $0) }
    }

    /// PT1H30M, P1D, -PT15M
    static func duration(_ v: String) -> TimeInterval? {
        var total = 0.0, num = "", sign = 1.0
        for ch in v {
            if ch == "-" { sign = -1 } else if ch.isNumber { num.append(ch) } else if let n = Double(num) {
                switch ch { case "W": total += n * 604800; case "D": total += n * 86400; case "H": total += n * 3600; case "M": total += n * 60; case "S": total += n; default: break }
                num = ""
            }
        }
        return v.contains("P") ? sign * total : nil
    }

    static func unescape(_ s: String) -> String {
        s.replacing("\\n", with: "\n").replacing("\\N", with: "\n").replacing("\\,", with: ",").replacing("\\;", with: ";").replacing("\\\\", with: "\\")
    }

    static func escape(_ s: String) -> String {
        s.replacing("\\", with: "\\\\").replacing(";", with: "\\;").replacing(",", with: "\\,").replacing("\n", with: "\\n")
    }

    // MARK: repeats

    public struct Occurrence: Sendable, Hashable {
        public var event: Event
        public var start: Date
        public var end: Date
    }

    /// Every occurrence overlapping [from, to): the series by its RRULE, minus EXDATEs, with overrides
    /// (RECURRENCE-ID) put in place of the occurrences they replace.
    public static func expand(_ events: [Event], from: Date, to: Date) -> [Occurrence] {
        var out: [Occurrence] = []
        for (_, group) in Dictionary(grouping: events, by: \.uid) {
            let overrides = group.filter { $0.recurrenceId != nil }
            let replaced = Set(overrides.compactMap(\.recurrenceId))
            for master in group where master.recurrenceId == nil {
                let length = master.end.timeIntervalSince(master.start)
                let starts = master.rrule.map { occurrences(master.start, rule: $0, until: to) } ?? [master.start]
                let skip = Set(master.exdates).union(replaced)
                for s in starts where !skip.contains(s) && s < to && s.addingTimeInterval(length) > from {
                    out.append(Occurrence(event: master, start: s, end: s.addingTimeInterval(length)))
                }
            }
            for o in overrides where o.status != "CANCELLED" && o.start < to && o.end > from {
                out.append(Occurrence(event: o, start: o.start, end: o.end))
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// FREQ DAILY/WEEKLY/MONTHLY/YEARLY with INTERVAL, COUNT, UNTIL and (weekly) BYDAY.
    static func occurrences(_ start: Date, rule: String, until end: Date) -> [Date] {
        var r: [String: String] = [:]
        for part in rule.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { r[kv[0].uppercased()] = String(kv[1]) }
        }
        let unit: Calendar.Component
        switch r["FREQ"] {
        case "DAILY": unit = .day
        case "WEEKLY": unit = .weekOfYear
        case "MONTHLY": unit = .month
        case "YEARLY": unit = .year
        default: return [start]
        }
        let interval = max(Int(r["INTERVAL"] ?? "") ?? 1, 1)
        let count = Int(r["COUNT"] ?? "")
        let until = r["UNTIL"].flatMap { date($0, [:])?.0 }.map { $0.addingTimeInterval(1) } ?? end
        let limit = min(until, end)
        let cal = Calendar.current
        let names = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]
        let byDay = unit == .weekOfYear ? (r["BYDAY"] ?? "").split(separator: ",").compactMap { names[String($0.suffix(2))] } : []
        var out: [Date] = []
        var step = 0
        while out.count < (count ?? 5000), step < 5000 {
            guard let base = cal.date(byAdding: unit, value: step * interval, to: start) else { break }
            if base > limit && byDay.isEmpty { break }
            if byDay.isEmpty {
                out.append(base)
            } else {
                // Each listed weekday of this week, at the start's time of day.
                let weekStart = cal.date(byAdding: .day, value: -((cal.component(.weekday, from: base) - cal.firstWeekday + 7) % 7), to: base)!
                if weekStart > limit { break }
                for day in 0..<7 {
                    let d = cal.date(byAdding: .day, value: day, to: weekStart)!
                    if byDay.contains(cal.component(.weekday, from: d)), d >= start, d <= limit, out.count < (count ?? 5000) { out.append(d) }
                }
            }
            step += 1
        }
        return out.filter { $0 <= limit }
    }

    // MARK: writing

    public static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: d)
    }

    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f.string(from: d)
    }

    /// Lines longer than 75 octets are folded.
    static func fold(_ line: String) -> String {
        var out = "", cur = ""
        for ch in line {
            if cur.utf8.count + ch.utf8.count > 73 { out += cur + "\r\n "; cur = "" }
            cur.append(ch)
        }
        return out + cur
    }

    /// One VEVENT in its own VCALENDAR, times in UTC (all-day as dates).
    public static func write(_ e: Event, method: String? = nil, now: Date = .now) -> String {
        var l = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//midway//EN"]
        if let method { l.append("METHOD:\(method)") }
        l += ["BEGIN:VEVENT", "UID:\(e.uid)", "DTSTAMP:\(stamp(now))", "SEQUENCE:\(e.sequence)"]
        if e.allDay {
            l += ["DTSTART;VALUE=DATE:\(day(e.start))", "DTEND;VALUE=DATE:\(day(e.end))"]
        } else {
            l += ["DTSTART:\(stamp(e.start))", "DTEND:\(stamp(e.end))"]
        }
        if let r = e.recurrenceId { l.append("RECURRENCE-ID:\(stamp(r))") }
        l.append("SUMMARY:\(escape(e.summary))")
        if !e.location.isEmpty { l.append("LOCATION:\(escape(e.location))") }
        if let r = e.rrule { l.append("RRULE:\(r)") }
        if !e.exdates.isEmpty { l.append("EXDATE:" + e.exdates.map(stamp).joined(separator: ",")) }
        if let s = e.status { l.append("STATUS:\(s)") }
        if let o = e.organizer { l.append("ORGANIZER:mailto:\(o)") }
        for a in e.attendees {
            let cn = a.name.isEmpty ? "" : ";CN=\"\(a.name.replacing("\"", with: ""))\""
            let rsvp = a.partstat == "NEEDS-ACTION" ? ";RSVP=TRUE" : ""
            l.append("ATTENDEE\(cn);ROLE=REQ-PARTICIPANT;PARTSTAT=\(a.partstat)\(rsvp):mailto:\(a.email)")
        }
        l += ["END:VEVENT", "END:VCALENDAR", ""]
        return l.map(fold).joined(separator: "\r\n")
    }

    /// METHOD:REPLY for one invitation: the event as sent, with only my attendee line and my answer.
    public static func reply(_ e: Event, me: String, partstat: String, now: Date = .now) -> String {
        var r = e
        let mine = e.attendees.first { $0.email == me.lowercased() }
        r.attendees = [Attendee(email: me.lowercased(), name: mine?.name ?? "", partstat: partstat)]
        r.rrule = nil
        r.exdates = []
        return write(r, method: "REPLY", now: now)
    }

    /// An edit of a stored resource: the main VEVENT's title, place, guests (and times, unless it repeats) are
    /// replaced; everything midway doesn't model (description, alarms, time zones, overrides) stays as it was.
    public static func patch(_ ics: String, with e: Event, now: Date = .now) -> String {
        let replaced: Set<String> = e.rrule == nil
            ? ["SUMMARY", "LOCATION", "DTSTART", "DTEND", "DURATION", "SEQUENCE", "DTSTAMP", "ORGANIZER", "ATTENDEE"]
            : ["SUMMARY", "LOCATION", "SEQUENCE", "DTSTAMP", "ORGANIZER", "ATTENDEE"]
        let fresh = lines(write(e, now: now)).filter { l in prop(l).map { replaced.contains($0.name) } ?? false }
        var out: [String] = [], block: [String]? = nil
        for line in lines(ics) {
            let p = prop(line)
            if p?.name == "BEGIN", p?.value == "VEVENT" { block = [line]; continue }
            guard var b = block else { out.append(line); continue }
            if p?.name == "END", p?.value == "VEVENT" {
                let isMaster = !b.contains { prop($0)?.name == "RECURRENCE-ID" }
                if isMaster { b = b.filter { l in !(prop(l).map { replaced.contains($0.name) } ?? false) } + fresh }
                out += b + [line]
                block = nil
                continue
            }
            b.append(line)
            block = b
        }
        return out.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    /// The stored resource with my PARTSTAT changed on every VEVENT, METHOD dropped; the rest stays as the server wrote it.
    public static func setPartstat(_ ics: String, me: String, partstat: String) -> String {
        lines(ics).compactMap { line -> String? in
            guard let p = prop(line) else { return line }
            if p.name == "METHOD" { return nil }
            guard p.name == "ATTENDEE", mailto(p.value) == me.lowercased() else { return line }
            var params = p.params
            params["PARTSTAT"] = partstat
            params["RSVP"] = nil
            let ps = params.sorted { $0.key < $1.key }.map { ";\($0.key)=\($0.value.contains(" ") || $0.value.contains(":") ? "\"\($0.value)\"" : $0.value)" }.joined()
            return "ATTENDEE\(ps):\(p.value)"
        }
        .map(fold).joined(separator: "\r\n") + "\r\n"
    }
}
