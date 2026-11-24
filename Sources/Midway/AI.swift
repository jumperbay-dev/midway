import AppKit
import MidwayCore
import SwiftUI

/// The summary card pinned above a message (screen 02), one at a time.
struct AICard {
    var messageId: Int64
    var preview: String
    var state: State
    var started = Date.now
    enum State { case running, summary(AI.Summary), failed(String), raw(String) }
}

extension AppModel {
    func detectAI() async {
        let d = await Engine.claude.detect(override: aiPath)
        engine = d
        await ai.configure(path: d.path, version: d.version, model: aiModel)
    }

    /// Why AI can't run for this account right now, or nil.
    func aiBlocked(_ account: Int64) -> String? {
        guard accounts.first(where: { $0.id == account })?.ai == true else { return AIError.off.errorDescription }
        guard let engine else { return "Looking for Claude Code…" }
        return engine.problem
    }

    func setAI(_ account: Int64, _ on: Bool) {
        try? store?.setAI(account, on)
        if let i = accounts.firstIndex(where: { $0.id == account }) { accounts[i].ai = on }
    }

    /// `a` in the reader: summary and "asked of you" for the thread.
    func summarise(_ m: Message) {
        guard let id = m.id, let store else { return }
        cancelAI()
        if let why = aiBlocked(m.accountId) { aiCard = AICard(messageId: id, preview: "", state: .failed(why)); return }
        let mails = (try? store.thread(m)) ?? []
        let request = AI.summarise(mails, redact: aiRedact)
        aiCard = AICard(messageId: id, preview: request.preview, state: .running)
        aiTask = Task {
            do {
                let s = try await ai.ask(request, as: AI.Summary.self)
                aiCard?.state = .summary(s)
            } catch is CancellationError {
            } catch AIError.raw(let text) {
                aiCard?.state = .raw(text)
            } catch {
                aiCard?.state = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
    }

    func cancelAI() {
        aiTask?.cancel()
        aiTask = nil
        aiCard = nil
    }

    func addToCalendar(_ e: AI.Event) {
        guard let ics = e.ics() else { notice = "Could not read the date “\(e.start)”"; return }
        let url = FileManager.default.temporaryDirectory.appending(path: "midway-\(UUID().uuidString).ics")
        guard (try? ics.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        NSWorkspace.shared.open(url)
    }
}

struct AICardView: View {
    let card: AICard
    let model: AppModel
    let reply: () -> Void
    @Local private var done: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "sparkle").foregroundStyle(T.teal)
                Text("Thread summary · Claude").font(.label11).foregroundStyle(T.teal)
                Spacer()
                if case .running = card.state {
                    TimelineView(.periodic(from: .now, by: 0.1)) { t in
                        Text("reading… \(t.date.timeIntervalSince(card.started), specifier: "%.1f") s").font(.meta12).foregroundStyle(T.faint)
                    }
                }
                Button { model.cancelAI() } label: { Kbd(key: "esc") }.buttonStyle(.plain).help("Close (esc)")
            }
            switch card.state {
            case .running:
                EmptyView()
            case .failed(let why):
                Text(why).foregroundStyle(T.gold).padding(.top, 12).textSelection(.enabled)
            case .raw(let text):
                Text(text).foregroundStyle(T.body).padding(.top, 12).textSelection(.enabled)
            case .summary(let s):
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(s.summary, id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•").foregroundStyle(T.faint); Text(line) }
                    }
                }
                .foregroundStyle(T.body).textSelection(.enabled).padding(.top, 12)
                if !s.asks.isEmpty {
                    Text("ASKED OF YOU").font(.label11).foregroundStyle(T.muted).padding(.top, 16)
                    // ponytail: ticks live as long as the card; a to-do list is its own feature
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(s.asks, id: \.self) { ask in
                            Button { done.formSymmetricDifference([ask]) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: done.contains(ask) ? "checkmark.square.fill" : "square").foregroundStyle(T.teal)
                                    Text(ask).strikethrough(done.contains(ask)).foregroundStyle(done.contains(ask) ? T.faint : T.text)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 8)
                }
                HStack(spacing: 8) {
                    Button("Draft reply", action: reply).buttonStyle(PrimaryButton())
                    if let e = s.event, let d = e.startDate {
                        Button("Add \(d.formatted(.dateTime.weekday().hour().minute())) to calendar") { model.addToCalendar(e) }.buttonStyle(OutlineButton())
                    }
                }
                .padding(.top, 16)
            }
            if !card.preview.isEmpty {
                Text(card.preview).font(.meta12).foregroundStyle(T.faint).padding(.top, 12)
            }
        }
        .font(.body13)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(T.teal.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.teal.opacity(0.4)))
    }
}

