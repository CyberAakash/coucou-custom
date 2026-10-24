#if !APPSTORE
import AppKit
import Combine
import SwiftUI

// coucou-custom fork: the Daily brief — a card in the notch (BriefNotchStage) or the full-screen
// story of cards (greeting and weather, what you did, your routines, the Mac's day, the Claude
// plan, today ahead), as Settings → Briefs says. It comes up by itself once a day or when opened
// from the menu-bar panel or Settings, in either place.

@MainActor
final class DailyBriefController {
    static let shared = DailyBriefController()

    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var subscription: AnyCancellable?
    private var building = false
    /// Due but you were away (or the notch busy): asked again each minute, that day only.
    private var retry: Timer?

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DailyBriefController.shared.checkSoon() }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DailyBriefController.shared.checkSoon() }
        })
        subscription = DailyBriefSettings.shared.objectWillChange
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { DailyBriefController.shared.schedule() } }
        schedule()
        checkSoon()
    }

    /// A timer for the chosen time today (or tomorrow), so the brief comes when it is due.
    private func schedule() {
        timer?.invalidate()
        timer = nil
        let s = DailyBriefSettings.shared
        guard s.enabled, s.trigger != .manual else { return }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var due = cal.date(byAdding: .minute, value: s.minuteOfDay, to: today) ?? Date()
        if due <= Date() { due = cal.date(byAdding: .day, value: 1, to: due) ?? due }
        let t = Timer(fire: due, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated {
                DailyBriefController.shared.check()
                DailyBriefController.shared.schedule()
            }
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// After a wake or an unlock, once things have settled.
    private func checkSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { MainActor.assumeIsolated { DailyBriefController.shared.check() } }
    }

    private func check() {
        let s = DailyBriefSettings.shared
        guard s.enabled, DailyBriefSchedule.shouldShow(trigger: s.trigger, minuteOfDay: s.minuteOfDay, now: Date(), lastShownDay: s.lastShownDay) else {
            // Shown, off, or past its time: no more asking.
            retry?.invalidate()
            retry = nil
            return
        }
        // Only when you are there (something touched in the last two minutes), and never over a
        // permission or a question waiting in the notch.
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let busy = AppState.shared.pendingApproval != nil || AppState.shared.pendingQuestion != nil
        guard idle < 120, CGDisplayIsAsleep(CGMainDisplayID()) == 0, !busy else {
            if s.trigger == .firstUse || busy, retry == nil {
                let t = Timer(timeInterval: 60, repeats: true) { _ in
                    MainActor.assumeIsolated { DailyBriefController.shared.check() }
                }
                t.tolerance = 15
                RunLoop.main.add(t, forMode: .common)
                retry = t
            }
            return
        }
        retry?.invalidate()
        retry = nil
        show(place: nil, byHand: false)
    }

    /// `place` nil: where Settings → Daily brief says. `byHand`: opened from the panel or Settings
    /// (only then may it ask for Calendar access).
    func show(place: BriefPlace? = nil, byHand: Bool = true) {
        guard !building else { return }
        building = true
        Task { @MainActor in
            let brief = await DailyBriefBuilder.build(askCalendar: byHand)
            building = false
            let s = DailyBriefSettings.shared
            if !byHand { s.lastShownDay = MacDay.dayKey(Date()) }
            // The full screen plays its own; the notch says hello.
            if s.sound, (place ?? s.place) == .notch { SoundEngine.shared.play("greeting") }
            switch place ?? s.place {
            case .fullScreen: showFull(brief, takeKeyboard: byHand || NSApp.isActive)
            case .notch: showNotch(brief)
            }
        }
    }

    // MARK: In the notch

    private func showNotch(_ brief: DailyBrief) {
        DailyBriefReads.markRead()
        var b = brief
        b.readStreak = DailyBriefReads.streak(now: Date())
        BriefNotchModel.shared.daily = b
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.dailyBrief)
    }

    func share(_ brief: DailyBrief) {
        BriefSharePanel.show(name: "Daily brief \(MacDay.dayKey(brief.date))") { BriefShareCard.daily(brief, hidePrivate: $0) }
    }

    // MARK: Full screen

    func showFull(_ brief: DailyBrief, takeKeyboard: Bool) {
        DailyBriefReads.markRead()
        var b = brief
        b.readStreak = DailyBriefReads.streak(now: Date())
        b.weekRead = DailyBriefReads.week(now: Date())
        let cards = DailyBriefCard.cards(for: b.sections)
        let story = BriefStory(count: cards.count, autoAdvance: DailyBriefSettings.shared.autoAdvance)
        story.sound = DailyBriefSettings.shared.sound
        if story.sound { SoundEngine.shared.play("greeting") }
        let close = { FullScreenOverlay.shared.close(owner: "brief") }
        FullScreenOverlay.shared.present(
            DailyBriefFullView(brief: b, cards: cards, story: story, close: close),
            owner: "brief", dim: 0.56, takeKeyboard: takeKeyboard) { event in story.handle(event, close: close) }
    }
}

