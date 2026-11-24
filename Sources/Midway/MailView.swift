import GRDB
import MidwayCore
import SwiftUI

/// Which list is showing: the unified Inbox, or one account's label (Gmail labels act as folders).
enum Box: Hashable {
    case inbox
    case label(account: Int64, name: String)

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .label(_, let name): Box.display(name)
        }
    }

    var query: (name: String, account: Int64?) {
        switch self {
        case .inbox: (Label.inbox, nil)
        case .label(let a, let n): (n, a)
        }
    }

    /// Gmail's system labels arrive as \Sent, \Starred…; user labels as they are.
    static func display(_ label: String) -> String {
        ["\\Sent": "Sent", "\\Starred": "Starred", "\\Important": "Important", "\\Draft": "Drafts"][label]
            ?? (label.hasPrefix("\\") ? String(label.dropFirst()) : label)
    }
}

/// Screen 01: sidebar 232, list 360, reader fills the rest. No toolbar; the keyboard does the rest.
struct MailView: View {
    let model: AppModel
    @Local private var box: Box = .inbox
    @Local private var messages: [Message] = []
    @Local private var selected: Int64?
    @FocusState private var focused: Bool

    var unread: Int { messages.count { !$0.seen } }
    var current: Message? { messages.first { $0.id == selected } }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model, box: $box)
            list
            Rectangle().fill(T.line).frame(width: 1)
            if let current, let store = model.store {
                Reader(message: current, store: store).id(current.id)
            } else {
                Text(messages.isEmpty ? "Nothing here yet" : "No message selected")
                    .foregroundStyle(T.faint).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea()
        .focusable().focused($focused).focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(characters: ["j", "k"]) { press in step(press.characters == "j" ? 1 : -1); return .handled }
        .onKeyPress(.downArrow) { step(1); return .handled }
        .onKeyPress(.upArrow) { step(-1); return .handled }
        .onChange(of: selected) { if let current { model.open(current) } }
        .onChange(of: box) { selected = nil; focused = true }
        .task(id: box) { await observe() }
        .sheet(isPresented: Bindable(model).adding) {
            AddAccount(model: model, back: { model.adding = false }).padding(.bottom, 48).background(T.bg)
        }
    }

    var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(box.title).font(.h1)
                Spacer()
                Text("\(unread) unread").font(.meta12).foregroundStyle(T.muted)
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
        guard let store = model.store else { return }
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
    @Local private var inboxUnread = 0
    @Local private var labels: [LabelRow] = []

    struct LabelRow: Hashable, FetchableRecord, Decodable {
        var accountId: Int64
        var name: String
        var unread: Int
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                item(.inbox, "Inbox", inboxUnread)
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
                if count > 0 { Text("\(count)").font(.meta12).foregroundStyle(b == .inbox ? T.teal : T.faint) }
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
            return (inbox, rows)
        }
        do {
            for try await (inbox, rows) in obs.values(in: store.db) { inboxUnread = inbox; labels = rows }
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
    @Local private var html: String?

    var initials: String {
        let name = message.fromName.isEmpty ? message.fromAddr : message.fromName
        return String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                hint("j", "next"); hint("k", "previous")
            }
            .font(.meta12).foregroundStyle(T.faint).padding(.top, 16)
        }
        .font(.body13)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { html = render() }
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
