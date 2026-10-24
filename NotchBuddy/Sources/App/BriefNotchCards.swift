#if !APPSTORE
import SwiftUI

// coucou-custom fork: the Daily brief and the Weekly recap in the notch, as Claude Design animated
// them — the notch widens into a pill (a small Mochi on the left, the brief's name on the right),
// then opens into a 560-wide card: Mochi peeking up from its bottom edge, the greeting and the day
// in a line, the numbers turning one after the other in a chip (‹ › to step), Open; share and close
// at its top right, as the island's other cards have them.

enum BriefPhase { case pill, card }

/// Readable from the nonisolated `islandSize`, as QuestionLayout is; written on the main actor only.
enum BriefLayout {
    nonisolated(unsafe) private static var phases: [IslandView: BriefPhase] = [:]

    static let cardWidth: CGFloat = 560
    /// The pill reaches this far past the notch on each side.
    static let pillWing: CGFloat = 100

    static func isBrief(_ view: IslandView) -> Bool { view == .dailyBrief || view == .weeklyBrief }

    static func phase(for view: IslandView) -> BriefPhase { phases[view] ?? .pill }

    static func cardHeight(nh: CGFloat) -> CGFloat { max(160, nh + 128) }

    static func size(for view: IslandView, nw: CGFloat, nh: CGFloat) -> (CGFloat, CGFloat)? {
        guard isBrief(view) else { return nil }
        switch phase(for: view) {
        case .pill: return (nw + pillWing * 2, nh)
        case .card: return (cardWidth, cardHeight(nh: nh))
        }
    }

    static func corner(for view: IslandView) -> CGFloat? {
        guard isBrief(view) else { return nil }
        return phase(for: view) == .pill ? 16 : 30
    }

    @MainActor
    static func set(_ phase: BriefPhase, for view: IslandView) {
        guard phases[view] != phase else { return }
        phases[view] = phase
        NotificationCenter.default.post(name: .islandBriefFit, object: nil)
    }

    /// The design's springs (stiffness 240, damping 23; the pop 380, 17).
    static let spring = Animation.interpolatingSpring(stiffness: 240, damping: 23)
    static let pop = Animation.interpolatingSpring(stiffness: 380, damping: 17)
}

/// One number in the turning chip.
struct BriefChip: Identifiable {
    let color: Color
    let value: String
    let label: String
    /// A project or an event name: left out of a shared image when you ask.
    var isPrivate = false
    var id: String { label + value }
}

/// What the island draws for a brief, in place of its usual header and card.
struct BriefNotchStage: View {
    @ObservedObject var state: AppState
    let view: IslandView
    let width: CGFloat
    let height: CGFloat
    /// One phase, not played (an off-screen render).
    var still: BriefPhase? = nil
    @ObservedObject private var model = BriefNotchModel.shared
    @State private var phase: BriefPhase = .pill

    private var isDaily: Bool { view == .dailyBrief }
    private var accent: Color { Color(hex: isDaily ? "#FB923C" : "#818CF8") }

