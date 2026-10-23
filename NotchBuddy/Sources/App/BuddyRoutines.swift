import Foundation

// coucou-custom fork: the Buddy's routines, after OpenPets' bundled plugins — Quick Reminders,
// Focus Buddy (Pomodoro), Simple Timer, Water Reminder, Launch Buddy and the calm corner's
// breathing. Pure values and rules here; BuddyRoutineController runs them.

// MARK: - Quick Reminders

struct BuddyReminder: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var text: String
    var due: Date
    var snoozes: Int = 0

    init(id: String = BuddyReminder.newID(), text: String, due: Date) {
        self.id = id
        self.text = text
        self.due = due
    }

    /// Short and readable: the assistant quotes it back to complete or snooze one.
    static func newID() -> String { String(UUID().uuidString.prefix(6)).lowercased() }
}

enum BuddyReminders {
    static let maxCount = 50
    static let snoozeMinutes = 5

    /// When "in 10 minutes", "at 15:30", "at 3pm" or "at 2026-10-24T09:00" falls; nil if it can't
    /// be read or is in the past. A bare time already past today means tomorrow.
    static func due(inMinutes: Double?, at: String?, now: Date, calendar: Calendar = .current) -> Date? {
        if let m = inMinutes, m > 0, m <= 60 * 24 * 365 { return now.addingTimeInterval(m * 60) }
        guard let raw = at?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let d = absolute(raw, calendar: calendar) { return d > now ? d : nil }
        guard let (h, m) = clock(raw) else { return nil }
        var c = calendar.dateComponents([.year, .month, .day], from: now)
        c.hour = h
        c.minute = m
        guard let today = calendar.date(from: c) else { return nil }
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }

    /// "2026-10-24T09:00", with or without seconds or a zone; local time when none.
    private static func absolute(_ s: String, calendar: Calendar) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    /// "15:30", "9:05", "3pm", "3:30 PM", "noon", "midnight".
    static func clock(_ s: String) -> (Int, Int)? {
        let t = s.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ".", with: "")
        if t == "noon" { return (12, 0) }
        if t == "midnight" { return (0, 0) }
        var body = t
        var meridiem: String?
        for suffix in ["am", "pm"] where body.hasSuffix(suffix) {
            meridiem = suffix
            body = String(body.dropLast(2))
        }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let h = Int(parts[0]) else { return nil }
        let m = parts.count == 2 ? Int(parts[1]) : 0
        guard let m, (0..<60).contains(m) else { return nil }
        if let meridiem {
            guard (1...12).contains(h) else { return nil }
            return ((h % 12) + (meridiem == "pm" ? 12 : 0), m)
        }
        guard (0..<24).contains(h), parts.count == 2 else { return nil }
        return (h, m)
    }

    /// Soonest first.
    static func sorted(_ list: [BuddyReminder]) -> [BuddyReminder] { list.sorted { $0.due < $1.due } }

    static func encode(_ list: [BuddyReminder]) -> Data? { try? JSONEncoder().encode(list) }
    static func decode(_ data: Data) -> [BuddyReminder]? { try? JSONDecoder().decode([BuddyReminder].self, from: data) }
}

// MARK: - Focus Buddy (Pomodoro)

struct BuddyFocusPlan: Codable, Equatable, Sendable {
    /// Minutes.
    var focus: Int = 25
    var shortBreak: Int = 5
    var longBreak: Int = 15
    /// A long break after this many focus sessions.
    var roundsBeforeLong: Int = 4

    static let standard = BuddyFocusPlan()
    /// What a session and a break can last, chosen in settings or asked of the assistant.
    static let focusRange = 1...180
    static let breakRange = 1...60
    static let longBreakRange = 1...90

    func minutes(_ phase: BuddyFocusPhase) -> Int {
        switch phase {
        case .focus: focus
        case .shortBreak: shortBreak
        case .longBreak: longBreak
        }
    }
}

