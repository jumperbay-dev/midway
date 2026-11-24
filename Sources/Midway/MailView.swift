import AppKit
import GRDB
import MidwayCore
import SwiftUI

/// Which list is showing: the unified Inbox, a local pile, drafts, or one account's label (Gmail labels act as folders).
enum Box: Hashable {
    case inbox
    case replyLater
    case setAside
    case snoozed
    case drafts
    case label(account: Int64, name: String)

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .replyLater: "Reply later"
        case .setAside: "Set aside"
        case .snoozed: "Snoozed"
        case .drafts: "Drafts"
        case .label(_, let name): Box.display(name)
        }
    }

    /// Label views hide snoozed mail until it is due, then show it as new (sorted by when it came back).
    func fetch(_ db: Database, now: Date) throws -> [Message] {
        let pileJoin = "SELECT message.* FROM message JOIN pile ON pile.messageId = message.id"
        switch self {
        case .replyLater: return try Message.fetchAll(db, sql: "\(pileJoin) WHERE pile.replyLater ORDER BY message.date")
        case .setAside: return try Message.fetchAll(db, sql: "\(pileJoin) WHERE pile.setAside ORDER BY message.date DESC")
        case .snoozed: return try Message.fetchAll(db, sql: "\(pileJoin) WHERE pile.snoozedUntil > ? ORDER BY pile.snoozedUntil", arguments: [now])
        case .drafts: return []
        case .inbox, .label:
            let (name, account): (String, Int64?) = if case .label(let a, let n) = self { (n, a) } else { (Label.inbox, nil) }
            return try Message.fetchAll(db, sql: """
                SELECT message.* FROM message JOIN label ON label.messageId = message.id
                LEFT JOIN pile ON pile.messageId = message.id
                WHERE label.name = ? AND (? IS NULL OR message.accountId = ?) AND (pile.snoozedUntil IS NULL OR pile.snoozedUntil <= ?)
                ORDER BY MAX(message.date, IFNULL(pile.snoozedUntil, '')) DESC
                """, arguments: [name, account, account, now])
        }
    }

    /// Gmail's system labels arrive as \\Sent, \\Starred…; user labels as they are.
    static func display(_ label: String) -> String {
        ["\\Sent": "Sent", "\\Starred": "Starred", "\\Important": "Important", "\\Draft": "Gmail drafts", "\\Trash": "Trash"][label]
            ?? (label.hasPrefix("\\") ? String(label.dropFirst()) : label)
    }
}

/// What covers the three panes, if anything.
enum Mode: Equatable {
    case mail, search, focus, keys
}

/// Screen 01: sidebar 232, list 360, reader fills the rest. The keyboard does the rest.
struct MailView: View {
    let model: AppModel
    @Local private var box: Box = .inbox
    @Local private var messages: [Message] = []
    @Local private var piles: [Int64: Pile] = [:]
    @Local private var selected: Int64?
    @Local private var snoozing = false
    @Local private var toast: String?
    /// Moves on when a snooze ends, so lists and counts refresh.
    @Local private var now = Date.now
    @Local private var pendingG = false
    @FocusState private var focused: Bool
    @Environment(\.openWindow) private var openWindow

    var unread: Int { messages.count { !$0.seen } }
    var current: Message? { messages.first { $0.id == selected } }

