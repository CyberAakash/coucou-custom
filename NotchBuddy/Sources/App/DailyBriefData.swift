#if !APPSTORE
import AppKit
import Combine
import EventKit
import Foundation

// coucou-custom fork: what the Daily brief is made of, and its settings — the Mac's day (read once
// a minute while the brief wants it), the routines' diary, today's calendar, the weather, the
// agents' day from the recap, the Claude plan.

enum DailyBriefSection: String, CaseIterable, Identifiable, Codable {
    case weather, work, routines, mac, plan, ahead
    var id: String { rawValue }

    var title: String {
        switch self {
        case .weather: "Greeting and weather"
        case .work: "What you did"
        case .routines: "Your routines"
        case .mac: "The Mac's day"
        case .plan: "Claude plan"
        case .ahead: "Today ahead"
        }
    }

    var detail: String {
        switch self {
        case .weather: "Hello, and the weather in your city (Voice → Your city)."
        case .work: "Agent sessions, time with agents, files and lines changed, commands, questions, the top project."
        case .routines: "Water against your goal, focus sessions, reminders done and left, breathing."
        case .mac: "CPU and memory through the day, with the busiest moments and what caused them."
        case .plan: "The 5-hour and weekly windows of your Claude plan."
        case .ahead: "Your calendar's events today. Asks for Calendar access the first time."
        }
    }

    var symbol: String {
        switch self {
        case .weather: "sun.max.fill"
        case .work: "hammer.fill"
        case .routines: "drop.fill"
        case .mac: "cpu"
        case .plan: "staroflife.fill"
        case .ahead: "calendar"
        }
    }
}

@MainActor
final class DailyBriefSettings: ObservableObject {
    static let shared = DailyBriefSettings()
    private let defaults = UserDefaults.standard

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "dailyBriefEnabled") } }
    /// Where it shows (stored under the first build's key: its "banner" is the notch).
    @Published var place: BriefPlace { didSet { defaults.set(place == .notch ? "banner" : place.rawValue, forKey: "dailyBriefStyle") } }
    @Published var trigger: DailyBriefTrigger { didSet { defaults.set(trigger.rawValue, forKey: "dailyBriefTrigger") } }
    /// Minutes after midnight.
    @Published var minuteOfDay: Int { didSet { defaults.set(minuteOfDay, forKey: "dailyBriefMinute") } }
    @Published var period: DailyBriefPeriod { didSet { defaults.set(period.rawValue, forKey: "dailyBriefPeriod") } }
    /// In the order they show.
    @Published var sections: [DailyBriefSection] {
        didSet { defaults.set(sections.map(\.rawValue), forKey: "dailyBriefSections") }
    }
    /// Seconds each full-screen card stays before the next (0: only by click or arrow key).
    @Published var autoAdvance: Int { didSet { defaults.set(autoAdvance, forKey: "dailyBriefAutoAdvance") } }
    @Published var sound: Bool { didSet { defaults.set(sound, forKey: "dailyBriefSound") } }
    /// "" uses your first name from macOS.
    @Published var name: String { didSet { defaults.set(name, forKey: "dailyBriefName") } }

    var lastShownDay: String? {
        get { defaults.string(forKey: "dailyBriefLastShown") }
        set { defaults.set(newValue, forKey: "dailyBriefLastShown") }
    }

    static let autoAdvanceChoices = [0, 6, 10, 15]

    private init() {
        enabled = defaults.bool(forKey: "dailyBriefEnabled")
        place = defaults.string(forKey: "dailyBriefStyle") == BriefPlace.fullScreen.rawValue ? .fullScreen : .notch
        trigger = DailyBriefTrigger(rawValue: defaults.string(forKey: "dailyBriefTrigger") ?? "") ?? .firstUse
        minuteOfDay = defaults.object(forKey: "dailyBriefMinute") as? Int ?? 8 * 60
        period = DailyBriefPeriod(rawValue: defaults.string(forKey: "dailyBriefPeriod") ?? "") ?? .auto
        let stored = (defaults.stringArray(forKey: "dailyBriefSections") ?? []).compactMap(DailyBriefSection.init(rawValue:))
        sections = defaults.object(forKey: "dailyBriefSections") == nil ? DailyBriefSection.allCases : stored
        autoAdvance = defaults.object(forKey: "dailyBriefAutoAdvance") as? Int ?? 0
        sound = defaults.object(forKey: "dailyBriefSound") as? Bool ?? true
        name = defaults.string(forKey: "dailyBriefName") ?? ""
    }

    var resolvedName: String? { name.isEmpty ? resolveUserFirstName() : name }

    func toggle(_ s: DailyBriefSection, _ on: Bool) {
        // Calendar access is asked when you turn its card on, never when a brief comes by itself.
        if on, s == .ahead { Task { _ = await DailyBriefCalendar.requestAccess() } }
        if on, !sections.contains(s) {
            // Back in its own place among the others.
            let order = DailyBriefSection.allCases
            sections.append(s)
            sections.sort { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! }
        } else if !on {
            sections.removeAll { $0 == s }
        }
    }

    /// The Mac's day is recorded only for a brief that shows it.
    var recordsMac: Bool { enabled && sections.contains(.mac) }
}

