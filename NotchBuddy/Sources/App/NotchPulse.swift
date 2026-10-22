import SwiftUI

// MARK: - NotchPulse (coucou-custom fork)
//
// What the notch does for an event that does not open it: a short sound, a wiggle, and a
// light that runs once around the notch outline (NotchOrbitRing). See NotchAlertRules for
// which events open the notch instead. Animates only while a pulse runs (~1.5 s): no CPU
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

        var color: Color {
            switch self {
            case .sessionStart:  Color(hex: "#E07950")
            case .agentStart:    Color(hex: "#22D3EE")
            case .agentDone, .finishedQuiet: Color(hex: "#4ADE80")
            case .agentsRunning: Color(hex: "#F5A623")
            case .errorQuiet:    Color(hex: "#F87171")
            }
        }
    }

    struct Ring: Equatable {
        let id = UUID()
        let color: Color
        let start: Date
    }

    @Published private(set) var ring: Ring?
    @Published private(set) var wiggle = 0
    private var lastSound = Date.distantPast

    static let ringDuration: TimeInterval = 1.5

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
        let r = Ring(color: kind.color, start: now)
        ring = r
        wiggle += 1
        if kind == .agentDone || kind == .finishedQuiet {
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.ringDuration + 0.1) { [weak self] in
            if self?.ring?.id == r.id { self?.ring = nil }
        }
    }
}

// MARK: - Orbit ring

/// A short bright segment that travels the notch outline ~1.2 laps and fades, with a glow.
struct NotchOrbitRing: View {
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
                    let fade = min(1, t / 0.15) * min(1, (d - t) / 0.4)
                    let shape = IslandShape(width: width, height: height, cornerRadius: cornerRadius, topRadius: topRadius)
                    if reduceMotion {
                        shape.stroke(ring.color, lineWidth: 1.5).opacity(0.8 * fade)
                    } else {
                        let head = (t / d * 1.2).truncatingRemainder(dividingBy: 1)
                        ZStack {
                            segment(shape, from: head, length: 0.24)
                                .stroke(ring.color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                                .blur(radius: 5)
                                .opacity(0.85 * fade)
                            segment(shape, from: head, length: 0.24)
                                .stroke(ring.color.opacity(0.95), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                                .opacity(fade)
                        }
                    }
                }
            }
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
    }

    /// `length` of the outline starting at `from`, wrapping past the end of the path.
    private func segment(_ shape: IslandShape, from: Double, length: Double) -> some Shape {
        WrappedTrim(base: shape, from: from, length: length)
    }
}

private struct WrappedTrim: Shape {
    let base: IslandShape
    let from: Double
    let length: Double

    func path(in rect: CGRect) -> Path {
        let full = base.path(in: rect)
        let end = from + length
        if end <= 1 { return full.trimmedPath(from: from, to: end) }
        var p = full.trimmedPath(from: from, to: 1)
        p.addPath(full.trimmedPath(from: 0, to: end - 1))
        return p
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