    var body: some View {
        let nh = state.notchHeight
        ZStack(alignment: .top) {
            pill(nh: nh)
            card(nh: nh)
        }
        .frame(width: width, height: height, alignment: .top)
        .onAppear {
            guard still == nil else { return }
            phase = .pill
            BriefLayout.set(.pill, for: view)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                guard state.mode == .expanded, state.view == view else { return }
                BriefLayout.set(.card, for: view)
                phase = .card
            }
        }
        .onDisappear { if still == nil { BriefLayout.set(.pill, for: view) } }
    }

    // MARK: The pill

    private func pill(nh: CGFloat) -> some View {
        let on = (still ?? phase) == .pill
        return HStack(spacing: 0) {
            DesignMochi(size: 22, mode: .idle)
                .scaleEffect(on ? 1 : 0.5)
                .animation(BriefLayout.pop, value: on)
                .padding(.leading, 12)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Circle().fill(accent).frame(width: 6, height: 6)
                Text(isDaily ? "Daily brief" : "Weekly brief")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundColor(Color(hex: "#E1E3E6")).lineLimit(1).fixedSize()
            }
            .padding(.trailing, 14)
        }
        .frame(width: width, height: nh)
        .opacity(on ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: on)
        .allowsHitTesting(false)
    }

    // MARK: The card

    private func card(nh: CGFloat) -> some View {
        let on = (still ?? phase) == .card
        let h = BriefLayout.cardHeight(nh: nh)
        let mochiH = 78 * 0.86
        return ZStack(alignment: .topLeading) {
            DesignMochi(size: 78, mode: .peek)
                .offset(x: 18, y: on ? h + 18 - mochiH : h + 90 - mochiH)
                .animation(BriefLayout.pop.delay(on ? 0.25 : 0), value: on)
            Group {
                if isDaily { daily } else { weekly }
            }
            .padding(.leading, 116).padding(.trailing, 22).padding(.top, nh + 10)
            .opacity(on ? 1 : 0)
            .offset(y: on ? 0 : -10)
            .animation(BriefLayout.spring.delay(on ? 0.12 : 0), value: on)
            // The island's own chrome, beside the camera: share and close.
            HStack(spacing: 6) {
                Text(isDaily ? "Daily brief" : "Weekly recap").font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .padding(.trailing, 4)
                BriefNotchIcon(symbol: "square.and.arrow.up", help: "Share as an image", action: share)
                BriefNotchIcon(symbol: "xmark", help: "Close (Later)") {
                    NotificationCenter.default.post(name: .islandCollapse, object: nil)
                }
            }
            .frame(height: nh)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 16)
            .opacity(on ? 1 : 0)
            .animation(.easeOut(duration: 0.3).delay(on ? 0.2 : 0), value: on)
        }
        .frame(width: BriefLayout.cardWidth, height: h, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { if on { open() } }
        .allowsHitTesting(on)
    }

    @ViewBuilder private var daily: some View {
        if let b = model.daily {
            let line = DailyBriefText.notchLine(work: b.work, isToday: b.isToday)
            content(title: b.greeting + ".", line: line, chips: Self.chips(b))
        } else {
            content(title: "Your Daily brief is on its way.", line: ("", "", ""), chips: [])
        }
    }

    @ViewBuilder private var weekly: some View {
        if let b = model.weekly {
            let line = DailyBriefText.weekNotchLine(b.work, isThisWeek: b.isThisWeek)
            content(title: (b.isThisWeek ? "Your week, " : "Last week, ") + b.rangeLabel, line: line, chips: Self.chips(b))
        } else {
            content(title: String(localized: "recap.no-activity"), line: ("", "", ""), chips: [])
        }
    }

    private func content(title: String, line: (lead: String, value: String, tail: String), chips: [BriefChip]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 17, weight: .bold)).tracking(-0.17).foregroundColor(Color(hex: "#F5F6F8")).lineLimit(1)
                (Text(line.lead) + Text(line.value).foregroundColor(accent).fontWeight(.semibold) + Text(line.tail))
                    .font(.system(size: 15)).foregroundColor(Color(hex: "#E1E3E6")).lineLimit(1).minimumScaleFactor(0.8)
            }
            HStack(spacing: 10) {
                BriefChipCarousel(chips: chips)
                Button("Open", action: open)
                    .buttonStyle(BriefFilledButton(fill: accent, ink: Color(hex: isDaily ? "#170C04" : "#0B0A24")))
            }
        }
    }

    private func share() {
        NotificationCenter.default.post(name: .islandCollapse, object: nil)
        if isDaily, let b = model.daily { DailyBriefController.shared.share(b) }
        if !isDaily, let b = model.weekly { WeeklyBriefController.shared.share(b) }
    }

    private func open() {
        NotificationCenter.default.post(name: .islandCollapse, object: nil)
        if isDaily, let b = model.daily { DailyBriefController.shared.showFull(b, takeKeyboard: true) }
        if !isDaily, let b = model.weekly { WeeklyBriefController.shared.showFull(b, takeKeyboard: true) }
    }

    // MARK: The numbers

    static func chips(_ b: DailyBrief) -> [BriefChip] {
        var out: [BriefChip] = []
        if let w = b.work, !w.isEmpty {
            out.append(BriefChip(color: Color(hex: "#FB923C"), value: DailyBriefText.duration(minutes: w.minutes), label: "with your agents"))
            if w.linesAdded + w.linesRemoved > 0 {
                out.append(BriefChip(color: Color(hex: "#34D399"), value: "+\(w.linesAdded.formatted()) / −\(w.linesRemoved.formatted())", label: "lines changed"))
            }
        }
        if let water = b.water {
            let pct = Int((Double(water.ml) / Double(max(1, water.goal)) * 100).rounded())
            out.append(BriefChip(color: Color(hex: "#22D3EE"), value: DailyBriefText.water(water.ml), label: "water, \(pct)% of goal"))
        }
        if let d = b.diary, d.focusSessions > 0 {
            out.append(BriefChip(color: Color(hex: "#A78BFA"), value: "\(d.focusSessions)", label: d.focusSessions == 1 ? "focus session" : "focus sessions"))
        }
        if let s = b.plan?.session {
            out.append(BriefChip(color: Color(hex: "#E07950"), value: "\(Int(s.percent.rounded()))%", label: "of the session used"))
        }
        if let next = b.events.first(where: { $0.end > Date() }) {
            out.append(BriefChip(color: Color(hex: "#F472B6"), value: next.allDay ? "Today" : next.start.formatted(.dateTime.hour().minute()), label: next.title, isPrivate: true))
        }
        if let w = b.weather {
            out.append(BriefChip(color: Color(hex: "#F7B32B"), value: "\(w.now)°", label: "high \(w.high)°, low \(w.low)°"))
        }
        return out
    }

    static func chips(_ b: WeeklyBrief) -> [BriefChip] {
        let w = b.work
        var out: [BriefChip] = []
        if !w.total.isEmpty {
            out.append(BriefChip(color: Color(hex: "#818CF8"), value: DailyBriefText.duration(minutes: w.total.minutes), label: "with your agents"))
            out.append(BriefChip(color: Color(hex: "#3B9EFF"), value: "\(w.total.sessions)", label: "sessions over \(w.activeDays) of 7 days"))
            if let p = w.projects.first { out.append(BriefChip(color: Color(hex: "#FB923C"), value: p.name, label: "top project", isPrivate: true)) }
            if w.total.linesAdded + w.total.linesRemoved > 0 {
                out.append(BriefChip(color: Color(hex: "#34D399"), value: "+\(w.total.linesAdded.formatted()) / −\(w.total.linesRemoved.formatted())", label: "lines changed"))
            }
        }
        if let water = b.water {
            out.append(BriefChip(color: Color(hex: "#22D3EE"), value: "\(water.days.filter { $0 >= water.goal }.count) of 7", label: "days at your water goal"))
        }
        if b.routines.focusSessions > 0 {
            out.append(BriefChip(color: Color(hex: "#A78BFA"), value: "\(b.routines.focusSessions)", label: "focus sessions"))
        }
        if let all = b.plan?.weekly.first {
            out.append(BriefChip(color: Color(hex: "#E07950"), value: "\(Int(all.percent.rounded()))%", label: "of the weekly limit used"))
        }
        return out
    }
}

