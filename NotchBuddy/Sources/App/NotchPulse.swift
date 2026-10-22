import SwiftUI

// MARK: - NotchPulse (coucou-custom fork)
//
// What the notch does for an event that does not open it: a short sound, a wiggle, Mochi's
// reaction, and a breathing aura around the notch (NotchHalo) — a soft multi-colour glow that
// hugs the notch, swells, lets its colours flow, and settles. Each event has its own motion:
//   session start   one slow swell             agent start   a quick double flicker
//   agents running  a calm breath that keeps going until the last agent finishes
//   done            a bright double pulse      error         a short red flare + bigger shake
// See NotchAlertRules for which events open the notch instead. Draws only while a pulse runs
// or agents are running: no CPU otherwise.

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

        /// Three colours that flow around the aura.
        var palette: [Color] {
            let hex: [String] = switch self {
            case .sessionStart:  ["#FF8A4C", "#F472B6", "#A78BFA"]   // orange, pink, violet
            case .agentStart:    ["#22D3EE", "#818CF8", "#60A5FA"]   // cyan, indigo, blue
            case .agentsRunning: ["#F5A623", "#FB7185", "#FBBF24"]   // amber, rose, gold
            case .agentDone, .finishedQuiet: ["#4ADE80", "#22D3EE", "#A3E635"]   // green, cyan, lime
            case .errorQuiet:    ["#F87171", "#F59E0B", "#EF4444"]   // red, amber
            }
            return hex.map { Color(hex: $0) }
        }

        var motion: Motion {
            switch self {
            case .sessionStart:  .swell
            case .agentStart:    .flicker
            case .agentsRunning: .swell
            case .agentDone, .finishedQuiet: .doublePulse
            case .errorQuiet:    .flare
            }
        }

        var emote: BotEmote {
            switch self {
            case .sessionStart:  .surprised
            case .agentStart:    .wink
            case .agentsRunning: .proud
            case .agentDone, .finishedQuiet: .happy
            case .errorQuiet:    .annoyed
            }
        }
    }

    struct Pulse: Equatable {
        let id = UUID()
        let palette: [Color]
        let motion: Motion
        let start: Date
    }

    @Published private(set) var pulse: Pulse?
    /// Agents are running in some session: the aura keeps a calm breath until they finish.
    @Published private(set) var breathing = false
    @Published private(set) var wiggle = 0
    @Published private(set) var wiggleStrength: CGFloat = 1
    private var lastSound = Date.distantPast
    private var breathingSince: Date?

    /// `quiet`: the session's terminal is in front: no sound, still the light.
    func signal(_ kind: Kind, quiet: Bool) {
        guard NotchAlertRules.setting(NotchAlertRules.ambientKey) else {
            // Ambient off: upstream's sounds only.
            if !quiet, [.sessionStart, .finishedQuiet, .errorQuiet].contains(kind) { SoundEngine.shared.play(kind.sound) }
            breathing = false
            return
        }
        let now = Date()
        if !quiet, NotchAlertRules.playsSound(last: lastSound, now: now) {
            SoundEngine.shared.play(kind.sound)
            lastSound = now
        }
        appendAppLog("nb.log", "[Notch] pulse: \(kind.rawValue)")
        updateBreathing(now: now)
        // Open notch: the card already shows it, no light over the content.
        guard AppState.shared.mode != .expanded else { return }
        let p = Pulse(palette: kind.palette, motion: kind.motion, start: now)
        pulse = p
        wiggleStrength = kind == .errorQuiet ? 1.8 : 1
        wiggle += 1
        // Mochi reacts at the aura's peak, so the two read as one gesture.
        DispatchQueue.main.asyncAfter(deadline: .now() + kind.motion.peak) {
            NotificationCenter.default.post(name: .triggerEmote, object: kind.emote)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + kind.motion.duration + 0.1) { [weak self] in
            if self?.pulse?.id == p.id { self?.pulse = nil }
        }
    }

    /// On while any session waits on background agents; capped at 15 min so a lost event can't
    /// leave it breathing forever.
    private func updateBreathing(now: Date) {
        let running = LiveSessions.shared.sessions.contains { $0.status == .background || ($0.isBusy && $0.runningSubagents > 0) }
        if running {
            if breathingSince == nil { breathingSince = now }
            breathing = now.timeIntervalSince(breathingSince ?? now) < 15 * 60
        } else {
            breathingSince = nil
            breathing = false
        }
    }
}

// MARK: - Motion curves

/// How the aura's intensity moves over time for one event (0…1).
enum Motion: Equatable {
    case swell, flicker, doublePulse, flare

    var duration: TimeInterval {
        switch self {
        case .swell: 1.9
        case .flicker: 0.9
        case .doublePulse: 1.9
        case .flare: 1.1
        }
    }

    /// When the aura is brightest (Mochi reacts then).
    var peak: TimeInterval {
        switch self {
        case .swell: 0.5
        case .flicker: 0.15
        case .doublePulse: 0.3
        case .flare: 0.12
        }
    }

