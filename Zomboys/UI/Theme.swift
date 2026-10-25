import SwiftUI
import UIKit

enum CommandTheme {
    static let background = Color(hex: 0x101310)
    static let panel = Color(hex: 0x1B201B)
    static let raised = Color(hex: 0x252B24)
    static let line = Color(hex: 0x343B32)
    static let lime = Color(hex: 0xD6F75A)
    static let text = Color(hex: 0xF1F2E9)
    static let muted = Color(hex: 0x929D8B)
    static let red = Color(hex: 0xFA7666)
    static let cyan = Color(hex: 0x8DDACA)

    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255,
                  blue: Double(hex & 255) / 255, opacity: 1)
    }
}

extension View {
    func tacticalGlass(cornerRadius: CGFloat = 15) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius)
                // A flat tactical panel avoids recapturing and blurring the
                // moving 3D scene behind the HUD on every display frame.
                .fill(CommandTheme.background.opacity(0.96))
        }
        .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(CommandTheme.line.opacity(0.9), lineWidth: 1))
    }
}

struct Eyebrow: View {
    let text: String
    var color: Color = CommandTheme.muted
    var body: some View {
        Text(text)
            .font(CommandTheme.mono(9, weight: .semibold))
            .tracking(1.7)
            .foregroundStyle(color)
    }
}

struct TacticalButton: ButtonStyle {
    var primary = false
    var height: CGFloat = 48
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CommandTheme.mono(11, weight: .bold))
            .tracking(0.7)
            .foregroundStyle(primary ? CommandTheme.background : CommandTheme.text)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(primary ? CommandTheme.lime : CommandTheme.raised)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

struct IconButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 40
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(CommandTheme.text)
                .frame(width: size, height: size)
                .background(CommandTheme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(CommandTheme.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