/// In the composer (screen 04): a one-line intent and Draft for replies, Polish for what you wrote.
/// The suggestion streams into a card; nothing reaches the body until Use.
struct ComposeAI: View {
    let model: AppModel
    let draft: Draft
    @Binding var body_: NSAttributedString
    @Local private var intent = ""
    @Local private var text = ""
    @Local private var running: Task<Void, Never>?
    @Local private var started = Date.now
    @Local private var error: String?
    @Local private var preview = ""
    @Local private var isDraft = true

    /// What you wrote, before the quoted message the reply starts with.
    var mine: String {
        let s = body_.string
        return String(s[..<(s.range(of: "\n\nOn ")?.lowerBound ?? s.endIndex)])
    }

    var body: some View {
        if let why = model.aiBlocked(draft.accountId) {
            if model.accounts.first(where: { $0.id == draft.accountId })?.ai == true {
                Text(why).font(.meta12).foregroundStyle(T.faint).padding(.top, 12)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "sparkle").foregroundStyle(T.teal)
                    if let store = model.store, source(store) != nil {
                        TextField("What should the reply say?", text: $intent).textFieldStyle(.plain).onSubmit(runDraft)
                        Button("Draft", action: runDraft).buttonStyle(OutlineButton())
                    } else {
                        Text("Claude").foregroundStyle(T.muted)
                        Spacer()
                    }
                    if !mine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Polish") { polish(mine, "make it clear and friendly, fix spelling and grammar") }.buttonStyle(OutlineButton())
                    }
                }
                .padding(.horizontal, 16).frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 6).fill(T.surface))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.line))

                if running != nil || !text.isEmpty || error != nil { card }
            }
            .padding(.top, 16)
            .onKeyPress(.escape) { guard running != nil || !text.isEmpty else { return .ignored }; discard(); return .handled }
        }
    }

    var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(isDraft ? "Draft · Claude Code" : "Polished · Claude Code").font(.label11).foregroundStyle(T.teal)
                Spacer()
                if running != nil {
                    TimelineView(.periodic(from: .now, by: 0.1)) { t in
                        Text("writing… \(t.date.timeIntervalSince(started), specifier: "%.1f") s").font(.meta12).foregroundStyle(T.faint)
                    }
                }
            }
            if let error {
                Text(error).foregroundStyle(T.gold).padding(.top, 12)
            } else {
                Text(text.isEmpty ? " " : text).font(.system(size: 15)).lineSpacing(6).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            }
            HStack(spacing: 8) {
                Button { use() } label: { HStack(spacing: 6) { Text("Use draft"); Text("⌘⇧↩").font(.system(size: 10)) } }
                    .buttonStyle(PrimaryButton()).keyboardShortcut(.return, modifiers: [.command, .shift]).disabled(running != nil || text.isEmpty)
                Button("Shorter") { polish(text, "make it shorter") }.buttonStyle(OutlineButton()).disabled(running != nil || text.isEmpty)
                Button("Warmer") { polish(text, "make it warmer") }.buttonStyle(OutlineButton()).disabled(running != nil || text.isEmpty)
                Spacer()
                Button(running != nil ? "Stop" : "Discard") { discard() }.buttonStyle(GhostButton())
            }
            .padding(.top, 16)
            Text(preview).font(.meta12).foregroundStyle(T.faint).padding(.top, 12)
        }
        .font(.body13)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 6).fill(T.teal.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.teal.opacity(0.4)))
        .padding(.top, 16)
    }

    func runDraft() {
        guard let store = model.store, let m = source(store) else { return }
        let me = model.accounts.first { $0.id == draft.accountId }?.email ?? "me"
        isDraft = true
        start(AI.draft((try? store.thread(m)) ?? [], intent: intent, me: me, redact: model.aiRedact))
    }

    func source(_ store: Store) -> Message? {
        if let id = model.replySource[draft.id ?? -1], let m = try? store.db.read({ try Message.fetchOne($0, key: id) }) { return m }
        return draft.inReplyTo.flatMap { try? store.message(withMessageId: $0) }
    }

    func polish(_ source: String, _ how: String) {
        isDraft = false
        start(AI.polish(source, how: how, redact: model.aiRedact))
    }

    func start(_ r: AIRequest) {
        running?.cancel()
        text = ""; error = nil; started = .now; preview = r.preview
        let ai = model.ai
        running = Task {
            do {
                let result = try await ai.run(r) { delta in Task { @MainActor in text += delta } }
                text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch is CancellationError {
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            running = nil
        }
    }

    /// A draft goes above the quote; a polish replaces what you wrote.
    func use() {
        let out = NSMutableAttributedString(attributedString: body_)
        let replace = isDraft ? NSRange(location: 0, length: 0) : NSRange(location: 0, length: (mine as NSString).length)
        out.replaceCharacters(in: replace, with: NSAttributedString(string: text, attributes: RichText.base))
        body_ = out
        discard()
    }

    func discard() {
        running?.cancel()
        running = nil
        text = ""; error = nil
    }
}

/// In the tag picker: Claude proposes tags and maybe a rule; a click applies one.
struct TagSuggest: View {
    let model: AppModel
    let message: Message
    let pick: (String) -> Void
    let rule: (String, String) -> Void
    @Local private var state: Result<AI.TagSuggestion, AIError>?
    @Local private var running = false

    var body: some View {
        if model.aiBlocked(message.accountId) == nil {
            HStack(spacing: 8) {
                Image(systemName: "sparkle").foregroundStyle(T.teal)
                switch state {
                case nil:
                    Button(running ? "Asking Claude…" : "Suggest tags") { suggest() }.buttonStyle(GhostButton()).disabled(running)
                case .failure(let e):
                    Text(e.errorDescription ?? "").font(.meta12).foregroundStyle(T.gold).lineLimit(1)
                case .success(let s):
                    ForEach(s.tags, id: \.self) { t in Button(t) { pick(t) }.buttonStyle(OutlineButton()) }
                    if let r = s.rule, let first = s.tags.first {
                        Button { rule(r, first) } label: { Text("Rule: \(r)").font(.mono12).lineLimit(1) }.buttonStyle(GhostButton()).help("Add this rule for \(first)")
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12).frame(height: 40)
            .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
        }
    }

    func suggest() {
        guard let store = model.store, let raw = try? store.raw(message) else { return }
        let p = MIME.parse(raw)
        let existing = (try? store.db.read { try String.fetchAll($0, sql: "SELECT name FROM tag ORDER BY name") }) ?? []
        let r = AI.suggestTags(from: message.fromAddr, via: message.via, subject: message.subject, text: AI.text(p), existing: existing, redact: model.aiRedact)
        running = true
        let ai = model.ai
        Task {
            do {
                var s = try await ai.ask(r, as: AI.TagSuggestion.self)
                if let q = s.rule, (try? Query(q)) == nil { s.rule = nil }  // only rules midway can run
                state = .success(s)
            } catch is CancellationError {
            } catch {
                state = .failure(error as? AIError ?? .failed("\(error)"))
            }
            running = false
        }
    }
}

/// Settings ▸ AI engines (screen 22): detect, test run on a sample, preview, and the per-account switch.
struct AISettings: View {
    let model: AppModel
    @Local private var testing = false
    @Local private var test: String?
    @Local private var runs: [AIRun] = []
    @Local private var showPreview = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("AI engines").font(.h2)
                Text("midway runs the command-line tools you already use. It stores no keys; each tool uses its own sign-in.")
                    .foregroundStyle(T.muted).padding(.top, 8)
                engineCard.padding(.top, 24)

                Text("ACCOUNTS").font(.label11).foregroundStyle(T.muted).padding(.top, 24)
                ForEach(model.accounts, id: \.id) { a in
                    HStack {
                        Text(a.email).font(.mono12)
                        Spacer()
                        Toggle("Send to AI", isOn: Binding(get: { a.ai }, set: { model.setAI(a.id!, $0) }))
                            .toggleStyle(.switch).controlSize(.mini).tint(T.teal)
                    }
                    .padding(.vertical, 8)
                    .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
                }
                Text("Off means this account's mail is never sent to AI.").font(.meta12).foregroundStyle(T.faint).padding(.top, 8)

                Toggle(isOn: Bindable(model).aiRedact) {
                    VStack(alignment: .leading) {
                        Text("Redact addresses and phone numbers")
                        Text("before anything is sent").font(.meta12).foregroundStyle(T.faint)
                    }
                }
                .toggleStyle(.switch).controlSize(.mini).tint(T.teal).padding(.top, 16)

                HStack {
                    Text("Model")
                    TextField("sonnet", text: Bindable(model).aiModel).textFieldStyle(.roundedBorder).frame(width: 160)
                        .onSubmit { Task { await model.detectAI() } }
                }
                .padding(.top, 16)

                log.padding(.top, 24)
            }
            .padding(32)
        }
        .font(.body13)
        .frame(width: 640, height: 640)
        .background(T.bg)
        .foregroundStyle(T.text)
        .preferredColorScheme(.dark)
        .task { runs = (try? model.store?.runs()) ?? [] }
    }

    var engineCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Claude Code").font(.h1)
                Spacer()
                let e = model.engine
                Text(e == nil ? "looking…" : e!.ready ? "ready" : e!.path == nil ? "not found" : e!.loggedIn ? "too old" : "signed out")
                    .font(.meta12).foregroundStyle(e?.ready == true ? T.teal : T.gold)
                    .padding(.horizontal, 8).frame(height: 20)
                    .overlay(Capsule().stroke(e?.ready == true ? T.teal.opacity(0.5) : T.line))
            }
            if let e = model.engine {
                if let p = e.path { Text(p).font(.mono12).foregroundStyle(T.faint).padding(.top, 8) }
                Text([e.version.map { "version \($0)" }, model.aiPath.isEmpty ? "found through your login shell" : "path set by you", e.loggedIn ? "signed in" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.meta12).foregroundStyle(T.faint).padding(.top, 4)
                if let problem = e.problem { Text(problem).font(.meta12).foregroundStyle(T.gold).padding(.top, 8).textSelection(.enabled) }
            }
            HStack(spacing: 8) {
                Button(testing ? "Testing…" : "Test run") { testRun() }.buttonStyle(OutlineButton()).disabled(testing || model.engine?.ready != true)
                Button("Preview") { showPreview.toggle() }.buttonStyle(GhostButton())
                Button("Change path") { choosePath() }.buttonStyle(GhostButton())
                if !model.aiPath.isEmpty { Button("Use login shell") { model.aiPath = ""; Task { await model.detectAI() } }.buttonStyle(GhostButton()) }
                Button("Detect again") { Task { await model.detectAI() } }.buttonStyle(GhostButton())
            }
            .padding(.top, 16)
            if let test { Text(test).font(.meta12).foregroundStyle(T.body).padding(.top, 12).textSelection(.enabled) }
            if showPreview {
                // Exactly what the test run sends on stdin.
                Text(AI.summarise(AI.sample, redact: model.aiRedact).stdin).font(.mono12).foregroundStyle(T.muted)
                    .textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(T.bg)).padding(.top, 12)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 6).fill(T.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(model.engine?.ready == true ? T.teal.opacity(0.5) : T.line))
    }

    var log: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("RUN LOG · NO MESSAGE CONTENT KEPT").font(.label11).foregroundStyle(T.muted).padding(.bottom, 6)
            if runs.isEmpty { Text("No runs yet").foregroundStyle(T.faint) }
            ForEach(runs, id: \.self) { r in
                Text("\(r.at.formatted(date: .omitted, time: .shortened))  \(r.engine)  \(r.task.padding(toLength: 9, withPad: " ", startingAt: 0))  \(r.messages) msg · \(String(format: "%.1f", Double(r.bytes) / 1024)) KB  \(r.outcome == "ok" ? String(format: "ok %.1f s · $%.3f", Double(r.ms) / 1000, r.cost) : r.outcome)")
                    .foregroundStyle(r.outcome == "ok" ? T.muted : T.gold)
            }
        }
        .font(.mono12)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(T.surface.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(T.line))
    }

    /// The fixed check: summarise the built-in sample, so nothing of yours is sent.
    func testRun() {
        testing = true
        test = nil
        let ai = model.ai
        Task {
            do {
                let s = try await ai.ask(AI.summarise(AI.sample, redact: model.aiRedact), as: AI.Summary.self)
                test = "Works. " + (s.summary + s.asks.map { "To do: \($0)" }).joined(separator: " ")
            } catch {
                test = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            testing = false
            runs = (try? model.store?.runs()) ?? []
        }
    }

    func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.message = "Choose the claude binary"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.aiPath = url.path
        Task { await model.detectAI() }
    }
}
