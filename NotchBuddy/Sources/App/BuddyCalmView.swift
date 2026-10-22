#if !APPSTORE
import SwiftUI

// coucou-custom fork: the calm corner's breathing session. The desktop Buddy itself breathes
// (it grows as the lungs fill). Full screen (BuddyCalmFullView) uses the screen: the step and its
// guidance at the top, the Buddy in a glowing orb in the middle with the seconds under it, the
// breaths and the controls in a bar at the bottom. Otherwise, and once the Buddy is dragged away,
// a small card by the Buddy (BuddyCalmView): the rhythm, the step and its seconds, the steps of
// one breath, the breaths and time left, one main button. In Coucou's look (BuddyDesign).

/// What the guide says at a moment, for the card and full screen alike.
struct BuddyBreathModel {
    let session: BuddyBreathSession
    let phase: BuddyBreathSession.Phase
    let now: Date

    init(_ s: BuddyBreathSession, now: Date) {
        session = s
        phase = s.phase(at: now)
        self.now = now
    }

    /// Not started yet: waiting for Start.
    var fresh: Bool { session.isPaused && session.elapsed(at: now) <= -BuddyBreathSession.leadIn + 0.01 }
    var tint: Color { BuddyCalmView.tint(phase) }

    var title: String {
        if fresh { return "Breathe with Mochi" }
        switch phase {
        case .settling: return session.isPaused ? "Paused" : "Get ready"
        case .breathing(let p): return session.isPaused ? "Paused" : p.step.label
        case .done: return "Nicely done"
        }
    }

    var line: String {
        if fresh { return "\(session.pattern.hint). Press Start when you are ready." }
        switch phase {
        case .settling: return session.isPaused ? "Resume when you are ready" : "Settle in, let your shoulders drop"
        case .breathing(let p): return session.isPaused ? "Resume when you are ready" : p.step.guidance
        case .done: return "\(session.pattern.cycles) breaths, \(BuddyTimeText.duration(TimeInterval(session.pattern.totalSeconds))). Take a moment."
        }
    }

    /// The step's seconds left (or the settling count).
    var count: String? {
        if fresh { return nil }
        switch phase {
        case .settling(let left): return "\(left)"
        case .breathing(let p): return "\(p.left)"
        case .done: return nil
        }
    }

    /// The breath now, 1-based; 0 before, past the last once done.
    var cycle: Int {
        switch phase {
        case .settling: 0
        case .breathing(let p): p.cycle
        case .done: session.pattern.cycles + 1
        }
    }

    var meta: String {
        "\(BuddyTimeText.clock(session.remaining(at: now))) left · \(session.pattern.pace) / min"
    }

    var primary: String {
        if phase == .done { return "Done" }
        if fresh { return "Start" }
        return session.isPaused ? "Resume" : "Pause"
    }
}

/// Start, pause, resume, close: the main button's job.
@MainActor
private func breathPrimary(_ m: BuddyBreathModel, _ routines: BuddyRoutineController) {
    if m.phase == .done { routines.stopBreathing() }
    else if m.session.isPaused { routines.resumeBreathing() }
    else { routines.pauseBreathing() }
}

/// The rhythm as a chip: its name and timing; a tap opens the list (BuddyRhythmList).
struct BuddyRhythmChip: View {
    let current: BuddyBreathing
    @Binding var open: Bool