/// What the notch's brief cards show (the island draws them from here).
@MainActor
final class BriefNotchModel: ObservableObject {
    static let shared = BriefNotchModel()
    @Published var daily: DailyBrief?
    @Published var weekly: WeeklyBrief?
}

// MARK: - The cards

enum DailyBriefCard: Hashable {
    case intro, greeting, work, routines, mac, plan, ahead, closing

    static func cards(for sections: [DailyBriefSection]) -> [DailyBriefCard] {
        var out: [DailyBriefCard] = sections.map {
            switch $0 {
            case .weather: .greeting
            case .work: .work
            case .routines: .routines
            case .mac: .mac
            case .plan: .plan
            case .ahead: .ahead
            }
        }
        if out.first != .greeting { out.insert(.greeting, at: 0) }
        out.insert(.intro, at: 0)
        // The streak and "Start the day" live on Today ahead; without it, a card of their own.
        if !out.contains(.ahead) { out.append(.closing) }
        return out
    }
}

struct DailyBriefFullView: View {
    let brief: DailyBrief
    let cards: [DailyBriefCard]
    @ObservedObject var story: BriefStory
    let close: () -> Void

    var body: some View {
        BriefStoryFrame(story: story, title: "Daily brief",
                        date: brief.date.formatted(.dateTime.weekday(.wide).day().month(.wide)), close: close,
                        share: { DailyBriefController.shared.share(brief) }) { i in
            DailyBriefCardView(card: cards[i], brief: brief, close: close)
        }
    }
}

private struct DailyBriefCardView: View {
    let card: DailyBriefCard
    let brief: DailyBrief
    let close: () -> Void

    var body: some View {
        switch card {
        case .intro: DailyIntro(brief: brief)
        case .greeting: GreetingCard(brief: brief)
        case .work: WorkCard(brief: brief)
        case .routines: RoutinesCard(brief: brief)
        case .mac: MacCard(brief: brief)
        case .plan: PlanCard(limits: brief.plan, close: close)
        case .ahead: AheadCard(brief: brief, close: close)
        case .closing: ClosingCard(brief: brief, close: close)
        }
    }
}

// MARK: Card pieces

struct CardTitle: View {
    let label: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased()).font(.system(size: 11.5, weight: .bold)).tracking(1.3).foregroundColor(HubTheme.muted)
                .briefAppear(0.02)
            Text(title).font(.system(size: 30, weight: .bold)).lineLimit(2).minimumScaleFactor(0.7)
                .briefAppear(0.1)
        }
        .padding(.bottom, 6)
    }
}

struct Tile<Content: View>: View {
    var glow: Color? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(HubTheme.card)
                    .overlay {
                        if let glow {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(RadialGradient(colors: [glow.opacity(0.2), .clear], center: .topLeading, startRadius: 0, endRadius: 300))
                        }
                    }
            )
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
            .briefAppear(0.22)
    }
}

/// The Daily brief's first card: your name, large, and what is inside.
private struct DailyIntro: View {
    let brief: DailyBrief

