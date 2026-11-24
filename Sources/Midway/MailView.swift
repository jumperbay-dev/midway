import GRDB
import MidwayCore
import SwiftUI

/// Which list is showing: the unified Inbox, local drafts, or one account's label (Gmail labels act as folders).
enum Box: Hashable {
    case inbox
    case drafts
    case label(account: Int64, name: String)

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .drafts: "Drafts"
        case .label(_, let name): Box.display(name)
        }
    }

    var query: (name: String, account: Int64?) {
        switch self {
        case .inbox, .drafts: (Label.inbox, nil)
        case .label(let a, let n): (n, a)
        }
    }

    /// Gmail's system labels arrive as \Sent, \Starred…; user labels as they are.
    static func display(_ label: String) -> String {
        ["\\Sent": "Sent", "\\Starred": "Starred", "\\Important": "Important", "\\Draft": "Gmail drafts", "\\Trash": "Trash"][label]
            ?? (label.hasPrefix("\\") ? String(label.dropFirst()) : label)
    }
}

/// Screen 01: sidebar 232, list 360, reader fills the rest. The keyboard does the rest.
struct MailView: View {
    let model: AppModel
    @Local private var box: Box = .inbox
    @Local private var messages: [Message] = []
    @Local private var selected: Int64?
    @Local private var searching = false
    @Local private var toast: String?
    @FocusState private var focused: Bool
    @Environment(\.openWindow) private var openWindow

    var unread: Int { messages.count { !$0.seen } }
    var current: Message? { messages.first { $0.id == selected } }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model, box: $box, compose: { compose(nil) })
            if searching {
                SearchView(model: model, open: { m in box = .inbox; searching = false; selected = m.id }, close: { searching = false; focused = true })
            } else if box == .drafts {
                DraftsList(model: model)
            } else {
                list
                Rectangle().fill(T.line).frame(width: 1)
                if let current, let store = model.store {
                    Reader(message: current, store: store, act: act, reply: { compose(current) }).id(current.id)
                } else {
                    Text(messages.isEmpty ? "Nothing here yet" : "No message selected")
                        .foregroundStyle(T.faint).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .overlay(alignment: .bottom) { Toasts(model: model, toast: $toast, openWindow: { openWindow(id: "compose", value: $0) }) }
        .ignoresSafeArea()
        .focusable().focused($focused).focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(characters: ["j", "k"]) { press in step(press.characters == "j" ? 1 : -1); return .handled }
        .onKeyPress(.downArrow) { step(1); return .handled }
        .onKeyPress(.upArrow) { step(-1); return .handled }
        .onKeyPress(characters: ["e", "#", "s", "u", "r", "c", "/"]) { press in key(press.characters) }
        .onKeyPress(characters: ["z"]) { press in
            guard press.modifiers.contains(.command), model.last != nil else { return .ignored }
            model.undo(); toast = nil; return .handled
        }
        .onChange(of: selected) { if let current { model.open(current) } }
        .onChange(of: box) { selected = nil; searching = false; focused = true }
        .task(id: box) { await observe() }
        .sheet(isPresented: Bindable(model).adding) {
            AddAccount(model: model, back: { model.adding = false }).padding(.bottom, 48).background(T.bg)
        }
    }

    func key(_ c: String) -> KeyPress.Result {
        switch c {
        case "/": searching = true
        case "c": compose(nil)
        case "r": if let current { compose(current) }
        case "e", "#", "s", "u":
            guard let current else { return .ignored }
            act(c == "e" ? .archive : c == "#" ? .trash : c == "s" ? .flagged : .seen, current)
        default: return .ignored
        }
        return .handled
    }

    /// Archive and delete move the selection on; star and unread toggle in place.
    func act(_ kind: OpKind, _ m: Message) {
        let value = switch kind { case .flagged: !m.flagged; case .seen: !m.seen; default: true }
        if kind == .archive || kind == .trash {
            let i = messages.firstIndex { $0.id == m.id } ?? 0
            selected = messages.indices.contains(i + 1) ? messages[i + 1].id : i > 0 ? messages[i - 1].id : nil
        }
        model.act(kind, value, m)
        toast = switch kind {
        case .archive: "Archived"
        case .trash: "Moved to Trash"
        case .flagged: value ? "Starred" : "Unstarred"
        case .seen: value ? "Marked read" : "Marked unread"
        }
        focused = true
    }

    func compose(_ replyTo: Message?) {
        if let id = model.newDraft(replyingTo: replyTo) { openWindow(id: "compose", value: id) }
    }

    var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(box.title).font(.h1)
                Spacer()
                Text("\(unread) unread").font(.meta12).foregroundStyle(T.muted)
                Button { searching = true } label: { Kbd(key: "/") }.buttonStyle(.plain).help("Search (/)").accessibilityLabel("Search")
            }
            .padding(.horizontal, 16).frame(height: 56)
            .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(messages) { m in
                            Row(message: m, selected: m.id == selected)
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
        guard let store = model.store, box != .drafts else { return }
        let q = box.query
        let obs = ValueObservation.tracking { db in
            try Message.fetchAll(db, sql: """
                SELECT message.* FROM message JOIN label ON label.messageId = message.id
                WHERE label.name = ? AND (? IS NULL OR message.accountId = ?)
                ORDER BY message.date DESC
                """, arguments: [q.name, q.account, q.account])
        }
        do {
            for try await rows in obs.values(in: store.db) { messages = rows }
        } catch {}
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
    let compose: () -> Void
    @Local private var inboxUnread = 0
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
        .task { await observe() }
    }

    func item(_ b: Box, _ title: String, _ count: Int) -> some View {
        Button { box = b } label: {
            HStack {
                Text(title).lineLimit(1)
                Spacer()
                if count > 0 { Text("\(count)").font(.meta12).foregroundStyle(b == .inbox ? T.teal : b == .drafts && failed > 0 ? T.gold : T.faint) }
            }
            .padding(.horizontal, 12).frame(height: b == .inbox ? 32 : 28)
            .background(RoundedRectangle(cornerRadius: 4).fill(box == b ? T.sel : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func observe() async {
        guard let store = model.store else { return }
        let obs = ValueObservation.tracking { db in
            let inbox = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM message JOIN label ON label.messageId = message.id
                WHERE label.name = ? AND message.seen = 0
                """, arguments: [Label.inbox]) ?? 0
            let rows = try LabelRow.fetchAll(db, sql: """
                SELECT message.accountId, label.name, SUM(message.seen = 0) AS unread
                FROM label JOIN message ON message.id = label.messageId
                WHERE label.name != ? GROUP BY message.accountId, label.name ORDER BY label.name
                """, arguments: [Label.inbox])
            let drafts = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM draft") ?? 0
            let failed = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox WHERE error IS NOT NULL") ?? 0
            return (inbox, rows, drafts, failed)
        }
        do {
            for try await (inbox, rows, d, f) in obs.values(in: store.db) { inboxUnread = inbox; labels = rows; drafts = d; failed = f }
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
    let act: (OpKind, Message) -> Void
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
                hint("e", "archive"); hint("#", "delete"); hint("s", "star"); hint("r", "reply"); hint("/", "search"); hint("⌘Z", "undo")
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
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(icon == "star.fill" ? T.gold : T.muted)
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
