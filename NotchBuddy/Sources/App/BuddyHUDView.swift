#if !APPSTORE
import SwiftUI

// coucou-custom fork: the Buddy's HUD, under it (or over it when there is no room): what runs —
// the focus session, the timer — with its controls, and alerts until you act on them. Notch cards
// (BuddyDesign): a ring for the progress, the time large, capsule buttons.

/// Set by the Buddy while it is carried (Settings → Buddy → "Card while dragging": Shrink).
@MainActor
final class BuddyHUDLook: ObservableObject {
    @Published var compact = false
    /// The cards changed size on their own (a glass logged adds a line): the window follows, or
    /// what grew past it could not be clicked.
    var resized: (() -> Void)?
}

struct BuddyHUDView: View {
    @ObservedObject var routines: BuddyRoutineController
    @ObservedObject var look: BuddyHUDLook

    var body: some View {
        Group {
            if look.compact {
                compactRow
            } else {
                VStack(spacing: 8) {
                    ForEach(routines.alerts) { alert in
                        if let kind = RoutineMomentKind.of(alert.kind) {
                            BuddyRoutineCard(moment: RoutineMoment(kind: kind, alert: alert), routines: routines)
                        } else {
                            alertCard(alert)
                        }
                    }
                    if let f = routines.focus { focusCard(f) }
                    if let c = routines.countdown { timerCard(c) }
                }
            }
        }
        .padding(12)
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in look.resized?() }
    }

    /// While carried: only the rings, in one small capsule.
    private var compactRow: some View {
        HStack(spacing: 6) {
            ForEach(routines.alerts) { a in
                BuddyRing(progress: progress(a.kind), tint: tint(a.kind), symbol: icon(a.kind), size: 26, pulse: true)
            }
            if let f = routines.focus {
                let total = TimeInterval(max(1, f.plan.minutes(f.phase) * 60))
                BuddyRing(progress: 1 - f.remaining(at: routines.now) / total,
                          tint: f.phase.isBreak ? BuddyPalette.green : BuddyPalette.indigo,
                          symbol: f.phase.isBreak ? "cup.and.saucer.fill" : "brain.head.profile", size: 26)
            }
            if let c = routines.countdown {
                BuddyRing(progress: 1 - c.remaining(at: routines.now) / max(1, c.total), tint: BuddyPalette.amber,
                          symbol: "timer", size: 26)
            }
        }
        .padding(6)
        .background(Capsule().fill(Color(hex: "#15171B").opacity(0.94)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
    }

    // MARK: Cards

    private func alertCard(_ a: BuddyAlert) -> some View {
        let tint = tint(a.kind)
        return card(tint) {
            row(ring: BuddyRing(progress: progress(a.kind), tint: tint, symbol: icon(a.kind), pulse: true),
                title: a.title, subtitle: a.detail)
            // The routines' own alerts are BuddyRoutineCard's; this is the launch greeting's.
            pill("OK", tint: tint) { routines.dismiss(a) }
        }
    }

    private func focusCard(_ f: BuddyFocusSession) -> some View {
        let left = f.remaining(at: routines.now)
        let total = TimeInterval(max(1, f.plan.minutes(f.phase) * 60))
        let tint = f.phase.isBreak ? BuddyPalette.green : BuddyPalette.indigo
        return card(tint) {
            row(ring: BuddyRing(progress: 1 - left / total, tint: tint,
                                symbol: f.phase.isBreak ? "cup.and.saucer.fill" : "brain.head.profile"),
                title: f.phase.label,
                subtitle: f.isPaused ? "Round \(f.round) · paused" : "Round \(f.round) · \(f.completed) done",
                time: BuddyTimeText.clock(left))
            HStack(spacing: 6) {
                pill(f.isPaused ? "Resume" : "Pause", tint: tint) {
                    f.isPaused ? routines.resumeFocus() : routines.pauseFocus()
                }
                pill(f.phase.isBreak ? "Focus now" : "Break") { routines.skipFocus() }
                pill("End") { routines.endFocus() }
            }
        }
    }

    private func timerCard(_ c: BuddyCountdown) -> some View {
        let left = c.remaining(at: routines.now)
        let tint = BuddyPalette.amber
        return card(tint) {
            row(ring: BuddyRing(progress: 1 - left / max(1, c.total), tint: tint, symbol: "timer"),
                title: c.label.isEmpty ? "Timer" : c.label,
                subtitle: c.isPaused ? "Paused" : "of \(BuddyTimeText.duration(c.total))",
                time: BuddyTimeText.clock(left))
            HStack(spacing: 6) {
                pill(c.isPaused ? "Resume" : "Pause", tint: tint) {
                    c.isPaused ? routines.resumeTimer() : routines.pauseTimer()
                }
                pill("+5 min") { routines.addToTimer(300) }
                pill("Cancel") { routines.cancelTimer() }
            }
        }
    }

    // MARK: Pieces

    private func card<C: View>(_ tint: Color, @ViewBuilder _ content: @escaping () -> C) -> some View {
        BuddyCard(tint: tint, wash: 0.42) {
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(12)
                .frame(width: 252, alignment: .leading)
        }
    }

    private func row(ring: BuddyRing, title: String, subtitle: String, time: String? = nil) -> some View {
        HStack(spacing: 10) {
            ring
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(BuddyPalette.text)
                    .lineLimit(2)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(BuddyPalette.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let time {
                Text(time)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(BuddyPalette.text)
            }
        }
    }

    private func pill(_ title: String, tint: Color? = nil, _ run: @escaping () -> Void) -> some View {
        Button(title, action: run).buttonStyle(BuddyPillButtonStyle(tint: tint, compact: true))
    }

    private func progress(_ k: BuddyAlert.Kind) -> Double {
        guard k == .water else { return 1 }
        let goal = routines.settings.waterPlan.goal
        return goal > 0 ? Double(routines.waterToday) / Double(goal) : 0
    }

    private func icon(_ k: BuddyAlert.Kind) -> String {
        switch k {
        case .reminder: "bell.fill"
        case .timerDone: "timer"
        case .focusDone: "cup.and.saucer.fill"
        case .breakDone: "brain.head.profile"
        case .water: "drop.fill"
        case .greeting: "sun.max.fill"
        }
    }

    private func tint(_ k: BuddyAlert.Kind) -> Color {
        switch k {
        case .reminder: BuddyPalette.pink
        case .timerDone: BuddyPalette.amber
        case .focusDone: BuddyPalette.green
        case .breakDone: BuddyPalette.indigo
        case .water: BuddyPalette.cyan
        case .greeting: BuddyPalette.amber
        }
    }
}

/// A routine's alert on the Buddy, in the look of its full-screen moment: its ring, its words, its
/// quick actions (water's glasses keep it up, for another), then the buttons that close it.
struct BuddyRoutineCard: View {
    let moment: RoutineMoment
    @ObservedObject var routines: BuddyRoutineController
    @ObservedObject private var settings = BuddyRoutineSettings.shared
    @State private var startTotal: Int?

    var body: some View {
        let tint = moment.tint
        let quick = moment.quick
        let actions = moment.actions
        let today = settings.waterLog.total(on: Date())
        let poured = today - (startTotal ?? today)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.08), lineWidth: 5)
                    if let p = moment.progress {
                        Circle().trim(from: 0, to: CGFloat(min(1, max(0.02, p))))
                            .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(BriefLayout.spring, value: p)
                    }
                    Image(systemName: moment.symbol).font(.system(size: 17, weight: .semibold)).foregroundColor(tint)
                }
                .frame(width: 50, height: 50)
                VStack(alignment: .leading, spacing: 3) {
                    Text(moment.title).font(.system(size: 15, weight: .bold)).foregroundColor(BuddyPalette.text).lineLimit(2)
                    if !moment.detail.isEmpty {
                        Text(moment.detail).font(.system(size: 12).monospacedDigit()).foregroundColor(BuddyPalette.secondary).lineLimit(2)
                            .contentTransition(.numericText())
                            .animation(BriefLayout.spring, value: moment.detail)
                    }
                    if moment.isPreview {
                        Text("A preview: its buttons do nothing").font(.system(size: 11, weight: .semibold)).foregroundColor(BuddyPalette.muted)
                    } else if moment.kind == .water, poured > 0 {
                        Text("+\(BuddyWater.amount(poured)) just now").font(.system(size: 11, weight: .semibold)).foregroundColor(tint)
                            .transition(.opacity.combined(with: .offset(y: 4)))
                    }
                }
                Spacer(minLength: 0)
            }
            if !quick.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(quick.enumerated()), id: \.offset) { i, q in
                        let filled = i == 0 && moment.kind == .water
                        Button { perform(q) } label: {
                            HStack(spacing: 4) {
                                if let symbol = q.symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)) }
                                Text(q.title).font(.system(size: 12, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .foregroundColor(filled ? Color(hex: "#06131A") : tint)
                            .frame(maxWidth: .infinity).frame(height: 30)
                            .background(Capsule().fill(filled ? tint : tint.opacity(0.14)))
                            .overlay(Capsule().strokeBorder(tint.opacity(filled ? 0 : 0.4)))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(BriefPress())
                    }
                }
            }
            HStack(spacing: 6) {
                ForEach(Array(actions.enumerated()), id: \.offset) { i, a in
                    BuddyWaterButton(title: a.title, filled: i == actions.count - 1) { perform(a) }
                }
            }
        }
        .padding(14)
        .frame(width: 290, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(hex: "#0E0F11"))
                RadialGradient(colors: [tint.opacity(0.2), .clear], center: .topLeading, startRadius: 0, endRadius: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        )
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
        .onAppear { if startTotal == nil { startTotal = today } }
    }

    /// An action closes the card by what it does (logged, snoozed, done); a preview's, by itself.
    private func perform(_ a: RoutineMoment.Action) {
        withAnimation(BriefLayout.pop) { a.run() }
        if moment.isPreview, !a.keepsOpen, let alert = moment.alert { routines.withdraw(alert) }
    }
}

