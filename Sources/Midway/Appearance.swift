import Sparkle
import SwiftUI

/// Sparkle 2 with an EdDSA-signed appcast. Off in dev builds, which have no feed URL in Info.plist.
@MainActor final class Updates {
    let controller: SPUStandardUpdaterController?

    init() {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        controller = feed.isEmpty ? nil : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func check() { controller?.checkForUpdates(nil) }
}

/// Screen 21: one card per theme, drawn from its own palette.
struct AppearanceSettings: View {
    let model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Appearance").font(.h2)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3), spacing: 16) {
                ForEach(Theme.allCases, id: \.self) { t in
                    Button { model.theme = t } label: { card(t) }.buttonStyle(.plain)
                }
            }
        }
        .padding(32)
        .frame(width: 640, alignment: .topLeading)
    }

    func card(_ t: Theme) -> some View {
        let on = model.theme == t
        return VStack(alignment: .leading, spacing: 8) {
            if t == .system {
                mini(.pier).overlay { mini(.deep).mask { HStack(spacing: 0) { Rectangle(); Color.clear } } }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                mini(t.palette(scheme)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Text(t.rawValue).fontWeight(.semibold)
                Spacer()
                if t == .deep { Text("default").font(.meta12).foregroundStyle(T.teal) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(T.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? T.teal : T.line, lineWidth: on ? 2 : 1))
        .contentShape(Rectangle())
    }

    func mini(_ p: Palette) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(Color(hex: p.teal).opacity(0.7)).frame(width: 28, height: 6)
                RoundedRectangle(cornerRadius: 2).fill(Color(hex: p.line)).frame(width: 20, height: 3)
                RoundedRectangle(cornerRadius: 2).fill(Color(hex: p.line)).frame(width: 24, height: 3)
                Spacer()
            }
            .padding(8).frame(width: 40).frame(maxHeight: .infinity).background(Color(hex: p.surface))
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(Color(hex: p.teal).opacity(0.2)).frame(height: 20)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(hex: p.teal).opacity(0.5)))
                RoundedRectangle(cornerRadius: 2).fill(Color(hex: p.line)).frame(height: 3)
                RoundedRectangle(cornerRadius: 2).fill(Color(hex: p.line)).frame(width: 40, height: 3)
                Spacer()
            }
            .padding(8).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity).frame(height: 96).background(Color(hex: p.bg))
    }
}
