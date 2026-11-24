import AppKit
import GRDB
import MidwayCore
import SwiftUI

/// What the event editor works on: a new event, or one from a calendar.
struct EventDraft: Identifiable {
    var id = UUID()
    var resource: Int64?
    var calendarId: Int64?
    var uid = UUID().uuidString.lowercased() + "@midway"
    var title = ""
    var location = ""
    var start: Date
    var end: Date
    var allDay = false
    /// Comma-separated guest addresses; invitations go out only through "Save and invite".
    var guests = ""
    var attendees: [ICal.Attendee] = []
    var organizer: String?
    var rrule: String?
    var sequence = 0
    /// The stored iCalendar, patched on save so what midway doesn't edit survives.
    var stored: String?
    /// "Filled by Claude from …"
    var note: String?
}

enum CalView: String, CaseIterable { case day = "Day", week = "Week", month = "Month", agenda = "Agenda" }

extension AppModel {
    func startCalendars(_ account: Account, _ credentials: Credentials) {
        guard let id = account.id, let store else { return }
        let s = CalendarSync(account: account, login: { try await credentials.login() }, store: store) { [weak self] state in
            Task { @MainActor in self?.calState[id] = state }
        }
        calSyncers[id] = s
        calTasks.append(Task { await s.run() })
    }

    func wakeCalendars() { calSyncers.values.forEach { $0.wake() } }

    /// Opens the editor for a stored event (the series, for a repeat).
    func edit(_ i: Instance) {
        guard let store, let r = try? store.resource(i.resourceId),
              let master = ICal.parse(r.ics).events.first(where: { $0.recurrenceId == nil }) ?? ICal.parse(r.ics).events.first else { return }
        editing = EventDraft(resource: i.resourceId, calendarId: r.calendar.id, uid: master.uid, title: master.summary, location: master.location,
                             start: master.rrule == nil ? master.start : i.start, end: master.rrule == nil ? master.end : i.end, allDay: master.allDay,
                             guests: master.attendees.map(\.email).filter { !isMine($0) }.joined(separator: ", "),
                             attendees: master.attendees, organizer: master.organizer, rrule: master.rrule, sequence: master.sequence, stored: r.ics)
    }

    func isMine(_ address: String) -> Bool { accounts.contains { $0.email.lowercased() == address.lowercased() } }

    /// Saves the editor's event. `invite` writes the guest list with you as organiser; servers with CalDAV scheduling
    /// (Fastmail, Google) send the invitations.
    func save(_ d: EventDraft, invite: Bool) async throws {
        guard let store, let cal = try store.calendars().first(where: { $0.id == d.calendarId }),
              let me = accounts.first(where: { $0.id == cal.accountId })?.email
        else { throw AddError("Choose a calendar you can write to.") }
        guard let sync = calSyncers[cal.accountId] else { throw AddError("Sign in to \(me) again to write to its calendars.") }
        var e = ICal.Event()
        e.uid = d.uid; e.summary = d.title; e.location = d.location
        e.start = d.start; e.end = d.end; e.allDay = d.allDay
        e.rrule = d.rrule
        e.sequence = d.stored == nil ? 0 : d.sequence + 1
        e.organizer = d.organizer
        e.attendees = d.attendees
        if invite {
            let guests = MIME.addresses(d.guests).filter { !$0.address.isEmpty && !isMine($0.address) }
            e.organizer = d.organizer ?? me
            e.attendees = [ICal.Attendee(email: me, partstat: "ACCEPTED")] + guests.map { g in
                d.attendees.first { $0.email == g.address.lowercased() } ?? ICal.Attendee(email: g.address.lowercased(), name: g.name)
            }
        }
        let ics = d.stored.map { ICal.patch($0, with: e) } ?? ICal.write(e)
        try await sync.save(ics, calendar: cal, resource: d.resource, uid: d.uid)
    }

    func deleteEvent(_ d: EventDraft) async throws {
        guard let id = d.resource, let store, let r = try store.resource(id), let sync = calSyncers[r.calendar.accountId] else { return }
        try await sync.delete(resource: id)
    }

    /// Answers an invitation: my PARTSTAT on the calendar copy (the stored one if the server already added it,
    /// else a new one in `calendar`), and an iCalendar REPLY to the organiser over SMTP when the server didn't do it.
    func respond(_ e: ICal.Event, ics: String, message: Message, partstat: String, calendar: CalendarRow?) async throws {
        guard let store, let account = accounts.first(where: { $0.id == message.accountId }) else { return }
        let mine = Set([account.email.lowercased(), message.via?.lowercased()].compactMap { $0 })
        let me = e.attendees.first { mine.contains($0.email) }?.email ?? account.email
        var serverReplies = false
        if let rid = try store.resource(uid: e.uid), let r = try store.resource(rid), let sync = calSyncers[r.calendar.accountId] {
            // The server added it from the mail already (Gmail does); changing my answer there lets it send the reply.
            try await sync.save(ICal.setPartstat(r.ics, me: me, partstat: partstat), calendar: r.calendar, resource: rid, uid: e.uid)
            serverReplies = true
        } else if partstat != "DECLINED", let calendar {
            guard let sync = calSyncers[calendar.accountId] else { throw AddError("Sign in to this account again to add the event.") }
            try await sync.save(ICal.setPartstat(ics, me: me, partstat: partstat), calendar: calendar, uid: e.uid)
        }
        guard !serverReplies, let organizer = e.organizer else { return }
        let word = ["ACCEPTED": "Accepted", "TENTATIVE": "Tentative", "DECLINED": "Declined"][partstat] ?? partstat
        let built = Compose.build(from: MIME.Address(name: "", address: me), to: [MIME.Address(name: "", address: organizer)], cc: [],
                                  subject: "\(word): \(e.summary)", text: "\(me) has answered \(word.lowercased()).", html: "<p>\(me) has answered \(word.lowercased()).</p>",
                                  calendar: ("REPLY", ICal.reply(e, me: me, partstat: partstat)))
        // The outbox sends drafts; this one exists only until it has gone.
        let draft = try store.save(Draft(accountId: account.id!))
        try store.enqueue(draft: draft.id!, account: account.id!, raw: built.raw, recipients: [organizer], sendAt: .now)
        wakeOutbox()
    }

