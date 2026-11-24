import Foundation
import GRDB

public struct CalendarRow: Codable, Hashable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "calendar"
    public var id: Int64?
    public var accountId: Int64
    public var url: String
    public var name: String
    /// "#RRGGBB" from the server, if it has one.
    public var colour: String?
    public var ctag: String?
    public var visible = true
    public var writable = true
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// One occurrence in a visible range, with its calendar's name and colour.
public struct Instance: Codable, Hashable, Sendable, FetchableRecord {
    public var resourceId: Int64
    public var calendarId: Int64
    public var uid: String
    public var title: String
    public var location: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var recurring: Bool
    public var guests: Int
    public var calendar: String
    public var colour: String?
}

extension Store {
    /// Repeats are stored expanded over this window, so week and month views are one indexed query.
    static func window(_ now: Date) -> (Date, Date) { (now.addingTimeInterval(-366 * 86400), now.addingTimeInterval(2 * 366 * 86400)) }

    static func migrateCalendars(_ db: Database) throws {
        try db.create(table: "calendar") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("accountId", .integer).notNull().references("account", onDelete: .cascade)
            t.column("url", .text).notNull().unique()
            t.column("name", .text).notNull()
            t.column("colour", .text)
            t.column("ctag", .text)
            t.column("visible", .boolean).notNull().defaults(to: true)
            t.column("writable", .boolean).notNull().defaults(to: true)
        }
        try db.create(table: "event_resource") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("calendarId", .integer).notNull().references("calendar", onDelete: .cascade)
            t.column("href", .text).notNull()
            t.column("etag", .text).notNull()
            t.column("ics", .text).notNull()
            t.column("uid", .text).notNull().indexed()
            t.uniqueKey(["calendarId", "href"])
        }
        try db.create(table: "event_instance") { t in
            t.column("resourceId", .integer).notNull().references("event_resource", onDelete: .cascade).indexed()
            t.column("calendarId", .integer).notNull()
            t.column("uid", .text).notNull()
            t.column("title", .text).notNull()
            t.column("location", .text).notNull()
            t.column("start", .datetime).notNull().indexed()
            t.column("end", .datetime).notNull()
            t.column("allDay", .boolean).notNull()
            t.column("recurring", .boolean).notNull()
            t.column("guests", .integer).notNull()
        }
    }

    /// The account's calendars as the server lists them now; gone ones are dropped with their events.
    @discardableResult
    public func saveCalendars(account: Int64, _ remote: [CalDAV.Remote]) throws -> [CalendarRow] {
        try db.write { db in
            let urls = remote.map(\.url.absoluteString)
            try db.execute(sql: "DELETE FROM calendar WHERE accountId = ? AND url NOT IN (\(urls.isEmpty ? "''" : databaseQuestionMarks(count: urls.count)))",
                           arguments: StatementArguments([account] + urls))
            for r in remote {
                if var c = try CalendarRow.filter(Column("url") == r.url.absoluteString).fetchOne(db) {
                    c.name = r.name; c.colour = r.colour; c.writable = r.writable
                    try c.update(db)
                } else {
                    var c = CalendarRow(accountId: account, url: r.url.absoluteString, name: r.name, colour: r.colour, writable: r.writable)
                    try c.insert(db)
                }
            }
            return try CalendarRow.filter(Column("accountId") == account).order(Column("name")).fetchAll(db)
        }
    }

    public func calendars() throws -> [CalendarRow] {
        try db.read { try CalendarRow.order(Column("accountId"), Column("name")).fetchAll($0) }
    }

    public func setVisible(_ calendar: Int64, _ on: Bool) throws {
        try db.write { try $0.execute(sql: "UPDATE calendar SET visible = ? WHERE id = ?", arguments: [on, calendar]) }
    }

    public func setCtag(_ calendar: Int64, _ ctag: String?) throws {
        try db.write { try $0.execute(sql: "UPDATE calendar SET ctag = ? WHERE id = ?", arguments: [ctag, calendar]) }
    }

    /// href → ETag of what is stored.
    public func etags(calendar: Int64) throws -> [String: String] {
        try db.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT href, etag FROM event_resource WHERE calendarId = ?", arguments: [calendar])
                .map { ($0["href"] as String, $0["etag"] as String) })
        }
    }

    /// Stores fetched events (replacing by href) and drops removed ones; repeats are expanded again.
    public func storeEvents(calendar: Int64, _ resources: [CalDAV.Resource], removed: [String] = [], now: Date = .now) throws {
        let (from, to) = Self.window(now)
        try db.write { db in
            for href in removed {
                try db.execute(sql: "DELETE FROM event_resource WHERE calendarId = ? AND href = ?", arguments: [calendar, href])
            }
            for r in resources {
                let parsed = ICal.parse(r.ics)
                try db.execute(sql: """
                    INSERT INTO event_resource (calendarId, href, etag, ics, uid) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT (calendarId, href) DO UPDATE SET etag = excluded.etag, ics = excluded.ics, uid = excluded.uid
                    """, arguments: [calendar, r.href, r.etag, r.ics, parsed.events.first?.uid ?? r.href])
                let id = try Int64.fetchOne(db, sql: "SELECT id FROM event_resource WHERE calendarId = ? AND href = ?", arguments: [calendar, r.href])!
                try db.execute(sql: "DELETE FROM event_instance WHERE resourceId = ?", arguments: [id])
                for o in ICal.expand(parsed.events, from: from, to: to) {
                    try db.execute(sql: """
                        INSERT INTO event_instance (resourceId, calendarId, uid, title, location, start, end, allDay, recurring, guests)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [id, calendar, o.event.uid, o.event.summary, o.event.location, o.start, o.end, o.event.allDay,
                                         o.event.rrule != nil || o.event.recurrenceId != nil, o.event.attendees.count])
                }
            }
        }
    }

    /// Occurrences overlapping [from, to) in visible calendars.
    public func instances(from: Date, to: Date) throws -> [Instance] {
        try db.read { try Self.instances($0, from: from, to: to) }
    }

    public static func instances(_ db: Database, from: Date, to: Date) throws -> [Instance] {
        try Instance.fetchAll(db, sql: """
            SELECT i.*, c.name AS calendar, c.colour FROM event_instance i JOIN calendar c ON c.id = i.calendarId
            WHERE c.visible AND i.start < ? AND i.end > ? ORDER BY i.allDay DESC, i.start
            """, arguments: [to, from])
    }

    public func resource(_ id: Int64) throws -> (calendar: CalendarRow, href: String, etag: String, ics: String)? {
        try db.read { db in
            guard let r = try Row.fetchOne(db, sql: "SELECT * FROM event_resource WHERE id = ?", arguments: [id]),
                  let c = try CalendarRow.fetchOne(db, key: r["calendarId"] as Int64) else { return nil }
            return (c, r["href"], r["etag"], r["ics"])
        }
    }

    /// The stored event with this UID, if it is already on one of your calendars (an invite Gmail added, say).
    public func resource(uid: String) throws -> Int64? {
        try db.read { try Int64.fetchOne($0, sql: "SELECT id FROM event_resource WHERE uid = ?", arguments: [uid]) }
    }
}

/// Polls one account's calendars: every 5 minutes, and at once on wake (app focus, after an edit).
// ponytail: ctag + ETag diff on every server; sync-collection tokens (RFC 6578) when calendars get big
public actor CalendarSync {
    public enum State: Sendable, Equatable { case idle, syncing, synced(Date), failed(String) }

    let account: Account
    let store: Store
    let dav: CalDAV
    let onState: @Sendable (State) -> Void
    var wakeup: CheckedContinuation<Void, Never>?

    public init(account: Account, login: @escaping @Sendable () async throws -> Login, store: Store, session: URLSession? = nil, onState: @escaping @Sendable (State) -> Void) {
        self.account = account
        self.store = store
        self.dav = CalDAV(login: login, session: session)
        self.onState = onState
    }

    public func run() async {
        while !Task.isCancelled {
            await syncOnce()
            await withTaskGroup(of: Void.self) { g in
                g.addTask { try? await Task.sleep(for: .seconds(300)) }
                g.addTask { await self.waitForWake() }
                await g.next()
                g.cancelAll()
            }
            wakeup?.resume(); wakeup = nil
        }
    }

    func waitForWake() async { await withCheckedContinuation { wakeup = $0 } }

    public nonisolated func wake() { Task { await self.resumeWake() } }
    func resumeWake() { wakeup?.resume(); wakeup = nil }

    public func syncOnce() async {
        guard let id = account.id else { return }
        onState(.syncing)
        do {
            let calendars = try store.saveCalendars(account: id, try await dav.discover(CalDAV.start(for: account)))
            for c in calendars {
                guard let url = URL(string: c.url) else { continue }
                let remote = try await dav.etags(url)
                let local = try store.etags(calendar: c.id!)
                let changed = remote.filter { local[$0.key] != $0.value }.map(\.key)
                let removed = local.keys.filter { remote[$0] == nil }
                if !changed.isEmpty || !removed.isEmpty {
                    try store.storeEvents(calendar: c.id!, try await dav.multiget(url, changed), removed: removed)
                }
            }
            onState(.synced(.now))
        } catch {
            onState(.failed(String(describing: error)))
        }
    }

    // MARK: writes

    /// Writes an event to a calendar (new, or over the stored one with If-Match), then reads back what the server kept.
    /// On a 412 the server copy is fetched and stored, and `.conflict` is thrown so the editor can say so.
    // ponytail: no offline queue for calendar edits; a failed write is shown and nothing is kept
    public func save(_ ics: String, calendar: CalendarRow, resource: Int64? = nil, uid: String) async throws {
        let existing = try resource.flatMap { try store.resource($0) }
        let calURL = URL(string: calendar.url)!
        let href = existing?.href ?? calURL.appending(path: "\(uid.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-_."))) ?? UUID().uuidString).ics").path(percentEncoded: true)
        let url = URL(string: href, relativeTo: calURL)!.absoluteURL
        do {
            _ = try await dav.put(url, ics: ics, etag: existing?.etag)
        } catch CalDAV.Failure.conflict {
            try await refetch(calendar, href)
            throw CalDAV.Failure.conflict
        }
        try await refetch(calendar, href)
        // Moving to another calendar: the old copy goes once the new one is saved.
        if let existing, existing.calendar.id != calendar.id, let old = URL(string: existing.href, relativeTo: URL(string: existing.calendar.url)) {
            try await dav.delete(old.absoluteURL, etag: existing.etag)
            try store.storeEvents(calendar: existing.calendar.id!, [], removed: [existing.href])
        }
    }

    public func delete(resource id: Int64) async throws {
        guard let r = try store.resource(id), let url = URL(string: r.href, relativeTo: URL(string: r.calendar.url)) else { return }
        do {
            try await dav.delete(url.absoluteURL, etag: r.etag)
        } catch CalDAV.Failure.status(404, _) {}
        try store.storeEvents(calendar: r.calendar.id!, [], removed: [r.href])
    }

    func refetch(_ calendar: CalendarRow, _ href: String) async throws {
        let got = try await dav.multiget(URL(string: calendar.url)!, [href])
        try store.storeEvents(calendar: calendar.id!, got, removed: got.isEmpty ? [href] : [])
    }
}

// MARK: quick add

/// "Climbing with Marta sat 3–5pm /climbing", "Lunch with Ada thu 12", "Dentist tomorrow 14:00", "Mum's birthday dec 3":
/// parsed on the Mac, no AI.
public enum QuickAdd {
    public struct Result: Equatable, Sendable {
        public var title: String
        public var start: Date
        public var end: Date
        public var allDay: Bool
        /// The word after "/", to match a calendar name.
        public var calendar: String?
        /// The words that set the time, shown beside the parsed time.
        public var when: String
    }

    static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    public static func parse(_ text: String, now: Date = .now, calendar cal: Calendar = .current) -> Result? {
        var title: [String] = [], when: [String] = []
        var day: Date?, hours: (Int, Int, Int?, Int?)?, calendarHint: String?
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var i = 0
        while i < words.count {
            let w = words[i], l = w.lowercased()
            if l.hasPrefix("/"), l.count > 1 {
                calendarHint = String(l.dropFirst())
            } else if l == "today" || l == "tonight" {
                day = now; when.append(w)
            } else if l == "tomorrow" || l == "tmr" {
                day = cal.date(byAdding: .day, value: 1, to: now); when.append(w)
            } else if let wd = Snooze.weekday(l), l.count <= 9, ["sun", "mon", "tue", "wed", "thu", "fri", "sat"].contains(String(l.prefix(3))) {
                day = cal.nextDate(after: cal.startOfDay(for: now).addingTimeInterval(-1), matching: DateComponents(weekday: wd), matchingPolicy: .nextTime); when.append(w)
            } else if let m = months.firstIndex(of: String(l.prefix(3))), l.count <= 9, i + 1 < words.count, let d = Int(words[i + 1]) {
                day = date(m + 1, d, now, cal); when += [w, words[i + 1]]; i += 1
            } else if let d = Int(l), (1...31).contains(d), i + 1 < words.count, let m = months.firstIndex(of: String(words[i + 1].lowercased().prefix(3))) {
                day = date(m + 1, d, now, cal); when += [w, words[i + 1]]; i += 1
            } else if hours == nil, let r = range(l), day != nil || i == words.count - 1 || words.dropFirst(i + 1).allSatisfy({ $0.hasPrefix("/") }) || l.contains(":") || l.hasSuffix("m") || l.contains("-") || l.contains("–") {
                hours = r; when.append(w)
            } else {
                title.append(w)
            }
            i += 1
        }
        guard day != nil || hours != nil, !title.isEmpty else { return nil }
        var base = cal.startOfDay(for: day ?? now)
        guard let (h1, m1, h2, m2) = hours else {
            return Result(title: title.joined(separator: " "), start: base, end: cal.date(byAdding: .day, value: 1, to: base)!, allDay: true, calendar: calendarHint, when: when.joined(separator: " "))
        }
        var start = cal.date(bySettingHour: h1, minute: m1, second: 0, of: base)!
        if day == nil, start < now { base = cal.date(byAdding: .day, value: 1, to: base)!; start = cal.date(bySettingHour: h1, minute: m1, second: 0, of: base)! }
        var end = h2.map { cal.date(bySettingHour: $0, minute: m2 ?? 0, second: 0, of: base)! } ?? start.addingTimeInterval(3600)
        if end <= start { end = cal.date(byAdding: .day, value: 1, to: end)! }
        return Result(title: title.joined(separator: " "), start: start, end: end, allDay: false, calendar: calendarHint, when: when.joined(separator: " "))
    }

    static func date(_ month: Int, _ day: Int, _ now: Date, _ cal: Calendar) -> Date? {
        var c = cal.dateComponents([.year], from: now)
        c.month = month; c.day = day
        guard let d = cal.date(from: c) else { return nil }
        return d < cal.startOfDay(for: now) ? cal.date(byAdding: .year, value: 1, to: d) : d
    }

    /// "12", "3pm", "14:30", "3-5pm", "3–5pm", "10:00-11:30": start and optional end. A bare "3-5" with "pm" on the end
    /// puts both in the afternoon; "11-1pm" runs over noon.
    static func range(_ w: String) -> (Int, Int, Int?, Int?)? {
        let parts = w.split(whereSeparator: { $0 == "-" || $0 == "–" }).map(String.init)
        guard (1...2).contains(parts.count) else { return nil }
        let suffix = parts.last!.hasSuffix("pm") ? "pm" : parts.last!.hasSuffix("am") ? "am" : ""
        guard let (eh, em) = Snooze.clock(parts.last!) else { return nil }
        if parts.count == 1 { return (eh, em, nil, nil) }
        let first = parts[0].hasSuffix("m") ? parts[0] : parts[0] + suffix
        guard var (sh, sm) = Snooze.clock(first) else { return nil }
        if sh > eh, suffix == "pm", !parts[0].hasSuffix("m") { sh -= 12 }  // 11-1pm
        return (sh, sm, eh, em)
    }
}
