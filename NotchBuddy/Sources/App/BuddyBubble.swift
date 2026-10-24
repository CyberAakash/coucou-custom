import SwiftUI

// MARK: - BuddyBubble (coucou-custom fork)
//
// What the desktop Buddy says. It rides Mochi's hop and sway frame by frame (the bubble lives in
// its own window while Mochi hops inside his, so a fixed bubble was left behind when he jumped
// as he spoke), comes in, types its words, and goes away with an animation of its own style.
// Every motion is a pure function of the time since it appeared, so a frame can be rendered at
// any moment (the previews in Settings and the fork's own image checks use that).

enum BuddyBubbleStyle: String, CaseIterable, Identifiable {
    case glass, comic, sticker
    var id: String { rawValue }
    var label: String {
        switch self {
        case .glass: return "Glass"
        case .comic: return "Comic"
        case .sticker: return "Sticker"
        }
    }
}

@MainActor
final class BuddyBubbleModel: ObservableObject {
    @Published var text: String
    @Published var style: BuddyBubbleStyle
    /// The bubble is over Mochi (its tail or trail points down) or under him.
    @Published var above: Bool
    @Published var shownAt: Date
    @Published var leftAt: Date?
    /// Mochi's hop and sway now, in points (y down), read every frame.
    var ride: () -> CGSize

    init(text: String, style: BuddyBubbleStyle, above: Bool = true, shownAt: Date = .now,
         ride: @escaping () -> CGSize = { .zero }) {
        self.text = text
        self.style = style
        self.above = above
        self.shownAt = shownAt
        self.ride = ride
    }
}

struct BuddyBubbleView: View {
    @ObservedObject var model: BuddyBubbleModel
    /// Room above the bubble for Mochi's hop and the entrance overshoot.
    var rideRoom: CGFloat = 18
    /// A fixed moment instead of the clock (previews, image checks).
    var frozenAt: Date? = nil

    static let side: CGFloat = 10
    static let bottom: CGFloat = 4

    var body: some View {
        Group {
            if let frozenAt {
                frame(at: frozenAt)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: isFinished)) { ctx in
                    frame(at: ctx.date)
                }
            }
        }
        .padding(.horizontal, Self.side)
        .padding(model.above ? .top : .bottom, rideRoom)
        .padding(model.above ? .bottom : .top, Self.bottom)
        .fixedSize()
    }

    private var isFinished: Bool {
        guard let l = model.leftAt else { return false }
        return Date.now.timeIntervalSince(l) > 0.6
    }

    private func frame(at now: Date) -> some View {
        let t = now.timeIntervalSince(model.shownAt)
        let out = model.leftAt.map { max(0, now.timeIntervalSince($0)) }
        let ride = model.ride()
        return BubbleBody(text: model.text, style: model.style, above: model.above, t: t, out: out)
            .offset(x: ride.width, y: ride.height)
    }
}

// MARK: - Motion helpers

enum BubbleMotion {
    /// 0 → 1 with a soft overshoot (a damped spring), `x` in units of `duration`.
    static func spring(_ t: Double, duration: Double, bounce: Double = 0.35) -> Double {
        guard t > 0 else { return 0 }
        let x = t / duration
        guard x < 3 else { return 1 }
        return 1 - exp(-5.5 * x) * cos(x * .pi * (1 + bounce * 2.2))
    }
    static func easeOut(_ t: Double, duration: Double) -> Double {
        let x = min(1, max(0, t / duration))
        return 1 - pow(1 - x, 3)
    }
    /// How many characters are visible after `t` seconds, at `rate` characters a second.
    static func typed(_ text: String, t: Double, delay: Double, rate: Double) -> Int {
        min(text.count, max(0, Int(((t - delay) * rate).rounded(.down))))
    }
}

/// The full text laid out, the part not yet typed transparent: the bubble keeps its final size
/// while the words appear.
private func typedText(_ text: String, visible: Int, color: Color) -> Text {
    let shown = String(text.prefix(visible))
    let rest = String(text.dropFirst(visible))
    return Text(shown).foregroundColor(color) + Text(rest).foregroundColor(.clear)
}

// MARK: - Styles

private struct BubbleBody: View {
    let text: String
    let style: BuddyBubbleStyle
    let above: Bool
    let t: Double
    let out: Double?

    var body: some View {
        // In a stack, so the wrapped text's height is measured before the bubble is drawn
        // round it (bare, a two-line text overflowed a one-line bubble).
        VStack(spacing: 0) {
            switch style {
            case .glass: GlassBubble(text: text, above: above, t: t, out: out)
            case .comic: ComicBubble(text: text, above: above, t: t, out: out)
            case .sticker: StickerBubble(text: text, above: above, t: t, out: out)
            }
        }
    }
}

/// Dark glass in the Buddy's card colours, a thin gradient rim, and a trail of two dots down to
/// his head. The dots come first, then the bubble rises out of them and the words type in;
/// it leaves by floating up and fading.
private struct GlassBubble: View {
    let text: String, above: Bool, t: Double, out: Double?

