#if !APPSTORE
import SwiftUI

// coucou-custom fork: the Buddy's surfaces (its HUD, the calm panel) in Coucou's own look — the
// notch's dark cards (CardBackground: #141518, a colour wash from below, a hairline), its type
// colours and accents, round progress like the notch's gauges, capsule buttons.

enum BuddyPalette {
    static let card = Color(hex: "#141518")
    static let raised = Color.white.opacity(0.06)
    static let hairline = Color.white.opacity(0.07)
    static let text = Color(hex: "#F1F2F4")
    static let body = Color(hex: "#B0B5BE")
    static let secondary = Color(hex: "#8E939C")
    static let muted = Color(hex: "#5C6370")
    static let ink = Color(hex: "#0B0C0E")

    static let indigo = Color(hex: "#6366F1")
    static let violet = Color(hex: "#A78BFA")
    static let green = Color(hex: "#34D399")
    static let amber = Color(hex: "#F5A524")
    static let cyan = Color(hex: "#22D3EE")
    static let sky = Color(hex: "#3B9EFF")
    static let pink = Color(hex: "#F472B6")
    static let red = Color(hex: "#F4505E")
}

/// A notch card: dark, washed from below with `tint`.
struct BuddyCard<Content: View>: View {
    var tint: Color
    var radius: CGFloat = 18
    var wash: Double = 0.5
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(BuddyPalette.card)
                    RadialGradient(colors: [tint.opacity(wash), .clear], center: UnitPoint(x: 0.5, y: 1.35),
                                   startRadius: 0, endRadius: 240)
                        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                }
            )
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
}

/// Round progress with a symbol in the middle, like the notch's gauges.
struct BuddyRing: View {
    var progress: Double
    var tint: Color
    var symbol: String
    var size: CGFloat = 36
    var pulse = false
    @State private var on = false

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.14))
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 3)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: progress)
            Image(systemName: symbol)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundColor(tint)
                .scaleEffect(pulse && on ? 1.12 : 1)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard pulse else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true }
        }
    }
}

/// A capsule button: filled with the accent for the main action, glass otherwise.
struct BuddyPillButtonStyle: ButtonStyle {
    var tint: Color? = nil
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11 : 11.5, weight: .semibold))
            .foregroundColor(tint == nil ? Color(hex: "#E1E3E6") : BuddyPalette.ink)
            .padding(.horizontal, compact ? 9 : 12)
            .frame(height: compact ? 24 : 27)
            .background(Capsule().fill(tint ?? Color.white.opacity(configuration.isPressed ? 0.14 : 0.08)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(tint == nil ? 0.08 : 0)))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

/// A round icon button (close, mute).
struct BuddyIconButton: View {
    let symbol: String
    var help: String = ""
    let run: () -> Void

    var body: some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundColor(BuddyPalette.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
#endif