    /// From Claude's summary: the editor, filled in and marked, nothing saved yet.
    func addToCalendar(_ e: AI.Event) {
        guard let start = e.startDate else { notice = "Could not read the date “\(e.start)”"; return }
        let end = e.end.flatMap { ISO8601DateFormatter().date(from: $0) } ?? start.addingTimeInterval(3600)
        let cal = (try? store?.calendars())?.first { $0.writable && $0.visible }
        editing = EventDraft(calendarId: cal?.id, title: e.title, location: e.location ?? "", start: start, end: end, note: "from this mail · check before saving")
        calFocus = start
        mode = .calendar
    }
}

extension Color {
    /// "#62C792" from a calendar server, else a tag tone by id.
    static func calendar(_ hex: String?, _ id: Int64) -> Color {
        guard let hex, hex.hasPrefix("#"), hex.count >= 7, let v = UInt32(hex.dropFirst().prefix(6), radix: 16) else { return T.tag(Int(id)) }
        return Color(hex: v)
    }
}

/// Screens 13–16: the calendar sidebar, then day, week, month or agenda. ⌘1 back to mail.
struct CalendarView: View {
    let model: AppModel
    @Local private var view: CalView = .week
    @Local private var instances: [Instance] = []
    @Local private var calendars: [CalendarRow] = []
    @Local private var upNext: [Instance] = []
    @Local private var quick = ""
    @Local private var error: String?
    @FocusState private var quickFocused: Bool

    var cal: Calendar { .current }
    var focus: Date { model.calFocus }

