#if !APPSTORE
import Foundation

// coucou-custom fork: the Daily brief's rules, kept free of AppKit so tests/DailyBriefTests.swift
// can run them — the Mac's day in 5-minute buckets, the routines' day, what the agents did, when
// the brief comes up, and its headline.

// MARK: - The Mac's day

/// Five minutes of the Mac: the CPU's mean and peak, the memory's mean, and what used the CPU
/// most at the peak (read only when it was busy).
struct MacDayBucket: Codable, Equatable {
    var minute: Int          // minutes since midnight, a multiple of 5
    var cpuSum: Double = 0
    var cpuMax: Double = 0
    var memSum: Double = 0
    var samples: Int = 0
    var peakApp: String? = nil

    var cpu: Double { samples > 0 ? cpuSum / Double(samples) : 0 }
    var memory: Double { samples > 0 ? memSum / Double(samples) : 0 }
}

struct MacDay: Codable, Equatable {
    var day: String                       // "2026-10-23"
    var buckets: [MacDayBucket] = []

    static let bucketMinutes = 5
    /// A peak is named only when the CPU was at least this busy.
    static let busy = 0.6

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    mutating func add(cpu: Double, memory: Double, topApp: String?, at date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let minute = ((c.hour ?? 0) * 60 + (c.minute ?? 0)) / Self.bucketMinutes * Self.bucketMinutes
        let cpu = max(0, min(1, cpu)), memory = max(0, min(1, memory))
        if buckets.last?.minute != minute {
            buckets.append(MacDayBucket(minute: minute))
        }
        var b = buckets[buckets.count - 1]
        b.cpuSum += cpu
        b.memSum += memory
        b.samples += 1
        if cpu >= b.cpuMax {
            b.cpuMax = cpu
            if cpu >= Self.busy, let topApp, !topApp.isEmpty { b.peakApp = topApp }
        }
        buckets[buckets.count - 1] = b
    }

    var averageCPU: Double? {
        let n = buckets.reduce(0) { $0 + $1.samples }
        return n > 0 ? buckets.reduce(0) { $0 + $1.cpuSum } / Double(n) : nil
    }

    var averageMemory: Double? {
        let n = buckets.reduce(0) { $0 + $1.samples }
        return n > 0 ? buckets.reduce(0) { $0 + $1.memSum } / Double(n) : nil
    }

    /// The busiest moments, most first, at least `apart` minutes from each other.
    func peaks(count: Int = 2, apart: Int = 60) -> [MacDayBucket] {
        var picked: [MacDayBucket] = []
        for b in buckets.sorted(by: { $0.cpuMax > $1.cpuMax }) where b.cpuMax >= Self.busy {
            if picked.allSatisfy({ abs($0.minute - b.minute) >= apart }) { picked.append(b) }
            if picked.count == count { break }
        }
        return picked
    }

    /// "14:20" for a bucket's minute.
    static func clock(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}

// MARK: - The routines' day

/// What the routines saw each day, besides the water (BuddyWaterLog keeps that).
struct BuddyDiary: Codable, Equatable {
    struct Day: Codable, Equatable {
        var focusSessions = 0
        var focusMinutes = 0
        var remindersDone = 0
        var timersDone = 0
        var breathingSessions = 0
    }

    var days: [String: Day] = [:]
    static let keepDays = 60

    mutating func record(on date: Date, calendar: Calendar = .current, _ change: (inout Day) -> Void) {
        let key = MacDay.dayKey(date, calendar: calendar)
        var d = days[key] ?? Day()
        change(&d)
        days[key] = d
        if days.count > Self.keepDays {
            for k in days.keys.sorted().dropLast(Self.keepDays) { days[k] = nil }
        }
    }

    func day(_ date: Date, calendar: Calendar = .current) -> Day? { days[MacDay.dayKey(date, calendar: calendar)] }
}

// MARK: - What the agents did

struct DayWork: Equatable {
    var sessions = 0
    var minutes = 0
    var filesChanged = 0
    var linesAdded = 0
    var linesRemoved = 0
    var commands = 0
    var questions = 0
    var approvals = 0
    var topProject: String? = nil
    var topAgentPill: String? = nil
    /// Sessions per hour of the day, for the little timeline.
    var byHour: [Int] = Array(repeating: 0, count: 24)

    var isEmpty: Bool { sessions == 0 }