enum BuddyFocusPhase: String, Codable, Sendable {
    case focus, shortBreak, longBreak

    var isBreak: Bool { self != .focus }

    var label: String {
        switch self {
        case .focus: "Focus"
        case .shortBreak: "Break"
        case .longBreak: "Long break"
        }
    }
}

struct BuddyFocusSession: Equatable, Sendable {
    var plan: BuddyFocusPlan
    var phase: BuddyFocusPhase
    /// The focus session in progress or just done (1-based).
    var round: Int
    /// When the phase ends while running; nil while paused.
    var endsAt: Date?
    /// Seconds left, while paused.
    var pausedLeft: TimeInterval?
    /// Focus sessions finished.
    var completed: Int = 0

    static func start(_ plan: BuddyFocusPlan, at now: Date) -> BuddyFocusSession {
        BuddyFocusSession(plan: plan, phase: .focus, round: 1,
                          endsAt: now.addingTimeInterval(TimeInterval(plan.focus * 60)), pausedLeft: nil)
    }

    var isPaused: Bool { endsAt == nil }

    func remaining(at now: Date) -> TimeInterval {
        if let endsAt { return max(0, endsAt.timeIntervalSince(now)) }
        return max(0, pausedLeft ?? 0)
    }

    func isOver(at now: Date) -> Bool { !isPaused && remaining(at: now) <= 0 }

    mutating func pause(at now: Date) {
        guard !isPaused else { return }
        pausedLeft = remaining(at: now)
        endsAt = nil
    }

    mutating func resume(at now: Date) {
        guard isPaused else { return }
        endsAt = now.addingTimeInterval(pausedLeft ?? 0)
        pausedLeft = nil
    }

    /// The next phase: a focus session leads to a break (long every `roundsBeforeLong`), a break
    /// to the next focus session. Used when a phase runs out and for Skip.
    mutating func advance(at now: Date) {
        switch phase {
        case .focus:
            completed += 1
            phase = round % max(1, plan.roundsBeforeLong) == 0 ? .longBreak : .shortBreak
        case .shortBreak, .longBreak:
            round += 1
            phase = .focus
        }
        endsAt = now.addingTimeInterval(TimeInterval(plan.minutes(phase) * 60))
        pausedLeft = nil
    }
}

// MARK: - Simple Timer

struct BuddyCountdown: Equatable, Sendable {
    var label: String
    var total: TimeInterval
    var endsAt: Date?
    var pausedLeft: TimeInterval?

    static let maxSeconds: TimeInterval = 24 * 3600
    static let presets = [1, 3, 5, 10, 15, 25, 30, 45, 60]

    static func start(seconds: TimeInterval, label: String, at now: Date) -> BuddyCountdown? {
        guard seconds >= 1, seconds <= maxSeconds else { return nil }
        return BuddyCountdown(label: label, total: seconds, endsAt: now.addingTimeInterval(seconds), pausedLeft: nil)
    }

    var isPaused: Bool { endsAt == nil }

    func remaining(at now: Date) -> TimeInterval {
        if let endsAt { return max(0, endsAt.timeIntervalSince(now)) }
        return max(0, pausedLeft ?? 0)
    }

    func isOver(at now: Date) -> Bool { !isPaused && remaining(at: now) <= 0 }

    mutating func pause(at now: Date) {
        guard !isPaused else { return }
        pausedLeft = remaining(at: now)
        endsAt = nil
    }

    mutating func resume(at now: Date) {
        guard isPaused else { return }
        endsAt = now.addingTimeInterval(pausedLeft ?? 0)
        pausedLeft = nil
    }

    mutating func add(_ seconds: TimeInterval, at now: Date) {
        let left = min(Self.maxSeconds, remaining(at: now) + seconds)
        total += seconds
        if isPaused { pausedLeft = left } else { endsAt = now.addingTimeInterval(left) }
    }
}

// MARK: - Water Reminder

