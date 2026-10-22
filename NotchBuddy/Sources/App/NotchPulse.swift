import SwiftUI

// MARK: - NotchPulse (coucou-custom fork)
//
// What the notch does for an event that does not open it: a short sound, a wiggle, and a soft
// spotlight halo that blooms around the notch and fades (NotchHalo). See NotchAlertRules for
// which events open the notch instead. Animates only while a pulse runs (~1.8 s): no CPU
// when nothing happens.

@MainActor
final class NotchPulse: ObservableObject {
    static let shared = NotchPulse()

    enum Kind: String {
        case sessionStart, agentStart, agentDone, agentsRunning, finishedQuiet, errorQuiet

        var sound: String {
            switch self {
            case .sessionStart:  "work"
            case .agentStart:    "pop"
            case .agentDone:     "tick"
            case .agentsRunning: "blip"
            case .finishedQuiet: "finish"
            case .errorQuiet:    "error"
            }
        }

        var color: Color { Color(hex: hex) }

        /// The second colour of the halo's gradient: the same hue family, shifted, so the glow
        /// shimmers instead of being one flat colour.
        var companion: Color {
            switch self {
            case .sessionStart:  Color(hex: "#F472B6")   // orange → pink
            case .agentStart:    Color(hex: "#818CF8")   // cyan → indigo
            case .agentDone, .finishedQuiet: Color(hex: "#22D3EE")   // green → cyan
            case .agentsRunning: Color(hex: "#FB7185")   // amber → rose
            case .errorQuiet:    Color(hex: "#F59E0B")   // red → amber
            }
        }

        private var hex: String {
            switch self {
            case .sessionStart:  "#E07950"
            case .agentStart:    "#22D3EE"
            case .agentDone, .finishedQuiet: "#4ADE80"
            case .agentsRunning: "#F5A623"
            case .errorQuiet:    "#F87171"
            }
        }
    }

    struct Ring: Equatable {
        let id = UUID()
        let color: Color
        let companion: Color
        let start: Date
    }

    @Published private(set) var ring: Ring?
    @Published private(set) var wiggle = 0
    private var lastSound = Date.distantPast

    static let ringDuration: TimeInterval = 1.8

    /// `quiet`: the session's terminal is in front (upstream's rule): no sound, still the light.
    func signal(_ kind: Kind, quiet: Bool) {
        guard NotchAlertRules.setting(NotchAlertRules.ambientKey) else {
            // Ambient off: upstream's sounds only.
            if !quiet, [.sessionStart, .finishedQuiet, .errorQuiet].contains(kind) { SoundEngine.shared.play(kind.sound) }
            return
        }
        let now = Date()
        if !quiet, NotchAlertRules.playsSound(last: lastSound, now: now) {
            SoundEngine.shared.play(kind.sound)
            lastSound = now
        }
        appendAppLog("nb.log", "[Notch] pulse: \(kind.rawValue)")
        // Open notch: the card already shows it, no light over the content.
        guard AppState.shared.mode != .expanded else { return }
        let r = Ring(color: kind.color, companion: kind.companion, start: now)
        ring = r
        wiggle += 1
        // Mochi reacts to every pulse, so a start is as visible as an end.
        let emote: BotEmote = switch kind {
        case .sessionStart:  .surprised
        case .agentStart:    .wink
        case .agentsRunning: .proud
        case .agentDone, .finishedQuiet: .happy
        case .errorQuiet:    .annoyed
        }
        NotificationCenter.default.post(name: .triggerEmote, object: emote)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.ringDuration + 0.1) { [weak self] in
            if self?.ring?.id == r.id { self?.ring = nil }
        }
    }
}

// MARK: - Spotlight halo

/// A blurred colour glow that blooms around the notch and fades, plus a soft spotlight cast
/// below it. Drawn behind the black island, so only what spills past its edges shows.
struct NotchHalo: View {
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    let topRadius: CGFloat
    @ObservedObject private var pulse = NotchPulse.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: pulse.ring == nil)) { context in
            if let ring = pulse.ring {
                let t = context.date.timeIntervalSince(ring.start)
                let d = NotchPulse.ringDuration
                if t >= 0 && t < d {
                    let p = t / d
                    // Quick rise, long soft fall.
                    let intensity = min(1, t / 0.25) * pow(max(0, 1 - p), 1.6)
                    let bloom = reduceMotion ? 1.08 : 1.0 + 0.2 * (1 - pow(1 - p, 3))
                    let turn = reduceMotion ? 0.0 : 180.0 * p
                    let shape = IslandShape(width: width, height: height, cornerRadius: cornerRadius, topRadius: topRadius)
                    ZStack {
                        // Aura hugging the notch outline.
                        shape
                            .fill(AngularGradient(colors: [ring.color, ring.companion, ring.color.opacity(0.7),
                                                           ring.companion, ring.color],
                                                  center: .center, angle: .degrees(turn)))
                            .scaleEffect(x: bloom, y: 1 + (bloom - 1) * 2.4, anchor: .top)
                            .blur(radius: 16 + 12 * p)
                            .opacity(min(1, 1.15 * intensity))
                        // Spotlight cast down from the notch.
                        Ellipse()
                            .fill(RadialGradient(colors: [ring.color.opacity(0.75), ring.companion.opacity(0.35), .clear],
                                                 center: .center, startRadius: 0, endRadius: width * 0.55))
                            .frame(width: width * 1.4, height: height * 3 + 40)
                            .offset(y: height * 0.6)
                            .blur(radius: 20)
                            .opacity(0.85 * intensity)
                    }
                    .frame(width: width, height: height, alignment: .top)
                }
            }
        }
        .frame(width: width, height: height, alignment: .top)
        .allowsHitTesting(false)
    }
}

// MARK: - Wiggle

/// A small horizontal shake of the notch on each pulse.
struct NotchWiggle: ViewModifier {
    @ObservedObject private var pulse = NotchPulse.shared
    @State private var offset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .onChange(of: pulse.wiggle) { _, _ in
                guard !reduceMotion else { return }
                let steps: [CGFloat] = [3, -3, 2, -1.5, 0]
                for (i, x) in steps.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.07 * Double(i)) {
                        withAnimation(.easeInOut(duration: 0.07)) { offset = x }
                    }
                }
            }
    }
}
