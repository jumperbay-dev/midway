import AppKit
import MidwayCore
import SwiftUI

/// Screen 03: its own window, From / To / Cc / Subject rows, the body, and a footer with Send (⌘↩).
/// Every change saves the draft locally at once.
struct ComposeView: View {
    let model: AppModel
    let draftId: Int64
    @Local private var draft: Draft?
    @Local private var body_ = NSAttributedString()
    @Local private var error: String?
    @Local private var showCc = false
    @Local private var suggestions: [Contact] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text(draft.map { $0.subject.isEmpty ? "New message" : $0.subject } ?? "").font(.meta12).foregroundStyle(T.muted).lineLimit(1)
                Spacer()
            }
            .overlay(alignment: .trailing) {
                if let d = draft { Text("saved \(d.updatedAt.formatted(date: .omitted, time: .shortened))").font(.meta12).foregroundStyle(T.faint) }
            }
            .padding(.horizontal, 16).frame(height: 40)
            .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }

            if draft != nil {
                VStack(alignment: .leading, spacing: 0) {
                    fields
                    if let draft { ComposeAI(model: model, draft: draft, body_: $body_) }
                    RichTextEditor(text: $body_).padding(.top, 16)
                    footer
                }
                .padding(.horizontal, 32).padding(.top, 16).padding(.bottom, 24)
            } else {
                Spacer()
            }
        }
        .font(.body13)
        .background(T.bg)
        .foregroundStyle(T.text)
        .preferredColorScheme(.dark)
        .frame(minWidth: 560, minHeight: 420)
        .task { load() }
        .onChange(of: draft) { save() }
        .onChange(of: body_) { save() }
    }

    @ViewBuilder var fields: some View {
        if let d = Binding($draft) {
            if model.accounts.count > 1 {
                field("From") {
                    Picker("", selection: d.accountId) {
                        ForEach(model.accounts, id: \.id) { a in Text(a.email).tag(a.id!) }
                    }
                    .labelsHidden().fixedSize().font(.mono12)
                }
            }
            field("To") {
                TextField("", text: d.toList)
                    .onChange(of: d.wrappedValue.toList) { suggest(d.wrappedValue.toList) }
                if !showCc { Button("Cc") { showCc = true }.buttonStyle(GhostButton()) }
            }
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions, id: \.address) { c in
                        Button { pick(c) } label: {
                            HStack(spacing: 8) {
                                Text(c.name.isEmpty ? c.address : c.name)
                                if !c.name.isEmpty { Text(c.address).font(.mono12).foregroundStyle(T.faint) }
                                Spacer()
                                if c.sent > 0 { Text("you write to").font(.meta12).foregroundStyle(T.faint) }
                            }
                            .padding(.horizontal, 12).frame(height: 28).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(T.surface))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.line))
                .padding(.leading, 72).frame(maxWidth: 480, alignment: .leading)
            }
            if showCc {
                field("Cc") { TextField("", text: d.ccList) }
                field("Bcc") { TextField("", text: d.bccList) }
            }
            field("Subject") { TextField("", text: d.subject).fontWeight(.semibold) }
        }
    }

    func field(_ key: String, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(key).font(.meta12).foregroundStyle(T.faint).frame(width: 60, alignment: .leading)
            content()
        }
        .textFieldStyle(.plain)
        .frame(height: 40)
        .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
    }

    var footer: some View {
        HStack(spacing: 12) {
            if let error {
                Text(error).font(.meta12).foregroundStyle(T.gold).lineLimit(2)
            } else {
                Text("undo for 10 s after sending").font(.meta12).foregroundStyle(T.faint)
            }
            Spacer()
            Button("Discard") { discard() }.buttonStyle(GhostButton())
            Text("⌘↩").font(.meta12).foregroundStyle(T.faint)
            Button("Send") { send() }.buttonStyle(PrimaryButton()).keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.top, 16)
        .overlay(alignment: .top) { Rectangle().fill(T.line).frame(height: 1) }
    }

    func load() {
        guard let d = try? model.store?.draft(draftId) else { dismiss(); return }
        // Reopened from undo send or a failed send: it is a draft again.
        model.unsend(draftId)
        draft = d
        body_ = RichText.attributed(d.rtf)
        showCc = !d.ccList.isEmpty || !d.bccList.isEmpty
    }

    func save() {
        guard var d = draft, let store = model.store else { return }
        d.rtf = RichText.rtf(body_)
        if let saved = try? store.save(d), saved.updatedAt.timeIntervalSince(draft?.updatedAt ?? .distantPast) > 30 {
            draft?.updatedAt = saved.updatedAt  // the "saved" time, without re-rendering on every key
        }
    }

    /// Autocomplete the address being typed after the last comma.
    func suggest(_ list: String) {
        let current = list.split(separator: ",", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        suggestions = current.contains("@") && current.contains(">") ? [] : (try? model.store?.contacts(matching: current)) ?? []
    }

    func pick(_ c: Contact) {
        guard var d = draft else { return }
        var parts = d.toList.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        parts.removeLast()
        parts.append(c.name.isEmpty ? c.address : "\(c.name) <\(c.address)>")
        d.toList = parts.filter { !$0.isEmpty }.joined(separator: ", ") + ", "
        draft = d
        suggestions = []
    }

    func send() {
        guard let d = draft else { return }
        save()
        do {
            try model.send(d, body: body_)
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    func discard() {
        try? model.store?.deleteDraft(draftId)
        dismiss()
    }
}

/// NSTextView with rich text: bold and italic from Format ▸ Font (⌘B, ⌘I), links detected as you type.
// ponytail: bold, italic and links only; lists, quotes and inline images when the composer gets a toolbar
struct RichTextEditor: NSViewRepresentable {
    @Binding var text: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isRichText = true
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticLinkDetectionEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.drawsBackground = false
        tv.insertionPointColor = NSColor(T.teal)
        tv.typingAttributes = RichText.base
        tv.textStorage?.setAttributedString(text)
        tv.delegate = context.coordinator
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let tv = scroll.documentView as! NSTextView
        if tv.attributedString() != text { tv.textStorage?.setAttributedString(text) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: RichTextEditor
        init(_ parent: RichTextEditor) { self.parent = parent }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = NSAttributedString(attributedString: tv.attributedString())
        }
    }
}

@MainActor enum RichText {
    static let base: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 15),
        .foregroundColor: NSColor(T.text),
        .paragraphStyle: { let p = NSMutableParagraphStyle(); p.minimumLineHeight = 24; return p }(),
    ]

    static func rtf(_ plain: String) -> Data { rtf(NSAttributedString(string: plain, attributes: base)) }

    static func rtf(_ s: NSAttributedString) -> Data {
        (try? s.data(from: NSRange(location: 0, length: s.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])) ?? Data()
    }

    static func attributed(_ rtf: Data) -> NSAttributedString {
        guard !rtf.isEmpty, let s = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        else { return NSAttributedString(string: "", attributes: base) }
        return s
    }

    /// The safe subset only: text, bold, italic and http(s)/mailto links. Colours and fonts stay behind.
    static func html(_ s: NSAttributedString) -> String {
        var out = ""
        s.enumerateAttributes(in: NSRange(location: 0, length: s.length)) { attrs, range, _ in
            var t = escape(s.attributedSubstring(from: range).string).replacing("\n", with: "<br>")
            let traits = (attrs[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            if traits.contains(.bold) { t = "<b>\(t)</b>" }
            if traits.contains(.italic) { t = "<i>\(t)</i>" }
            let link = (attrs[.link] as? URL)?.absoluteString ?? attrs[.link] as? String
            if let link, ["http", "https", "mailto"].contains(URL(string: link)?.scheme?.lowercased() ?? "") {
                t = "<a href=\"\(escape(link))\">\(t)</a>"
            }
            out += t
        }
        return "<div style=\"font:14px/1.5 -apple-system,Helvetica,Arial,sans-serif\">\(out)</div>"
    }

    static func escape(_ s: String) -> String {
        s.replacing("&", with: "&amp;").replacing("<", with: "&lt;").replacing(">", with: "&gt;").replacing("\"", with: "&quot;")
    }
}