    /// The visible range for the current view.
    var range: (Date, Date) {
        switch view {
        case .day: let d = cal.startOfDay(for: focus); return (d, cal.date(byAdding: .day, value: 1, to: d)!)
        case .week: let s = cal.dateInterval(of: .weekOfYear, for: focus)!.start; return (s, cal.date(byAdding: .day, value: 7, to: s)!)
        case .month:
            let m = cal.dateInterval(of: .month, for: focus)!.start
            let s = cal.dateInterval(of: .weekOfYear, for: m)!.start
            return (s, cal.date(byAdding: .day, value: 42, to: s)!)
        case .agenda: let d = cal.startOfDay(for: .now); return (d, cal.date(byAdding: .day, value: 60, to: d)!)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            CalSidebar(model: model, calendars: calendars, upNext: upNext)
            VStack(spacing: 0) {
                header
                Group {
                    switch view {
                    case .day: WeekGrid(days: days, instances: instances, open: model.edit)
                    case .week: WeekGrid(days: days, instances: instances, open: model.edit)
                    case .month: MonthGrid(start: range.0, month: cal.component(.month, from: focus), instances: instances, open: model.edit) { model.calFocus = $0; view = .day }
                    case .agenda: Agenda(instances: instances, open: model.edit)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .trailing) {
            if model.editing != nil { EventEditor(model: model, calendars: calendars.filter(\.writable)) }
        }
        .font(.body13)
        .task(id: [range.0, range.1] as [Date]) { await observe() }
        .onAppear { model.wakeCalendars() }
    }

    var days: [Date] {
        view == .day ? [cal.startOfDay(for: focus)] : (0..<7).map { cal.date(byAdding: .day, value: $0, to: range.0)! }
    }

    var header: some View {
        HStack(spacing: 16) {
            Text(view == .agenda ? "Agenda" : focus.formatted(.dateTime.month(.wide).year())).font(.h1)
            if view == .week { Text("week \(cal.component(.weekOfYear, from: focus))").font(.meta12).foregroundStyle(T.faint) }
            Spacer()
            if view != .agenda {
                Button("‹") { step(-1) }.buttonStyle(GhostButton()).help("Previous")
                Button("Today") { model.calFocus = .now }.buttonStyle(OutlineButton())
                Button("›") { step(1) }.buttonStyle(GhostButton()).help("Next")
            }
            HStack(spacing: 0) {
                ForEach(CalView.allCases, id: \.self) { v in
                    Button { view = v } label: {
                        Text(v.rawValue).font(.meta12).foregroundStyle(view == v ? T.teal : T.muted)
                            .padding(.horizontal, 12).frame(height: 24)
                            .background(RoundedRectangle(cornerRadius: 4).fill(view == v ? T.teal.opacity(0.14) : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4).overlay(RoundedRectangle(cornerRadius: 6).stroke(T.line))
            quickAdd
        }
        .padding(.horizontal, 24).frame(height: 64)
        .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
    }

    var parsed: QuickAdd.Result? { QuickAdd.parse(quick) }

    /// The calendar a quick add lands in: the "/word" one, else the first visible one you can write to.
    var target: CalendarRow? {
        let writable = calendars.filter(\.writable)
        if let hint = parsed?.calendar, let c = writable.first(where: { $0.name.lowercased().hasPrefix(hint) }) { return c }
        return writable.first(where: \.visible) ?? writable.first
    }

    var quickAdd: some View {
        HStack(spacing: 8) {
            Text("+").foregroundStyle(T.teal)
            TextField("Lunch with Ada thu 12", text: $quick).textFieldStyle(.plain).focused($quickFocused)
                .onSubmit(addQuick)
                .onKeyPress(.escape) { quick = ""; return .handled }
        }
        .padding(.horizontal, 12).frame(width: 240, height: 32)
        .background(RoundedRectangle(cornerRadius: 6).fill(T.bg))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(quickFocused ? T.teal : T.line))
        .popover(isPresented: .constant(parsed != nil && quickFocused), arrowEdge: .bottom) { if let parsed { preview(parsed) } }
    }

    func preview(_ p: QuickAdd.Result) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("NEW EVENT").font(.label11).foregroundStyle(T.muted); Spacer(); Text("parsed on this Mac, no AI").font(.meta12).foregroundStyle(T.faint) }
                .padding(.horizontal, 16).padding(.vertical, 10)
            row("What", p.title, nil)
            row("When", p.allDay ? p.start.formatted(.dateTime.weekday().day().month()) + " · all day"
                : "\(p.start.formatted(.dateTime.weekday().day().month())) · \(p.start.formatted(date: .omitted, time: .shortened))–\(p.end.formatted(date: .omitted, time: .shortened))", "“\(p.when)”")
            row("Calendar", target?.name ?? "No calendar yet", p.calendar.map { "“/\($0)”" })
            if let error { Text(error).font(.meta12).foregroundStyle(T.gold).padding(.horizontal, 16).padding(.top, 8) }
            HStack {
                Text("⇧↩ more details").font(.meta12).foregroundStyle(T.faint)
                Spacer()
                Button { addQuick() } label: { HStack(spacing: 6) { Text("Add"); Text("↩").font(.system(size: 10)) } }.buttonStyle(PrimaryButton()).disabled(target == nil)
            }
            .padding(16)
        }
        .font(.body13).frame(width: 400).background(T.surface)
    }

    func row(_ k: String, _ v: String, _ source: String?) -> some View {
        HStack(spacing: 12) {
            Text(k).font(.meta12).foregroundStyle(T.faint).frame(width: 64, alignment: .leading)
            Text(v).lineLimit(1)
            Spacer()
            if let source { Text(source).font(.meta12).foregroundStyle(T.faint) }
        }
        .padding(.horizontal, 16).frame(height: 40)
        .overlay(alignment: .top) { Rectangle().fill(T.line).frame(height: 1) }
    }

    func addQuick() {
        guard let p = parsed, let c = target else { return }
        let d = EventDraft(calendarId: c.id, title: p.title, start: p.start, end: p.end, allDay: p.allDay)
        // Shift-return opens the editor instead of saving straight away.
        if NSEvent.modifierFlags.contains(.shift) { model.editing = d; quick = ""; return }
        Task {
            do {
                try await model.save(d, invite: false)
                quick = ""; error = nil
                model.calFocus = p.start
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
        }
    }

    func step(_ n: Int) {
        let unit: Calendar.Component = view == .day ? .day : view == .week ? .weekOfYear : .month
        model.calFocus = cal.date(byAdding: unit, value: n, to: focus)!
    }

    func observe() async {
        guard let store = model.store else { return }
        let (from, to) = range
        let obs = ValueObservation.tracking { db in
            (try Store.instances(db, from: from, to: to),
             try CalendarRow.order(Column("accountId"), Column("name")).fetchAll(db),
             try Store.instances(db, from: .now, to: .now.addingTimeInterval(7 * 86400)).filter { !$0.allDay }.prefix(3).map { $0 })
        }
        do {
            for try await (i, c, u) in obs.values(in: store.db) { instances = i; calendars = c; upNext = u }
        } catch {}
    }
}

/// Mail / Calendar switch, mini month, Up next, and the calendars by account with an eye each.
struct CalSidebar: View {
    let model: AppModel
    let calendars: [CalendarRow]
    let upNext: [Instance]
    @Local private var month = Date.now

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ModeSwitch(model: model)
                mini
                if !upNext.isEmpty {
                    Text("UP NEXT").font(.label11).foregroundStyle(T.faint).padding(.horizontal, 12).padding(.top, 16).padding(.bottom, 4)
                    ForEach(upNext, id: \.self) { i in
                        Button { model.edit(i) } label: {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 2).fill(Color.calendar(i.colour, i.calendarId)).frame(width: 2)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(i.title).lineLimit(1)
                                    Text(i.start.formatted(.dateTime.weekday().hour().minute()) + (i.location.isEmpty ? "" : " · \(i.location)"))
                                        .font(.meta12).foregroundStyle(T.faint).lineLimit(1)
                                }
                                Spacer()
                                Text(i.start.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))).font(.meta12)
                                    .foregroundStyle(i.start.timeIntervalSinceNow < 3 * 3600 ? T.teal : T.faint)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 4).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("CALENDARS").font(.label11).foregroundStyle(T.faint).padding(.horizontal, 12).padding(.top, 16).padding(.bottom, 4)
                if calendars.isEmpty {
                    Text("Calendars appear after the first sync. Gmail accounts added before this version sign in again once.")
                        .font(.meta12).foregroundStyle(T.faint).padding(.horizontal, 12)
                }
                ForEach(model.accounts, id: \.id) { a in
                    let mine = calendars.filter { $0.accountId == a.id }
                    if !mine.isEmpty {
                        Text(a.email).font(.system(size: 11, design: .monospaced)).foregroundStyle(T.faint).padding(.horizontal, 12).padding(.top, 4)
                        ForEach(mine) { c in
                            Button { try? model.store?.setVisible(c.id!, !c.visible) } label: {
                                HStack(spacing: 8) {
                                    RoundedRectangle(cornerRadius: 3).fill(c.visible ? Color.calendar(c.colour, c.id!) : .clear)
                                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.calendar(c.colour, c.id!)))
                                        .frame(width: 12, height: 12)
                                    Text(c.name).lineLimit(1).foregroundStyle(c.visible ? T.text : T.faint)
                                    Spacer()
                                    Image(systemName: c.visible ? "eye" : "eye.slash").font(.system(size: 10)).foregroundStyle(T.faint)
                                }
                                .padding(.horizontal, 12).frame(height: 28).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).help(c.visible ? "Hide \(c.name)" : "Show \(c.name)")
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { status }
        .font(.body13)
        .padding(.horizontal, 12).padding(.top, 48).padding(.bottom, 16)
        .frame(width: T.sidebar)
        .background(T.surface)
        .overlay(alignment: .trailing) { Rectangle().fill(T.line).frame(width: 1) }
    }

    var status: some View {
        let states = model.calState.values
        let failed = states.compactMap { if case .failed(let e) = $0 { e } else { nil } }.first
        let last = states.compactMap { if case .synced(let d) = $0 { d } else { nil } }.max()
        return HStack(spacing: 8) {
            Circle().fill(failed != nil ? T.gold : T.teal).frame(width: 8, height: 8)
            Text(failed.map { "Calendar sync: \($0)" } ?? (model.calSyncers.isEmpty ? "Sign in again to sync calendars" : nil) ?? last.map { "Synced \($0.formatted(date: .omitted, time: .shortened)) · \(calendars.count) calendars" } ?? "Syncing calendars…")
                .lineLimit(2)
        }
        .font(.meta12).foregroundStyle(T.muted).padding(12).help(failed ?? "")
    }

    var mini: some View {
        let cal = Calendar.current
        let first = cal.dateInterval(of: .month, for: month)!.start
        let start = cal.dateInterval(of: .weekOfYear, for: first)!.start
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        let order = (0..<7).map { symbols[($0 + cal.firstWeekday - 1) % 7] }
        return VStack(spacing: 0) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide))).fontWeight(.semibold)
                Spacer()
                Button("‹") { month = cal.date(byAdding: .month, value: -1, to: month)! }.buttonStyle(.plain).foregroundStyle(T.muted)
                Button("›") { month = cal.date(byAdding: .month, value: 1, to: month)! }.buttonStyle(.plain).foregroundStyle(T.muted).padding(.leading, 8)
            }
            .padding(.horizontal, 4).frame(height: 28)
            HStack(spacing: 0) { ForEach(0..<7, id: \.self) { Text(order[$0]).frame(maxWidth: .infinity) } }
                .font(.system(size: 11)).foregroundStyle(T.faint).padding(.vertical, 4)
            ForEach(0..<6, id: \.self) { w in
                let week = cal.date(byAdding: .weekOfYear, value: w, to: start)!
                let focused = cal.isDate(week, equalTo: model.calFocus, toGranularity: .weekOfYear)
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { d in
                        let day = cal.date(byAdding: .day, value: d, to: week)!
                        let inMonth = cal.isDate(day, equalTo: month, toGranularity: .month)
                        Button { model.calFocus = day } label: {
                            Text("\(cal.component(.day, from: day))").font(.system(size: 11, weight: cal.isDateInToday(day) ? .semibold : .regular))
                                .foregroundStyle(cal.isDateInToday(day) ? T.bg : inMonth ? T.text : T.faint.opacity(0.6))
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(cal.isDateInToday(day) ? T.teal : .clear))
                                .frame(maxWidth: .infinity, minHeight: 24).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 4).fill(focused ? T.sel : .clear))
            }
        }
        .padding(.horizontal, 4).padding(.top, 4)
    }
}

