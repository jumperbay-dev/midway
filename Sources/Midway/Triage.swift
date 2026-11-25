import GRDB
import MidwayCore
import SwiftUI

/// Screen "Snooze": a field for plain words ("fri 9") over numbered presets.
struct SnoozePicker: View {
    let snoozed: Bool
    let pick: (Date?, Bool) -> Void
    @Local private var text = ""
    @Local private var wakeOnReply = true
    @FocusState private var focused: Bool
    let choices = Snooze.choices()

    var parsed: Date? { Snooze.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Snooze until… try “fri 9” or “tomorrow 14”", text: $text)
                .textFieldStyle(.plain).focused($focused)
                .padding(.horizontal, 12).frame(height: 36)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.teal))
                .onSubmit { if let parsed { pick(parsed, wakeOnReply) } }
                .onKeyPress(characters: .decimalDigits) { press in
                    // Digits pick a preset until you start typing words.
                    guard text.isEmpty, let n = Int(press.characters), choices.indices.contains(n - 1) else { return .ignored }
                    pick(choices[n - 1].date, wakeOnReply)
                    return .handled
                }
                .padding(.bottom, 8)
            if !text.isEmpty {
                option(parsed.map(Snooze.label) ?? "Not a time yet", nil, parsed != nil) { if let parsed { pick(parsed, wakeOnReply) } }
            } else {
                ForEach(Array(choices.enumerated()), id: \.element) { i, c in
                    option(c.title, "\(i + 1)", true, detail: Snooze.label(c.date)) { pick(c.date, wakeOnReply) }
                }
                if snoozed { option("Unsnooze now", nil, true) { pick(nil, wakeOnReply) } }
            }
            Rectangle().fill(T.line).frame(height: 1).padding(.horizontal, -8).padding(.top, 8)
            Toggle("Bring back early if they reply", isOn: $wakeOnReply)
                .toggleStyle(.switch).controlSize(.mini).tint(T.teal)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).frame(height: 36).padding(.top, 4)
        }
        .font(.body13)
        .padding(8).frame(width: 336)
        .background(T.surface)
        .onAppear { focused = true }
    }

    func option(_ title: String, _ key: String?, _ enabled: Bool, detail: String? = nil, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).foregroundStyle(enabled ? T.text : T.faint)
                Spacer()
                if let detail { Text(detail).font(.meta12).foregroundStyle(T.faint) }
                if let key { Kbd(key: key) }
            }
            .padding(.horizontal, 12).frame(height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled)
    }
}

extension Snooze {
    /// "Wed 08:00", or "Mon 1 Dec 08:00" past this week.
    static func label(_ d: Date) -> String {
        d.timeIntervalSinceNow < 6 * 86400
            ? d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            : d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}

/// Screen "Command bar" (⌘K): one field over grouped commands, places and messages.
struct CommandBar: View {
    struct Command: Identifiable {
        let id = UUID()
        let group: String
        let title: String
        let key: String?
        let run: () -> Void
    }

    let model: AppModel
    let commands: [Command]
    let open: (Message) -> Void
    let close: () -> Void
    @Local private var text = ""
    @Local private var index = 0
    @Local private var hits: [Message] = []
    @FocusState private var focused: Bool

