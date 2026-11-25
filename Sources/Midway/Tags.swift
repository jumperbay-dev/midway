import AppKit
import GRDB
import MidwayCore
import SwiftUI
import UniformTypeIdentifiers

struct TagChip: View {
    let tag: Tag
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(T.tag(tag.colour)).frame(width: 6, height: 6)
            Text(tag.name)
        }
        .font(T.font(11)).foregroundStyle(T.muted)
        .padding(.horizontal, 8).frame(height: 18)
        .background(RoundedRectangle(cornerRadius: 4).fill(T.line.opacity(0.6)))
    }
}

/// "via shop+": which of your addresses the mail reached, when it is not the account's own.
struct ViaChip: View {
    let label: String
    var body: some View {
        Text("via \(label)").font(T.font(11, mono: true)).foregroundStyle(T.muted)
            .padding(.horizontal, 8).frame(height: 18)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(T.line))
    }
}

/// Screen 12: a fuzzy picker over the tags, with "Create tag" for a new name.
/// ↩ applies (or removes an applied tag), ⌘↩ applies and adds a rule for the sender.
struct TagPicker: View {
    let model: AppModel
    let title: String
    let applied: Set<Int64>
    let pick: (Tag, Bool) -> Void
    let close: () -> Void
    /// The message being tagged, for Claude's suggestions.
    var message: Message?
    @Local private var text = ""
    @Local private var index = 0
    @Local private var tags: [Tag] = []
    @Local private var counts: [Int64: Int] = [:]
    @FocusState private var focused: Bool

    enum Item { case tag(Tag), create(String) }

    var items: [Item] {
        let q = text.trimmingCharacters(in: .whitespaces)
        let matched = tags.filter { Self.fuzzy($0.name, q) }
            .sorted { a, b in a.name.lowercased().hasPrefix(q.lowercased()) && !b.name.lowercased().hasPrefix(q.lowercased()) }
        let exact = tags.contains { $0.name.lowercased() == q.lowercased() }
        return matched.map(Item.tag) + (q.isEmpty || exact ? [] : [.create(q)])
    }

    /// Every typed letter appears in the name, in order ("tra" finds Travel and Tax return).
    static func fuzzy(_ name: String, _ q: String) -> Bool {
        var rest = Substring(q.lowercased())
        for c in name.lowercased() where c == rest.first { rest = rest.dropFirst() }
        return rest.isEmpty
    }