/// The Mail / Calendar switch at the top of both sidebars.
struct ModeSwitch: View {
    let model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            ForEach([("Mail", false), ("Calendar", true)], id: \.0) { title, isCal in
                let on = (model.mode == .calendar) == isCal
                Button { model.mode = isCal ? .calendar : .mail } label: {
                    Text(title).font(.meta12).foregroundStyle(on ? T.text : T.muted)
                        .frame(maxWidth: .infinity).frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 4).fill(on ? T.sel : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(isCal ? "Calendar (⌘2)" : "Mail (⌘1)")
            }
        }
        .padding(4).overlay(RoundedRectangle(cornerRadius: 6).stroke(T.line))
        .padding(.bottom, 8)
    }
}

/// Day and week: 48 pt an hour, an all-day row, the now line, overlapping events side by side.
struct WeekGrid: View {
    let days: [Date]
    let instances: [Instance]
    let open: (Instance) -> Void
    let hour: CGFloat = 48
    var cal: Calendar { .current }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 56, height: 1)
                ForEach(days, id: \.self) { d in
                    let today = cal.isDateInToday(d)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(d.formatted(.dateTime.weekday())).font(.meta12)
                        Text("\(cal.component(.day, from: d))").font(.system(size: 20, weight: .semibold))
                    }
                    .foregroundStyle(today ? T.teal : T.muted)
                    .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .leading) { Rectangle().fill(T.line).frame(width: 1) }
                }
            }
            HStack(alignment: .top, spacing: 0) {
                Text("all-day").font(.system(size: 11)).foregroundStyle(T.faint).frame(width: 48, alignment: .trailing).padding(.trailing, 8).padding(.top, 8)
                ForEach(days, id: \.self) { d in
                    VStack(spacing: 2) {
                        ForEach(instances.filter { $0.allDay && $0.start < cal.date(byAdding: .day, value: 1, to: d)! && $0.end > d }, id: \.self) { i in
                            Button { open(i) } label: { chip(i).padding(.horizontal, 8).frame(height: 20) }.buttonStyle(.plain)
                        }
                    }
                    .padding(4).frame(maxWidth: .infinity, minHeight: 28, alignment: .top)
                    .overlay(alignment: .leading) { Rectangle().fill(T.line).frame(width: 1) }
                }
            }
            .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }

            ScrollViewReader { proxy in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { h in
                                Text(String(format: "%02d", h)).font(.system(size: 11)).foregroundStyle(T.faint)
                                    .frame(width: 48, height: hour, alignment: .topTrailing).padding(.trailing, 8).offset(y: -7).id(h)
                            }
                        }
                        ForEach(days, id: \.self) { d in column(d) }
                    }
                    .padding(.top, 8)
                }
                .onAppear { proxy.scrollTo(7, anchor: .top) }
            }
        }
        .padding(.trailing, 12)
    }

    func column(_ d: Date) -> some View {
        let next = cal.date(byAdding: .day, value: 1, to: d)!
        let items = instances.filter { !$0.allDay && $0.start < next && $0.end > d }
        let lanes = Self.lanes(items)
        return GeometryReader { g in
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { _ in Rectangle().fill(T.line.opacity(0.6)).frame(height: 1).frame(maxHeight: hour, alignment: .top) }
                }
                ForEach(items, id: \.self) { i in
                    let (lane, count) = lanes[i] ?? (0, 1)
                    let top = max(i.start, d).timeIntervalSince(d) / 3600 * hour
                    let height = max(min(i.end, next).timeIntervalSince(max(i.start, d)) / 3600 * hour - 2, 20)
                    let w = g.size.width / CGFloat(count)
                    Button { open(i) } label: { block(i) }
                        .buttonStyle(.plain)
                        .frame(width: w - 4, height: height)
                        .offset(x: CGFloat(lane) * w + 2, y: top)
                }
                if cal.isDateInToday(d) {
                    let y = Date.now.timeIntervalSince(d) / 3600 * hour
                    Rectangle().fill(T.teal).frame(height: 2).offset(y: y)
                }
            }
        }
        .frame(height: hour * 24)
        .frame(maxWidth: .infinity)
        .background(cal.isDateInToday(d) ? T.teal.opacity(0.03) : .clear)
        .overlay(alignment: .leading) { Rectangle().fill(T.line).frame(width: 1) }
    }

    /// Greedy lanes: each event takes the first lane free at its start; a cluster shares its widest count.
    static func lanes(_ items: [Instance]) -> [Instance: (Int, Int)] {
        var out: [Instance: (Int, Int)] = [:]
        var laneEnds: [Date] = [], cluster: [Instance] = [], clusterEnd = Date.distantPast
        func close() { let n = max(laneEnds.count, 1); for c in cluster { out[c] = (out[c]!.0, n) }; laneEnds = []; cluster = [] }
        for i in items.sorted(by: { $0.start < $1.start }) {
            if i.start >= clusterEnd { close() }
            let lane = laneEnds.firstIndex { $0 <= i.start } ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(i.end) } else { laneEnds[lane] = i.end }
            out[i] = (lane, 1)
            cluster.append(i)
            clusterEnd = max(clusterEnd, i.end)
        }
        close()
        return out
    }

    func block(_ i: Instance) -> some View {
        let c = Color.calendar(i.colour, i.calendarId)
        return VStack(alignment: .leading, spacing: 0) {
            Text(i.title).fontWeight(.semibold).lineLimit(2)
            Text(i.start.formatted(date: .omitted, time: .shortened) + (i.location.isEmpty ? "" : " · \(i.location)")).foregroundStyle(T.muted).lineLimit(1)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(c.opacity(0.17)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(c.opacity(0.55)))
        .contentShape(Rectangle())
    }

    func chip(_ i: Instance) -> some View {
        let c = Color.calendar(i.colour, i.calendarId)
        return Text(i.title).font(.system(size: 11)).lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(c.opacity(0.17)).padding(.horizontal, -8))
    }
}