    var body: some View {
        var lines: [(String, String)] = []
        if let w = brief.weather { lines.append((DailyBriefWeather.symbol(w.code), "\(w.now)° and \(DailyBriefWeather.describe(w.code).lowercased()) in \(w.city)")) }
        if let w = brief.work, !w.isEmpty {
            lines.append(("hammer.fill", "\(DailyBriefText.duration(minutes: w.minutes)) with your agents \(brief.isToday ? "so far today" : "yesterday")"))
        }
        if let water = brief.water { lines.append(("drop.fill", "\(DailyBriefText.water(water.ml)) of water of \(DailyBriefText.water(water.goal))")) }
        if let next = brief.events.first(where: { $0.end > Date() }) {
            lines.append(("calendar", "\(next.title) at \(next.start.formatted(.dateTime.hour().minute()))"))
        }
        if brief.readStreak > 1 { lines.append(("flame.fill", "\(brief.readStreak) days in a row")) }
        return BriefIntroCard(kicker: "Daily brief · " + brief.date.formatted(.dateTime.weekday(.wide).day().month(.wide)),
                              greeting: DailyBriefText.greeting(at: brief.date, name: nil) + ",",
                              name: DailyBriefSettings.shared.resolvedName,
                              lines: Array(lines.prefix(4)), palette: BriefPalette.now(brief.date))
    }
}

struct Stat: View {
    let value: String
    let label: String
    var color: Color = HubTheme.text
    /// Counted up from zero when set, written by `format`.
    var count: Int? = nil
    var format: (Int) -> String = { $0.formatted() }

    var body: some View {
        Tile {
            Group {
                if let count { BriefCountUp(value: count, format: format) } else { Text(value) }
            }
            .font(.system(size: 30, weight: .bold).monospacedDigit()).foregroundColor(color).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: 12.5)).foregroundColor(HubTheme.secondary)
        }
    }
}

// MARK: Greeting

private struct GreetingCard: View {
    let brief: DailyBrief
    @State private var hop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            CardTitle(label: "Today", title: brief.weather.map { "\($0.now)°, \(DailyBriefWeather.describe($0.code).lowercased()) in \($0.city)." }
                      ?? (brief.isToday ? "Here's your day so far." : "Here's yesterday, and today."))
            if let w = brief.weather {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.city).font(.system(size: 11.5)).foregroundColor(HubTheme.secondary)
                        Text("\(w.now)°").font(.system(size: 48, weight: .light).monospacedDigit())
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Label(DailyBriefWeather.describe(w.code), systemImage: DailyBriefWeather.symbol(w.code))
                            .font(.system(size: 15, weight: .semibold))
                            .symbolRenderingMode(.multicolor)
                        Text(w.line).font(.system(size: 12)).foregroundColor(HubTheme.secondary)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach(w.hours, id: \.hour) { h in
                            VStack(spacing: 5) {
                                Text(String(format: "%02d:00", h.hour)).font(.system(size: 10.5)).foregroundColor(HubTheme.muted)
                                Image(systemName: DailyBriefWeather.symbol(h.code)).symbolRenderingMode(.multicolor).font(.system(size: 12))
                                Text("\(h.temp)°").font(.system(size: 13, weight: .semibold).monospacedDigit())
                            }
                            .frame(width: 50, height: 70)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
                        }
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: "#1B2A44"), HubTheme.card], startPoint: .topLeading, endPoint: .bottomTrailing)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
            } else if brief.sections.contains(.weather) {
                Tile {
                    Label("Name your city in Settings → Voice → Your city to see the weather here.", systemImage: "cloud.sun")
                        .font(.system(size: 13)).foregroundColor(HubTheme.secondary)
                }
                .frame(height: 70)
            }
            Text(brief.headline).font(.system(size: 15)).foregroundColor(HubTheme.body).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Text("Tap to continue").font(.system(size: 11.5)).foregroundColor(HubTheme.muted)
        }
        .onAppear { withAnimation(.spring(response: 0.45, dampingFraction: 0.5).delay(0.2)) { hop = true }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.6).delay(0.55)) { hop = false } }
    }
}

// MARK: What you did

private struct WorkCard: View {
    let brief: DailyBrief