    var body: some View {
        Group {
            switch model.mode {
            case .focus:
                FocusView(model: model, close: { model.mode = .mail; focused = true })
            case .keys:
                KeyboardMap(close: { model.mode = .mail; focused = true })
            case .mail, .search:
                HStack(spacing: 0) {
                    Sidebar(model: model, box: $box, now: now, compose: { compose(nil) })
                    if model.mode == .search {
                        SearchView(model: model, open: { m in box = .inbox; model.mode = .mail; selected = m.id }, close: { model.mode = .mail; focused = true })
                    } else if box == .drafts {
                        DraftsList(model: model)
                    } else {
                        list
                        Rectangle().fill(T.line).frame(width: 1)
                        if let current, let store = model.store {
                            Reader(message: current, store: store, pile: piles[current.id ?? -1], snoozing: $snoozing,
                                   act: act, setPile: pile, snooze: snooze, reply: { compose(current) })
                                .id(current.id)
                        } else {
                            Text(messages.isEmpty ? (box == .inbox ? "All caught up" : "Nothing here") : "No message selected")
                                .foregroundStyle(T.faint).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottom) { Toasts(model: model, toast: $toast, openWindow: { openWindow(id: "compose", value: $0) }) }
        .overlay {
            if model.commandBar {
                CommandBar(model: model, commands: commands, open: { m in box = .inbox; model.mode = .mail; selected = m.id }, close: { model.commandBar = false; focused = true })
            }
        }
        .ignoresSafeArea()
        .focusable().focused($focused).focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(characters: ["j", "k"]) { press in step(press.characters == "j" ? 1 : -1); return .handled }
        .onKeyPress(.downArrow) { step(1); return .handled }
        .onKeyPress(.upArrow) { step(-1); return .handled }
        .onKeyPress(characters: ["e", "#", "s", "u", "r", "c", "/", "l", "y", "h", "z", "g", "i", "?"]) { press in key(press) }
        .onChange(of: selected) { if let current { model.open(current) } }
        .onChange(of: box) { selected = nil; model.mode = .mail; focused = true }
        .task(id: [box, now] as [AnyHashable]) { await observe() }
        .task(id: piles) { await tick() }
        .sheet(isPresented: Bindable(model).adding) {
            AddAccount(model: model, back: { model.adding = false }).padding(.bottom, 48).background(T.bg)
        }
    }

    func key(_ press: KeyPress) -> KeyPress.Result {
        let c = press.characters
        if press.modifiers.contains(.command) {
            guard c == "z", model.undoLast != nil else { return .ignored }
            undo(); return .handled
        }
        // g i: go to inbox.
        if pendingG {
            pendingG = false
            if c == "i" { box = .inbox; return .handled }
        }
        switch c {
        case "g": pendingG = true
        case "/": model.mode = .search
        case "?": model.mode = .keys
        case "c": compose(nil)
        case "z": if model.undoLast != nil { undo() }
        case "r": if let current { compose(current) }
        case "h": if current != nil { snoozing = true }
        case "e", "#", "s", "u", "l", "y":
            guard let current else { return .ignored }
            switch c {
            case "l": pile(.replyLater, current)
            case "y": pile(.setAside, current)
            default: act(c == "e" ? .archive : c == "#" ? .trash : c == "s" ? .flagged : .seen, current)
            }
        default: return .ignored
        }
        return .handled
    }

    func undo() {
        model.undo()
        toast = nil
        focused = true
    }

    /// Archive and delete move the selection on; star and unread toggle in place.
    func act(_ kind: OpKind, _ m: Message) {
        let value = switch kind { case .flagged: !m.flagged; case .seen: !m.seen; default: true }
        if kind == .archive || kind == .trash { moveOn(from: m) }
        model.act(kind, value, m)
        toast = switch kind {
        case .archive: "Archived"
        case .trash: "Moved to Trash"
        case .flagged: value ? "Starred" : "Unstarred"
        case .seen: value ? "Marked read" : "Marked unread"
        }
        focused = true
    }

    enum PileKind { case replyLater, setAside }

    func pile(_ kind: PileKind, _ m: Message) {
        let on = !(kind == .replyLater ? piles[m.id ?? -1]?.replyLater ?? false : piles[m.id ?? -1]?.setAside ?? false)
        if !on && (box == .replyLater || box == .setAside) { moveOn(from: m) }
        model.setPile(m) { if kind == .replyLater { $0.replyLater = on } else { $0.setAside = on } }
        toast = switch kind {
        case .replyLater: on ? "Reply later" : "Out of Reply later"
        case .setAside: on ? "Set aside" : "No longer set aside"
        }
        focused = true
    }

    func snooze(_ m: Message, _ until: Date?, _ wakeOnReply: Bool) {
        snoozing = false
        if until != nil || box == .snoozed { moveOn(from: m) }
        model.setPile(m) { $0.snoozedUntil = until; $0.wakeOnReply = wakeOnReply }
        toast = until.map { "Snoozed until \($0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))" } ?? "Unsnoozed"
        focused = true
    }

    func moveOn(from m: Message) {
        let i = messages.firstIndex { $0.id == m.id } ?? 0
        selected = messages.indices.contains(i + 1) ? messages[i + 1].id : i > 0 ? messages[i - 1].id : nil
    }

    func compose(_ replyTo: Message?) {
        if let id = model.newDraft(replyingTo: replyTo) { openWindow(id: "compose", value: id) }
    }

    /// Everything the command bar can do, in its groups. Message actions apply to the selected message.
    var commands: [CommandBar.Command] {
        var out: [CommandBar.Command] = []
        if let m = current {
            let p = piles[m.id ?? -1]
            let group = "This message · \(m.subject.prefix(40))"
            out += [
                .init(group: group, title: "Archive", key: "e") { act(.archive, m) },
                .init(group: group, title: "Reply", key: "r") { compose(m) },
                .init(group: group, title: "Reply to all", key: nil) { if let id = model.newDraft(replyingTo: m, all: true) { openWindow(id: "compose", value: id) } },
                .init(group: group, title: p?.replyLater == true ? "Remove from Reply later" : "Reply later", key: "l") { pile(.replyLater, m) },
                .init(group: group, title: p?.setAside == true ? "Remove from Set aside" : "Set aside", key: "y") { pile(.setAside, m) },
                .init(group: group, title: "Snooze…", key: "h") { snoozing = true },
                .init(group: group, title: m.flagged ? "Unstar" : "Star", key: "s") { act(.flagged, m) },
                .init(group: group, title: m.seen ? "Mark unread" : "Mark read", key: "u") { act(.seen, m) },
                .init(group: group, title: "Delete", key: "#") { act(.trash, m) },
            ]
        }
        out += [
            .init(group: "Go to", title: "Inbox", key: "g i") { box = .inbox },
            .init(group: "Go to", title: "Reply later", key: nil) { box = .replyLater },
            .init(group: "Go to", title: "Set aside", key: nil) { box = .setAside },
            .init(group: "Go to", title: "Snoozed", key: nil) { box = .snoozed },
            .init(group: "Go to", title: "Drafts", key: nil) { box = .drafts },
        ]
        for a in model.accounts where a.kind == .google {
            for name in model.labels[a.id ?? -1] ?? [] {
                out.append(.init(group: "Go to", title: "\(Box.display(name)) · \(a.email)", key: nil) { box = .label(account: a.id!, name: name) })
            }
        }
        out += [
            .init(group: "Commands", title: "New message", key: "c") { compose(nil) },
            .init(group: "Commands", title: "Focus and reply", key: "⌘.") { model.mode = .focus },
            .init(group: "Commands", title: "Search mail", key: "/") { model.mode = .search },
            .init(group: "Commands", title: "Keyboard map", key: "?") { model.mode = .keys },
            .init(group: "Commands", title: "Add account", key: nil) { model.adding = true },
        ]
        if model.undoLast != nil { out.append(.init(group: "Commands", title: "Undo", key: "z") { undo() }) }
        return out
    }

    var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(box.title).font(.h1)
                Spacer()
                Text("\(unread) unread").font(.meta12).foregroundStyle(T.muted)
                Button { model.mode = .search } label: { Kbd(key: "/") }.buttonStyle(.plain).help("Search (/)").accessibilityLabel("Search")
            }
            .padding(.horizontal, 16).frame(height: 56)
            .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(messages) { m in
                            Row(message: m, pile: piles[m.id ?? -1], now: now, selected: m.id == selected)
                                .id(m.id)
                                .onTapGesture { selected = m.id; focused = true }
                        }
                    }
                }
                .onChange(of: selected) { proxy.scrollTo(selected) }
            }
        }
        .frame(width: T.list)
    }

    func step(_ d: Int) {
        let i = messages.firstIndex { $0.id == selected }.map { $0 + d } ?? 0
        if messages.indices.contains(i) { selected = messages[i].id }
    }

    func observe() async {
        guard let store = model.store else { return }
        let (box, now) = (self.box, self.now)
        let obs = ValueObservation.tracking { db in
            (try box.fetch(db, now: now), try Pile.fetchAll(db))
        }
        do {
            for try await (rows, p) in obs.values(in: store.db) {
                messages = rows
                piles = Dictionary(uniqueKeysWithValues: p.map { ($0.messageId, $0) })
            }
        } catch {}
    }

    /// Wakes when the next snooze ends (or every 5 minutes, which also catches new snoozes).
    func tick() async {
        while !Task.isCancelled {
            let next = (try? model.store?.nextSnoozeEnd()).flatMap { $0 }
            let wait = min(max(next.map { $0.timeIntervalSinceNow } ?? 300, 1), 300)
            try? await Task.sleep(for: .seconds(wait + 0.5))
            now = .now
        }
    }
}

