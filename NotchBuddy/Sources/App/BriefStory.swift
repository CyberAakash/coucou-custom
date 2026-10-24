#if !APPSTORE
import SwiftUI

// coucou-custom fork: the full-screen frame the Daily brief and the Weekly recap share, as Claude
// Design drew it — an 800 × 600 card over the blurred screen, progress ticks, a title and a date,
// one card at a time (a click on its left third goes back, elsewhere on; ←/→, Space or Return;
// Esc or a click beside it closes), optional auto-advance.

@MainActor
final class BriefStory: ObservableObject {
    let count: Int
    let autoAdvance: Int
    /// Plays the brief's sounds (off in Settings → Briefs): a soft peek for each card, a proud one at the end.
    var sound = false
    @Published var index = 0
    @Published var cardStart = Date()
    private var timer: Timer?

    init(count: Int, autoAdvance: Int) {
        self.count = max(1, count)
        self.autoAdvance = autoAdvance
        arm()
    }

    /// False at the last card.
    @discardableResult
    func next() -> Bool {
        guard index + 1 < count else { return false }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { index += 1 }
        if sound { SoundEngine.shared.play(index + 1 == count ? "proud" : "peek") }
        cardStart = Date()
        arm()
        return true
    }

    func previous() {
        guard index > 0 else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { index -= 1 }
        cardStart = Date()
        arm()
    }

    private func arm() {
        timer?.invalidate()
        timer = nil
        guard autoAdvance > 0, index + 1 < count else { return }
        let t = Timer(timeInterval: TimeInterval(autoAdvance), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// The overlay's keys: Esc closes, → Space Return go on (closing at the end), ← goes back.
    func handle(_ event: NSEvent, close: () -> Void) -> Bool {
        switch event.keyCode {
        case 53: close(); return true
        case 124, 49, 36: if !next() { close() }; return true
        case 123: previous(); return true
        default: return false
        }
    }
}

struct BriefStoryFrame<Card: View>: View {
    @ObservedObject var story: BriefStory
    let title: String
    let date: String
    let close: () -> Void
    var share: (() -> Void)? = nil
    @ViewBuilder let card: (Int) -> Card
    @State private var shown = false

    static var size: CGSize { CGSize(width: 800, height: 600) }

    var body: some View {
        ZStack {
            // A click beside the card closes it, as in the design.
            Color.clear.contentShape(Rectangle()).onTapGesture(perform: close)
            VStack(spacing: 18) {
                frame
                HStack(spacing: 14) {
                    hint(["←", "→"], "Move")
                    hint(["Esc"], "Close")
                }
                .opacity(shown ? 1 : 0)
            }
            .scaleEffect(shown ? 1 : 0.94)
            .opacity(shown ? 1 : 0)
        }
        .onAppear { withAnimation(BriefLayout.spring) { shown = true } }
    }

    private var frame: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color(hex: "#0E0F11"))
            // The design's click zones: the left third goes back, the rest goes on.
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).frame(width: Self.size.width * 0.32)
                    .onTapGesture { story.previous() }
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { if !story.next() { close() } }
            }
            .padding(.top, 60)
            ZStack {
                ForEach(0..<story.count, id: \.self) { i in
                    if i == story.index {
                        card(i)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .offset(x: 48)).combined(with: .scale(scale: 0.97)),
                                removal: .opacity.combined(with: .offset(x: -48)).combined(with: .scale(scale: 0.97))))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(EdgeInsets(top: 76, leading: 40, bottom: 36, trailing: 40))
            ticks.padding(.horizontal, 28).padding(.top, 18)
            header.padding(.horizontal, 28).padding(.top, 32)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Color.white.opacity(0.07)))
        .shadow(color: .black.opacity(0.6), radius: 50, y: 40)
        .foregroundColor(HubTheme.text)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12.5, weight: .bold)).foregroundColor(Color(hex: "#F5F6F8"))
            Text(date).font(.system(size: 12.5)).foregroundColor(Color(hex: "#6B7079"))
            Spacer()
            Text("\(story.index + 1) of \(story.count)").font(.system(size: 12).monospacedDigit()).foregroundColor(Color(hex: "#6B7079"))
            if let share { headerButton("square.and.arrow.up", help: "Share as an image", action: share) }
            headerButton("xmark", help: "Close", action: close)
        }
        .frame(height: 28)
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundColor(HubTheme.secondary)
                .frame(width: 24, height: 24).background(Circle().fill(Color.white.opacity(0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var ticks: some View {
        HStack(spacing: 6) {
            ForEach(0..<story.count, id: \.self) { i in
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.14))
                        if i < story.index {
                            Capsule().fill(Color(hex: "#F5F6F8"))
                        } else if i == story.index {
                            if story.autoAdvance > 0 {
                                TimelineView(.animation) { ctx in
                                    let k = min(1, ctx.date.timeIntervalSince(story.cardStart) / Double(story.autoAdvance))
                                    Capsule().fill(Color(hex: "#F5F6F8")).frame(width: g.size.width * k)
                                }
                            } else {
                                Capsule().fill(Color(hex: "#F5F6F8"))
                            }
                        }
                    }
                }
                .frame(height: 3)
            }
        }
    }

    private func hint(_ keys: [String], _ what: String) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                Text(k).font(.system(size: 10.5, weight: .bold)).padding(.horizontal, 6).frame(height: 18)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.12)))
            }
            Text(what).font(.system(size: 11.5)).foregroundColor(HubTheme.secondary)
        }
        .foregroundColor(HubTheme.text)
    }
}