/// A compact month: six weeks, three events a day and a count for the rest; a day opens in the day view.
struct MonthGrid: View {
    let start: Date
    let month: Int
    let instances: [Instance]
    let open: (Instance) -> Void
    let day: (Date) -> Void
    var cal: Calendar { .current }

    var body: some View {
        let symbols = cal.shortStandaloneWeekdaySymbols
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { i in
                    Text(symbols[(i + cal.firstWeekday - 1) % 7].uppercased()).font(.label11).foregroundStyle(T.faint)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
            }
            .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(0..<6, id: \.self) { w in
                    GridRow {
                        ForEach(0..<7, id: \.self) { d in cell(cal.date(byAdding: .day, value: w * 7 + d, to: start)!) }
                    }
                }
            }
        }
    }

    func cell(_ d: Date) -> some View {
        let next = cal.date(byAdding: .day, value: 1, to: d)!
        let items = instances.filter { $0.start < next && $0.end > d }
        let out = cal.component(.month, from: d) != month
        return VStack(alignment: .leading, spacing: 4) {
            Button { day(d) } label: {
                Text("\(cal.component(.day, from: d))").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(cal.isDateInToday(d) ? T.teal : out ? T.faint.opacity(0.6) : T.muted)
            }
            .buttonStyle(.plain)
            ForEach(items.prefix(3), id: \.self) { i in
                Button { open(i) } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Color.calendar(i.colour, i.calendarId)).frame(width: 7, height: 7)
                        if !i.allDay { Text(i.start.formatted(date: .omitted, time: .shortened)).foregroundStyle(T.faint) }
                        Text(i.title).lineLimit(1)
                    }
                    .font(.system(size: 11)).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if items.count > 3 { Text("+\(items.count - 3) more").font(.system(size: 11)).foregroundStyle(T.faint) }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(cal.isDateInToday(d) ? T.sel : out ? Color.black.opacity(0.15) : .clear)
        .overlay(alignment: .trailing) { Rectangle().fill(T.line).frame(width: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
    }
}

/// The next 60 days, by day; past events today are dimmed.
struct Agenda: View {
    let instances: [Instance]
    let open: (Instance) -> Void
    var cal: Calendar { .current }

    var body: some View {
        let byDay = Dictionary(grouping: instances) { cal.startOfDay(for: max($0.start, cal.startOfDay(for: .now))) }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if instances.isEmpty { Text("Nothing in the next 60 days").foregroundStyle(T.faint).padding(.top, 24) }
                ForEach(byDay.keys.sorted(), id: \.self) { d in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(cal.isDateInToday(d) ? "Today" : d.formatted(.dateTime.weekday(.wide))).font(.h1).foregroundStyle(cal.isDateInToday(d) ? T.teal : T.text)
                        Text(d.formatted(.dateTime.day().month(.wide))).foregroundStyle(T.faint)
                    }
                    .padding(.top, 16).padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
                    ForEach(byDay[d]!, id: \.self) { i in
                        Button { open(i) } label: {
                            HStack(spacing: 16) {
                                Text(i.allDay ? "all day" : "\(i.start.formatted(date: .omitted, time: .shortened))–\(i.end.formatted(date: .omitted, time: .shortened))")
                                    .foregroundStyle(i.start <= .now && i.end > .now ? T.teal : T.faint).frame(width: 110, alignment: .leading)
                                Circle().fill(Color.calendar(i.colour, i.calendarId)).frame(width: 8, height: 8)
                                (Text(i.title).fontWeight(.semibold) + Text(i.location.isEmpty ? "" : " · \(i.location)").foregroundStyle(T.faint)).lineLimit(1)
                                Spacer()
                                Text(i.calendar).foregroundStyle(T.faint).frame(width: 120, alignment: .trailing).lineLimit(1)
                            }
                            .padding(.vertical, 12).contentShape(Rectangle())
                            .opacity(i.end < .now ? 0.55 : 1)
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .bottom) { Rectangle().fill(T.line.opacity(0.5)).frame(height: 1) }
                    }
                }
            }
            .padding(.horizontal, 32).padding(.bottom, 32)
        }
    }
}

