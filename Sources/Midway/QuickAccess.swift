import AppKit
import MidwayCore
import SwiftUI

/// Above the message body: the code banner (for 15 minutes), then tracking, key links and booking references.
struct QuickStrip: View {
    let items: [QuickItem]
    let model: AppModel

    var code: QuickItem? { items.first { $0.kind == .code && $0.date.timeIntervalSinceNow > -Quick.codeLifetime } }
    var rest: [QuickItem] { items.filter { $0.kind != .code } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let code {
                HStack(spacing: 12) {
                    Image(systemName: "key").foregroundStyle(T.teal)
                    Text("Code").font(.meta12).foregroundStyle(T.muted)
                    Text(code.value).font(.system(size: 20, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Text("hidden 15 min after it came").font(.meta12).foregroundStyle(T.faint)
                    Button("Copy") { model.copy(code.value, secret: true, notice: "Copied code") }.buttonStyle(PrimaryButton())
                }
                .padding(.horizontal, 16).frame(height: 52)
                .background(RoundedRectangle(cornerRadius: 6).fill(T.teal.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.teal.opacity(0.4)))
            }
            if !rest.isEmpty {
                HStack(spacing: 8) {
                    ForEach(rest, id: \.self) { button($0) }
                }
            }
        }
    }

    @ViewBuilder func button(_ i: QuickItem) -> some View {
        switch i.kind {
        case .parcel:
            Button { open(i.url) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "shippingbox")
                    Text(i.delivered ? "\(i.label) · delivered" : i.url == nil ? i.label : "Open tracking · \(i.label)")
                    if i.value != i.url { Text(i.value).font(.mono12).foregroundStyle(T.faint).lineLimit(1) }
                }
            }
            .buttonStyle(OutlineButton()).disabled(i.url == nil).help(i.url ?? "")
        case .link:
            Button { open(i.url) } label: {
                HStack(spacing: 6) {
                    Text(i.label)
                    Text(i.host ?? "").font(.mono12).foregroundStyle(T.faint)
                }
            }
            .buttonStyle(OutlineButton()).help(i.url ?? "")
        case .booking:
            Button { model.copy(i.value, notice: "Copied \(i.value)") } label: {
                HStack(spacing: 6) {
                    Text(i.label).foregroundStyle(T.muted)
                    Text(i.value).font(.mono12)
                    Image(systemName: "doc.on.doc").font(.system(size: 10))
                }
            }
            .buttonStyle(OutlineButton()).help("Copy")
        case .code:
            EmptyView()
        }
    }

    /// Links open in the browser, never in the viewer; the button already shows the real domain.
    func open(_ s: String?) {
        guard let s, let url = URL(string: s), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
}