/// Bottom-centre notices: the last action (⌘Z undoes it) and messages inside their undo-send window.
struct Toasts: View {
    let model: AppModel
    @Binding var toast: String?
    let openWindow: (Int64) -> Void
    @Local private var sending: [OutboxRow] = []

    struct OutboxRow: Hashable, FetchableRecord, Decodable {
        var draftId: Int64
        var toList: String
        var sendAt: Date
        var error: String?
    }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(sending, id: \.self) { o in
                if o.error == nil && o.sendAt > .now {
                    pill("Sending to \(MIME.addresses(o.toList).map { $0.name.isEmpty ? $0.address : $0.name }.joined(separator: ", "))") { Button("Undo") { model.unsend(o.draftId); openWindow(o.draftId) }.buttonStyle(GhostButton()) }
                }
            }
            if let toast {
                pill(toast) { HStack(spacing: 6) { Kbd(key: "⌘Z"); Text("undo") }.font(.meta12).foregroundStyle(T.faint) }
                    .task(id: toast) { try? await Task.sleep(for: .seconds(5)); self.toast = nil }
            }
        }
        .padding(.bottom, 72)
        .task { await observe() }
    }

    func pill(_ text: String, @ViewBuilder _ trailing: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(text).lineLimit(1)
            trailing()
        }
        .font(.body13)
        .padding(.leading, 16).padding(.trailing, 8).frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 6).fill(T.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.line))
        .frame(maxWidth: 480)
    }

    func observe() async {
        guard let store = model.store else { return }
        let obs = ValueObservation.tracking { db in
            try OutboxRow.fetchAll(db, sql: "SELECT outbox.draftId, draft.toList, outbox.sendAt, outbox.error FROM outbox JOIN draft ON draft.id = outbox.draftId")
        }
        do {
            for try await rows in obs.values(in: store.db) {
                sending = rows
                // Hide each one when its window ends.
                if let next = rows.map(\.sendAt).filter({ $0 > .now }).min() {
                    Task { try? await Task.sleep(for: .seconds(next.timeIntervalSinceNow + 0.1)); sending = sending }
                }
            }
        } catch {}
    }
}