    var body: some View {
        let rise = BubbleMotion.spring(t - 0.08, duration: 0.42, bounce: 0.25)
        let leave = out.map { BubbleMotion.easeOut($0, duration: 0.32) } ?? 0
        let dot1 = BubbleMotion.easeOut(t, duration: 0.14), dot2 = BubbleMotion.easeOut(t - 0.05, duration: 0.14)
        let visible = BubbleMotion.typed(text, t: t, delay: 0.16, rate: 42)
        let rim = AngularGradient(colors: [Color(hex: "#6366F1"), Color(hex: "#F472B6"), Color(hex: "#F5A524"), Color(hex: "#22D3EE"), Color(hex: "#6366F1")],
                                  center: .center, angle: .degrees(t * 50))
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        let bubble = typedText(text, visible: visible, color: Color(hex: "#F1F2F4"))
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .lineLimit(3)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 220)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(shape.fill(Color(hex: "#141518").opacity(0.94)))
            .background(shape.fill(LinearGradient(colors: [Color.white.opacity(0.10), .clear], startPoint: .top, endPoint: .center)))
            .overlay(shape.strokeBorder(rim, lineWidth: 1.2).opacity(0.85))
            .shadow(color: Color(hex: "#6366F1").opacity(0.35), radius: 10, y: 2)
            .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
            .scaleEffect(0.82 + 0.18 * rise, anchor: above ? .bottom : .top)
            .offset(y: (above ? 1 : -1) * 10 * (1 - rise))
            .opacity(min(1, rise * 1.6))
        let trail = VStack(spacing: 3) {
            Circle().fill(Color(hex: "#141518")).overlay(Circle().strokeBorder(Color(hex: "#A78BFA").opacity(0.7), lineWidth: 1.2))
                .frame(width: 8, height: 8).scaleEffect(above ? dot2 : dot1)
            Circle().fill(Color(hex: "#141518")).overlay(Circle().strokeBorder(Color(hex: "#A78BFA").opacity(0.7), lineWidth: 1))
                .frame(width: 5, height: 5).scaleEffect(above ? dot1 : dot2)
        }
        return VStack(spacing: 3) {
            if above { bubble; trail } else { trail.rotationEffect(.degrees(180)); bubble }
        }
        .offset(y: -14 * leave)
        .opacity(1 - leave)
        .blur(radius: 2.5 * leave)
    }
}

/// A white comic bubble with a tail on Mochi, wobbling in from the tail and typing its words;
/// it shrinks back into the tail to leave.
private struct ComicBubble: View {
    let text: String, above: Bool, t: Double, out: Double?

    var body: some View {
        let pop = BubbleMotion.spring(t, duration: 0.38, bounce: 0.5)
        let leave = out.map { BubbleMotion.easeOut($0, duration: 0.24) } ?? 0
        let visible = BubbleMotion.typed(text, t: t, delay: 0.12, rate: 40)
        let shape = ComicShape(tail: 10, tailDown: above)
        return typedText(text, visible: visible, color: Color(hex: "#1D1B22"))
            .font(.system(size: 13.5, weight: .bold, design: .rounded))
            .lineLimit(3)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 220)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .padding(above ? .bottom : .top, 10)
            // The hard comic shadow belongs to the bubble, not the words (it drew a ghost of the text).
            .background(ZStack {
                shape.fill(Color.black.opacity(0.28)).offset(x: 2, y: 3)
                shape.fill(Color.white)
                shape.stroke(Color(hex: "#1D1B22"), lineWidth: 2)
            })
            .rotationEffect(.degrees(-7 * (1 - pop)), anchor: above ? .bottom : .top)
            .scaleEffect(max(0.01, (0.35 + 0.65 * pop) * (1 - 0.6 * leave)), anchor: above ? .bottom : .top)
            .opacity(min(1, pop * 2) * (1 - leave))
    }
}

private struct ComicShape: Shape {
    let tail: CGFloat, tailDown: Bool
    func path(in rect: CGRect) -> Path {
        let body = tailDown ? CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - tail)
                            : CGRect(x: rect.minX, y: rect.minY + tail, width: rect.width, height: rect.height - tail)
        var p = Path(roundedRect: body, cornerRadius: min(14, body.height / 2), style: .continuous)
        var tl = Path()
        // A short tail leaning to one side, like a drawn speech bubble.
        let baseY = tailDown ? body.maxY - 1 : body.minY + 1
        let tipY = tailDown ? rect.maxY : rect.minY
        tl.move(to: CGPoint(x: body.midX - 8, y: baseY))
        tl.addLine(to: CGPoint(x: body.midX - 2, y: tipY))
        tl.addLine(to: CGPoint(x: body.midX + 6, y: baseY))
        tl.closeSubpath()
        p.addPath(tl)
        return p.normalized()
    }
}

/// A bold coloured sticker, slightly tilted, slapped on with a squash and a bounce; the whole
/// line shows at once. It pops off to leave.
private struct StickerBubble: View {
    let text: String, above: Bool, t: Double, out: Double?

    var body: some View {
        let slap = BubbleMotion.spring(t, duration: 0.34, bounce: 0.6)
        let leave = out.map { BubbleMotion.easeOut($0, duration: 0.2) } ?? 0
        let squashX = 1 + 0.18 * (1 - slap), squashY = 1 - 0.18 * (1 - slap)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Text(text)
            .font(.system(size: 13.5, weight: .heavy, design: .rounded))
            .foregroundColor(.white)
            .lineLimit(3)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 210)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(shape.fill(LinearGradient(colors: [Color(hex: "#F472B6"), Color(hex: "#A78BFA")],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(shape.strokeBorder(Color.white, lineWidth: 2.5))
            .shadow(color: Color(hex: "#A78BFA").opacity(0.45), radius: 8, y: 3)
            .rotationEffect(.degrees(-3))
            .padding(above ? .bottom : .top, 6)   // no tail: a little air over his head
            .scaleEffect(x: squashX * slap * (1 + 0.15 * leave), y: squashY * slap * (1 - leave), anchor: above ? .bottom : .top)
            .opacity(min(1, slap * 3) * (1 - leave))
    }
}