    var body: some View {
        let w = brief.work ?? DayWork()
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(label: "What you did", title: title(w))
            if w.isEmpty {
                Tile { Text("No agent session \(brief.isToday ? "yet today" : "yesterday"). Coucou counts them as your agents work.")
                    .font(.system(size: 13)).foregroundColor(HubTheme.secondary) }
                    .frame(height: 80)
            } else {
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        Stat(value: "", label: w.sessions == 1 ? "agent session" : "agent sessions", count: w.sessions)
                        Stat(value: "", label: "with agents", count: w.minutes, format: DailyBriefText.duration(minutes:))
                        Stat(value: "", label: w.filesChanged == 1 ? "file changed" : "files changed", count: w.filesChanged)
                    }
                    GridRow {
                        Tile {
                            HStack(spacing: 4) {
                                BriefCountUp(value: w.linesAdded) { "+\($0.formatted())" }.foregroundColor(HubTheme.green)
                                Text("/").foregroundColor(HubTheme.muted)
                                BriefCountUp(value: w.linesRemoved) { "−\($0.formatted())" }.foregroundColor(HubTheme.red)
                            }
                            .font(.system(size: 30, weight: .bold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.5)
                            Text("lines added / removed").font(.system(size: 12.5)).foregroundColor(HubTheme.secondary)
                        }
                        Stat(value: "", label: "commands run", count: w.commands)
                        Stat(value: "", label: w.questions == 1 ? "question answered" : "questions answered", count: w.questions)
                    }
                }
                .frame(height: 210)
                if let project = w.topProject {
                    Tile(glow: HubTheme.accent) {
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Top project").font(.system(size: 11.5)).foregroundColor(HubTheme.secondary)
                                Text(project).font(.system(size: 20, weight: .bold)).foregroundColor(HubTheme.accent).lineLimit(1)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(agentLine(w)).font(.system(size: 12)).foregroundColor(HubTheme.secondary).lineLimit(1)
                                HourStrip(byHour: w.byHour)
                            }
                        }
                    }
                    .frame(height: 74)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func title(_ w: DayWork) -> String {
        guard !w.isEmpty else { return "A quiet day for your agents." }
        return "\(DailyBriefText.duration(minutes: w.minutes)) with your agents\(brief.isToday ? " so far" : "")."
    }