    /// Every typed word must appear in the title.
    var shown: [Command] {
        let words = text.lowercased().split(separator: " ")
        let matched = commands.filter { c in words.allSatisfy { c.title.lowercased().contains($0) } }
        return matched + hits.map { m in
            Command(group: "Messages", title: "\(m.fromName.isEmpty ? m.fromAddr : m.fromName) · \(m.subject)", key: nil) { open(m) }
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            T.scrim.onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.right").foregroundStyle(T.teal)
                    TextField("Type a command, a place or words from a message", text: $text)
                        .textFieldStyle(.plain).font(T.font(15)).focused($focused)
                        .onKeyPress(.downArrow) { index = min(index + 1, max(shown.count - 1, 0)); return .handled }
                        .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                        .onKeyPress(.escape) { close(); return .handled }
                        .onSubmit { run(index) }
                }
                .padding(.horizontal, 16).frame(height: 52)
                .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            let items = shown
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, c in
                                if i == 0 || items[i - 1].group != c.group {
                                    Text(c.group).font(.label11).foregroundStyle(T.faint).lineLimit(1)
                                        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
                                }
                                Button { run(i) } label: {
                                    HStack(spacing: 8) {
                                        Text(c.title).lineLimit(1)
                                        Spacer()
                                        if let key = c.key { Kbd(key: key) }
                                        if i == index { Kbd(key: "↩") }
                                    }
                                    .padding(.horizontal, 16).frame(height: 36)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(i == index ? T.sel : .clear))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).id(i)
                            }
                            if items.isEmpty {
                                Text("Nothing matches").foregroundStyle(T.faint).padding(16)
                            }
                        }
                    }
                    .frame(maxHeight: 420)
                    .onChange(of: index) { proxy.scrollTo(index) }
                }

                HStack(spacing: 16) {
                    HStack(spacing: 4) { Kbd(key: "↑"); Kbd(key: "↓"); Text("move") }
                    HStack(spacing: 4) { Kbd(key: "↩"); Text("run") }
                    HStack(spacing: 4) { Kbd(key: "esc"); Text("close") }
                }
                .font(.meta12).foregroundStyle(T.faint)
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(T.line).frame(height: 1) }
            }
            .font(.body13)
            .padding(8).frame(width: 600)
            .background(RoundedRectangle(cornerRadius: 8).fill(T.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.line))
            .padding(.top, 128)
        }
        .task { focused = true }  // after the overlay is in the hierarchy, or the list keeps focus
        .onChange(of: text) { index = 0; findMessages() }
    }

    func run(_ i: Int) {
        let items = shown
        guard items.indices.contains(i) else { return }
        close()
        items[i].run()
    }

    func findMessages() {
        guard text.count >= 2, let store = model.store, let q = Store.ftsQuery(text) else { hits = []; return }
        hits = (try? store.db.read { db in
            try Message.fetchAll(db, sql: """
                SELECT message.* FROM message_fts JOIN message ON message.id = message_fts.rowid
                WHERE message_fts MATCH ? ORDER BY message.date DESC LIMIT 5
                """, arguments: [q])
        }) ?? []
    }
}

/// The keyboard map (?), drawn like Settings › Keyboard.
// ponytail: read-only; rebinding comes with the Settings screens
struct KeyboardMap: View {
    let close: () -> Void
    static let bound = ["E": "archive", "R": "reply", "S": "star", "G": "go to", "J": "next", "K": "previous", "C": "compose",
                        "U": "unread", "Z": "undo", "L": "reply later", "H": "snooze", "Y": "set aside", "T": "tag"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard").font(.h2)
                Spacer()
                Button(action: close) { Kbd(key: "esc") }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
            }
            VStack(alignment: .leading, spacing: 8) {
                row("QWERTYUIOP", 0); row("ASDFGHJKL", 30); row("ZXCVBNM", 60)
            }
            .padding(.top, 24)
            HStack(alignment: .top, spacing: 48) {
                list("Keys", [("Delete", "#"), ("Search", "/"), ("This map", "?")])
                list("Sequences", [("Go to inbox", "g i"), ("Go to Screener", "g s")])
                list("In the Screener", [("Allow", "y"), ("Block", "n"), ("Allow and tag", "t")])
                list("With modifiers", [("Command bar", "⌘ K"), ("Send", "⌘ ↩"), ("Focus and reply", "⌘ ."), ("Undo", "⌘ Z"), ("Copy latest code", "⌥ ⌘ C")])
            }
            .padding(.top, 32)
            Spacer()
        }
        .font(.body13)
        .padding(.horizontal, 48).padding(.top, 48).padding(.bottom, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    func row(_ keys: String, _ pad: CGFloat) -> some View {
        HStack(spacing: 8) {
            ForEach(keys.map(String.init), id: \.self) { k in
                let label = Self.bound[k]
                VStack(alignment: .leading) {
                    Text(k).font(T.font(15, .semibold)).foregroundStyle(label == nil ? T.faint : T.teal)
                    Spacer()
                    Text(label ?? "").font(T.font(11)).foregroundStyle(label == nil ? T.faint : T.text).lineLimit(1)
                }
                .padding(8).frame(width: 64, height: 56, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(label == nil ? T.surface : T.teal.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(label == nil ? T.line : T.teal.opacity(0.6)))
            }
        }
        .padding(.leading, pad)
    }

    func list(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.label11).foregroundStyle(T.faint).padding(.bottom, 4)
            ForEach(rows, id: \.0) { r in
                HStack {
                    Text(r.0)
                    Spacer()
                    HStack(spacing: 4) { ForEach(r.1.split(separator: " ").map(String.init), id: \.self) { Kbd(key: $0) } }
                }
                .frame(width: 240, height: 36)
                .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
            }
        }
    }
}

/// Screen "Focus and reply" (⌘.): the Reply later pile on the left, one reply on the right, Send and next.
struct FocusView: View {
    let model: AppModel
    let close: () -> Void
    @Local private var pile: [Message] = []
    @Local private var selected: Int64?
    @Local private var draft: Draft?
    @Local private var body_ = NSAttributedString()
    @Local private var drafts: [Int64: Int64] = [:]  // message → draft
    @Local private var edited: Set<Int64> = []  // drafts you typed in
    @Local private var error: String?