/// Local drafts, and messages still in the outbox with their state. Opening one edits it as a draft.
struct DraftsList: View {
    let model: AppModel
    @Local private var rows: [Item] = []
    @Environment(\.openWindow) private var openWindow

    struct Item: Hashable, FetchableRecord, Decodable {
        var id: Int64
        var toList: String
        var subject: String
        var updatedAt: Date
        var error: String?
        var queued: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("Drafts").font(.h1); Spacer() }
                .padding(.horizontal, 16).frame(height: 56)
                .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows, id: \.id) { r in
                        Button { openWindow(id: "compose", value: r.id) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(r.toList.isEmpty ? "No recipients" : r.toList).fontWeight(.semibold).lineLimit(1)
                                    Spacer()
                                    Text(Row.time(r.updatedAt)).font(.meta12).foregroundStyle(T.faint)
                                }
                                Text(r.subject.isEmpty ? "(no subject)" : r.subject).lineLimit(1)
                                if let e = r.error { Text("Not sent, retrying · \(e)").font(.meta12).foregroundStyle(T.gold).lineLimit(1) }
                                else if r.queued { Text("Sending…").font(.meta12).foregroundStyle(T.teal) }
                            }
                            .padding(.horizontal, 32).padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .font(.body13)
        .frame(maxWidth: .infinity)
        .task { await observe() }
    }

    func observe() async {
        guard let store = model.store else { return }
        let obs = ValueObservation.tracking { db in
            try Item.fetchAll(db, sql: """
                SELECT draft.id, draft.toList, draft.subject, draft.updatedAt, outbox.error, outbox.id IS NOT NULL AS queued
                FROM draft LEFT JOIN outbox ON outbox.draftId = draft.id ORDER BY draft.updatedAt DESC
                """)
        }
        do { for try await r in obs.values(in: store.db) { rows = r } } catch {}
    }
}