/// Screen 17: the side panel for a new or stored event.
struct EventEditor: View {
    let model: AppModel
    let calendars: [CalendarRow]
    @Local private var d = EventDraft(start: .now, end: .now)
    @Local private var error: String?
    @Local private var busy = false
    @Local private var confirmDelete = false

    var account: Account? { model.accounts.first { a in calendars.first { $0.id == d.calendarId }?.accountId == a.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(d.resource == nil ? "NEW EVENT" : "EVENT").font(.label11).foregroundStyle(T.muted)
                Spacer()
                Button { close() } label: { Kbd(key: "esc") }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
            }
            TextField("Title", text: $d.title).textFieldStyle(.plain).font(.h2).padding(.top, 16)
            if let note = d.note {
                HStack(spacing: 8) {
                    Text("Filled by Claude").font(.label11).foregroundStyle(T.teal)
                    Text(note).font(.meta12).foregroundStyle(T.muted)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(T.teal.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.teal.opacity(0.4)))
                .padding(.top, 16)
            }
            field("When") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        DatePicker("", selection: $d.start, displayedComponents: d.allDay ? [.date] : [.date, .hourAndMinute]).labelsHidden()
                        Text("to").foregroundStyle(T.faint)
                        DatePicker("", selection: $d.end, displayedComponents: d.allDay ? [.date] : [.date, .hourAndMinute]).labelsHidden()
                    }
                    .disabled(d.rrule != nil)
                    Toggle("All day", isOn: $d.allDay).toggleStyle(.checkbox).disabled(d.rrule != nil)
                    if d.rrule != nil { Text("Repeats. Times change for the whole series in the calendar it came from.").font(.meta12).foregroundStyle(T.faint) }
                }
            }
            field("Calendar") {
                FlowRow(calendars.filter { d.resource == nil || $0.accountId == calendars.first { $0.id == d.calendarId }?.accountId }) { c in
                    Button { d.calendarId = c.id } label: {
                        HStack(spacing: 6) {
                            Circle().fill(Color.calendar(c.colour, c.id!)).frame(width: 8, height: 8)
                            Text(c.name)
                        }
                        .font(.meta12).padding(.horizontal, 8).frame(height: 24)
                        .background(Capsule().fill(d.calendarId == c.id ? T.teal.opacity(0.14) : .clear))
                        .overlay(Capsule().stroke(d.calendarId == c.id ? T.teal.opacity(0.6) : T.line))
                    }
                    .buttonStyle(.plain)
                }
            }
            field("Where") { TextField("", text: $d.location).textFieldStyle(.plain) }
            field("Guests") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("ada@example.com, jonas@…", text: $d.guests).textFieldStyle(.plain)
                    Text(d.attendees.isEmpty ? "no invites sent" : d.attendees.map { "\($0.name.isEmpty ? $0.email : $0.name): \($0.partstat.lowercased())" }.joined(separator: " · "))
                        .font(.meta12).foregroundStyle(T.faint).lineLimit(2)
                }
            }
            if let error { Text(error).font(.meta12).foregroundStyle(T.gold).padding(.top, 12).textSelection(.enabled) }
            Spacer()
            if let c = calendars.first(where: { $0.id == d.calendarId }), let a = account {
                Text("Saves to \(a.email) · \(c.name) over CalDAV.").font(.meta12).foregroundStyle(T.faint).padding(.bottom, 12)
            }
            HStack(spacing: 8) {
                if d.resource != nil {
                    Button(confirmDelete ? "Delete for good?" : "Delete") { confirmDelete ? run { try await model.deleteEvent(d) } : (confirmDelete = true) }
                        .buttonStyle(GhostButton()).foregroundStyle(confirmDelete ? T.gold : T.muted)
                } else {
                    Button("Discard") { close() }.buttonStyle(GhostButton())
                }
                Spacer()
                Button("Save and invite") { run { try await model.save(d, invite: true) } }.buttonStyle(OutlineButton())
                    .disabled(busy || MIME.addresses(d.guests).isEmpty || d.calendarId == nil)
                Button { run { try await model.save(d, invite: false) } } label: { HStack(spacing: 6) { Text(busy ? "Saving…" : "Save"); Text("⌘S").font(.system(size: 10)) } }
                    .buttonStyle(PrimaryButton()).keyboardShortcut("s").disabled(busy || d.calendarId == nil || d.title.isEmpty)
            }
        }
        .font(.body13)
        .padding(32)
        .frame(width: 472)
        .frame(maxHeight: .infinity)
        .background(T.surface)
        .overlay(alignment: .leading) { Rectangle().fill(T.line).frame(width: 1) }
        .task(id: model.editing?.id) {
            if let e = model.editing { d = e; error = nil; confirmDelete = false; if d.calendarId == nil { d.calendarId = calendars.first?.id } }
        }
        .onChange(of: d.start) { old, new in if d.end <= new { d.end = new.addingTimeInterval(max(d.end.timeIntervalSince(old), 3600)) } }
    }

    func field(_ k: String, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(k).font(.meta12).foregroundStyle(T.faint).frame(width: 78, alignment: .leading)
            content()
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
    }

    func run(_ work: @escaping () async throws -> Void) {
        busy = true; error = nil
        Task {
            do {
                try await work()
                close()
            } catch CalDAV.Failure.conflict {
                error = "This event changed on the server while you edited it. The server's version is in the calendar now; your edit was not saved."
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
            busy = false
        }
    }

    func close() { model.editing = nil }
}