/// Later and Done: as large as the glasses, the whole half row clickable.
private struct BuddyWaterButton: View {
    let title: String
    let filled: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12.5, weight: .bold))
                .foregroundColor(filled ? BuddyPalette.ink : BuddyPalette.text)
                .frame(maxWidth: .infinity).frame(height: 32)
                .background(Capsule().fill(filled ? Color(hex: "#F1F2F4").opacity(hover ? 1 : 0.92)
                                                  : Color.white.opacity(hover ? 0.14 : 0.08)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(filled ? 0 : 0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(BriefPress())
        .onHover { hover = $0 }
    }
}

// MARK: - A routine's alert in the notch

/// What the notch's routine card shows (the island draws it from here); apart from the Buddy's
/// alerts, so one set to the notch is not on the Buddy as well.
@MainActor
final class RoutineNotchModel: ObservableObject {
    static let shared = RoutineNotchModel()
    @Published var moment: RoutineMoment?
    private var closing: DispatchWorkItem?

    func show(_ moment: RoutineMoment) {
        closing?.cancel()
        self.moment = moment
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.routineAlert)
        // A start is a short moment: gone by itself, as full screen.
        if moment.alert == nil {
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.close() } }
            closing = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(RoutineMomentSettings.shared.startSeconds + 3), execute: work)
        }
    }

    func close() {
        closing?.cancel()
        moment = nil
        NotificationCenter.default.post(name: .islandCollapse, object: nil)
    }
}