    var body: some View {
        Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { open.toggle() } } label: {
            HStack(spacing: 6) {
                Image(systemName: "leaf.fill").font(.system(size: 10, weight: .semibold)).foregroundColor(BuddyPalette.green)
                Text(current.name).font(.system(size: 12, weight: .bold)).foregroundColor(BuddyPalette.text)
                Text(current.detail).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundColor(BuddyPalette.secondary)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundColor(BuddyPalette.muted)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(Color.white.opacity(open ? 0.12 : 0.07)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Change the rhythm")
    }
}

/// The rhythms, each with its timing and what it is for; picking one starts it over.
struct BuddyRhythmList: View {
    @ObservedObject var routines: BuddyRoutineController
    let current: BuddyBreathing
    @Binding var open: Bool

    var body: some View {
        VStack(spacing: 2) {
            ForEach(BuddyBreathing.allCases) { p in
                let on = p == current
                Button {
                    routines.restartBreathing(p)
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { open = false }
                } label: {
                    HStack(spacing: 10) {
                        Text(p.name).font(.system(size: 12.5, weight: .semibold)).foregroundColor(BuddyPalette.text)
                            .frame(width: 78, alignment: .leading)
                        Text(p.detail).font(.system(size: 11, design: .monospaced)).foregroundColor(BuddyPalette.secondary)
                            .frame(width: 58, alignment: .leading)
                        Text(p.hint).font(.system(size: 11)).foregroundColor(BuddyPalette.muted).lineLimit(1)
                        Spacer(minLength: 4)
                        if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(BuddyPalette.green) }
                    }
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(on ? 0.08 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.25)))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// One breath's steps, as wide as they last; the one now fills up.
struct BuddyBreathTrack: View {
    let model: BuddyBreathModel
    var height: CGFloat = 6
    var labels = true

    var body: some View {
        let steps = model.session.pattern.steps
        let total = CGFloat(model.session.pattern.breathSeconds)
        GeometryReader { g in
            let gap: CGFloat = 4
            let w = max(0, g.size.width - gap * CGFloat(steps.count - 1))
            HStack(spacing: gap) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    let fill: Double = {
                        switch model.phase {
                        case .breathing(let p): i < p.index ? 1 : (i == p.index ? p.progress : 0)
                        case .done: 1
                        case .settling: 0
                        }
                    }()
                    let width = w * CGFloat(step.1) / total
                    VStack(alignment: .leading, spacing: 5) {
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                            Capsule().fill(BuddyCalmView.color(step.0)).frame(width: width * fill)
                        }
                        .frame(height: height)
                        if labels {
                            Text("\(step.0 == .inhale ? "In" : step.0 == .exhale ? "Out" : "Hold") \(step.1)s")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(BuddyPalette.muted)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                    .frame(width: width)
                }
            }
        }
        .frame(height: labels ? height + 18 : height)
    }
}

/// A dot per breath: done ones dim, the one now lit and a little bigger.
struct BuddyBreathDots: View {
    let model: BuddyBreathModel
    var size: CGFloat = 7

    var body: some View {
        HStack(spacing: size * 0.8) {
            ForEach(1...model.session.pattern.cycles, id: \.self) { i in
                Circle()
                    .fill(i < model.cycle ? model.tint.opacity(0.5) : (i == model.cycle ? model.tint : Color.white.opacity(0.12)))
                    .frame(width: size, height: size)
                    .scaleEffect(i == model.cycle && !model.session.isPaused ? 1.35 : 1)
                    .animation(.easeInOut(duration: 0.5), value: model.cycle)
            }
        }
    }
}

// MARK: - The card by the Buddy

struct BuddyCalmView: View {
    @ObservedObject var routines: BuddyRoutineController
    @ObservedObject var settings = BuddyRoutineSettings.shared
    @State private var rhythms = false
    /// Its size as it changes (the rhythm list opening): the window follows.
    var onSize: ((CGSize) -> Void)? = nil

    static let width: CGFloat = 316

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: routines.breathing?.isPaused ?? true)) { tl in
            if let s = routines.breathing { card(BuddyBreathModel(s, now: tl.date)) }
        }
        .frame(width: Self.width)
        .padding(12)
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize?($0) }
    }

    private func card(_ m: BuddyBreathModel) -> some View {
        BuddyCard(tint: m.tint, radius: 20, wash: 0.36) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    BuddyRhythmChip(current: m.session.pattern, open: $rhythms)
                    Spacer(minLength: 4)
                    BuddyIconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Full screen") { routines.setBreathingFull(true) }
                    BuddyIconButton(symbol: settings.breathingCues ? "speaker.wave.2.fill" : "speaker.slash.fill",
                                    help: settings.breathingCues ? "Mute the breathing cues" : "A soft sound at each breath") {
                        settings.breathingCues.toggle()
                    }
                    BuddyIconButton(symbol: "xmark", help: "Close (Esc)") { routines.stopBreathing() }
                }
                if rhythms { BuddyRhythmList(routines: routines, current: m.session.pattern, open: $rhythms) }
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(m.title)
                            .font(.system(size: 19, weight: .bold))
                            .foregroundColor(BuddyPalette.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text(m.line)
                            .font(.system(size: 12))
                            .foregroundColor(BuddyPalette.secondary)
                            .lineLimit(2)
                            .frame(height: 32, alignment: .topLeading)   // the card keeps its height
                    }
                    .animation(.easeInOut(duration: 0.3), value: m.title)
                    Spacer(minLength: 4)
                    if let c = m.count {
                        Text(c)
                            .font(.system(size: 38, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(m.tint)
                            .contentTransition(.numericText())
                            .animation(.easeOut(duration: 0.25), value: c)
                            .frame(minWidth: 34, alignment: .trailing)
                    } else {
                        Image(systemName: m.phase == .done ? "checkmark.circle.fill" : "lungs.fill")
                            .font(.system(size: 28)).foregroundColor(m.tint)
                    }
                }
                BuddyBreathTrack(model: m)
                HStack(spacing: 8) {
                    BuddyBreathDots(model: m, size: 6)
                    Spacer(minLength: 6)
                    Text(m.meta)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(BuddyPalette.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                HStack(spacing: 8) {
                    if !m.fresh {
                        BuddyRoundButton(symbol: "arrow.counterclockwise", help: m.phase == .done ? "Again" : "Restart") {
                            routines.restartBreathing()
                        }
                    }
                    Button { breathPrimary(m, routines) } label: {
                        Text(m.primary).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BuddyPillButtonStyle(tint: m.tint))
                    .keyboardShortcut(.space, modifiers: [])
                }
            }
            .padding(16)
        }
    }

    static func footer(_ s: BuddyBreathSession, phase: BuddyBreathSession.Phase) -> String {
        switch phase {
        case .done: "Mochi feels calmer too"
        case .settling where s.isPaused: "Mochi is ready when you are"
        default: "Breathing with Mochi"
        }
    }

    static func color(_ step: BuddyBreathing.Step) -> Color {
        switch step {
        case .inhale: BuddyPalette.cyan
        case .holdFull: BuddyPalette.violet
        case .exhale: BuddyPalette.green
        case .holdEmpty: BuddyPalette.indigo
        }
    }

    static func tint(_ phase: BuddyBreathSession.Phase) -> Color {
        switch phase {
        case .breathing(let p): color(p.step)
        case .settling: BuddyPalette.indigo
        case .done: BuddyPalette.green
        }
    }
}