/// How the water nudges go: every so often, within hours, on some days, toward a daily goal.
struct BuddyWaterPlan: Codable, Equatable, Sendable {
    /// Millilitres a day.
    var goal = 2000
    /// One glass, logged from the nudge.
    var glass = 250
    /// Minutes between nudges.
    var every = 60
    /// Minutes after midnight; from == to is all day. `to` is exclusive and may wrap midnight.
    var from = 9 * 60
    var to = 21 * 60
    /// Calendar weekdays (1 Sunday … 7 Saturday).
    var days: Set<Int> = Set(1...7)
    /// No more nudges once the goal is reached that day.
    var stopAtGoal = true

    static let standard = BuddyWaterPlan()
    static let goals = [1500, 2000, 2500, 3000]
    static let glasses = [150, 200, 250, 330, 500]
    static let intervals = [20, 30, 45, 60, 90, 120]
    /// The limits a custom value is kept in (the presets are inside them).
    static let goalRange = 250...6000
    static let glassRange = 50...1500
    static let everyRange = 10...240
}

enum BuddyWater {
    /// Away longer than this, the nudge waits until you are back.
    static let awaySeconds: TimeInterval = 120
    static let snoozeMinutes = 15

    /// The nudge is due and you are at the Mac: a nudge to nobody is noise.
    static func shouldNudge(due: Date, now: Date, userIdle: TimeInterval) -> Bool {
        now >= due && userIdle < awaySeconds
    }

    /// Inside the plan's days and hours.
    static func isActive(_ plan: BuddyWaterPlan, at date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let inHours: Bool
        if plan.from == plan.to { inHours = true }
        else if plan.from < plan.to { inHours = m >= plan.from && m < plan.to }
        else { inHours = m >= plan.from || m < plan.to }
        // Past midnight in a wrapping window, the day is the one it started on.
        var day = c.weekday ?? 1
        if plan.from > plan.to && m < plan.to { day = day == 1 ? 7 : day - 1 }
        return inHours && plan.days.contains(day)
    }

    /// The next nudge after `date`: `every` minutes on, or the next start of the hours when that
    /// falls outside them. Nil when no day is picked.
    static func next(after date: Date, plan: BuddyWaterPlan, calendar: Calendar = .current) -> Date? {
        guard !plan.days.isEmpty else { return nil }
        let candidate = date.addingTimeInterval(TimeInterval(max(1, plan.every) * 60))
        if isActive(plan, at: candidate, calendar: calendar) { return candidate }
        // The next window start, over the coming week.
        let start = calendar.startOfDay(for: candidate)
        for d in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: d, to: start),
                  let open = calendar.date(byAdding: .minute, value: plan.from, to: day) else { continue }
            if open > candidate && isActive(plan, at: open, calendar: calendar) { return open }
        }
        return nil
    }

    /// "2026-10-23", the day's key in the log.
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "750 ml", "1.25 L", "2 L".
    static func amount(_ ml: Int) -> String {
        if ml < 1000 { return "\(ml) ml" }
        let l = Double(ml) / 1000
        return l == l.rounded() ? "\(Int(l)) L" : String(format: "%g L", (l * 100).rounded() / 100)
    }
}

/// Millilitres drunk per day, the last 60 days.
struct BuddyWaterLog: Codable, Equatable, Sendable {
    var days: [String: Int] = [:]

    static let keepDays = 60

    func total(on date: Date, calendar: Calendar = .current) -> Int { days[BuddyWater.dayKey(date, calendar: calendar)] ?? 0 }

    mutating func add(_ ml: Int, on date: Date, calendar: Calendar = .current) {
        let key = BuddyWater.dayKey(date, calendar: calendar)
        days[key] = min(20_000, max(0, (days[key] ?? 0) + ml))
        if days.count > Self.keepDays {
            for k in days.keys.sorted().dropLast(Self.keepDays) { days[k] = nil }
        }
    }

