#if !APPSTORE
import AppKit
import Combine
import SwiftUI

// coucou-custom fork: the Weekly recap, in the notch or full screen (Settings → Briefs). Upstream's
// recap card and its Monday rule stay; the fork's controller decides where it shows and gives it
// a full-screen story: the week's work and how it compares, day by day, projects and agents, your
// routines, the Mac's week, the Claude plan, then sharing it.

enum WeeklyBriefSection: String, CaseIterable, Identifiable {
    case summary, days, projects, routines, mac, plan
    var id: String { rawValue }

    var title: String {
        switch self {
        case .summary: "The week in numbers"
        case .days: "Day by day"
        case .projects: "Projects and agents"
        case .routines: "Your routines"
        case .mac: "The Mac's week"
        case .plan: "Claude plan"
        }
    }

    var detail: String {
        switch self {
        case .summary: "Time with agents against the week before, sessions, active days, files, lines, commands, questions, approvals."
        case .days: "Each day's time with agents, the busiest day and the longest session."
        case .projects: "Where the time went: your top projects, and which agents did the work."
        case .routines: "Water each day against your goal, focus sessions, reminders, timers, breathing."
        case .mac: "The Mac's average load each day and its busiest moment of the week (needs the Daily brief's Mac's day)."
        case .plan: "Your Claude plan's 5-hour and weekly windows now."
        }
    }

    var symbol: String {
        switch self {
        case .summary: "number"
        case .days: "chart.bar.fill"
        case .projects: "folder.fill"
        case .routines: "drop.fill"
        case .mac: "cpu"
        case .plan: "staroflife.fill"
        }
    }
}

@MainActor
final class WeeklyBriefSettings: ObservableObject {
    static let shared = WeeklyBriefSettings()
    private let defaults = UserDefaults.standard

    /// Coucou's own Monday-morning recap (from 8:00, once a week, when there was work).
    @Published var autoShow: Bool { didSet { defaults.set(autoShow, forKey: "weeklyRecapAutoShow") } }
    /// The notch by default: where the recap has always shown.
    @Published var place: BriefPlace { didSet { defaults.set(place.rawValue, forKey: "weeklyRecapPlace") } }
    @Published var period: WeeklyBriefPeriod { didSet { defaults.set(period.rawValue, forKey: "weeklyRecapPeriod") } }
    @Published var sections: [WeeklyBriefSection] {
        didSet { defaults.set(sections.map(\.rawValue), forKey: "weeklyRecapSections") }
    }
    @Published var autoAdvance: Int { didSet { defaults.set(autoAdvance, forKey: "weeklyRecapAutoAdvance") } }

    private init() {
        autoShow = defaults.object(forKey: "weeklyRecapAutoShow") as? Bool ?? true
        place = BriefPlace(rawValue: defaults.string(forKey: "weeklyRecapPlace") ?? "") ?? .notch
        period = WeeklyBriefPeriod(rawValue: defaults.string(forKey: "weeklyRecapPeriod") ?? "") ?? .lastWeek
        let stored = (defaults.stringArray(forKey: "weeklyRecapSections") ?? []).compactMap(WeeklyBriefSection.init(rawValue:))
        sections = defaults.object(forKey: "weeklyRecapSections") == nil ? WeeklyBriefSection.allCases : stored
        autoAdvance = defaults.object(forKey: "weeklyRecapAutoAdvance") as? Int ?? 0
    }

    func toggle(_ s: WeeklyBriefSection, _ on: Bool) {
        if on, !sections.contains(s) {
            let order = WeeklyBriefSection.allCases
            sections.append(s)
            sections.sort { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! }
        } else if !on {
            sections.removeAll { $0 == s }
        }
    }
}

// MARK: - The week's data

struct WeeklyBrief {
    var date: Date
    var weekStart: Date
    var isThisWeek: Bool
    var headline: String
    var work: WeekWork
    /// Millilitres each day, Monday first, and the goal; nil without Water.
    var water: (days: [Int], goal: Int)?
    var routines: BuddyDiary.Day
    var macDays: [MacDay?]
    var plan: PlanUsage?
    var sections: [WeeklyBriefSection]

    var rangeLabel: String {
        let end = Calendar.current.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        return "\(weekStart.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day()))"
    }