struct Row: View {
    let message: Message
    var pile: Pile? = nil
    var now: Date = .now
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(message.fromName.isEmpty ? message.fromAddr : message.fromName)
                    .fontWeight(message.seen ? .regular : .semibold)
                    .foregroundStyle(message.seen ? T.muted : T.text)
                    .lineLimit(1)
                Spacer()
                if message.flagged { Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(T.gold) }
                Text(Row.time(message.date)).font(.meta12).foregroundStyle(T.faint)
            }
            Text(message.subject.isEmpty ? "(no subject)" : message.subject).lineLimit(1)
            Text(message.preview).font(.meta12).foregroundStyle(T.faint).lineLimit(1)
            if let pile, pile.replyLater || pile.setAside || pile.snoozedUntil != nil {
                HStack(spacing: 4) {
                    if pile.replyLater { chip("Reply later", T.gold) }
                    if pile.setAside { chip("Set aside", T.muted) }
                    if let until = pile.snoozedUntil {
                        until > now ? chip("Until \(until.formatted(.dateTime.weekday(.abbreviated).hour().minute()))", T.muted) : chip("Back from snooze", T.teal)
                    }
                }
                .padding(.top, 6)
            }
        }
        .font(.body13)
        .padding(.leading, 32).padding(.trailing, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? T.sel : .clear)
        .overlay(alignment: .topLeading) {
            if !message.seen { Circle().fill(T.teal).frame(width: 6, height: 6).offset(x: 16, y: 19) }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
        .contentShape(Rectangle())
    }

    func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(color)
            .padding(.horizontal, 8).frame(height: 18)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    /// 09:14 today, Mon this week, 18 Nov before that.
    static func time(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if let days = cal.dateComponents([.day], from: d, to: .now).day, days < 7 { return d.formatted(.dateTime.weekday(.abbreviated)) }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }
}

struct Sidebar: View {
    let model: AppModel
    @Binding var box: Box
    let now: Date
    let compose: () -> Void
    @Local private var inboxUnread = 0
    @Local private var later = 0
    @Local private var aside = 0
    @Local private var snoozed = 0
    @Local private var drafts = 0
    @Local private var failed = 0
    @Local private var labels: [LabelRow] = []

