#if !APPSTORE
import AVFoundation
import SwiftUI

// MARK: - VoiceLevels (coucou-custom fork)

/// Nine frequency bands of what the mic hears while Coucou listens (the FFT Flow's pill already
/// uses), and the loudness of what Coucou says. Read every frame by `VoiceWaveView`.
final class VoiceLevels: @unchecked Sendable {
    static let shared = VoiceLevels()
    private let bands = FlowAudioBands()
    func consume(_ buffer: AVAudioPCMBuffer) { bands.consume(buffer) }
    func reset() { bands.reset() }
    var mic: [Float] { bands.levels }
}

// MARK: - VoiceWaveView

/// The listening animation: three coloured waves in the notch, breathing with the voice.
/// Listening follows the mic bands, thinking is a slow travelling swell, speaking follows
/// Coucou's own loudness, and the timeline pauses when voice is off so a hidden island costs
/// nothing. Own palette, on purpose not Siri's.
struct VoiceWaveView: View {
    @ObservedObject private var state = AppState.shared
    /// Narrow: inside the compact pill. Wide: the bottom of the voice card.
    var compact = true

    @State private var smooth = WaveSmoother()   // a class: the Canvas closure may not mutate state

    private static let colors: [Color] = [Color(hex: "#F97316"), Color(hex: "#22D3EE"), Color(hex: "#F472B6")]

    var body: some View {
        let active = state.voiceActive
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { context in
            Canvas { ctx, size in
                let t = context.date.timeIntervalSinceReferenceDate
                let sub = state.voiceSubState
                let levels = smooth.frame(at: context.date, target: WaveMath.target(for: sub, at: t))
                let thinking = sub == .thinking
                ctx.blendMode = .plusLighter
                for k in 0..<Self.colors.count {
                    let path = WaveMath.path(wave: k, levels: levels, time: t, size: size, compact: compact, thinking: thinking)
                    ctx.stroke(path, with: .color(Self.colors[k].opacity(thinking ? 0.55 : 0.85)), lineWidth: compact ? 1.6 : 2.2)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The numbers behind the waves, kept out of the view body (the type-checker thanks you).
enum WaveMath {
    @MainActor static func target(for sub: BotVoiceSubState, at t: Double) -> [Float] {
        switch sub {
        case .listening:
            return VoiceLevels.shared.mic
        case .speaking:
            let out = VoiceSpeaker.shared.outputLevel
            let base: Float = out < 0 ? Float(0.35 + 0.3 * sin(t * 9) * sin(t * 2.3)) : Float(out)
            return (0..<9).map { (i: Int) -> Float in base * Float(0.6 + 0.4 * sin(Double(i) * 0.9 + t * 5)) }
        case .thinking:
            return (0..<9).map { (i: Int) -> Float in Float(0.18 + 0.12 * sin(t * 1.6 + Double(i) * 0.7)) }
        case .none:
            return [Float](repeating: 0, count: 9)
        }
    }

    static func path(wave k: Int, levels: [Float], time t: Double, size: CGSize, compact: Bool, thinking: Bool) -> Path {
        var path = Path()
        let energy: Double = Double(levels.reduce(0, +)) / Double(max(1, levels.count))
        let mid: Double = size.height / 2
        let idle: Double = compact ? 0.6 : 1.0
        let gain: Double = compact ? 9 : 14
        let phase: Double = t * (1.9 + Double(k) * 0.45) * (thinking ? 0.45 : 1)
        let freq: Double = (compact ? 2.2 : 3.0) + Double(k) * 0.5
        let scale: Double = k == 0 ? 1 : 0.8
        let steps = max(8, Int(size.width / 2))
        for s in 0...steps {
            let x: Double = Double(s) / Double(steps)
            // Quiet at the edges; each x region follows its own band.
            let env: Double = pow(1 - pow(2 * x - 1, 2), 1.4)
            let band: Double = Double(levels[min(8, Int(x * 8.99))])
            let amp: Double = (idle + band * gain + energy * 3) * env
            let y: Double = mid + sin(x * .pi * 2 * freq + phase + Double(k) * 1.3) * amp * scale
            let point = CGPoint(x: x * size.width, y: y)
            if s == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

/// Eases nine levels toward their targets: fast up, slower down, so 20 Hz mic frames read as
/// motion at 30 fps instead of steps.
final class WaveSmoother {
    private var levels = [Float](repeating: 0, count: 9)
    private var last = Date.distantPast

    func frame(at date: Date, target: [Float]) -> [Float] {
        let dt = Float(min(0.1, max(0.001, date.timeIntervalSince(last))))
        last = date
        for i in 0..<9 {
            let want = i < target.count ? min(1, max(0, target[i])) : 0
            let k: Float = want > levels[i] ? 18 : 6
            levels[i] += (want - levels[i]) * min(1, k * dt)
        }
        return levels
    }
}

// MARK: - VoiceGlowRim

/// A flowing colour rim around the voice card, Apple-Intelligence-like in idea, in Coucou's
/// colours: a rotating angular gradient stroked three times with growing blur. Breathes with
/// the voice; still when voice is off.
struct VoiceGlowRim: View {
    @ObservedObject private var state = AppState.shared
    let cornerRadius: CGFloat

    var body: some View {
        let active = state.voiceActive
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let level = CGFloat(VoiceLevels.shared.mic.max() ?? 0)
            let breathing = state.voiceSubState == .listening ? level : CGFloat(0.25 + 0.2 * sin(t * 2.4))
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            let gradient = AngularGradient(
                colors: [Color(hex: "#F97316"), Color(hex: "#F472B6"), Color(hex: "#22D3EE"), Color(hex: "#F97316")],
                center: .center, angle: .degrees(t * 40))
            ZStack {
                shape.strokeBorder(gradient, lineWidth: 1.2 + breathing * 1.4)
                shape.strokeBorder(gradient, lineWidth: 2 + breathing * 3).blur(radius: 5)
                shape.strokeBorder(gradient, lineWidth: 3 + breathing * 5).blur(radius: 14).opacity(0.55)
            }
            .opacity(active ? 0.5 + breathing * 0.5 : 0)
            .compositingGroup()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