    static let dayLetters = ["M", "T", "W", "T", "F", "S", "S"]
    static let dayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
}

@MainActor
enum WeeklyBriefBuilder {
    static func build(now: Date = Date(), period: WeeklyBriefPeriod? = nil) -> WeeklyBrief {
        let s = WeeklyBriefSettings.shared
        let cal = Calendar.current
        let period = period ?? s.period
        let start = period.weekStart(now: now, calendar: cal)
        let records = RecapStore.shared.records()
        let work = WeekWork.from(turns: records.turns, decisions: records.decisions, weekStart: start, calendar: cal)
        let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        let rs = BuddyRoutineSettings.shared
        let diary = BuddyDiaryStore.diary
        var sum = BuddyDiary.Day()
        for d in days {
            guard let day = diary.day(d, calendar: cal) else { continue }
            sum.focusSessions += day.focusSessions
            sum.focusMinutes += day.focusMinutes
            sum.remindersDone += day.remindersDone
            sum.timersDone += day.timersDone
            sum.breathingSessions += day.breathingSessions
        }
        return WeeklyBrief(
            date: now, weekStart: start, isThisWeek: period == .thisWeek,
            headline: DailyBriefText.weekHeadline(work, isThisWeek: period == .thisWeek),
            work: work,
            water: rs.waterEnabled ? (days.map { rs.waterLog.total(on: $0, calendar: cal) }, rs.waterPlan.goal) : nil,
            routines: sum,
            macDays: days.map { MacDayRecorder.shared.day($0) },
            plan: AppState.shared.claudePlanUsage,
            sections: s.sections)
    }
}

@MainActor
final class WeeklyBriefController {
    static let shared = WeeklyBriefController()

    /// `place` and `period` nil: as Settings → Briefs says (Monday's recap asks for last week).
    func show(place: BriefPlace? = nil, period: WeeklyBriefPeriod? = nil) {
        let brief = WeeklyBriefBuilder.build(period: period)
        switch place ?? WeeklyBriefSettings.shared.place {
        case .notch:
            BriefNotchModel.shared.weekly = brief
            NotificationCenter.default.post(name: .hookExpand, object: IslandView.weeklyBrief)
        case .fullScreen:
            showFull(brief, takeKeyboard: true)
        }
    }

    func showFull(_ brief: WeeklyBrief, takeKeyboard: Bool) {
        let cards = WeeklyBriefCard.cards(for: brief.sections)
        let story = BriefStory(count: cards.count, autoAdvance: WeeklyBriefSettings.shared.autoAdvance)
        let close = { FullScreenOverlay.shared.close(owner: "weekly") }
        FullScreenOverlay.shared.present(
            WeeklyBriefFullView(brief: brief, cards: cards, story: story, close: close),
            owner: "weekly", dim: 0.5, takeKeyboard: takeKeyboard) { event in story.handle(event, close: close) }
    }

    /// The weekly summary RecapStore makes for sharing, for the brief's week.
    func share(_ brief: WeeklyBrief) {
        guard let summary = RecapStore.shared.weeklySummary(for: brief.weekStart) else { return }
        RecapSharePanel.show(summary: summary, hideProjects: AppState.shared.recapHideProjects)
    }
}

// MARK: - Full screen

enum WeeklyBriefCard: Hashable {
    case summary, days, projects, routines, mac, plan, closing

    static func cards(for sections: [WeeklyBriefSection]) -> [WeeklyBriefCard] {
        var out: [WeeklyBriefCard] = sections.map {
            switch $0 {
            case .summary: .summary
            case .days: .days
            case .projects: .projects
            case .routines: .routines
            case .mac: .mac
            case .plan: .plan
            }
        }
        out.append(.closing)
        return out
    }
}

struct WeeklyBriefFullView: View {
    let brief: WeeklyBrief
    let cards: [WeeklyBriefCard]
    @ObservedObject var story: BriefStory
    let close: () -> Void