    struct LabelRow: Hashable, FetchableRecord, Decodable {
        var accountId: Int64
        var name: String
        var unread: Int
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Button(action: compose) {
                    HStack { Label("New message", systemImage: "square.and.pencil"); Spacer(); Kbd(key: "c") }
                        .padding(.horizontal, 12).frame(height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(T.muted).padding(.bottom, 8)
                item(.inbox, "Inbox", inboxUnread)
                item(.replyLater, "Reply later", later)
                item(.setAside, "Set aside", aside)
                if snoozed > 0 { item(.snoozed, "Snoozed", snoozed) }
                if drafts > 0 { item(.drafts, failed > 0 ? "Drafts · \(failed) not sent" : "Drafts", drafts) }
                ForEach(model.accounts.filter { $0.kind == .google }, id: \.id) { a in
                    let rows = labels.filter { $0.accountId == a.id }
                    if !rows.isEmpty {
                        Text(a.email).font(.label11).foregroundStyle(T.faint).lineLimit(1)
                            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
                        ForEach(rows, id: \.self) { l in item(.label(account: l.accountId, name: l.name), Box.display(l.name), l.unread) }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Button { model.adding = true } label: {
                    Label("Add account", systemImage: "plus").font(.meta12).foregroundStyle(T.muted)
                        .padding(.horizontal, 12).frame(height: 28)
                }
                .buttonStyle(.plain)
                status
            }
        }
        .font(.body13)
        .padding(.horizontal, 12).padding(.top, 48).padding(.bottom, 16)
        .frame(width: T.sidebar)
        .background(T.surface)
        .overlay(alignment: .trailing) { Rectangle().fill(T.line).frame(width: 1) }
        .task(id: now) { await observe() }
    }

    func item(_ b: Box, _ title: String, _ count: Int) -> some View {
        Button { box = b } label: {
            HStack {
                Text(title).lineLimit(1)
                Spacer()
                if count > 0 { Text("\(count)").font(.meta12).foregroundStyle(b == .inbox ? T.teal : b == .replyLater || (b == .drafts && failed > 0) ? T.gold : T.faint) }
            }
            .padding(.horizontal, 12).frame(height: b == .inbox ? 32 : 28)
            .background(RoundedRectangle(cornerRadius: 4).fill(box == b ? T.sel : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func observe() async {
        guard let store = model.store else { return }
        let now = self.now
        let obs = ValueObservation.tracking { db in
            let inbox = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM message JOIN label ON label.messageId = message.id LEFT JOIN pile ON pile.messageId = message.id
                WHERE label.name = ? AND message.seen = 0 AND (pile.snoozedUntil IS NULL OR pile.snoozedUntil <= ?)
                """, arguments: [Label.inbox, now]) ?? 0
            let piles = try GRDB.Row.fetchOne(db, sql: "SELECT SUM(replyLater), SUM(setAside), SUM(snoozedUntil > ?) FROM pile", arguments: [now])
            let counts = [0, 1, 2].map { (piles?[$0] as Int?) ?? 0 }
            let rows = try LabelRow.fetchAll(db, sql: """
                SELECT message.accountId, label.name, SUM(message.seen = 0) AS unread
                FROM label JOIN message ON message.id = label.messageId
                WHERE label.name != ? GROUP BY message.accountId, label.name ORDER BY label.name
                """, arguments: [Label.inbox])
            let drafts = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM draft") ?? 0
            let failed = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox WHERE error IS NOT NULL") ?? 0
            return (inbox, rows, drafts, failed, counts)
        }
        do {
            for try await (inbox, rows, d, f, c) in obs.values(in: store.db) {
                inboxUnread = inbox; labels = rows; drafts = d; failed = f
                (later, aside, snoozed) = (c[0], c[1], c[2])
                // Dock badge only in v1: unread in the Inbox, snoozed mail not counted.
                NSApplication.shared.dockTile.badgeLabel = inbox > 0 ? "\(inbox)" : nil
                model.labels = Dictionary(grouping: rows, by: { $0.accountId }).mapValues { $0.map { $0.name } }
            }
        } catch {}
    }

    /// The most urgent account state wins: sign-in, then offline, then the latest sync.
    @ViewBuilder var status: some View {
        let states = model.accounts.compactMap { a in a.id.flatMap { model.sync[$0] }.map { (a, $0) } }
        let n = model.accounts.count
        if let (a, _) = states.first(where: { $0.1 == .signInFailed }) {
            footer(T.gold, "Sign in again · \(a.email)", T.gold).background(RoundedRectangle(cornerRadius: 6).fill(T.gold.opacity(0.12)))
        } else if states.contains(where: { if case .offline = $0.1 { true } else { false } }) {
            footer(T.gold, "Offline · retrying", T.gold).background(RoundedRectangle(cornerRadius: 6).fill(T.gold.opacity(0.12)))
        } else if let last = states.compactMap({ if case .synced(let d) = $0.1 { d } else { nil } }).max(), states.count == n {
            footer(T.teal, "Synced \(last.formatted(date: .omitted, time: .shortened)) · \(n) account\(n == 1 ? "" : "s")", T.muted)
        } else {
            footer(T.faint, "Connecting…", T.muted)
        }
    }

    func footer(_ dot: Color, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(dot).frame(width: 8, height: 8)
            Text(text).font(.meta12).foregroundStyle(color).lineLimit(1)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Reader: View {
    let message: Message
    let store: Store
    let pile: Pile?
    @Binding var snoozing: Bool
    let act: (OpKind, Message) -> Void
    let setPile: (MailView.PileKind, Message) -> Void
    let snooze: (Message, Date?, Bool) -> Void
    let reply: () -> Void
    @Local private var html: String?

    var initials: String {
        let name = message.fromName.isEmpty ? message.fromAddr : message.fromName
        return String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                tool("archivebox", "Archive (e)") { act(.archive, message) }
                tool(pile?.replyLater == true ? "arrowshape.turn.up.left.circle.fill" : "arrowshape.turn.up.left.circle", "Reply later (l)") { setPile(.replyLater, message) }
                tool(pile?.setAside == true ? "bookmark.fill" : "bookmark", "Set aside (y)") { setPile(.setAside, message) }
                tool(pile?.snoozedUntil.map { $0 > .now } == true ? "alarm.fill" : "alarm", "Snooze (h)") { snoozing = true }
                    .popover(isPresented: $snoozing, arrowEdge: .bottom) {
                        SnoozePicker(snoozed: pile?.snoozedUntil.map { $0 > .now } == true) { snooze(message, $0, $1) }
                    }
                tool("trash", "Delete (#)") { act(.trash, message) }
                tool(message.flagged ? "star.fill" : "star", "Star (s)") { act(.flagged, message) }
                tool(message.seen ? "envelope.badge" : "envelope.open", message.seen ? "Mark unread (u)" : "Mark read (u)") { act(.seen, message) }
                Spacer()
                tool("arrowshape.turn.up.left", "Reply (r)", reply)
            }
            .padding(.top, -12).padding(.trailing, -16).padding(.bottom, 16)
            Text(message.subject.isEmpty ? "(no subject)" : message.subject).font(.h2).textSelection(.enabled)
            HStack(spacing: 12) {
                Text(initials).font(.system(size: 13, weight: .semibold)).foregroundStyle(T.teal)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(T.sel)).overlay(Circle().stroke(T.line))
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text(message.fromName.isEmpty ? message.fromAddr : message.fromName).fontWeight(.semibold)
                        Text(message.fromAddr).font(.mono12).foregroundStyle(T.faint)
                    }
                    (Text("to ") + Text(message.toAddr).foregroundStyle(T.teal) + Text(" · \(message.date.formatted(.dateTime.weekday(.wide).day().month().hour().minute()))"))
                        .font(.meta12).foregroundStyle(T.muted)
                }
            }
            .padding(.top, 16)

            Group {
                if let html { MessageWebView(html: html) } else { Spacer() }
            }
            .padding(.top, 24)

            HStack(spacing: 16) {
                hint("e", "archive"); hint("l", "reply later"); hint("h", "snooze"); hint("r", "reply"); hint("/", "search"); hint("⌘K", "command")
            }
            .font(.meta12).foregroundStyle(T.faint).padding(.top, 16)
        }
        .font(.body13)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { html = render() }
    }

    func tool(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(icon == "star.fill" || icon.hasSuffix("circle.fill") ? T.gold : icon.hasSuffix(".fill") ? T.text : T.muted)
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 6) { Kbd(key: key); Text(label) }
    }

    func render() -> String {
        guard let raw = try? store.raw(message) else { return Reader.page("<p>The message file is missing.</p>") }
        let p = MIME.parse(raw)
        if let h = p.html {
            // Mail HTML is designed for white paper; give it that, inside the dark reader.
            return "<style>:root{color-scheme:light}html{background:#fff;color:#111;border-radius:6px}body{margin:16px;font:15px/24px -apple-system,sans-serif}</style>" + h
        }
        let escaped = (p.text ?? "").replacing("&", with: "&amp;").replacing("<", with: "&lt;").replacing(">", with: "&gt;")
        return Reader.page("<div style=\"white-space:pre-wrap\">\(escaped)</div>")
    }

    static func page(_ body: String) -> String {
        "<style>:root{color-scheme:dark}html{background:transparent}body{margin:0;max-width:640px;color:#C3D3DA;font:15px/24px -apple-system,sans-serif}</style>" + body
    }
}

/// Screen 09: search fills the space of list and reader. Local results as you type (FTS5, works offline);
/// return also asks the servers, whose extra hits show under "On server".
struct SearchView: View {
    let model: AppModel
    let open: (Message) -> Void
    let close: () -> Void
    @Local private var text = ""
    @Local private var local: [Message] = []
    @Local private var server: [Message] = []
    @Local private var asking = false
    @Local private var took: Duration = .zero
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(T.teal)
                TextField("Search mail", text: $text).textFieldStyle(.plain).font(.system(size: 15)).focused($focused)
                    .onSubmit { Task { await askServer() } }
                    .onKeyPress(.escape) { close(); return .handled }
                if !text.isEmpty {
                    Text("\(local.count) results · \(Int(took.components.attoseconds / 1_000_000_000_000_000)) ms").font(.meta12).foregroundStyle(T.faint)
                }
            }
            .padding(.horizontal, 16).frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 6).fill(T.surface))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.teal))

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !local.isEmpty { header("From", "Subject", "Date") }
                    ForEach(local) { row($0) }
                    if asking || !server.isEmpty {
                        Text(asking ? "Asking the servers…" : "On server").font(.label11).foregroundStyle(T.faint).padding(.top, 24).padding(.bottom, 8)
                        ForEach(server) { row($0) }
                    }
                }
                .padding(.top, 16)
            }

            HStack {
                Text("return also searches older mail on the server").foregroundStyle(T.faint)
                Spacer()
                Text("Searches the local index. Works offline.").foregroundStyle(T.faint)
            }
            .font(.meta12).padding(.top, 16)
        }
        .font(.body13)
        .padding(.horizontal, 64).padding(.top, 32).padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { focused = true }
        .task(id: text) { search() }
    }

    func header(_ a: String, _ b: String, _ c: String) -> some View {
        HStack(spacing: 16) {
            Text(a).frame(width: 180, alignment: .leading)
            Text(b).frame(maxWidth: .infinity, alignment: .leading)
            Text(c).frame(width: 70, alignment: .leading)
        }
        .font(.label11).foregroundStyle(T.faint).padding(.horizontal, 4).padding(.bottom, 8)
    }

    func row(_ m: Message) -> some View {
        Button { open(m) } label: {
            HStack(spacing: 16) {
                Text(m.fromName.isEmpty ? m.fromAddr : m.fromName).fontWeight(m.seen ? .regular : .semibold).lineLimit(1).frame(width: 180, alignment: .leading)
                Text(m.subject.isEmpty ? "(no subject)" : m.subject).foregroundStyle(m.seen ? T.muted : T.text).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text(Row.time(m.date)).foregroundStyle(T.faint).frame(width: 70, alignment: .leading)
            }
            .padding(.horizontal, 4).padding(.vertical, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(T.line.opacity(0.6)).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func search() {
        server = []
        guard let store = model.store, let q = Store.ftsQuery(text) else { local = []; return }
        let start = ContinuousClock.now
        local = (try? store.db.read { db in
            try Message.fetchAll(db, sql: """
                SELECT message.* FROM message_fts JOIN message ON message.id = message_fts.rowid
                WHERE message_fts MATCH ? ORDER BY message.date DESC LIMIT 200
                """, arguments: [q])
        }) ?? []
        took = ContinuousClock.now - start
    }

    func askServer() async {
        guard !text.isEmpty, let store = model.store else { return }
        let before = Set(local.compactMap(\.id))
        asking = true
        let ids = await model.searchServer(text).filter { !before.contains($0) }
        asking = false
        server = ((try? await store.db.read { db in try Message.fetchAll(db, keys: ids) }) ?? []).sorted { $0.date > $1.date }
        let extra = Set(server.compactMap(\.id))
        local.removeAll { extra.contains($0.id ?? -1) }
    }
}