/// One number at a time, the next sliding up every 2.4 s; ‹ › and the dots step through them,
/// and the turning waits while the pointer is on it or for a while after you step.
struct BriefChipCarousel: View {
    let chips: [BriefChip]
    @State private var index = 0
    @State private var direction = 1
    @State private var hovering = false
    @State private var steppedAt = Date.distantPast

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Capsule().fill(Color(hex: "#18191C"))
                if chips.indices.contains(index) {
                    let c = chips[index]
                    HStack(spacing: 8) {
                        Circle().fill(c.color).frame(width: 7, height: 7)
                        Text(c.value).font(.system(size: 13, weight: .bold).monospacedDigit()).foregroundColor(Color(hex: "#F5F6F8")).lineLimit(1).fixedSize()
                        Text(c.label).font(.system(size: 13)).foregroundColor(Color(hex: "#8E939C")).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .id(index)
                    // Forward slides up, back slides down, as the design's translateY(±100%).
                    .transition(.asymmetric(insertion: .move(edge: direction > 0 ? .bottom : .top).combined(with: .opacity),
                                            removal: .move(edge: direction > 0 ? .top : .bottom).combined(with: .opacity)))
                }
                if chips.isEmpty {
                    Text("Nothing to count yet").font(.system(size: 13)).foregroundColor(Color(hex: "#8E939C"))
                }
            }
            .frame(height: 32)
            .clipShape(Capsule())
            .onHover { hovering = $0 }
            if chips.count > 1 {
                BriefNotchIcon(symbol: "chevron.left", help: "Previous") { step(-1) }
                HStack(spacing: 4) {
                    ForEach(0..<chips.count, id: \.self) { i in
                        Capsule().fill(i == index ? Color(hex: "#F5F6F8") : Color.white.opacity(0.2))
                            .frame(width: i == index ? 14 : 5, height: 5)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                            .onTapGesture { go(to: i) }
                    }
                }
                BriefNotchIcon(symbol: "chevron.right", help: "Next") { step(1) }
            }
        }
        .task(id: chips.count) {
            guard chips.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.4))
                if Task.isCancelled { break }
                guard !hovering, Date().timeIntervalSince(steppedAt) > 6 else { continue }
                move(to: (index + 1) % chips.count, direction: 1)
            }
        }
    }

    private func step(_ delta: Int) {
        guard !chips.isEmpty else { return }
        go(to: (index + delta + chips.count) % chips.count, direction: delta)
    }

    private func go(to i: Int, direction d: Int? = nil) {
        guard i != index else { return }
        steppedAt = Date()
        move(to: i, direction: d ?? (i > index ? 1 : -1))
    }

    /// The direction lands first, so the leaving chip takes the new one's way out.
    private func move(to i: Int, direction d: Int) {
        direction = d
        DispatchQueue.main.async { withAnimation(BriefLayout.spring) { index = i } }
    }
}

/// A small round button in the notch, as the island's others.
struct BriefNotchIcon: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .bold))
                .foregroundColor(Color(hex: hover ? "#F5F6F8" : "#8E939C"))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(hover ? 0.14 : 0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .help(help)
    }
}

struct BriefFilledButton: ButtonStyle {
    let fill: Color
    let ink: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(ink)
            .padding(.horizontal, 14).frame(height: 32)
            .background(Capsule().fill(fill))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.3), value: configuration.isPressed)
    }
}
#endif
