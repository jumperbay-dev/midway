import Foundation

/// Snooze times, computed on the Mac. "When I'm free" (calendars) and "day before departure" (bookings)
/// join with the Calendars and Quick access milestones.
public enum Snooze {
    public struct Choice: Hashable, Sendable {
        public let title: String
        public let date: Date
    }

    public static func choices(now: Date = .now, calendar cal: Calendar = .current) -> [Choice] {
        func at(_ hour: Int, _ day: Date) -> Date { cal.date(bySettingHour: hour, minute: 0, second: 0, of: day)! }
        var out: [Choice] = []
        if at(18, now) > now.addingTimeInterval(30 * 60) { out.append(Choice(title: "Later today", date: at(18, now))) }
        out.append(Choice(title: "Tomorrow morning", date: at(8, cal.date(byAdding: .day, value: 1, to: now)!)))
        let saturday = cal.nextDate(after: now, matching: DateComponents(weekday: 7), matchingPolicy: .nextTime)!
        out.append(Choice(title: "This weekend", date: at(9, saturday)))
        let monday = cal.nextDate(after: now, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime)!
        out.append(Choice(title: "Next week", date: at(8, monday)))
        return out
    }

    /// "fri 9", "tomorrow 14:30", "mon", "18" (today, or tomorrow if past), "in 3 days"; nil if it isn't a time.
    public static func parse(_ text: String, now: Date = .now, calendar cal: Calendar = .current) -> Date? {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }
        var day: Date?
        var hour: Int?, minute = 0
        var i = 0
        while i < words.count {
            let w = words[i]
            if w == "today" { day = now }
            else if w == "tomorrow" || w == "tmr" { day = cal.date(byAdding: .day, value: 1, to: now) }
            else if w == "in", i + 2 < words.count, let n = Int(words[i + 1]) {
                let unit: Calendar.Component? = words[i + 2].hasPrefix("day") ? .day : words[i + 2].hasPrefix("week") ? .weekOfYear : words[i + 2].hasPrefix("hour") ? .hour : nil
                guard let unit, let d = cal.date(byAdding: unit, value: n, to: now) else { return nil }
                if unit == .hour { return d }
                day = d; i += 2
            } else if let wd = weekday(w) {
                day = cal.nextDate(after: now, matching: DateComponents(weekday: wd), matchingPolicy: .nextTime)
            } else if let (h, m) = clock(w) {
                hour = h; minute = m
            } else {
                return nil
            }
            i += 1
        }
        guard day != nil || hour != nil else { return nil }
        let base = day ?? now
        guard var d = cal.date(bySettingHour: hour ?? 8, minute: minute, second: 0, of: base) else { return nil }
        if day == nil, d <= now { d = cal.date(byAdding: .day, value: 1, to: d)! }
        return d > now ? d : nil
    }

    static func weekday(_ w: String) -> Int? {
        let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        guard w.count >= 3, let i = names.firstIndex(where: { w.hasPrefix($0) }) else { return nil }
        return i + 1
    }

    /// "9", "9am", "9pm", "14:30", "9.30"
    static func clock(_ w: String) -> (Int, Int)? {
        var s = Substring(w), pm = false, am = false
        if s.hasSuffix("pm") { pm = true; s = s.dropLast(2) } else if s.hasSuffix("am") { am = true; s = s.dropLast(2) }
        let parts = s.split(whereSeparator: { $0 == ":" || $0 == "." })
        guard (1...2).contains(parts.count), var h = Int(parts[0]), h <= 23 else { return nil }
        let m = parts.count == 2 ? Int(parts[1]) ?? -1 : 0
        guard (0...59).contains(m) else { return nil }
        if pm && h < 12 { h += 12 }
        if am && h == 12 { h = 0 }
        return (h, m)
    }
}
