import SwiftUI

/// Atlantis dark, from the midway screens canvas. Every value comes from the design's scale.
enum T {
    static let bg = Color(hex: 0x0B1620)
    static let surface = Color(hex: 0x0F1E2A)
    static let line = Color(hex: 0x1C3040)
    static let sel = Color(hex: 0x132634)
    static let text = Color(hex: 0xDCE7EC)
    static let body = Color(hex: 0xC3D3DA)
    static let muted = Color(hex: 0x8DA3AE)
    static let faint = Color(hex: 0x64808C)
    static let teal = Color(hex: 0x3FC1B6)
    static let gold = Color(hex: 0xD9A441)

    static let sidebar: CGFloat = 232
    static let list: CGFloat = 360
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension Font {
    static let body13 = Font.system(size: 13)
    static let meta12 = Font.system(size: 12)
    static let label11 = Font.system(size: 11, weight: .medium)
    static let h1 = Font.system(size: 15, weight: .semibold)
    static let h2 = Font.system(size: 20, weight: .semibold)
    static let display = Font.system(size: 28, weight: .semibold)
    static let mono12 = Font.system(size: 12, design: .monospaced)
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
        configuration.label.font(.system(size: 12, weight: .medium)).foregroundStyle(T.bg)
            .padding(.horizontal, 12).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 4).fill(T.teal.opacity(configuration.isPressed ? 0.8 : 1)))
    }
}

struct GhostButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium)).foregroundStyle(T.muted)
            .padding(.horizontal, 8).frame(height: 28)
            .contentShape(Rectangle()).opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// The CLT SDK declares `@State` as a macro whose plugin ships only with Xcode; this names the
/// property wrapper itself so the app builds with just the Command Line Tools.
typealias Local<Value> = SwiftUICore.State<Value>