    /// The last `count` days up to `date`, oldest first.
    func history(_ count: Int, upTo date: Date, calendar: Calendar = .current) -> [(day: Date, ml: Int)] {
        (0..<count).reversed().compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: calendar.startOfDay(for: date)).map { ($0, total(on: $0, calendar: calendar)) }
        }
    }
}

// MARK: - Calm corner: breathing

enum BuddyBreathing: String, CaseIterable, Codable, Sendable, Identifiable {
    case calm, box, calming, energizing, quickReset

    var id: String { rawValue }

    var name: String {
        switch self {
        case .calm: "Calm"
        case .box: "Box"
        case .calming: "4-7-8"
        case .energizing: "Energize"
        case .quickReset: "Quick reset"
        }
    }

    var hint: String {
        switch self {
        case .calm: "A longer breath out"
        case .box: "Steady focus"
        case .calming: "Wind down, before sleep"
        case .energizing: "A clear head"
        case .quickReset: "About a minute"
        }
    }

    var detail: String {
        switch self {
        case .calm: "4-6"
        case .box: "4-4-4-4"
        case .calming: "4-7-8"
        case .energizing: "4-4-6"
        case .quickReset: "3-3-3"
        }
    }

    enum Step: String, Sendable {
        case inhale, holdFull, exhale, holdEmpty

        var label: String {
            switch self {
            case .inhale: "Breathe in"
            case .holdFull, .holdEmpty: "Hold"
            case .exhale: "Breathe out"
            }
        }

        var guidance: String {
            switch self {
            case .inhale: "Slowly, through your nose"
            case .holdFull: "Lungs full, stay still"
            case .exhale: "Long and slow, let it go"
            case .holdEmpty: "Lungs empty, rest"
            }
        }
    }

    /// One breath: each step and its seconds.
    var steps: [(Step, Int)] {
        switch self {
        case .calm: [(.inhale, 4), (.exhale, 6)]
        case .box: [(.inhale, 4), (.holdFull, 4), (.exhale, 4), (.holdEmpty, 4)]
        case .calming: [(.inhale, 4), (.holdFull, 7), (.exhale, 8)]
        case .energizing: [(.inhale, 4), (.holdFull, 4), (.exhale, 6)]
        case .quickReset: [(.inhale, 3), (.holdFull, 3), (.exhale, 3)]
        }
    }

    /// Breaths in one session.
    var cycles: Int {
        switch self {
        case .calm: 10
        case .box: 8
        case .calming: 4
        case .energizing: 8
        case .quickReset: 6
        }
    }

    var breathSeconds: Int { steps.reduce(0) { $0 + $1.1 } }
    var totalSeconds: Int { cycles * breathSeconds }
    /// Breaths a minute, "6".
    var pace: String { String(format: "%g", (600.0 / Double(breathSeconds)).rounded() / 10) }

    struct Position: Equatable, Sendable {
        var step: Step
        /// Which step of the breath (0-based).
        var index: Int
        var left: Int
        /// 0…1 into the step.
        var progress: Double
        /// 1-based.
        var cycle: Int
    }

    /// Where `elapsed` seconds fall; nil before the start and once done.
    func position(elapsed: TimeInterval) -> Position? {
        guard elapsed >= 0, elapsed < TimeInterval(totalSeconds) else { return nil }
        let cycle = Int(elapsed) / breathSeconds
        var t = elapsed - TimeInterval(cycle * breathSeconds)
        for (i, (step, secs)) in steps.enumerated() {
            if t < TimeInterval(secs) {
                return Position(step: step, index: i, left: max(1, Int(ceil(TimeInterval(secs) - t))),
                                progress: t / TimeInterval(secs), cycle: cycle + 1)
            }
            t -= TimeInterval(secs)
        }
        return nil
    }

    /// How full the lungs are, 0…1: eased in on the way in, out on the way out.
    static func fullness(step: Step, progress: Double) -> Double {
        let p = min(max(progress, 0), 1)
        let eased = 0.5 - cos(p * .pi) / 2
        switch step {
        case .inhale: return eased
        case .holdFull: return 1
        case .exhale: return 1 - eased
        case .holdEmpty: return 0
        }
    }

    /// How big Mochi is (1 = itself): it fills up breathing in and empties breathing out.
    static func scale(step: Step, progress: Double) -> Double { 1 + 0.12 * fullness(step: step, progress: progress) }
}

/// One breathing session: a few seconds to settle, the breaths, pauses.
struct BuddyBreathSession: Equatable, Sendable {
    static let leadIn: TimeInterval = 3

    var pattern: BuddyBreathing
    var started: Date
    /// While paused, since when.
    var pausedAt: Date?
    var pausedTotal: TimeInterval = 0

    init(pattern: BuddyBreathing, at now: Date) {
        self.pattern = pattern
        started = now
    }

    var isPaused: Bool { pausedAt != nil }

    /// Seconds of breathing so far: negative while settling in, pauses left out.
    func elapsed(at now: Date) -> TimeInterval {
        let end = pausedAt ?? now
        return end.timeIntervalSince(started) - pausedTotal - Self.leadIn
    }

    enum Phase: Equatable, Sendable {
        case settling(left: Int)
        case breathing(BuddyBreathing.Position)
        case done
    }

    func phase(at now: Date) -> Phase {
        let e = elapsed(at: now)
        if e < 0 { return .settling(left: max(1, Int(ceil(-e)))) }
        return pattern.position(elapsed: e).map { .breathing($0) } ?? .done
    }

    func remaining(at now: Date) -> TimeInterval {
        min(TimeInterval(pattern.totalSeconds), max(0, TimeInterval(pattern.totalSeconds) - elapsed(at: now)))
    }

    mutating func pause(at now: Date) {
        guard pausedAt == nil, phase(at: now) != .done else { return }
        pausedAt = now
    }

    mutating func resume(at now: Date) {
        guard let p = pausedAt else { return }
        pausedTotal += now.timeIntervalSince(p)
        pausedAt = nil
    }

    /// From the top, with the same pattern or another.
    mutating func restart(_ pattern: BuddyBreathing? = nil, at now: Date) {
        self = BuddyBreathSession(pattern: pattern ?? self.pattern, at: now)
    }
}

// MARK: - Launch Buddy

enum BuddyGreeting {
    /// "Good morning, Aakash!" by the hour; plain when there is no name.
    static func line(hour: Int, name: String?) -> String {
        let name = (name ?? "").isEmpty ? nil : name
        let part: String
        switch hour {
        case 5..<12: part = "Good morning"
        case 12..<17: part = "Good afternoon"
        case 17..<22: part = "Good evening"
        default: return name.map { "Hi \($0)! Up late?" } ?? "Hi! Up late?"
        }
        return name.map { "\(part), \($0)!" } ?? part + "!"
    }
}

// MARK: - Text

enum BuddyTimeText {
    /// "25 min left", "1 h 5 min left", "45 s left".
    static func left(_ seconds: TimeInterval) -> String {
        let s = Int(ceil(max(0, seconds)))
        if s < 60 { return "\(s) s left" }
        let m = Int(ceil(Double(s) / 60))
        if m < 60 { return "\(m) min left" }
        return m % 60 == 0 ? "\(m / 60) h left" : "\(m / 60) h \(m % 60) min left"
    }

    /// "4:05", "1:02:03".
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(ceil(max(0, seconds)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// "10 minutes", "1 hour 30 minutes", "45 seconds".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) second\(s == 1 ? "" : "s")" }
        let m = s / 60
        let h = m / 60, rem = m % 60
        func unit(_ n: Int, _ w: String) -> String { "\(n) \(w)\(n == 1 ? "" : "s")" }
        if h == 0 { return unit(m, "minute") }
        return rem == 0 ? unit(h, "hour") : unit(h, "hour") + " " + unit(rem, "minute")
    }
}