    var body: some View {
        ZStack(alignment: .top) {
            T.scrim.onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "tag").foregroundStyle(T.teal)
                    TextField("Tag…", text: $text).textFieldStyle(.plain).font(T.font(15)).focused($focused)
                        .onKeyPress(.downArrow) { index = min(index + 1, max(items.count - 1, 0)); return .handled }
                        .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                        .onKeyPress(.escape) { close(); return .handled }
                        .onSubmit { choose(index, rule: NSEvent.modifierFlags.contains(.command)) }
                    Text(title).font(.meta12).foregroundStyle(T.faint).lineLimit(1)
                }
                .padding(.horizontal, 12).frame(height: 44)
                .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }

                if let message {
                    TagSuggest(model: model, message: message, pick: { name in
                        guard let tag = tags.first(where: { $0.name.lowercased() == name.lowercased() }) ?? (try? model.store?.createTag(name)) else { return }
                        close(); pick(tag, false)
                    }, rule: { query, name in
                        guard let store = model.store, let tag = tags.first(where: { $0.name.lowercased() == name.lowercased() }) ?? (try? store.createTag(name)), let id = tag.id else { return }
                        _ = try? store.addRule(query, tag: id)
                        _ = try? store.rerun(tag: id)
                        close(); model.notice = "Rule added: \(query) → \(tag.name)"
                    })
                }

                VStack(alignment: .leading, spacing: 0) {
                    let all = items
                    ForEach(Array(all.enumerated()), id: \.offset) { i, item in
                        Button { choose(i, rule: false) } label: {
                            HStack(spacing: 12) {
                                switch item {
                                case .tag(let t):
                                    Circle().fill(T.tag(t.colour)).frame(width: 8, height: 8)
                                    Text(t.name)
                                    Spacer()
                                    if applied.contains(t.id ?? -1) { Image(systemName: "checkmark").font(T.font(11)).foregroundStyle(T.teal) }
                                    Text("\(counts[t.id ?? -1] ?? 0)").font(.meta12).foregroundStyle(T.faint)
                                case .create(let name):
                                    Text("+").foregroundStyle(T.teal).frame(width: 8)
                                    Text("Create tag “\(name)”")
                                    Spacer()
                                }
                                if i == index { Kbd(key: "↩") }
                            }
                            .padding(.horizontal, 12).frame(height: 36)
                            .background(RoundedRectangle(cornerRadius: 4).fill(i == index ? T.sel : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if all.isEmpty { Text("Type a name to create a tag").foregroundStyle(T.faint).padding(12) }
                }
                .padding(.vertical, 8)

                HStack(spacing: 16) {
                    HStack(spacing: 4) { Kbd(key: "↩"); Text("apply") }
                    HStack(spacing: 4) { Kbd(key: "⌘↩"); Text("apply and make a rule") }
                    HStack(spacing: 4) { Kbd(key: "esc"); Text("close") }
                }
                .font(.meta12).foregroundStyle(T.faint)
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(T.line).frame(height: 1) }
            }
            .font(.body13)
            .padding(12).frame(width: 440)
            .background(RoundedRectangle(cornerRadius: 8).fill(T.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.line))
            .padding(.top, 120)
        }
        .task { load(); focused = true }
        .onChange(of: text) { index = 0 }
    }

    func load() {
        guard let store = model.store else { return }
        (tags, counts) = (try? store.db.read { db in
            (try Tag.fetchAll(db, sql: "SELECT * FROM tag ORDER BY name"),
             Dictionary(uniqueKeysWithValues: try GRDB.Row.fetchAll(db, sql: "SELECT tagId, COUNT(*) AS n FROM tag_link GROUP BY tagId").map { ($0["tagId"] as Int64, $0["n"] as Int) }))
        }) ?? ([], [:])
    }

    func choose(_ i: Int, rule: Bool) {
        let all = items
        guard all.indices.contains(i), let store = model.store else { return }
        let tag: Tag? = switch all[i] {
        case .tag(let t): t
        case .create(let name): try? store.createTag(name)
        }
        close()
        if let tag { pick(tag, rule) }
    }
}

/// "matches 41 messages", or what is wrong with the query.
struct RulePreview: View {
    let model: AppModel
    let query: String

    var body: some View {
        let text: (String, Color) = {
            do {
                let n = try model.store?.count(Query(query)) ?? 0
                return ("matches \(n) message\(n == 1 ? "" : "s")", T.faint)
            } catch {
                return ((error as? LocalizedError)?.errorDescription ?? "Not a query yet", T.gold)
            }
        }()
        Text(text.0).font(.meta12).foregroundStyle(text.1).lineLimit(1)
    }
}

/// Screen 10: tags on the left; colour, rules and re-run for the selected one on the right.
struct TagsView: View {
    let model: AppModel
    @Binding var box: Box
    @Local var selected: Int64?
    @Local private var tags: [Tag] = []
    @Local private var counts: [Int64: Int] = [:]
    @Local private var ruleCounts: [Int64: Int] = [:]
    @Local private var rules: [TagRule] = []
    @Local private var matches: [Int64: Int] = [:]
    @Local private var pending = 0
    @Local private var name = ""
    @Local private var nameFor: Int64?
    @Local private var newRule = ""
    @Local private var error: String?

    init(model: AppModel, box: Binding<Box>, selected: Int64?) {
        self.model = model
        _box = box
        _selected = Local(initialValue: selected)
    }

