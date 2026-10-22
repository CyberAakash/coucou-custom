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
        case sessionStart, promptSent, agentStart, agentDone, agentsRunning, finishedQuiet, errorQuiet

        var sound: String {
            switch self {
            case .sessionStart:  "work"
            case .promptSent:    "send"
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
            case .promptSent:    ["#60A5FA", "#A78BFA", "#22D3EE"]   // blue, violet, cyan
            case .agentStart:    ["#22D3EE", "#818CF8", "#60A5FA"]   // cyan, indigo, blue
            case .agentsRunning: ["#F5A623", "#FB7185", "#FBBF24"]   // amber, rose, gold
            case .agentDone, .finishedQuiet: ["#4ADE80", "#22D3EE", "#A3E635"]   // green, cyan, lime
            case .errorQuiet:    ["#F87171", "#F59E0B", "#EF4444"]   // red, amber
            }
            return hex.map { Color(hex: $0) }
        }

        var motion: Motion {
            switch self {
            case .sessionStart, .promptSent: .swell
            case .agentStart:    .flicker
            case .agentsRunning: .swell
            case .agentDone, .finishedQuiet: .doublePulse
            case .errorQuiet:    .flare
            }
        }

        var emote: BotEmote {
            switch self {
            case .sessionStart:  .surprised
            case .promptSent:    .listening
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

    /// Settings → Spotlight → Preview: the real path, so sound, wiggle and Mochi play too.
    func preview(_ kind: Kind) { signal(kind, quiet: false) }

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
        let running = NotchAlertRules.setting(SpotlightSettings.breatheKey)
            && LiveSessions.shared.sessions.contains { $0.status == .background || ($0.isBusy && $0.runningSubagents > 0) }
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

/// The aura: a coloured light under the notch, brightest at the notch and fading out with no
/// visible edge. Drawn behind the black island, so only the light around its edges shows.
/// Brightness, size, softness, colours and motion come from Settings → Spotlight.
struct NotchHalo: View {
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    let topRadius: CGFloat
    /// Settings preview: loops this event's motion instead of following real pulses.
    var preview: NotchPulse.Kind? = nil
    @ObservedObject private var pulse = NotchPulse.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(SpotlightSettings.brightnessKey) private var brightness = SpotlightSettings.defaultBrightness
    @AppStorage(SpotlightSettings.sizeKey) private var size = 1.0
    @AppStorage(SpotlightSettings.softnessKey) private var softness = 1.0
    @AppStorage(SpotlightSettings.colorModeKey) private var colorMode = SpotlightSettings.ColorMode.byEvent.rawValue
    @AppStorage(SpotlightSettings.colorKey) private var colorHex = SpotlightSettings.defaultColor
    @AppStorage(SpotlightSettings.motionKey) private var moving = true

    private static let breathPalette = NotchPulse.Kind.agentsRunning.palette

    var body: some View {
        let active = preview != nil || pulse.pulse != nil || pulse.breathing
        TimelineView(.animation(minimumInterval: 1.0 / 40, paused: !active)) { context in
            let now = context.date
            let oneShot: (NotchPulse.Pulse, Double)? = if let preview {
                // The motion, then a short rest, again and again.
                (NotchPulse.Pulse(palette: preview.palette, motion: preview.motion, start: .distantPast),
                 preview.motion.intensity(at: now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: preview.motion.duration + 0.7)))
            } else {
                pulse.pulse.map { ($0, $0.motion.intensity(at: now.timeIntervalSince($0.start))) }
            }
            // The breath: slow, low, ~2.8 s period, only while agents run.
            let breath = preview == nil && pulse.breathing ? 0.22 + 0.18 * (0.5 - 0.5 * cos(2 * .pi * now.timeIntervalSinceReferenceDate / 2.8)) : 0
            let shot = oneShot?.1 ?? 0
            let level = max(shot, breath) * SpotlightSettings.clamped(brightness, SpotlightSettings.brightnessRange)
            if level > 0.01 {
                let palette = shot >= breath ? (oneShot?.0.palette ?? Self.breathPalette) : Self.breathPalette
                aura(level: level, palette: colors(palette), time: now.timeIntervalSinceReferenceDate, calm: shot < breath)
            }
        }
        .frame(width: width, height: height, alignment: .top)
        .allowsHitTesting(false)
    }

    /// The event's palette, or the user's single colour / white in three tints.
    private func colors(_ event: [Color]) -> [Color] {
        switch SpotlightSettings.ColorMode(rawValue: colorMode) ?? .byEvent {
        case .byEvent: return event
        case .single:
            let c = Color(hex: colorHex)
            return [c.mix(with: .white, by: 0.25), c, c.mix(with: .black, by: 0.15)]
        case .white: return [.white, Color(white: 0.88), Color(white: 0.75)]
        }
    }

    /// The lower half of an ellipse centred on the screen's top edge. An elliptical gradient
    /// (it follows the ellipse, so it reaches 0 at the bottom too, unlike a circular one) falls off
    /// steeply from the notch; a wide feathered mask and a blur dissolve the rim. Faint colour
    /// blobs drift near the core in mirrored pairs so the two sides match.
    @ViewBuilder
    private func aura(level: Double, palette: [Color], time: TimeInterval, calm: Bool) -> some View {
        let reach = SpotlightSettings.clamped(size, SpotlightSettings.sizeRange)
        let soft = SpotlightSettings.clamped(softness, SpotlightSettings.softnessRange)
        let grow = reduceMotion ? 1.04 : 1 + 0.1 * level
        let w = (width * 1.35 + 72) * grow * reach   // semicircle width
        let depth = (height + 46) * grow * reach     // how far it reaches below the screen edge
        let h = depth * 2                            // full ellipse height (top half is off screen)
        let speed = (reduceMotion || !moving) ? 0 : (calm ? 0.45 : 1.1)
        let t = time * speed
        let dx = w * (0.11 + 0.04 * sin(t * 1.3))
        let dy = depth * (0.16 + 0.06 * sin(t * 0.9 + 1.2))
        let stopColors = [palette[0], palette[0], palette[1], palette[2], palette[2]]
        let stops = SpotlightSettings.falloff(softness: soft).enumerated().map { i, s in
            Gradient.Stop(color: stopColors[i].opacity(s.opacity), location: s.location)
        }
        ZStack {
            Ellipse().fill(EllipticalGradient(gradient: Gradient(stops: stops), center: .center,
                                              startRadiusFraction: 0, endRadiusFraction: 0.5))
            Group {
                blob(palette[1], size: w * 0.3).offset(x: -dx, y: dy)
                blob(palette[1], size: w * 0.3).offset(x: dx, y: dy)
                blob(palette[2], size: w * 0.24).offset(y: depth * 0.08)
            }
            .opacity(0.35)
        }
        .frame(width: w, height: h)
        .mask(Ellipse().frame(width: w, height: h).blur(radius: depth * 0.25 * soft))
        .blur(radius: 10 * soft)
        .opacity(level)
        // Centre on the notch's top edge: only the lower half is on screen.
        .position(x: width / 2, y: 0)
    }

    private func blob(_ color: Color, size: CGFloat) -> some View {
        Circle().fill(color).frame(width: size, height: size).blur(radius: size * 0.35)
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