/// A number that counts up from zero when its card comes, as the design's do (1.1 s, ease-out cubic).
struct BriefCountUp: View {
    let value: Int
    var format: (Int) -> String = { $0.formatted() }
    @State private var shown = 0.0

    var body: some View {
        CountingText(value: shown, format: format)
            .onAppear {
                withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: 1.1)) { shown = Double(value) }
            }
    }
}

/// SwiftUI steps `value` frame by frame through the animation; nothing runs once it lands.
private struct CountingText: View, Animatable {
    var value: Double
    let format: (Int) -> String
    nonisolated var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View { Text(format(Int(value.rounded()))) }
}

/// Where a brief shows.
enum BriefPlace: String, CaseIterable, Identifiable {
    case notch, fullScreen
    var id: String { rawValue }
    var label: String { self == .notch ? "In the notch" : "Full screen" }
}
// MARK: - The look: a moving sky behind, the intro, things arriving

/// Colours for the time of day: warm in the morning, clear in the afternoon, violet at dusk, deep at night.
struct BriefPalette {
    let colors: [Color]
    let accent: Color

    static func now(_ date: Date = Date(), calendar: Calendar = .current) -> BriefPalette {
        switch calendar.component(.hour, from: date) {
        case 5..<12: BriefPalette(colors: ["#FB923C", "#F472B6", "#F7B32B"].map { Color(hex: $0) }, accent: Color(hex: "#FB923C"))
        case 12..<17: BriefPalette(colors: ["#3B9EFF", "#22D3EE", "#34D399"].map { Color(hex: $0) }, accent: Color(hex: "#3B9EFF"))
        case 17..<21: BriefPalette(colors: ["#A78BFA", "#F472B6", "#FB923C"].map { Color(hex: $0) }, accent: Color(hex: "#A78BFA"))
        default: BriefPalette(colors: ["#6366F1", "#3B9EFF", "#A78BFA"].map { Color(hex: $0) }, accent: Color(hex: "#818CF8"))
        }
    }
}

/// Fades, rises and sharpens into place `delay` seconds after it appears.
struct BriefAppear: ViewModifier {
    let delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .blur(radius: shown ? 0 : 6)
            .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.82).delay(delay)) { shown = true } }
    }
}

extension View {
    func briefAppear(_ delay: Double = 0) -> some View { modifier(BriefAppear(delay: delay)) }
}

/// The first card: the brief's name, then yours, very large, word by word; a few words of what is
/// inside; Mochi hopping in.
struct BriefIntroCard: View {
    let kicker: String          // "Daily brief · Saturday, 24 October"
    let greeting: String        // "Good morning,"
    let name: String?           // "Aakash"
    let lines: [(symbol: String, text: String)]
    let palette: BriefPalette
    @State private var hop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer(minLength: 0)
            Text(kicker.uppercased()).font(.system(size: 12, weight: .heavy)).tracking(2).foregroundColor(palette.accent)
                .briefAppear(0.05)
            VStack(alignment: .leading, spacing: 0) {
                words(greeting, size: 44, weight: .semibold, color: HubTheme.body, start: 0.15)
                if let name, !name.isEmpty {
                    Text(name)
                        .font(.system(size: 84, weight: .heavy, design: .rounded))
                        .foregroundStyle(LinearGradient(colors: palette.colors + [.white], startPoint: .leading, endPoint: .trailing))
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .briefAppear(0.15 + 0.12 * Double(greeting.split(separator: " ").count) + 0.1)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                    HStack(spacing: 10) {
                        Image(systemName: l.symbol).font(.system(size: 13, weight: .semibold)).foregroundColor(palette.accent)
                            .frame(width: 28, height: 28).background(Circle().fill(palette.accent.opacity(0.15)))
                        Text(l.text).font(.system(size: 15)).foregroundColor(HubTheme.body).lineLimit(1)
                    }
                    .briefAppear(0.9 + 0.15 * Double(i))
                }
            }
            Spacer(minLength: 0)
            HStack {
                Text("Click or press → to begin").font(.system(size: 12)).foregroundColor(HubTheme.muted)
                    .briefAppear(1.5)
                Spacer()
                DesignMochi(size: 96, mode: hop ? .once : .idle)
                    .frame(width: 104, height: 90)
                    .offset(y: hop ? 0 : 120)
                    .rotationEffect(.degrees(hop ? 0 : -12))
            }
        }
        .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.55).delay(0.6)) { hop = true } }
    }

    /// The words arrive one after the other.
    private func words(_ text: String, size: CGFloat, weight: Font.Weight, color: Color, start: Double) -> some View {
        let parts = text.split(separator: " ").map(String.init)
        return HStack(spacing: size * 0.25) {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, w in
                Text(w).font(.system(size: size, weight: weight)).foregroundColor(color)
                    .briefAppear(start + 0.12 * Double(i))
            }
        }
        .lineLimit(1).minimumScaleFactor(0.5)
    }
}
#endif