/// Wrapping chips without a layout library.
struct FlowRow<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content
    init(_ items: [Item], @ViewBuilder content: @escaping (Item) -> Content) { self.items = items; self.content = content }
    var body: some View {
        // ponytail: an HStack that scrolls sideways; a real flow layout when someone has a dozen calendars
        ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { ForEach(items) { content($0) } } }
    }
}

/// Screen 12: an invitation in mail. Accept, Maybe or Decline; the clash with what is already on your calendars.
struct InviteCard: View {
    let model: AppModel
    let message: Message
    let ics: String
    let event: ICal.Event
    let method: String
    @Local private var calendars: [CalendarRow] = []
    @Local private var calendarId: Int64?
    @Local private var clashes: [Instance] = []
    @Local private var answer: String?
    @Local private var busy = false
    @Local private var error: String?

    var cal: Calendar { .current }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                VStack(spacing: 0) {
                    Text(event.start.formatted(.dateTime.month(.abbreviated)).uppercased()).font(.label11).foregroundStyle(T.gold)
                    Text("\(cal.component(.day, from: event.start))").font(.display)
                    Text(event.start.formatted(.dateTime.weekday())).font(.system(size: 11)).foregroundStyle(T.faint)
                }
                .frame(width: 64).padding(.vertical, 8)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(T.gold.opacity(0.5)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.summary).font(.h1)
                    Text((event.allDay ? "All day" : "\(event.start.formatted(date: .omitted, time: .shortened))–\(event.end.formatted(date: .omitted, time: .shortened))")
                         + (event.location.isEmpty ? "" : " · \(event.location)")).foregroundStyle(T.muted)
                    let accepted = event.attendees.filter { $0.partstat == "ACCEPTED" }.count
                    Text("Organiser \(event.organizer ?? "unknown") · \(event.attendees.count) guests, \(accepted) accepted").font(.meta12).foregroundStyle(T.faint)
                }
                Spacer()
            }
            .padding(.horizontal, 24).padding(.vertical, 16)

            if method == "CANCEL" {
                Text("The organiser cancelled this event.").foregroundStyle(T.gold).padding(.horizontal, 24).padding(.bottom, 16)
            } else if method == "REPLY" {
                let who = event.attendees.first
                Text("\(who?.name.isEmpty == false ? who!.name : who?.email ?? "A guest") answered \(who?.partstat.lowercased() ?? "").")
                    .foregroundStyle(T.muted).padding(.horizontal, 24).padding(.bottom, 16)
            } else {
                if !clashes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CLASH").font(.label11).foregroundStyle(T.gold)
                        ForEach(clashes, id: \.self) { c in
                            Text("Overlaps \(c.title) (\(c.calendar)), \(c.start.formatted(date: .omitted, time: .shortened))–\(c.end.formatted(date: .omitted, time: .shortened))")
                                .foregroundStyle(T.body)
                        }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Rectangle().fill(T.line).frame(height: 1) }
                }
                HStack(spacing: 8) {
                    ForEach([("Accept", "ACCEPTED"), ("Maybe", "TENTATIVE"), ("Decline", "DECLINED")], id: \.1) { title, ps in
                        Button(title) { respond(ps) }
                            .buttonStyle(OutlineButton())
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(answer == ps ? T.teal : .clear))
                            .disabled(busy)
                    }
                    if let answer { Text("You answered \(answer.lowercased()).").font(.meta12).foregroundStyle(T.teal) }
                    Spacer()
                    if !calendars.isEmpty {
                        Text("add to").font(.meta12).foregroundStyle(T.faint)
                        Picker("", selection: $calendarId) {
                            ForEach(calendars) { c in Text(c.name).tag(Optional(c.id!)) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 16)
                .overlay(alignment: .top) { Rectangle().fill(T.line).frame(height: 1) }
                if let error { Text(error).font(.meta12).foregroundStyle(T.gold).padding(.horizontal, 24).padding(.bottom, 12) }
            }
        }
        .font(.body13)
        .background(RoundedRectangle(cornerRadius: 6).fill(T.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.gold.opacity(0.5)))
        .task { load() }
    }

    func load() {
        guard let store = model.store else { return }
        calendars = ((try? store.calendars()) ?? []).filter(\.writable)
        calendarId = (calendars.first { $0.accountId == message.accountId && $0.visible } ?? calendars.first)?.id
        clashes = ((try? store.instances(from: event.start, to: event.end)) ?? []).filter { $0.uid != event.uid && !$0.allDay }
        // What I answered before, from the calendar copy if there is one.
        if let rid = try? store.resource(uid: event.uid), let r = try? store.resource(rid) {
            answer = ICal.parse(r.ics).events.first?.attendees.first { model.isMine($0.email) || $0.email == message.via }?.partstat
            if answer == "NEEDS-ACTION" { answer = nil }
        }
    }

    func respond(_ partstat: String) {
        busy = true; error = nil
        Task {
            do {
                try await model.respond(event, ics: ics, message: message, partstat: partstat, calendar: calendars.first { $0.id == calendarId })
                answer = partstat
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
            busy = false
        }
    }
}