    func intensity(at t: TimeInterval) -> Double {
        guard t >= 0, t < duration else { return 0 }
        func bump(_ center: Double, _ width: Double) -> Double { exp(-pow((t - center) / width, 2)) }
        switch self {
        case .swell:
            // Ease up like an inhale, hold a breath, ease out.
            if t < 0.5 { let x = t / 0.5; return x * x * (3 - 2 * x) }
            let x = (t - 0.5) / (duration - 0.5)
            return 1 - x * x * (3 - 2 * x)
        case .flicker:
            return max(0.85 * bump(0.15, 0.07), 0.6 * bump(0.42, 0.09))
        case .doublePulse:
            return max(bump(0.3, 0.16), 0.75 * bump(0.9, 0.2))
        case .flare:
            return t < 0.12 ? t / 0.12 : exp(-(t - 0.12) * 3.2)
        }
    }
}

// MARK: - Breathing aura

/// The aura: a coloured glow hugging the notch, a wider soft bloom, and a faint light cast below,
/// all on the notch's own shape. Drawn behind the black island, so only the glow around its
/// edges shows. Colours flow around it; the whole thing swells with the motion's intensity.
struct NotchHalo: View {
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    let topRadius: CGFloat
    @ObservedObject private var pulse = NotchPulse.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Calm: noticeable at the edge of vision, never glaring.
    private static let strength = 0.85
    private static let breathPalette = NotchPulse.Kind.agentsRunning.palette

    var body: some View {
        let active = pulse.pulse != nil || pulse.breathing
        TimelineView(.animation(minimumInterval: 1.0 / 40, paused: !active)) { context in
            let now = context.date
            let oneShot = pulse.pulse.map { ($0, $0.motion.intensity(at: now.timeIntervalSince($0.start))) }
            // The breath: slow, low, ~2.8 s period, only while agents run.
            let breath = pulse.breathing ? 0.22 + 0.18 * (0.5 - 0.5 * cos(2 * .pi * now.timeIntervalSinceReferenceDate / 2.8)) : 0
            let shot = oneShot?.1 ?? 0
            let level = max(shot, breath) * Self.strength
            if level > 0.01 {
                let palette = shot >= breath ? (oneShot?.0.palette ?? Self.breathPalette) : Self.breathPalette
                aura(level: level, palette: palette, time: now.timeIntervalSinceReferenceDate, calm: shot < breath)
            }
        }
        .frame(width: width, height: height, alignment: .top)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func aura(level: Double, palette: [Color], time: TimeInterval, calm: Bool) -> some View {
        let shape = IslandShape(width: width, height: height, cornerRadius: cornerRadius, topRadius: topRadius)
        // Colours drift round the notch: slow while breathing, livelier for a one-shot.
        let angle = reduceMotion ? 0 : (time * (calm ? 30 : 110)).truncatingRemainder(dividingBy: 360)
        let flow = AngularGradient(colors: palette + [palette[0]], center: .center, angle: .degrees(angle))
        let swell = reduceMotion ? 0.06 : 0.14 * level
        ZStack {
            // 1. Wide soft bloom.
            shape.fill(flow)
                .scaleEffect(x: 1.18 + swell, y: 1.7 + swell * 3, anchor: .top)
                .blur(radius: 30)
                .opacity(0.4 * level)
            // 2. The aura's body, close to the notch.
            shape.fill(flow)
                .scaleEffect(x: 1.04 + swell, y: 1.12 + swell * 2.2, anchor: .top)
                .blur(radius: 14)
                .opacity(0.8 * level)
            // 3. A brighter rim right at the notch's edge.
            shape.stroke(flow, lineWidth: 6)
                .blur(radius: 5)
                .opacity(0.9 * level)
            // 4. Faint light cast down onto the screen.
            Ellipse()
                .fill(RadialGradient(colors: [palette[0].opacity(0.55), palette[1].opacity(0.2), .clear],
                                     center: .center, startRadius: 0, endRadius: width * 0.5))
                .frame(width: width * 1.2, height: height * 2.6 + 30)
                .offset(y: height * 0.65)
                .blur(radius: 22)
                .opacity(0.45 * level)
        }
        .frame(width: width, height: height, alignment: .top)
    }
}

// MARK: - Wiggle

/// A small horizontal shake of the notch on each pulse (bigger for an error).
struct NotchWiggle: ViewModifier {
    @ObservedObject private var pulse = NotchPulse.shared
    @State private var offset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .onChange(of: pulse.wiggle) { _, _ in
                guard !reduceMotion else { return }
                let k = pulse.wiggleStrength
                let steps: [CGFloat] = [3, -3, 2, -1.5, 0].map { $0 * k }
                for (i, x) in steps.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.07 * Double(i)) {
                        withAnimation(.easeInOut(duration: 0.07)) { offset = x }
                    }
                }
            }
    }
}