    /// From the recap's turns that started inside [start, end).
    static func from(turns: [RecapTurn], decisions: [RecapDecision], start: Date, end: Date,
                     calendar: Calendar = .current) -> DayWork {
        let inDay = turns.filter { $0.start >= start && $0.start < end }
        var w = DayWork()
        w.sessions = inDay.count
        w.minutes = Int(mergedSeconds(inDay) / 60)
        w.filesChanged = inDay.reduce(0) { $0 + $1.filesChanged }
        w.linesAdded = inDay.reduce(0) { $0 + $1.linesAdded }
        w.linesRemoved = inDay.reduce(0) { $0 + $1.linesRemoved }
        w.commands = inDay.reduce(0) { $0 + $1.commandsRun }
        w.questions = inDay.reduce(0) { $0 + $1.questions }
        w.approvals = decisions.filter { d in
            let inside = d.date >= start && d.date < end
            return inside && (d.decision == "allow" || d.decision == "always")
        }.count
        var projects: [String: Int] = [:]
        var agents: [String: Int] = [:]
        for t in inDay {
            if !t.project.isEmpty { projects[t.project, default: 0] += 1 }
            agents[t.pillId, default: 0] += 1
            w.byHour[calendar.component(.hour, from: t.start)] += 1
        }
        // Ties go to the name first in order, so the brief never flickers between two.
        w.topProject = projects.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
        w.topAgentPill = agents.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
        return w
    }

    /// Overlapping turns counted once (the recap's own rule).
    static func mergedSeconds(_ turns: [RecapTurn]) -> Double {
        let sorted = turns.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var total: Double = 0
        var seg: (Date, Date)?
        for t in sorted {
            if let s = seg, t.start <= s.1 {
                seg = (s.0, max(s.1, t.end))
            } else {
                if let s = seg { total += s.1.timeIntervalSince(s.0) }
                seg = (t.start, t.end)
            }
        }
        if let s = seg { total += s.1.timeIntervalSince(s.0) }
        return total
    }

    /// Days in a row, ending with `day`, that had at least one agent session.
    static func streak(turns: [RecapTurn], endingOn day: Date, calendar: Calendar = .current) -> Int {
        let worked = Set(turns.map { MacDay.dayKey($0.start, calendar: calendar) })
        var n = 0
        var d = calendar.startOfDay(for: day)
        while worked.contains(MacDay.dayKey(d, calendar: calendar)) {
            n += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: d) else { break }
            d = prev
        }
        return n
    }
}

// MARK: - The week

/// Seven days of DayWork, their sum, the projects and agents of the week, and the week before's
/// time to compare with.
struct WeekWork: Equatable {
    struct Project: Equatable {
        let name: String
        let minutes: Int
        let sessions: Int
    }

    var start: Date
    var days: [DayWork]           // Monday first
    var total: DayWork
    var previousMinutes: Int
    var projects: [Project]       // most time first, at most 4
    var agents: [(pill: String, sessions: Int)]
    var longestSessionMinutes: Int
    var activeDays: Int { days.filter { !$0.isEmpty }.count }

    static func == (a: WeekWork, b: WeekWork) -> Bool {
        a.start == b.start && a.days == b.days && a.total == b.total && a.previousMinutes == b.previousMinutes
            && a.projects == b.projects && a.longestSessionMinutes == b.longestSessionMinutes
            && a.agents.map(\.pill) == b.agents.map(\.pill) && a.agents.map(\.sessions) == b.agents.map(\.sessions)
    }

    /// Index of the day with the most time, nil for an empty week.
    var busiestDay: Int? {
        guard let top = days.indices.max(by: { days[$0].minutes < days[$1].minutes }), days[top].minutes > 0 else { return nil }
        return top
    }

    /// −1…+∞: this week's time against the week before's; nil when there is nothing to compare.
    var change: Double? {
        guard previousMinutes > 0 else { return nil }
        return Double(total.minutes - previousMinutes) / Double(previousMinutes)
    }

    static func from(turns: [RecapTurn], decisions: [RecapDecision], weekStart: Date, calendar: Calendar = .current) -> WeekWork {
        let start = calendar.startOfDay(for: weekStart)
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        let previous = calendar.date(byAdding: .day, value: -7, to: start) ?? start
        let days = (0..<7).map { i -> DayWork in
            let d = calendar.date(byAdding: .day, value: i, to: start) ?? start
            let e = calendar.date(byAdding: .day, value: 1, to: d) ?? d
            return DayWork.from(turns: turns, decisions: decisions, start: d, end: e, calendar: calendar)
        }
        let total = DayWork.from(turns: turns, decisions: decisions, start: start, end: end, calendar: calendar)
        let inWeek = turns.filter { $0.start >= start && $0.start < end }
        var byProject: [String: [RecapTurn]] = [:]
        for t in inWeek where !t.project.isEmpty { byProject[t.project, default: []].append(t) }
        let projects = byProject.map { Project(name: $0.key, minutes: Int(DayWork.mergedSeconds($0.value) / 60), sessions: $0.value.count) }
            .sorted { $0.minutes != $1.minutes ? $0.minutes > $1.minutes : $0.name < $1.name }
        var byAgent: [String: Int] = [:]
        for t in inWeek { byAgent[t.pillId, default: 0] += 1 }
        let agents = byAgent.map { (pill: $0.key, sessions: $0.value) }
            .sorted { $0.sessions != $1.sessions ? $0.sessions > $1.sessions : $0.pill < $1.pill }
        let longest = inWeek.map { Int($0.end.timeIntervalSince($0.start) / 60) }.max() ?? 0
        let before = turns.filter { $0.start >= previous && $0.start < start }
        return WeekWork(start: start, days: days, total: total, previousMinutes: Int(DayWork.mergedSeconds(before) / 60),
                        projects: Array(projects.prefix(4)), agents: agents, longestSessionMinutes: longest)
    }