/// A round glass button with a symbol, the size of the pills.
struct BuddyRoundButton: View {
    let symbol: String
    var help = ""
    var size: CGFloat = 27
    let run: () -> Void

    var body: some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundColor(Color(hex: "#E1E3E6"))
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Full screen

/// The screen, dimmed: the step at the top, the Buddy in its orb in the middle (its own window, over
/// this one) with the seconds under it, the breaths and the controls at the bottom.
struct BuddyCalmFullView: View {
    @ObservedObject var routines: BuddyRoutineController
    @ObservedObject var settings = BuddyRoutineSettings.shared
    /// The orb's radius: a little more than the Buddy.
    let radius: CGFloat
    /// The orb's centre in the view (y down): where the Buddy's square is centred.
    let center: CGPoint
    @State private var rhythms = false
    @State private var dim = false
    @State private var revealed = false
    @State private var burst = false

    var body: some View {
        GeometryReader { g in
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: routines.breathing?.isPaused ?? true)) { tl in
                if let s = routines.breathing {
                    let m = BuddyBreathModel(s, now: tl.date)
                    ZStack {
                        Color.black.opacity(dim ? 0.88 : 0)
                        RadialGradient(colors: [m.tint.opacity(dim ? 0.2 : 0), .clear],
                                       center: UnitPoint(x: center.x / max(1, g.size.width), y: center.y / max(1, g.size.height)),
                                       startRadius: radius, endRadius: max(g.size.width, g.size.height) * 0.55)
                        BuddyOrb(session: s, now: tl.date, radius: radius)
                            .frame(width: radius * 3, height: radius * 3)
                            .position(center)
                            .scaleEffect(revealed ? 1 : 0.6, anchor: UnitPoint(x: center.x / max(1, g.size.width), y: center.y / max(1, g.size.height)))
                            .opacity(revealed ? 1 : 0)
                        // The boom: one ring out from the Buddy as the session opens.
                        Circle()
                            .stroke(m.tint.opacity(burst ? 0 : 0.9), lineWidth: burst ? 1 : 6)
                            .frame(width: radius * 2, height: radius * 2)
                            .scaleEffect(burst ? 2.6 : 0.4)
                            .position(center)
                        top(m, in: g.size)
                        countdown(m)
                        bottom(m, in: g.size)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) { dim = true }
            withAnimation(.spring(response: 0.7, dampingFraction: 0.72).delay(0.55)) { revealed = true }
            withAnimation(.easeOut(duration: 1.1).delay(0.7)) { burst = true }
        }
    }

    /// The step, large, at the top centre.
    private func top(_ m: BuddyBreathModel, in size: CGSize) -> some View {
        VStack(spacing: 10) {
            Text("\(m.session.pattern.name) · \(m.session.pattern.detail)".uppercased())
                .font(.system(size: 12, weight: .bold))
                .tracking(2)
                .foregroundColor(m.tint.opacity(0.9))
            Text(m.title)
                .font(.system(size: min(64, size.width / 18), weight: .bold, design: .rounded))
                .foregroundColor(BuddyPalette.text)
                .contentTransition(.opacity)
            Text(m.line)
                .font(.system(size: 18))
                .foregroundColor(BuddyPalette.body)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
        }
        .animation(.easeInOut(duration: 0.4), value: m.title)
        .position(x: center.x, y: max(110, min(size.height * 0.17, center.y - radius * 1.5 - 90)))
        .opacity(revealed ? 1 : 0)
        .offset(y: revealed ? 0 : -24)
    }

    /// The step's seconds, under the orb.
    private func countdown(_ m: BuddyBreathModel) -> some View {
        VStack(spacing: 0) {
            if let c = m.count {
                Text(c)
                    .font(.system(size: 64, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(m.tint)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.25), value: c)
                Text(m.count == nil ? "" : "SECONDS")
                    .font(.system(size: 10, weight: .bold)).tracking(2)
                    .foregroundColor(BuddyPalette.muted)
            } else {
                Text(BuddyCalmView.footer(m.session, phase: m.phase))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(BuddyPalette.body)
            }
        }
        .position(x: center.x, y: center.y + radius * 1.4 + 52)
        .opacity(revealed ? 1 : 0)
    }

    /// The breaths and the controls, in a bar at the bottom centre.
    private func bottom(_ m: BuddyBreathModel, in size: CGSize) -> some View {
        let wide = size.width >= 980
        return VStack(spacing: 12) {
            VStack(spacing: 14) {
            if rhythms && !wide {
                BuddyRhythmList(routines: routines, current: m.session.pattern, open: $rhythms)
                    .frame(width: 340)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BuddyPalette.card))
            }
            HStack(spacing: 14) {
                BuddyBreathDots(model: m, size: 9)
                Text(m.meta)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(BuddyPalette.secondary)
            }
            BuddyBreathTrack(model: m, height: 6, labels: true)
                .frame(width: min(520, size.width - 80))
            HStack(spacing: 14) {
                if wide {
                    HStack(spacing: 5) {
                        ForEach(BuddyBreathing.allCases) { p in
                            let on = p == m.session.pattern
                            Button { routines.restartBreathing(p) } label: {
                                VStack(spacing: 1) {
                                    Text(p.name).font(.system(size: 12, weight: .bold))
                                    Text(p.detail).font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundColor(on ? BuddyPalette.text.opacity(0.75) : BuddyPalette.muted)
                                }
                                .foregroundColor(on ? BuddyPalette.text : BuddyPalette.body)
                                .frame(width: 82, height: 40)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(on ? m.tint.opacity(0.22) : Color.white.opacity(0.04)))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(on ? m.tint.opacity(0.6) : Color.clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(p.hint)
                        }
                    }
                } else {
                    BuddyRhythmChip(current: m.session.pattern, open: $rhythms)
                }
                divider
                if !m.fresh {
                    BuddyRoundButton(symbol: "arrow.counterclockwise", help: m.phase == .done ? "Again" : "Restart", size: 36) {
                        routines.restartBreathing()
                    }
                }
                Button { breathPrimary(m, routines) } label: {
                    Text(m.primary).font(.system(size: 14, weight: .bold)).frame(width: 120, height: 36)
                }
                .buttonStyle(.plain)
                .foregroundColor(BuddyPalette.ink)
                .background(Capsule().fill(m.tint))
                .contentShape(Capsule())
                .keyboardShortcut(.space, modifiers: [])
                divider
                BuddyRoundButton(symbol: settings.breathingCues ? "speaker.wave.2.fill" : "speaker.slash.fill",
                                 help: settings.breathingCues ? "Mute the breathing cues" : "A soft sound at each breath", size: 36) {
                    settings.breathingCues.toggle()
                }
                BuddyRoundButton(symbol: "arrow.down.right.and.arrow.up.left", help: "A small card instead", size: 36) {
                    routines.setBreathingFull(false)
                }
                BuddyRoundButton(symbol: "xmark", help: "Close (Esc)", size: 36) { routines.stopBreathing() }
            }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(BuddyPalette.card.opacity(0.96)))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
            Text("Drag Mochi away to go on in a small card  ·  Space pauses  ·  Esc closes")
                .font(.system(size: 11))
                .foregroundColor(BuddyPalette.muted)
        }
        .position(x: size.width / 2, y: size.height - 150)
        .opacity(revealed ? 1 : 0)
        .offset(y: revealed ? 0 : 30)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: 26)
    }
}

/// The orb: a deep disc whose light swells as the lungs fill, a ripple at each new step, motes.
struct BuddyOrb: View {
    let session: BuddyBreathSession
    let now: Date
    let radius: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let s = session
            let phase = s.phase(at: now)
            let t = now.timeIntervalSinceReferenceDate
            var full = 0.22 + 0.06 * sin(t * 0.8)
            var ripple: Double? = nil
            var color = BuddyPalette.indigo
            switch phase {
            case .breathing(let p):
                full = BuddyBreathing.fullness(step: p.step, progress: p.progress)
                color = BuddyCalmView.color(p.step)
                ripple = p.progress * Double(s.pattern.steps[p.index].1)
            case .settling: full = 0.12
            case .done:
                full = 0.35 + 0.05 * sin(t * 0.8)
                color = BuddyPalette.green
            }
            if s.isPaused { full *= 0.7 }
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = radius * (0.9 + 0.12 * full)

            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 1.45, y: c.y - r * 1.45, width: r * 2.9, height: r * 2.9)),
                     with: .radialGradient(Gradient(stops: [
                        .init(color: color.opacity(0.14 + 0.26 * full), location: 0.66),
                        .init(color: color.opacity(0.05 + 0.08 * full), location: 0.8),
                        .init(color: .clear, location: 1),
                     ]), center: c, startRadius: 0, endRadius: r * 1.45))
            let disc = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ctx.fill(disc, with: .radialGradient(Gradient(colors: [Color(hex: "#1B1D3A"), Color(hex: "#0E0F1C"), Color(hex: "#08090F")]),
                                                 center: CGPoint(x: c.x, y: c.y - r * 0.2), startRadius: 0, endRadius: r))
            ctx.fill(disc, with: .radialGradient(Gradient(colors: [color.opacity(0.22 + 0.5 * full), .clear]),
                                                 center: c, startRadius: 0, endRadius: r * (0.45 + 0.5 * full)))
            let drift = CGPoint(x: c.x + cos(t * 0.21) * r * 0.35, y: c.y + sin(t * 0.17) * r * 0.3)
            ctx.fill(disc, with: .radialGradient(Gradient(colors: [BuddyPalette.violet.opacity(0.18), .clear]),
                                                 center: drift, startRadius: 0, endRadius: r * 0.7))
            for i in 0..<18 {
                let a = Double(i) * 2.399 + t * 0.03
                let d = r * (0.25 + 0.7 * Double((i * 37) % 11) / 11)
                let p = CGPoint(x: c.x + cos(a) * d, y: c.y + sin(a) * d * 0.9)
                let tw = 0.25 + 0.75 * (0.5 + 0.5 * sin(t * (1.3 + Double(i % 5) * 0.4) + Double(i)))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 1.3, y: p.y - 1.3, width: 2.6, height: 2.6)), with: .color(.white.opacity(0.5 * tw)))
            }
            ctx.stroke(disc, with: .color(color.opacity(0.35 + 0.3 * full)), lineWidth: 1.5)
            if let age = ripple, age < 1.6 {
                let k = age / 1.6
                let rr = r * (1 + 0.3 * k)
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)),
                           with: .color(color.opacity(0.5 * (1 - k) * (1 - k))), lineWidth: 2)
            }
        }
    }
}
#endif