    private func agentLine(_ w: DayWork) -> String {
        let agent = w.topAgentPill.flatMap { PillCatalog.definition(for: $0)?.name }
        return [w.approvals > 0 ? "\(w.approvals) approvals" : nil, agent.map { "mostly \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Sessions per hour, as a little strip.
private struct HourStrip: View {
    let byHour: [Int]

    var body: some View {
        let top = max(1, byHour.max() ?? 1)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<24, id: \.self) { h in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(byHour[h] > 0 ? HubTheme.accent : Color.white.opacity(0.08))
                    .frame(height: 3 + 15 * CGFloat(byHour[h]) / CGFloat(top))
            }
        }
        .frame(height: 18)
    }
}

// MARK: Routines

private struct RoutinesCard: View {
    let brief: DailyBrief

    var body: some View {
        let d = brief.diary ?? BuddyDiary.Day()
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(label: "Your routines", title: title(d))
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Tile(glow: Color(hex: "#22D3EE")) {
                        if let water = brief.water {
                            let k = Double(water.ml) / Double(max(1, water.goal))
                            HStack(spacing: 14) {
                                ZStack {
                                    Circle().stroke(Color.white.opacity(0.08), lineWidth: 6)
                                    Circle().trim(from: 0, to: CGFloat(min(1, k)))
                                        .stroke(Color(hex: "#22D3EE"), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                                        .rotationEffect(.degrees(-90))
                                    Text(MetricsFormat.percent(k)).font(.system(size: 14, weight: .bold).monospacedDigit())
                                }
                                .frame(width: 72, height: 72)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(DailyBriefText.water(water.ml)) / \(DailyBriefText.water(water.goal))")
                                        .font(.system(size: 22, weight: .bold).monospacedDigit())
                                    Text(water.ml >= water.goal ? "water · goal reached" : "water · \(DailyBriefText.water(water.goal - water.ml)) short")
                                        .font(.system(size: 12)).foregroundColor(HubTheme.secondary)
                                }
                            }
                        } else {
                            Text("Water").font(.system(size: 16, weight: .semibold))
                            Text("Turn on Water in Settings → Buddy to keep a daily goal.").font(.system(size: 12)).foregroundColor(HubTheme.secondary)
                        }
                    }
                    Tile(glow: Color(hex: "#818CF8")) {
                        countLine(d.focusSessions, d.focusSessions == 1 ? "focus session" : "focus sessions")
                        Segments(count: d.focusSessions, of: max(4, d.focusSessions), color: Color(hex: "#818CF8"))
                        Text(d.focusMinutes > 0 ? "\(DailyBriefText.duration(minutes: d.focusMinutes)) focused" : "None yet")
                            .font(.system(size: 12)).foregroundColor(HubTheme.secondary)
                    }
                }
                GridRow {
                    Tile(glow: HubTheme.green) {
                        countLine(d.remindersDone, "reminders done" + (brief.remindersLeft > 0 ? " · \(brief.remindersLeft) left" : ""))
                        Segments(count: d.remindersDone, of: d.remindersDone + brief.remindersLeft, color: HubTheme.green,
                                 rest: brief.remindersLeft > 0 ? Color(hex: "#F7B32B") : Color.white.opacity(0.1))
                        Text("\(d.timersDone) timer\(d.timersDone == 1 ? "" : "s") done").font(.system(size: 12)).foregroundColor(HubTheme.secondary)
                    }
                    Tile(glow: Color(hex: "#F472B6")) {
                        countLine(d.breathingSessions, d.breathingSessions == 1 ? "breathing session" : "breathing sessions")
                        Text(d.breathingSessions > 0 ? "A calmer day." : "One minute of calm, any time: right-click the Buddy → Breathe.")
                            .font(.system(size: 12)).foregroundColor(HubTheme.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func countLine(_ n: Int, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(n)").font(.system(size: 26, weight: .bold).monospacedDigit())
            Text(label).font(.system(size: 14)).foregroundColor(HubTheme.secondary)
        }
    }

    private func title(_ d: BuddyDiary.Day) -> String {
        var parts: [String] = []
        if let w = brief.water {
            let k = Double(w.ml) / Double(max(1, w.goal))
            parts.append(k >= 1 ? "Water goal reached." : k >= 0.75 ? "So close on water." : "Water at \(MetricsFormat.percent(k)).")
        }
        if d.focusSessions >= 4 { parts.append("Focus was strong.") }
        else if d.focusSessions > 0 { parts.append("\(d.focusSessions) focus session\(d.focusSessions == 1 ? "" : "s").") }
        return parts.isEmpty ? "A day to start a routine." : parts.joined(separator: " ")
    }
}

struct Segments: View {
    let count: Int
    let of: Int
    let color: Color
    var rest: Color = Color.white.opacity(0.1)

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<max(1, min(12, of)), id: \.self) { i in
                Capsule().fill(i < count ? color : rest).frame(height: 6)
            }
        }
    }
}

// MARK: The Mac's day

private struct MacCard: View {
    let brief: DailyBrief

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(label: "The Mac's day", title: title)
            if let mac = brief.mac, !mac.buckets.isEmpty {
                Tile {
                    HStack {
                        Text("CPU").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("avg \(MetricsFormat.percent(mac.averageCPU ?? 0)) · peak \(MetricsFormat.percent(mac.buckets.map(\.cpuMax).max() ?? 0))")
                            .font(.system(size: 12).monospacedDigit()).foregroundColor(HubTheme.secondary)
                    }
                    DayChart(values: mac.buckets.map { ($0.minute, $0.cpu) }, peaks: mac.peaks(), color: Color(hex: "#3B9EFF"))
                        .frame(height: 150)
                    HStack {
                        ForEach(["00:00", "06:00", "12:00", "18:00", "24:00"], id: \.self) { t in
                            Text(t).font(.system(size: 10.5)).foregroundColor(HubTheme.muted)
                            if t != "24:00" { Spacer() }
                        }
                    }
                }
                .frame(height: 220)
                Tile {
                    HStack {
                        Text("Memory").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("avg \(MetricsFormat.percent(mac.averageMemory ?? 0)) · peak \(MetricsFormat.percent(mac.buckets.map(\.memory).max() ?? 0))")
                            .font(.system(size: 12).monospacedDigit()).foregroundColor(HubTheme.secondary)
                    }
                    DayChart(values: mac.buckets.map { ($0.minute, $0.memory) }, peaks: [], color: Color(hex: "#A78BFA"))
                        .frame(height: 70)
                }
                .frame(height: 120)
            } else {
                Tile {
                    Text("Coucou keeps a light record of the Mac's day while the Daily brief shows it: one reading a minute, kept 14 days, never sent anywhere. Tomorrow's brief will have it.")
                        .font(.system(size: 13)).foregroundColor(HubTheme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(height: 100)
            }
            Spacer(minLength: 0)
        }
    }

    private var title: String {
        guard let mac = brief.mac, !mac.buckets.isEmpty else { return "The Mac's day starts now." }
        guard let peak = mac.peaks(count: 1).first else { return "A calm day for the Mac." }
        let when = MacDay.clock(peak.minute)
        return peak.peakApp.map { "Busiest at \(when), during \($0)." } ?? "Busiest at \(when)."
    }
}

/// A day, 00:00 to 24:00, as an area; the peaks dotted and named.
private struct DayChart: View {
    let values: [(minute: Int, value: Double)]
    let peaks: [MacDayBucket]
    let color: Color

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let point = { (m: Int, v: Double) in CGPoint(x: w * CGFloat(m + 2) / 1440, y: h * (1 - CGFloat(max(0, min(1, v))) * 0.92)) }
            ZStack(alignment: .topLeading) {
                Path { p in
                    guard let first = values.first else { return }
                    p.move(to: CGPoint(x: point(first.minute, 0).x, y: h))
                    for v in values { p.addLine(to: point(v.minute, v.value)) }
                    p.addLine(to: CGPoint(x: point(values.last!.minute, 0).x, y: h))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.04)], startPoint: .top, endPoint: .bottom))
                Path { p in
                    for (i, v) in values.enumerated() {
                        if i == 0 { p.move(to: point(v.minute, v.value)) } else { p.addLine(to: point(v.minute, v.value)) }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                ForEach(peaks, id: \.minute) { peak in
                    let p = point(peak.minute, peak.cpuMax)
                    Circle().fill(.white).frame(width: 9, height: 9)
                        .overlay(Circle().stroke(color, lineWidth: 3))
                        .position(p)
                    Text([peak.peakApp, MacDay.clock(peak.minute)].compactMap { $0 }.joined(separator: " "))
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 7).frame(height: 20)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .fixedSize()
                        .position(x: min(max(p.x + 50, 60), w - 60), y: max(10, p.y))
                }
            }
        }
    }
}

// MARK: Claude plan

struct PlanCard: View {
    let limits: ClaudePlanLimits?
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(label: "Claude plan" + (limits?.plan.map { " · \($0.capitalized)" } ?? ""), title: title)
            if let limits, !limits.limits.isEmpty {
                HStack(spacing: 12) {
                    ForEach(limits.limits.prefix(3)) { l in
                        ring(l, l.kind == .session ? HubTheme.accent : l.kind == .weeklyAll ? Color(hex: "#3B9EFF") : Color(hex: "#A78BFA"))
                    }
                }
                Text("Updated \(MetricsFormat.ago(limits.updatedAt, now: Date())), from Claude Code.")
                    .font(.system(size: 11.5)).foregroundColor(HubTheme.muted)
            } else {
                Tile {
                    Text("Your plan's limits show here once Claude Code can tell Coucou: it needs Claude Code installed and signed in with a Claude subscription, or Coucou's status-line relay (Settings → Agents → Plan gauge).")
                        .font(.system(size: 13)).foregroundColor(HubTheme.secondary).fixedSize(horizontal: false, vertical: true)
                    Button {
                        close()
                        FlowHubController.shared.show(.agents)
                    } label: {
                        Text("Open Agents settings").font(.system(size: 12.5, weight: .bold)).foregroundColor(HubTheme.onAccent)
                            .padding(.horizontal, 14).frame(height: 30).background(Capsule().fill(HubTheme.accent))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
                .frame(height: 130)
            }
            Spacer(minLength: 0)
        }
    }

    private var title: String {
        guard let limits, let used = limits.limits.map(\.percent).max() else { return "Your Claude plan." }
        return used < 50 ? "Plenty of Claude left." : used < 80 ? "Keep an eye on your plan." : "Your plan is nearly used up."
    }

