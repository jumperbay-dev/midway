import SwiftUI

/// One theme's colours, from the midway screens canvas (Atlantis dark and light).
struct Palette: Equatable {
    var bg, surface, line, sel, text, body, muted, faint, teal, gold: UInt32
    var dark: Bool

    static let deep = Palette(bg: 0x0B1620, surface: 0x0F1E2A, line: 0x1C3040, sel: 0x132634, text: 0xDCE7EC, body: 0xC3D3DA,
                              muted: 0x8DA3AE, faint: 0x64808C, teal: 0x3FC1B6, gold: 0xD9A441, dark: true)
    static let pier = Palette(bg: 0xF2F6F7, surface: 0xFFFFFF, line: 0xD5E0E4, sel: 0xE3EEF0, text: 0x10222D, body: 0x2A3E4A,
                              muted: 0x4F6774, faint: 0x5F7581, teal: 0x0E8580, gold: 0x9A6510, dark: false)
}

/// Settings ▸ Appearance. "Follow system" picks Deep or Pier with macOS light and dark.
enum Theme: String, CaseIterable {
    case system = "Follow system", deep = "Deep", pier = "Pier"

    func palette(_ scheme: ColorScheme) -> Palette {
        switch self {
        case .system: scheme == .dark ? .deep : .pier
        case .deep: .deep
        case .pier: .pier
        }
    }
    var scheme: ColorScheme? { self == .system ? nil : palette(.light).dark ? .dark : .light }
}

/// Tokens of the current palette. Views read them while they render; `Themed` swaps the palette and rebuilds.
@MainActor enum T {
    static var p = Palette.deep
    static var bg: Color { Color(hex: p.bg) }
    static var surface: Color { Color(hex: p.surface) }
    static var line: Color { Color(hex: p.line) }
    static var sel: Color { Color(hex: p.sel) }
    static var text: Color { Color(hex: p.text) }
    static var body: Color { Color(hex: p.body) }
    static var muted: Color { Color(hex: p.muted) }
    static var faint: Color { Color(hex: p.faint) }
    static var teal: Color { Color(hex: p.teal) }
    static var gold: Color { Color(hex: p.gold) }
    /// Text on a teal button.
    static var onPrimary: Color { p.dark ? bg : .white }
    /// Dims the window behind a sheet.
    static var scrim: Color { p.dark ? Color(hex: 0x050A0F).opacity(0.6) : Color(hex: p.text).opacity(0.2) }

    /// Eight muted sea tones for tags, so tags never fight the accent.
    static let tags: [UInt32] = [0xEE8F72, 0x62C792, 0xE58FB4, 0xA797F2, 0x6AB2EC, 0xD9A441, 0x3FC1B6, 0x8DA3AE]
    static func tag(_ i: Int) -> Color { Color(hex: tags[(i % 8 + 8) % 8]) }

    static let sidebar: CGFloat = 232
    static let list: CGFloat = 360

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular, mono: Bool = false) -> Font {
        .system(size: size, weight: weight, design: mono ? .monospaced : .default)
    }
}

extension View {
    func themed(_ theme: Theme) -> some View { Themed(theme: theme) { self } }
}

/// Puts the chosen theme on a window: the palette, the light or dark appearance, and a rebuild when either changes.
struct Themed<Content: View>: View {
    let theme: Theme
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = theme.palette(scheme)
        // ponytail: a global palette set while rendering, rebuilt with .id; an Environment value if themes ever mix in one window
        T.p = p
        return content()
            .id(p.bg)
            .background(T.bg)
            .foregroundStyle(T.text)
            .tint(T.teal)
            .preferredColorScheme(theme.scheme)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

@MainActor extension Font {
    static var body13: Font { T.font(13) }
    static var meta12: Font { T.font(12) }
    static var label11: Font { T.font(11, .medium) }
    static var h1: Font { T.font(15, .semibold) }
    static var h2: Font { T.font(20, .semibold) }
    static var display: Font { T.font(28, .semibold) }
    static var mono12: Font { T.font(12, mono: true) }
}

struct Kbd: View {
    let key: String
    var body: some View {
        Text(key).font(.system(size: 11, design: .monospaced)).foregroundStyle(T.faint)
            .padding(.horizontal, 4).frame(minWidth: 20, minHeight: 20)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(T.line))
    }
}

struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(T.font(12, .medium)).foregroundStyle(T.onPrimary)
            .padding(.horizontal, 12).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 4).fill(T.teal.opacity(configuration.isPressed ? 0.8 : 1)))
    }
}

struct OutlineButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(T.font(12, .medium)).foregroundStyle(T.text)
            .padding(.horizontal, 12).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 4).fill(T.sel.opacity(configuration.isPressed ? 0.6 : 1)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(T.line))
    }
}

struct GhostButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(T.font(12, .medium)).foregroundStyle(T.muted)
            .padding(.horizontal, 8).frame(height: 28)
            .contentShape(Rectangle()).opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// The CLT SDK declares `@State` as a macro whose plugin ships only with Xcode; this names the
/// property wrapper itself so the app builds with just the Command Line Tools.
typealias Local<Value> = SwiftUICore.State<Value>