    var current: Message? { pile.first { $0.id == selected } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("Focus and reply").font(.h1)
                Text("Reply later · \(pile.count)").font(.meta12).foregroundStyle(T.gold)
                Spacer()
                Button(action: leave) { Kbd(key: "esc") }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
            }
            .padding(.leading, 88).padding(.trailing, 32).frame(height: 56)  // clear of the window buttons
            .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView {
                        VStack(spacing: 12) { ForEach(pile) { card($0) } }
                    }
                    HStack(spacing: 16) {
                        HStack(spacing: 4) { Kbd(key: "⌘↩"); Text("send and next") }
                        HStack(spacing: 4) { Kbd(key: "esc"); Text("back to mail") }
                    }
                    .font(.meta12).foregroundStyle(T.faint)
                }
                .padding(.horizontal, 32).padding(.vertical, 24)
                .frame(width: 520)
                .overlay(alignment: .trailing) { Rectangle().fill(T.line).frame(width: 1) }

                reply
            }
        }
        .font(.body13)
        .task { await observe() }
        .onChange(of: selected) { load() }
        .onChange(of: body_) { save() }
    }

    func card(_ m: Message) -> some View {
        Button { selected = m.id } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(m.fromName.isEmpty ? m.fromAddr : m.fromName).fontWeight(.semibold).lineLimit(1)
                    Spacer()
                    Text(Row.time(m.date)).font(.meta12).foregroundStyle(T.faint)
                }
                Text(m.subject.isEmpty ? "(no subject)" : m.subject).fontWeight(.semibold).lineLimit(1)
                Text(m.preview).foregroundStyle(T.muted).lineLimit(3).padding(.top, 4)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(T.surface))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(m.id == selected ? T.teal : T.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder var reply: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let current, let draft {
                HStack {
                    Text("Reply to all · \(current.subject)").font(.label11).foregroundStyle(T.faint).lineLimit(1)
                    Spacer()
                    Text("from \(model.accounts.first { $0.id == draft.accountId }?.email ?? "")").font(.mono12).foregroundStyle(T.faint)
                }
                Text([draft.toList, draft.ccList].filter { !$0.isEmpty }.joined(separator: ", ")).font(.meta12).foregroundStyle(T.muted).lineLimit(1).padding(.top, 8)
                RichTextEditor(text: $body_).id(draft.id).padding(.top, 16)
                HStack(spacing: 12) {
                    if let error { Text(error).font(.meta12).foregroundStyle(T.gold) }
                    Spacer()
                    Button("Skip", action: next).buttonStyle(GhostButton())
                    Button("Send and next", action: send).buttonStyle(PrimaryButton()).keyboardShortcut(.return, modifiers: .command)
                }
                .padding(.top, 16)
                .overlay(alignment: .top) { Rectangle().fill(T.line).frame(height: 1) }
            } else {
                Text(pile.isEmpty ? "Nothing waiting for a reply." : "Pick a message.").foregroundStyle(T.faint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 32).padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    func observe() async {
        guard let store = model.store else { return }
        let obs = ValueObservation.tracking { db in try Box.replyLater.fetch(db, now: .now) }
        do {
            for try await rows in obs.values(in: store.db) {
                pile = rows
                if current == nil { selected = rows.first?.id }
            }
        } catch {}
    }

    /// Each message gets a reply-all draft the first time it is shown.
    func load() {
        error = nil
        guard let m = current, let id = m.id, let store = model.store else { draft = nil; return }
        if drafts[id] == nil { drafts[id] = model.newDraft(replyingTo: m, all: true) }
        draft = drafts[id].flatMap { try? store.draft($0) }
        body_ = RichText.attributed(draft?.rtf ?? Data())
    }

    func save() {
        guard var d = draft, let id = d.id, let store = model.store else { return }
        let rtf = RichText.rtf(body_)
        guard rtf != d.rtf else { return }
        d.rtf = rtf
        draft = try? store.save(d)
        edited.insert(id)
    }

    func send() {
        guard let d = draft, let m = current else { return }
        save()
        do {
            try model.send(d, body: body_)
            drafts[m.id!] = nil
            model.setPile(m) { $0.replyLater = false }
            next()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    func next() {
        let i = pile.firstIndex { $0.id == selected } ?? -1
        selected = pile.indices.contains(i + 1) ? pile[i + 1].id : pile.first { $0.id != selected }?.id
    }

    /// Drafts you never typed in are not kept.
    func leave() {
        for (_, d) in drafts where !edited.contains(d) { try? model.store?.deleteDraft(d) }
        close()
    }
}