    private func ring(_ l: ClaudePlanLimits.Limit, _ tint: Color) -> some View {
        let used = max(0, min(100, l.percent))
        return Tile(glow: tint) {
            VStack(spacing: 12) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.07), lineWidth: 12)
                    Circle().trim(from: 0, to: CGFloat(used / 100))
                        .stroke(used >= 90 ? HubTheme.red : tint, style: StrokeStyle(lineWidth: 12, lineCap: .round)).rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(Int(used.rounded()))%").font(.system(size: 28, weight: .bold).monospacedDigit())
                        Text("used").font(.system(size: 11.5)).foregroundColor(HubTheme.secondary)
                    }
                }
                .frame(width: 124, height: 124)
                VStack(spacing: 2) {
                    Text(l.kind == .session ? "Current session" : l.label == "All models" ? "Weekly · all models" : "Weekly · \(l.label)")
                        .font(.system(size: 13.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    Text(ClaudePlanLimits.resetText(l.resetsAt, now: Date())).font(.system(size: 11.5)).foregroundColor(HubTheme.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: Today ahead

private struct AheadCard: View {
    let brief: DailyBrief
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(label: "Today ahead", title: title)
                if DailyBriefCalendar.status != .fullAccess {
                    Tile {
                        Text("Allow Calendar access to see today's events (System Settings → Privacy & Security → Calendars → Coucou).")
                            .font(.system(size: 13)).foregroundColor(HubTheme.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(height: 90)
                } else {
                    ForEach(brief.events.prefix(6)) { e in
                        HStack(spacing: 12) {
                            Text(e.allDay ? "All day" : e.start.formatted(.dateTime.hour().minute()))
                                .font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundColor(HubTheme.secondary)
                                .frame(width: 56, alignment: .leading)
                            RoundedRectangle(cornerRadius: 1.5).fill(Color(hex: e.color ?? "#3B9EFF")).frame(width: 3, height: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                                if !e.allDay {
                                    Text(DailyBriefText.duration(minutes: Int(e.end.timeIntervalSince(e.start) / 60)))
                                        .font(.system(size: 11.5)).foregroundColor(HubTheme.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(HubTheme.card))
                        .opacity(e.end < Date() ? 0.45 : 1)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            StreakPanel(brief: brief, close: close).frame(width: 250)
        }
    }

    private var title: String {
        guard DailyBriefCalendar.status == .fullAccess else { return "Your day." }
        let upcoming = brief.events.filter { $0.end > Date() }
        guard let first = upcoming.first(where: { !$0.allDay }) ?? upcoming.first else { return "Nothing on your calendar." }
        let n = upcoming.count
        return "\(n) event\(n == 1 ? "" : "s"). First one at \(first.allDay ? "any time" : first.start.formatted(.dateTime.hour().minute()))."
    }
}

private struct ClosingCard: View {
    let brief: DailyBrief
    let close: () -> Void

    var body: some View {
        VStack {
            Spacer()
            StreakPanel(brief: brief, close: close).frame(width: 300, height: 380)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// The streak and the end of the brief: Mochi cheers.
private struct StreakPanel: View {
    let brief: DailyBrief
    let close: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            DesignMochi(size: 104, mode: .joy)
                .frame(width: 120, height: 96)
            VStack(spacing: 4) {
                Text(brief.readStreak > 1 ? "\(brief.readStreak)-day streak" : "Have a good one")
                    .font(.system(size: 24, weight: .bold))
                Text(brief.readStreak > 1 ? "Brief read every day" : "See you tomorrow morning")
                    .font(.system(size: 12.5)).foregroundColor(HubTheme.secondary)
            }
            HStack(spacing: 6) {
                ForEach(Array(["M", "T", "W", "T", "F", "S", "S"].enumerated()), id: \.offset) { i, d in
                    VStack(spacing: 4) {
                        Circle().fill(brief.weekRead.indices.contains(i) && brief.weekRead[i] ? HubTheme.accent : Color.white.opacity(0.1))
                            .frame(width: 20, height: 20)
                        Text(d).font(.system(size: 10)).foregroundColor(HubTheme.muted)
                    }
                }
            }
            Button(action: close) {
                Text("Start the day").font(.system(size: 14, weight: .bold)).foregroundColor(HubTheme.onAccent)
                    .padding(.horizontal, 24).frame(height: 40)
                    .background(Capsule().fill(HubTheme.accent))
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(RadialGradient(colors: [HubTheme.accent.opacity(0.18), HubTheme.card], center: .top, startRadius: 0, endRadius: 260)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
    }
}

#endif