    var body: some View {
        BriefStoryFrame(story: story, title: "Weekly recap", date: brief.rangeLabel, close: close) { i in
            switch cards[i] {
            case .summary: WeekSummaryCard(brief: brief)
            case .days: WeekDaysCard(brief: brief)
            case .projects: WeekProjectsCard(brief: brief)
            case .routines: WeekRoutinesCard(brief: brief)
            case .mac: WeekMacCard(brief: brief)
            case .plan: PlanCard(plan: brief.plan, close: close)
            case .closing: WeekClosingCard(brief: brief, close: close)
            }
        }
    }
}

private struct WeekSummaryCard: View {
    let brief: WeeklyBrief

    var body: some View {
        let w = brief.work
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(label: brief.isThisWeek ? "This week so far" : "Last week", title: title(w))
            if w.total.isEmpty {
                Tile { Text("No agent session that week. Coucou counts them as your agents work.")
                    .font(.system(size: 13)).foregroundColor(HubTheme.secondary) }
                    .frame(height: 80)
            } else {
                Tile(glow: HubTheme.accent) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(DailyBriefText.duration(minutes: w.total.minutes)).font(.system(size: 40, weight: .bold).monospacedDigit())
                        Text("with your agents").font(.system(size: 15)).foregroundColor(HubTheme.secondary)
                        Spacer()
                        if let c = w.change {
                            Text(DailyBriefText.change(c))
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundColor(c >= 0 ? HubTheme.green : Color(hex: "#F7B32B"))
                                .padding(.horizontal, 10).frame(height: 26)
                                .background(Capsule().fill((c >= 0 ? HubTheme.green : Color(hex: "#F7B32B")).opacity(0.14)))
                        }
                    }
                }
                .frame(height: 84)
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        Stat(value: "\(w.total.sessions)", label: w.total.sessions == 1 ? "agent session" : "agent sessions")
                        Stat(value: "\(w.activeDays) of 7", label: "days with work")
                        Stat(value: "\(w.total.filesChanged)", label: "files changed")
                    }
                    GridRow {
                        Tile {
                            HStack(spacing: 4) {
                                Text("+\(w.total.linesAdded)").foregroundColor(HubTheme.green)
                                Text("/").foregroundColor(HubTheme.muted)
                                Text("−\(w.total.linesRemoved)").foregroundColor(HubTheme.red)
                            }
                            .font(.system(size: 26, weight: .bold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.5)
                            Text("lines added / removed").font(.system(size: 12.5)).foregroundColor(HubTheme.secondary)
                        }
                        Stat(value: "\(w.total.commands)", label: "commands run")
                        Stat(value: "\(w.total.questions) · \(w.total.approvals)", label: "questions · approvals")
                    }
                }
                .frame(height: 200)
            }
            Spacer(minLength: 0)
        }
    }

    private func title(_ w: WeekWork) -> String {
        guard !w.total.isEmpty else { return "A quiet week." }
        if let c = w.change, c >= 0.15 { return "A bigger week than the last." }
        if let c = w.change, c <= -0.15 { return "A lighter week than the last." }
        return "A steady week with your agents."
    }
}

private struct WeekDaysCard: View {
    let brief: WeeklyBrief