// MARK: - The Mac's day, on disk

@MainActor
final class MacDayRecorder {
    static let shared = MacDayRecorder()

    /// Application Support/NotchBuddy/MacDay/<day>.json, the last 14 days.
    let directory = HookServer.supportDir.appendingPathComponent("MacDay", isDirectory: true)
    static let keepDays = 14

    private var timer: Timer?
    private var current: MacDay?
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var subscription: AnyCancellable?

    func start() {
        subscription = DailyBriefSettings.shared.objectWillChange
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        refresh()
    }

    private func refresh() {
        let want = DailyBriefSettings.shared.recordsMac
        if want, timer == nil {
            lastTicks = MachineVitals.cpuTicks()
            let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
            t.tolerance = 10
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !want, timer != nil {
            timer?.invalidate()
            timer = nil
            save()
        }
    }

    private func sample() {
        let now = Date()
        guard let ticks = MachineVitals.cpuTicks() else { return }
        defer { lastTicks = ticks }
        guard let last = lastTicks, ticks.total > last.total else { return }
        let cpu = Double(ticks.busy &- last.busy) / Double(ticks.total - last.total)
        let memory = RunnerSampler.memory().map { Double($0.used) / Double(max(1, $0.total)) } ?? 0
        let key = MacDay.dayKey(now)
        if current?.day != key {
            save()
            current = load(key) ?? MacDay(day: key)
            prune()
        }
        guard cpu >= MacDay.busy else {
            current?.add(cpu: cpu, memory: memory, topApp: nil, at: now)
            save()
            return
        }
        // What made it busy, only then: two readings of every process half a second apart,
        // off the main thread.
        Task.detached(priority: .utility) {
            let top = MacDayTopApp.name()
            await MainActor.run {
                let recorder = MacDayRecorder.shared
                guard recorder.current?.day == key else { return }
                recorder.current?.add(cpu: cpu, memory: memory, topApp: top, at: now)
                recorder.save()
            }
        }
    }

    func day(_ date: Date) -> MacDay? {
        let key = MacDay.dayKey(date)
        if current?.day == key { return current }
        return load(key)
    }

    private func url(_ key: String) -> URL { directory.appendingPathComponent("\(key).json") }

    private func load(_ key: String) -> MacDay? {
        guard let data = try? Data(contentsOf: url(key)) else { return nil }
        return try? JSONDecoder().decode(MacDay.self, from: data)
    }

    private func save() {
        guard let day = current, let data = try? JSONEncoder().encode(day) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(day.day), options: .atomic)
    }

    private func prune() {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let days = files.filter { $0.hasSuffix(".json") }.sorted()
        for f in days.dropLast(Self.keepDays) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(f))
        }
    }
}

/// The app using the CPU most right now, from two readings of every process 0.5 s apart.
enum MacDayTopApp: Sendable {
    static func name() -> String? {
        let first = times()
        usleep(500_000)
        let second = times()
        var best: (pid: pid_t, delta: UInt64)?
        for (pid, t) in second {
            guard let before = first[pid], t > before else { continue }
            if best == nil || t - before > best!.delta { best = (pid, t - before) }
        }
        guard let pid = best?.pid else { return nil }
        if let app = NSRunningApplication(processIdentifier: pid), let n = app.localizedName {
            return n.replacingOccurrences(of: " Helper", with: "")
        }
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, 256)
        let n = String(cString: buffer)
        return n.isEmpty ? nil : n
    }

    private static func times() -> [pid_t: UInt64] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let found = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard found > 0 else { return [:] }
        var out: [pid_t: UInt64] = [:]
        let own = getpid()
        for pid in pids.prefix(Int(found)) where pid > 0 && pid != own {
            var usage = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            if ok == 0 { out[pid] = usage.ri_user_time + usage.ri_system_time }
        }
        return out
    }
}

// MARK: - The routines' diary, in UserDefaults

@MainActor
enum BuddyDiaryStore {
    private static let key = "buddyDiary"

    static var diary: BuddyDiary {
        get {
            guard let d = UserDefaults.standard.data(forKey: key),
                  let v = try? JSONDecoder().decode(BuddyDiary.self, from: d) else { return BuddyDiary() }
            return v
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    static func record(_ change: (inout BuddyDiary.Day) -> Void) {
        var d = diary
        d.record(on: .now, change)
        diary = d
    }
}

// MARK: - Today's calendar

@MainActor
enum DailyBriefCalendar {
    struct Event: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let color: String?
    }

    private static let store = EKEventStore()

    static var status: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }

    /// Asks once (macOS shows its own prompt); false when refused.
    static func requestAccess() async -> Bool {
        if status == .fullAccess { return true }
        guard status == .notDetermined else { return false }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// The events of `day`, without asking for access.
    static func events(on day: Date, calendar: Calendar = .current) -> [Event] {
        guard status == .fullAccess else { return [] }
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(8)
            .map { e in
                Event(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "Event",
                      start: e.startDate, end: e.endDate, allDay: e.isAllDay,
                      color: e.calendar.map { NSColor(cgColor: $0.cgColor)?.hexString } ?? nil)
            }
    }
}

private extension NSColor {
    var hexString: String? {
        guard let c = usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

// MARK: - Days the brief was read

@MainActor
enum DailyBriefReads {
    private static let key = "dailyBriefReadDays"

    static var days: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
        set { UserDefaults.standard.set(Array(newValue.sorted().suffix(120)), forKey: key) }
    }

    static func markRead(_ date: Date = Date()) { days.insert(MacDay.dayKey(date)) }

    /// Days in a row up to today (or yesterday, when today's is not read yet).
    static func streak(now: Date, calendar: Calendar = .current) -> Int {
        let read = days
        var d = calendar.startOfDay(for: now)
        if !read.contains(MacDay.dayKey(d, calendar: calendar)) {
            d = calendar.date(byAdding: .day, value: -1, to: d) ?? d
        }
        var n = 0
        while read.contains(MacDay.dayKey(d, calendar: calendar)) {
            n += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: d) else { break }
            d = prev
        }
        return n
    }

    /// Monday to Sunday of this week.
    static func week(now: Date, calendar: Calendar = .current) -> [Bool] {
        let read = days
        var cal = calendar
        cal.firstWeekday = 2
        guard let start = cal.dateInterval(of: .weekOfYear, for: now)?.start else { return Array(repeating: false, count: 7) }
        return (0..<7).map { i in
            cal.date(byAdding: .day, value: i, to: start).map { read.contains(MacDay.dayKey($0, calendar: cal)) } ?? false
        }
    }
}

// MARK: - The brief

struct DailyBrief {
    var date: Date
    var day: Date
    var isToday: Bool
    var greeting: String
    var headline: String
    var weather: DailyBriefWeather?
    /// Days the brief was read, this week (Monday first), for its streak dots.
    var weekRead: [Bool]
    var readStreak: Int
    var work: DayWork?
    var streak: Int
    var water: (ml: Int, goal: Int)?
    var diary: BuddyDiary.Day?
    var remindersLeft: Int
    var mac: MacDay?
    var plan: PlanUsage?
    var events: [DailyBriefCalendar.Event]
    var sections: [DailyBriefSection]
}

@MainActor
enum DailyBriefBuilder {
    /// `askCalendar` false (a brief that comes by itself): reads the calendar only if access was
    /// already given, so no prompt ever stops it.
    static func build(now: Date = Date(), askCalendar: Bool = false) async -> DailyBrief {
        let settings = DailyBriefSettings.shared
        let cal = Calendar.current
        let day = settings.period.day(now: now, calendar: cal)
        let isToday = cal.isDate(day, inSameDayAs: now)
        let end = cal.date(byAdding: .day, value: 1, to: day) ?? now
        let records = RecapStore.shared.records()
        let work = DayWork.from(turns: records.turns, decisions: records.decisions, start: day, end: end, calendar: cal)
        let routines = BuddyRoutineSettings.shared
        var weather: DailyBriefWeather?
        let city = VoiceSettings.weatherCity.trimmingCharacters(in: .whitespaces)
        if settings.sections.contains(.weather), !city.isEmpty {
            weather = await DailyBriefWeather.fetch(city: city)
        }
        var events: [DailyBriefCalendar.Event] = []
        if settings.sections.contains(.ahead), askCalendar ? await DailyBriefCalendar.requestAccess() : DailyBriefCalendar.status == .fullAccess {
            events = DailyBriefCalendar.events(on: now, calendar: cal)
        }
        let routinesOn = routines.waterEnabled
        return DailyBrief(
            date: now, day: day, isToday: isToday,
            greeting: DailyBriefText.greeting(at: now, name: settings.resolvedName, calendar: cal),
            headline: DailyBriefText.headline(work: work, isToday: isToday),
            weather: weather,
            weekRead: DailyBriefReads.week(now: now, calendar: cal),
            readStreak: DailyBriefReads.streak(now: now, calendar: cal),
            work: work,
            streak: DayWork.streak(turns: records.turns, endingOn: day, calendar: cal),
            water: routinesOn ? (routines.waterLog.total(on: day, calendar: cal), routines.waterPlan.goal) : nil,
            diary: BuddyDiaryStore.diary.day(day, calendar: cal),
            remindersLeft: BuddyRoutineController.shared.reminders.count,
            mac: MacDayRecorder.shared.day(day),
            plan: AppState.shared.claudePlanUsage,
            events: events,
            sections: settings.sections)
    }
}
#endif