    var current: Tag? { tags.first { $0.id == selected } }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Tags").font(.h1)
                    Spacer()
                    Button("New tag", action: newTag).buttonStyle(OutlineButton())
                }
                .padding(.horizontal, 8).frame(height: 56)
                HStack(spacing: 8) {
                    Image(systemName: "lock").font(T.font(10))
                    Text("Stored on this Mac only. Never sent to a server.")
                }
                .font(.meta12).foregroundStyle(T.faint).padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(tags) { t in
                            Button { selected = t.id } label: {
                                HStack(spacing: 12) {
                                    Circle().fill(T.tag(t.colour)).frame(width: 8, height: 8)
                                    Text(t.name).lineLimit(1)
                                    Spacer()
                                    let r = ruleCounts[t.id!] ?? 0
                                    Text("\(r == 0 ? "manual" : r == 1 ? "1 rule" : "\(r) rules") · \(counts[t.id!] ?? 0)")
                                        .font(.meta12).foregroundStyle(selected == t.id ? T.text : T.faint)
                                }
                                .padding(.horizontal, 16).frame(height: 44)
                                .background(RoundedRectangle(cornerRadius: 10).fill(selected == t.id ? T.sel : .clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if let error { Text(error).font(.meta12).foregroundStyle(T.gold).padding(.horizontal, 8) }
                HStack(spacing: 8) {
                    Button("Export tags…", action: export).buttonStyle(OutlineButton())
                    Button("Import", action: importFile).buttonStyle(GhostButton())
                }
                .padding(.horizontal, 8).padding(.vertical, 16)
            }
            .padding(.horizontal, 12)
            .frame(width: 340)
            .overlay(alignment: .trailing) { Rectangle().fill(T.line).frame(width: 1) }

            if let tag = current { detail(tag) } else {
                Text(tags.isEmpty ? "No tags yet. Press t on a message, or New tag." : "Pick a tag")
                    .foregroundStyle(T.faint).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .font(.body13)
        .task(id: selected) { await observe() }
    }

    func detail(_ tag: Tag) -> some View {
        let colour = T.tag(tag.colour)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 6).fill(colour.opacity(0.15))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(colour.opacity(0.5)))
                    .overlay(Circle().fill(colour).frame(width: 12, height: 12))
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Name", text: $name).textFieldStyle(.plain).font(.h2)
                        .onSubmit(rename)
                    Text("\(counts[tag.id!] ?? 0) messages").font(.meta12).foregroundStyle(T.muted)
                }
                Spacer()
                Button("Show messages") { box = .tag(tag.id!, name: tag.name) }.buttonStyle(OutlineButton())
            }
            HStack(spacing: 8) {
                Text("Colour").font(.meta12).foregroundStyle(T.faint).frame(width: 60, alignment: .leading)
                ForEach(0..<8, id: \.self) { i in
                    Circle().fill(T.tag(i)).frame(width: 16, height: 16)
                        .overlay(Circle().stroke(T.text, lineWidth: i == tag.colour ? 2 : 0).padding(-3))
                        .padding(3)
                        .onTapGesture { var t = tag; t.colour = i; try? model.store?.save(t) }
                }
            }
            .padding(.top, 24)

            Text("RULES · TAG WHEN ANY MATCH").font(.label11).foregroundStyle(T.faint).padding(.top, 32)
            VStack(spacing: 8) {
                ForEach(rules) { r in
                    HStack(spacing: 12) {
                        Text(r.query).font(.mono12).lineLimit(1)
                        Spacer()
                        Text("\(matches[r.id!] ?? 0) matches").font(.meta12).foregroundStyle(T.faint)
                        Toggle("", isOn: Binding(get: { r.enabled }, set: { try? model.store?.setRule(r.id!, enabled: $0) }))
                            .toggleStyle(.switch).controlSize(.mini).labelsHidden().tint(T.teal)
                        Button { try? model.store?.deleteRule(r.id!) } label: { Image(systemName: "xmark").font(T.font(10)) }
                            .buttonStyle(GhostButton()).help("Remove rule")
                    }
                    .padding(.horizontal, 16).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 10).fill(T.surface))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(T.line))
                }
                HStack(spacing: 12) {
                    TextField("Add a rule: via:shop+ subject:booking, domain:…, list:…, from:…", text: $newRule)
                        .textFieldStyle(.plain).font(.mono12)
                        .onSubmit(addRule)
                    if !newRule.isEmpty {
                        RulePreview(model: model, query: newRule)
                        Button("Add rule", action: addRule).buttonStyle(GhostButton())
                    }
                }
                .padding(.horizontal, 16).frame(height: 44)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(T.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
            .padding(.top, 12)

            if pending > 0 {
                HStack(spacing: 16) {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(T.teal)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Re-run rules on existing mail")
                        Text("Adds \(tag.name) to \(pending) more message\(pending == 1 ? "" : "s"). Manual tags are never removed.").font(.meta12).foregroundStyle(T.faint)
                    }
                    Spacer()
                    Button("Apply") { try? model.store?.rerun(tag: tag.id!) }.buttonStyle(PrimaryButton())
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 10).fill(T.surface))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(T.line))
                .padding(.top, 24)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Delete tag") { try? model.store?.deleteTag(tag.id!); selected = nil }.buttonStyle(GhostButton())
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    func newTag() {
        guard let store = model.store else { return }
        let names = Set(tags.map { $0.name.lowercased() })
        let name = (1...).lazy.map { $0 == 1 ? "New tag" : "New tag \($0)" }.first { !names.contains($0.lowercased()) }!
        selected = (try? store.createTag(name))?.id
    }

    func rename() {
        guard var t = current, !name.trimmingCharacters(in: .whitespaces).isEmpty else { name = current?.name ?? ""; return }
        t.name = name.trimmingCharacters(in: .whitespaces)
        do { try model.store?.save(t); error = nil } catch { self.error = "A tag with that name exists."; name = current?.name ?? "" }
    }

    func addRule() {
        guard let id = selected else { return }
        do {
            try model.store?.addRule(newRule, tag: id)
            newRule = ""
        } catch {}
    }

    func export() {
        guard let store = model.store else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "midway tags.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.exportTags().write(to: url, options: .atomic); error = nil } catch { self.error = "Export failed: \(error.localizedDescription)" }
    }

    func importFile() {
        guard let store = model.store else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.importTags(Data(contentsOf: url)); error = nil } catch { self.error = "That file is not a midway tag export." }
    }

    func observe() async {
        guard let store = model.store else { return }
        let id = selected
        let obs = ValueObservation.tracking { db in
            func counts(_ sql: String) throws -> [Int64: Int] {
                Dictionary(uniqueKeysWithValues: try GRDB.Row.fetchAll(db, sql: sql).map { ($0[0] as Int64, $0[1] as Int) })
            }
            return (try Tag.fetchAll(db, sql: "SELECT * FROM tag ORDER BY name"),
                    try counts("SELECT tagId, COUNT(*) FROM tag_link GROUP BY tagId"),
                    try counts("SELECT tagId, COUNT(*) FROM tag_rule WHERE tagId IS NOT NULL GROUP BY tagId"),
                    try TagRule.fetchAll(db, sql: "SELECT * FROM tag_rule WHERE tagId = ? ORDER BY id", arguments: [id]))
        }
        do {
            for try await (t, c, rc, r) in obs.values(in: store.db) {
                (tags, counts, ruleCounts, rules) = (t, c, rc, r)
                matches = Dictionary(uniqueKeysWithValues: r.map { ($0.id!, (try? store.count(Query($0.query))) ?? 0) })
                pending = id.flatMap { try? store.pendingRerun(tag: $0) } ?? 0
                if selected == nil { selected = t.first?.id }
                if nameFor != selected { name = current?.name ?? ""; nameFor = selected }
            }
        } catch {}
    }
}
