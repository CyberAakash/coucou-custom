#if !APPSTORE
import SwiftUI

// coucou-custom fork: the Buddy's HUD, under it (or over it when there is no room): what runs —
// the focus session, the timer — with its controls, and alerts until you act on them. Notch cards
// (BuddyDesign): a ring for the progress, the time large, capsule buttons.

struct BuddyHUDView: View {
    @ObservedObject var routines: BuddyRoutineController

    var body: some View {
        VStack(spacing: 8) {
            ForEach(routines.alerts) { alert in alertCard(alert) }
            if let f = routines.focus { focusCard(f) }
            if let c = routines.countdown { timerCard(c) }
        }
        .padding(12)
        .fixedSize()
    }

    // MARK: Cards

    private func alertCard(_ a: BuddyAlert) -> some View {
        let tint = tint(a.kind)
        return card(tint) {
            row(ring: BuddyRing(progress: progress(a.kind), tint: tint, symbol: icon(a.kind), pulse: true),
                title: a.title, subtitle: a.detail)
            HStack(spacing: 6) {
                switch a.kind {
                case .reminder:
                    pill("Snooze 5 min") { routines.act(on: a) }
                    pill("Done", tint: tint) { routines.dismiss(a) }
                case .timerDone:
                    pill("Snooze 5 min") { routines.act(on: a) }
                    pill("Dismiss", tint: tint) { routines.dismiss(a) }
                case .breakDone:
                    pill("End") { routines.endFocus() }
                    pill("Start focus", tint: tint) { routines.act(on: a) }
                case .water:
                    pill("Skip") { routines.dismiss(a) }
                    pill("Later") { routines.snoozeWater() }
                    pill("+\(BuddyWater.amount(routines.settings.waterPlan.glass))", tint: tint) { routines.act(on: a) }
                case .focusDone, .greeting:
                    pill("OK", tint: tint) { routines.dismiss(a) }
                }
            }
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
#endif