    /// Monday of the week holding `date`.
    static func monday(of date: Date, calendar: Calendar = .current) -> Date {
        var cal = calendar
        cal.firstWeekday = 2
        return cal.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }
}

/// Which week the Weekly recap tells about.
enum WeeklyBriefPeriod: String, CaseIterable, Identifiable {
    case lastWeek, thisWeek
    var id: String { rawValue }

    func weekStart(now: Date, calendar: Calendar = .current) -> Date {
        let monday = WeekWork.monday(of: now, calendar: calendar)
        return self == .thisWeek ? monday : (calendar.date(byAdding: .day, value: -7, to: monday) ?? monday)
    }
}

// MARK: - When it comes up

enum DailyBriefTrigger: String, CaseIterable, Identifiable {
    /// The first time you are at the Mac after the chosen time (wake, unlock or launch).
    case firstUse
    /// At the chosen time, if you are at the Mac.
    case atTime
    /// Only when you open it.
    case manual
    var id: String { rawValue }
}

/// Which day the brief tells about.
enum DailyBriefPeriod: String, CaseIterable, Identifiable {
    /// Yesterday before noon, today after (a morning brief looks back, an evening one sums up).
    case auto, yesterday, today
    var id: String { rawValue }

    func day(now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        switch self {
        case .yesterday: return yesterday
        case .today: return today
        case .auto: return calendar.component(.hour, from: now) < 12 ? yesterday : today
        }
    }
}

enum DailyBriefSchedule {
    /// Shown by itself now? Once a day, at or after `minuteOfDay`; `atTime` only within the
    /// first 15 minutes after it (a Mac asleep at that time skips the day, as an alarm would).
    static func shouldShow(trigger: DailyBriefTrigger, minuteOfDay: Int, now: Date,
                           lastShownDay: String?, calendar: Calendar = .current) -> Bool {
        guard trigger != .manual else { return false }
        let today = MacDay.dayKey(now, calendar: calendar)
        guard lastShownDay != today else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: now)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        guard minute >= minuteOfDay else { return false }
        return trigger == .firstUse || minute < minuteOfDay + 15
    }
}

// MARK: - Words

enum DailyBriefText {
    static func greeting(at date: Date, name: String?, calendar: Calendar = .current) -> String {
        let h = calendar.component(.hour, from: date)
        let part = h < 5 ? "Good night" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
        let n = name?.trimmingCharacters(in: .whitespaces) ?? ""
        return n.isEmpty ? part : "\(part), \(n)"
    }

    /// "5h 12m", "48m", "0m".
    static func duration(minutes: Int) -> String {
        let m = max(0, minutes)
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    /// The line under the greeting: the day's work in a few words, or a gentle one when quiet.
    static func headline(work: DayWork?, isToday: Bool) -> String {
        let when = isToday ? "Today" : "Yesterday"
        guard let w = work, !w.isEmpty else {
            return isToday ? "A quiet day so far. Your agents are ready when you are." : "Yesterday was a quiet one. Fresh start today."
        }
        let sessions = w.sessions == 1 ? "1 agent session" : "\(w.sessions) agent sessions"
        var line = "\(when): \(sessions), \(duration(minutes: w.minutes)) of work"
        if w.filesChanged > 0 { line += ", \(w.filesChanged) file\(w.filesChanged == 1 ? "" : "s") changed" }
        if let p = w.topProject { line += ", mostly on \(p)" }
        return line + "."
    }

    /// "+12%", "−30%", "same".
    static func change(_ c: Double) -> String {
        let pct = Int((c * 100).rounded())
        return pct == 0 ? "same as the week before" : (pct > 0 ? "+\(pct)%" : "−\(-pct)%") + " vs the week before"
    }

    /// The Weekly recap's headline.
    static func weekHeadline(_ w: WeekWork, isThisWeek: Bool) -> String {
        guard !w.total.isEmpty else { return isThisWeek ? "A quiet week so far." : "A quiet week for your agents." }
        let lead = isThisWeek ? "This week so far" : "Last week"
        var line = "\(lead): \(duration(minutes: w.total.minutes)) with your agents over \(w.activeDays) day\(w.activeDays == 1 ? "" : "s")"
        if let p = w.projects.first { line += ", mostly on \(p.name)" }
        return line + "."
    }

    /// "1.5 L", "750 ml".
    static func water(_ ml: Int) -> String {
        ml >= 1000 ? String(format: "%.1f L", Double(ml) / 1000).replacingOccurrences(of: ".0 L", with: " L") : "\(ml) ml"
    }
}
#endif