/// A routine's alert in the notch, in its cards' look: Mochi on the left (the island's), its words,
/// water's progress, the quick actions (water's glasses keep it up), then the buttons that close it.
struct RoutineNotchCard: View {
    @ObservedObject private var model = RoutineNotchModel.shared
    @ObservedObject private var settings = BuddyRoutineSettings.shared
    @State private var startTotal: Int?

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: wash)
            if let m = model.moment { content(m) }
        }
        .onAppear { startTotal = settings.waterLog.total(on: Date()) }
        .onChange(of: model.moment?.alert?.id) { startTotal = settings.waterLog.total(on: Date()) }
    }

    private var wash: CardBackground<EmptyView>.Wash {
        switch model.moment?.kind {
        case .water: .cyan
        case .reminder: .pink
        case .focusStart: .indigo
        case .focusDone, .breakDone: .green
        case .timerStart, .timerDone: .amber
        case nil: .soft
        }
    }

    private func content(_ m: RoutineMoment) -> some View {
        let tint = m.tint
        let today = settings.waterLog.total(on: Date())
        let poured = today - (startTotal ?? today)
        let quick = m.quick
        let actions = m.actions
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: m.symbol).font(.system(size: 12, weight: .bold)).foregroundColor(tint)
                Text(m.title).font(.system(size: 15, weight: .semibold)).foregroundColor(Color(hex: "#F1F2F4")).lineLimit(1)
                Text(m.detail).font(.system(size: 12).monospacedDigit()).foregroundColor(Color(hex: "#8E939C")).lineLimit(1)
                    .contentTransition(.numericText())
                    .animation(BriefLayout.spring, value: m.detail)
                if m.isPreview {
                    Text("· a preview, its buttons do nothing").font(.system(size: 11)).foregroundColor(Color(hex: "#5C6370"))
                } else if m.kind == .water, poured > 0 {
                    Text("+\(BuddyWater.amount(poured)) just now").font(.system(size: 11.5, weight: .semibold)).foregroundColor(tint)
                }
            }
            if m.kind == .water, let p = m.progress {
                RunnerBar(fraction: min(1, p), color: tint).frame(maxWidth: 360).animation(BriefLayout.spring, value: p)
            }
            HStack(spacing: 8) {
                ForEach(Array(quick.enumerated()), id: \.offset) { i, q in
                    let filled = i == 0 && m.kind == .water
                    Button { perform(q) } label: {
                        HStack(spacing: 4) {
                            if let symbol = q.symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
                            Text(q.title).font(.system(size: 12.5, weight: .bold)).lineLimit(1)
                        }
                        .foregroundColor(filled ? Color(hex: "#06131A") : tint)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(Capsule().fill(filled ? tint : tint.opacity(0.14)))
                        .overlay(Capsule().strokeBorder(tint.opacity(filled ? 0 : 0.4)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(BriefPress())
                }
                Spacer(minLength: 8)
                ForEach(Array(actions.enumerated()), id: \.offset) { i, a in
                    if i == actions.count - 1 {
                        PrimaryButton(verbatim: a.title) { perform(a) }
                    } else {
                        SecondaryButton(verbatim: a.title) { perform(a) }
                    }
                }
            }
        }
        .padding(.leading, 116).padding(.trailing, 16)
    }

    private func perform(_ a: RoutineMoment.Action) {
        withAnimation(BriefLayout.pop) { a.run() }
        if !a.keepsOpen { model.close() }
    }
}
#endif