    var body: some View {
        let w = brief.work
        let top = max(1, w.days.map(\.minutes).max() ?? 1)
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(label: "Day by day", title: w.busiestDay.map { "\(WeeklyBrief.dayNames[$0]) was the busiest." } ?? "No busy day that week.")
            Tile {
                HStack(alignment: .bottom, spacing: 14) {
                    ForEach(0..<7, id: \.self) { i in
                        let m = w.days[i].minutes
                        VStack(spacing: 6) {
                            Text(m > 0 ? DailyBriefText.duration(minutes: m) : "")
                                .font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundColor(HubTheme.secondary)
                                .fixedSize()
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(i == w.busiestDay ? HubTheme.accent : HubTheme.accent.opacity(m > 0 ? 0.45 : 0.08))
                                .frame(height: max(6, 190 * CGFloat(m) / CGFloat(top)))
                            Text(WeeklyBrief.dayLetters[i]).font(.system(size: 12, weight: .semibold)).foregroundColor(HubTheme.muted)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: 270)
            HStack(spacing: 10) {
                Stat(value: w.busiestDay.map { DailyBriefText.duration(minutes: w.days[$0].minutes) } ?? "—",
                     label: "on \(w.busiestDay.map { WeeklyBrief.dayNames[$0] } ?? "the busiest day")")
                Stat(value: DailyBriefText.duration(minutes: w.longestSessionMinutes), label: "longest session")
                Stat(value: w.activeDays > 0 ? DailyBriefText.duration(minutes: w.total.minutes / w.activeDays) : "—", label: "a day with work, on average")
            }
            .frame(height: 90)
            Spacer(minLength: 0)
        }
    }
}

private struct WeekProjectsCard: View {
    let brief: WeeklyBrief

    var body: some View {
        let w = brief.work
        let total = max(1, w.projects.map(\.minutes).reduce(0, +))
        let colors: [Color] = [HubTheme.accent, Color(hex: "#3B9EFF"), Color(hex: "#A78BFA"), HubTheme.green]
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(label: "Projects and agents", title: w.projects.first.map { "Most of it went to \($0.name)." } ?? "No project that week.")
            if !w.projects.isEmpty {
                Tile {
                    GeometryReader { g in
                        HStack(spacing: 3) {
                            ForEach(Array(w.projects.enumerated()), id: \.offset) { i, p in
                                RoundedRectangle(cornerRadius: 4).fill(colors[i % colors.count])
                                    .frame(width: max(6, (g.size.width - 9) * CGFloat(p.minutes) / CGFloat(total)))
                            }
                        }
                    }
                    .frame(height: 12)
                    ForEach(Array(w.projects.enumerated()), id: \.offset) { i, p in
                        HStack(spacing: 10) {
                            Circle().fill(colors[i % colors.count]).frame(width: 9, height: 9)
                            Text(p.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            Spacer()
                            Text("\(DailyBriefText.duration(minutes: p.minutes)) · \(p.sessions) session\(p.sessions == 1 ? "" : "s")")
                                .font(.system(size: 12.5).monospacedDigit()).foregroundColor(HubTheme.secondary)
                        }
                        .padding(.top, 6)
                    }
                }
                .frame(height: 70 + CGFloat(w.projects.count) * 30)
            }
            if !w.agents.isEmpty {
                HubLabelRow(text: "Agents")
                HStack(spacing: 8) {
                    ForEach(w.agents.prefix(5), id: \.pill) { a in
                        let def = PillCatalog.definition(for: a.pill)
                        HStack(spacing: 6) {
                            Circle().fill(Color(hex: def?.color ?? "#8E939C")).frame(width: 8, height: 8)
                            Text(def?.name ?? a.pill).font(.system(size: 12.5, weight: .semibold))
                            Text("\(a.sessions)").font(.system(size: 12.5).monospacedDigit()).foregroundColor(HubTheme.secondary)
                        }
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(Capsule().fill(HubTheme.card))
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct HubLabelRow: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .bold)).tracking(1.2).foregroundColor(HubTheme.muted)
    }
}

private struct WeekRoutinesCard: View {
    let brief: WeeklyBrief

    var body: some View {
        let r = brief.routines
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(label: "Your routines", title: title)
            if let water = brief.water {
                let met = water.days.filter { $0 >= water.goal }.count
                Tile(glow: Color(hex: "#22D3EE")) {
                    HStack {
                        Text("Water").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Text("goal met \(met) of 7 days · \(DailyBriefText.water(water.days.reduce(0, +))) in all")
                            .font(.system(size: 12).monospacedDigit()).foregroundColor(HubTheme.secondary)
                    }
                    HStack(alignment: .bottom, spacing: 12) {
                        ForEach(0..<7, id: \.self) { i in
                            let k = Double(water.days[i]) / Double(max(1, water.goal))
                            VStack(spacing: 5) {
                                ZStack(alignment: .bottom) {
                                    RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.06))
                                    RoundedRectangle(cornerRadius: 5).fill(Color(hex: "#22D3EE").opacity(k >= 1 ? 1 : 0.55))
                                        .frame(height: 80 * CGFloat(min(1, k)))
                                }
                                .frame(height: 80)
                                Text(WeeklyBrief.dayLetters[i]).font(.system(size: 11, weight: .semibold)).foregroundColor(HubTheme.muted)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(height: 150)
            }
            HStack(spacing: 10) {
                Stat(value: "\(r.focusSessions)", label: "focus sessions · \(DailyBriefText.duration(minutes: r.focusMinutes))")
                Stat(value: "\(r.remindersDone)", label: "reminders done")
                Stat(value: "\(r.timersDone)", label: "timers done")
                Stat(value: "\(r.breathingSessions)", label: "breathing sessions")
            }
            .frame(height: 96)
            Spacer(minLength: 0)
        }
    }

    private var title: String {
        if let water = brief.water {
            let met = water.days.filter { $0 >= water.goal }.count
            if met >= 5 { return "Well hydrated, \(met) days of 7." }
        }
        if brief.routines.focusSessions >= 10 { return "\(brief.routines.focusSessions) focus sessions. Strong week." }
        return brief.routines.focusSessions + brief.routines.remindersDone > 0 ? "Your routines, all week." : "A week to start a routine."
    }
}

private struct WeekMacCard: View {
    let brief: WeeklyBrief

    var body: some View {
        let cpu = brief.macDays.map { $0?.averageCPU }
        let mem = brief.macDays.map { $0?.averageMemory }
        let peak = brief.macDays.enumerated().compactMap { i, d -> (Int, MacDayBucket)? in d?.peaks(count: 1).first.map { (i, $0) } }
            .max { $0.1.cpuMax < $1.1.cpuMax }
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(label: "The Mac's week", title: peak.map { p in
                "Busiest on \(WeeklyBrief.dayNames[p.0]) at \(MacDay.clock(p.1.minute))\(p.1.peakApp.map { ", during \($0)" } ?? "")."
            } ?? (cpu.contains { $0 != nil } ? "A calm week for the Mac." : "No record of the Mac's week yet."))
            if cpu.contains(where: { $0 != nil }) {
                Tile {
                    HStack(spacing: 16) {
                        legend("CPU", Color(hex: "#3B9EFF"))
                        legend("Memory", Color(hex: "#A78BFA"))
                        Spacer()
                        Text("average each day").font(.system(size: 11.5)).foregroundColor(HubTheme.muted)
                    }
                    HStack(alignment: .bottom, spacing: 14) {
                        ForEach(0..<7, id: \.self) { i in
                            VStack(spacing: 5) {
                                HStack(alignment: .bottom, spacing: 3) {
                                    bar(cpu[i], Color(hex: "#3B9EFF"))
                                    bar(mem[i], Color(hex: "#A78BFA"))
                                }
                                .frame(height: 170)
                                Text(WeeklyBrief.dayLetters[i]).font(.system(size: 11, weight: .semibold)).foregroundColor(HubTheme.muted)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(height: 240)
            } else {
                Tile {
                    Text("Turn on the Daily brief with its Mac's day card: Coucou then keeps one reading a minute, 14 days, on this Mac only, and the week shows here.")
                        .font(.system(size: 13)).foregroundColor(HubTheme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(height: 90)
            }
            Spacer(minLength: 0)
        }
    }

    private func bar(_ v: Double?, _ c: Color) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(v == nil ? Color.white.opacity(0.06) : c)
            .frame(width: 14, height: max(4, 170 * CGFloat(v ?? 0)))
    }

    private func legend(_ t: String, _ c: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(c).frame(width: 8, height: 8)
            Text(t).font(.system(size: 12.5, weight: .semibold))
        }
    }
}

private struct WeekClosingCard: View {
    let brief: WeeklyBrief
    let close: () -> Void
    @State private var cheer = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            HubLiveMochi(color: "#F5F6F8", size: 100, state: .finished)
                .frame(width: 124, height: 100)
                .scaleEffect(cheer ? 1.06 : 0.94)
            Text(brief.work.total.isEmpty ? "Here's to the next one" : "That was your week")
                .font(.system(size: 26, weight: .bold))
            Text(brief.headline).font(.system(size: 13.5)).foregroundColor(HubTheme.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 480)
            HStack(spacing: 10) {
                if !brief.work.total.isEmpty {
                    Button { WeeklyBriefController.shared.share(brief) } label: {
                        Label("Share as an image", systemImage: "square.and.arrow.up")
                            .font(.system(size: 13.5, weight: .semibold))
                            .padding(.horizontal, 18).frame(height: 40)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                }
                Button(action: close) {
                    Text("Done").font(.system(size: 14, weight: .bold)).foregroundColor(HubTheme.onAccent)
                        .padding(.horizontal, 26).frame(height: 40).background(Capsule().fill(HubTheme.accent))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(RadialGradient(colors: [Color(hex: "#818CF8").opacity(0.2), HubTheme.card], center: .top, startRadius: 0, endRadius: 320)))
        .onAppear { withAnimation(.easeInOut(duration: 0.6).repeatCount(5, autoreverses: true)) { cheer = true } }
    }
}

// MARK: - In the notch

/// A stat in a notch card: the value large, its label small (as upstream's recap card has them).
private struct NotchStat: View {
    let value: String
    let label: String
    var color: Color = Color(hex: "#F1F2F4")

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 16, weight: .bold).monospacedDigit()).foregroundColor(color).lineLimit(1)
            Text(label).font(.system(size: 9.5)).foregroundColor(Color(hex: "#8E939C")).lineLimit(1)
        }
    }
}

struct DailyBriefNotchCard: View {
    @ObservedObject var state: AppState
    @ObservedObject private var model = BriefNotchModel.shared

    var body: some View {
        ZStack {
            CardBackground(wash: .amber)
            VStack(alignment: .leading, spacing: 7) {
                if let b = model.daily {
                    HStack(spacing: 8) {
                        Text("Daily brief").font(.system(size: 11, weight: .semibold)).foregroundColor(Color(hex: "#F7B32B"))
                        Text(b.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                            .font(.system(size: 10)).foregroundColor(Color(hex: "#8E939C"))
                        Spacer(minLength: 6)
                        if let w = b.weather {
                            Label("\(w.now)° \(DailyBriefWeather.describe(w.code))", systemImage: DailyBriefWeather.symbol(w.code))
                                .font(.system(size: 10.5, weight: .medium)).foregroundColor(Color(hex: "#C9CBD1"))
                                .symbolRenderingMode(.multicolor).lineLimit(1)
                        }
                    }
                    Text(b.greeting + ". " + b.headline)
                        .font(.system(size: 12.5, weight: .semibold)).foregroundColor(Color(hex: "#F1F2F4"))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 14) {
                        if let w = b.work, !w.isEmpty {
                            NotchStat(value: DailyBriefText.duration(minutes: w.minutes), label: "with agents")
                            NotchStat(value: "\(w.sessions)", label: "sessions")
                            NotchStat(value: "\(w.filesChanged)", label: "files")
                        }
                        if let water = b.water {
                            NotchStat(value: MetricsFormat.percent(Double(water.ml) / Double(max(1, water.goal))), label: "water",
                                      color: Color(hex: "#22D3EE"))
                        }
                        if let d = b.diary, d.focusSessions > 0 {
                            NotchStat(value: "\(d.focusSessions)", label: "focus", color: Color(hex: "#A5B4FC"))
                        }
                        if let cpu = b.mac?.averageCPU { NotchStat(value: MetricsFormat.percent(cpu), label: "avg CPU") }
                        if let plan = b.plan, let w = plan.fiveHour {
                            NotchStat(value: "\(Int(max(0, 100 - ClaudePlanGauge.effectivePct(w)).rounded()))%", label: "5h left",
                                      color: Color(hex: "#FB923C"))
                        }
                        if let next = b.events.first(where: { $0.end > Date() }) {
                            NotchStat(value: next.allDay ? "Today" : next.start.formatted(.dateTime.hour().minute()), label: next.title)
                                .frame(maxWidth: 110, alignment: .leading)
                        }
                    }
                    HStack(spacing: 8) {
                        PrimaryButton(verbatim: "Full brief") {
                            NotificationCenter.default.post(name: .islandCollapse, object: nil)
                            DailyBriefController.shared.showFull(b, takeKeyboard: true)
                        }
                        SecondaryButton("OK") { NotificationCenter.default.post(name: .islandCollapse, object: nil) }
                    }
                } else {
                    Text("Your Daily brief is on its way.").font(.system(size: 14, weight: .semibold)).foregroundColor(Color(hex: "#F1F2F4"))
                }
            }
            .padding(.leading, 116)
            .padding(.trailing, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct WeeklyBriefNotchCard: View {
    @ObservedObject var state: AppState
    @ObservedObject private var model = BriefNotchModel.shared

    var body: some View {
        ZStack {
            CardBackground(wash: .indigo)
            VStack(alignment: .leading, spacing: 7) {
                if let b = model.weekly {
                    let w = b.work
                    HStack(spacing: 8) {
                        Text(String(localized: "recap.title")).font(.system(size: 11, weight: .semibold)).foregroundColor(Color(hex: "#818CF8"))
                        Text(b.rangeLabel).font(.system(size: 10)).foregroundColor(Color(hex: "#8E939C"))
                        Spacer(minLength: 6)
                        if let c = w.change {
                            Text(DailyBriefText.change(c)).font(.system(size: 10, weight: .semibold))
                                .foregroundColor(c >= 0 ? Color(hex: "#34D399") : Color(hex: "#F7B32B")).lineLimit(1)
                        }
                    }
                    HStack(alignment: .bottom, spacing: 16) {
                        // The week at a glance: each day's time with agents.
                        let top = max(1, w.days.map(\.minutes).max() ?? 1)
                        HStack(alignment: .bottom, spacing: 3) {
                            ForEach(0..<7, id: \.self) { i in
                                VStack(spacing: 2) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(i == w.busiestDay ? Color(hex: "#818CF8") : Color(hex: "#818CF8").opacity(w.days[i].minutes > 0 ? 0.45 : 0.12))
                                        .frame(width: 10, height: max(3, 30 * CGFloat(w.days[i].minutes) / CGFloat(top)))
                                    Text(WeeklyBrief.dayLetters[i]).font(.system(size: 8, weight: .semibold)).foregroundColor(Color(hex: "#6B7079"))
                                        .fixedSize()
                                }
                                .frame(width: 12)
                            }
                        }
                        NotchStat(value: DailyBriefText.duration(minutes: w.total.minutes), label: "with agents")
                        NotchStat(value: "\(w.total.sessions)", label: "sessions")
                        NotchStat(value: "\(w.activeDays)/7", label: "days")
                        NotchStat(value: "\(w.total.filesChanged)", label: "files")
                        if w.total.linesAdded + w.total.linesRemoved > 0 {
                            NotchStat(value: "+\(w.total.linesAdded.formatted())", label: "−\(w.total.linesRemoved.formatted()) lines", color: Color(hex: "#34D399"))
                        }
                    }
                    HStack(spacing: 6) {
                        if let p = w.projects.first {
                            Text("Top: \(p.name)").font(.system(size: 10.5, weight: .medium)).foregroundColor(Color(hex: "#C9CBD1")).lineLimit(1)
                        }
                        if let d = w.busiestDay {
                            Text("· busiest \(WeeklyBrief.dayNames[d])").font(.system(size: 10.5)).foregroundColor(Color(hex: "#8E939C")).lineLimit(1)
                        }
                        if let water = b.water {
                            Text("· water goal \(water.days.filter { $0 >= water.goal }.count)/7").font(.system(size: 10.5))
                                .foregroundColor(Color(hex: "#8E939C")).lineLimit(1)
                        }
                        if b.routines.focusSessions > 0 {
                            Text("· \(b.routines.focusSessions) focus").font(.system(size: 10.5)).foregroundColor(Color(hex: "#8E939C")).lineLimit(1)
                        }
                    }
                    HStack(spacing: 8) {
                        PrimaryButton(verbatim: "Full screen") {
                            NotificationCenter.default.post(name: .islandCollapse, object: nil)
                            WeeklyBriefController.shared.showFull(b, takeKeyboard: true)
                        }
                        if !w.total.isEmpty {
                            SecondaryButton(verbatim: String(localized: "recap.share-image")) { WeeklyBriefController.shared.share(b) }
                        }
                        SecondaryButton("OK") { NotificationCenter.default.post(name: .islandCollapse, object: nil) }
                    }
                } else {
                    Text(String(localized: "recap.no-activity")).font(.system(size: 14, weight: .semibold)).foregroundColor(Color(hex: "#F1F2F4"))
                }
            }
            .padding(.leading, 116)
            .padding(.trailing, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif
