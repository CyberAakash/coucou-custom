import Foundation

// MARK: - Daily brief tests (coucou-custom fork)

@main
enum DailyBriefTests {
    static var failures = 0

    static func check(_ label: String, _ ok: Bool) {
        print(ok ? "✓ \(label)" : "✗ \(label)")
        if !ok { failures += 1 }
    }

    static var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return c
    }()

    static func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    static func main() {
        macDayTests()
        diaryTests()
        workTests()
        scheduleTests()
        textTests()
        weatherTests()
        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("All daily brief tests passed")
    }

    static func macDayTests() {
        var d = MacDay(day: "2026-10-23")
        d.add(cpu: 0.2, memory: 0.5, topApp: nil, at: at(23, 9, 0), calendar: cal)
        d.add(cpu: 0.4, memory: 0.7, topApp: nil, at: at(23, 9, 4), calendar: cal)
        check("same 5 minutes, one bucket", d.buckets.count == 1 && d.buckets[0].minute == 540)
        check("bucket mean", abs(d.buckets[0].cpu - 0.3) < 1e-9 && abs(d.buckets[0].memory - 0.6) < 1e-9)
        check("bucket peak", d.buckets[0].cpuMax == 0.4)
        check("no app named under the busy line", d.buckets[0].peakApp == nil)
        d.add(cpu: 0.95, memory: 0.8, topApp: "Xcode", at: at(23, 14, 21), calendar: cal)
        check("new bucket at 14:20", d.buckets.count == 2 && d.buckets[1].minute == 860)
        check("peak app named when busy", d.buckets[1].peakApp == "Xcode")
        d.add(cpu: 0.7, memory: 0.8, topApp: "Chrome", at: at(23, 14, 22), calendar: cal)
        check("a lower reading keeps the peak's app", d.buckets[1].peakApp == "Xcode" && d.buckets[1].cpuMax == 0.95)
        d.add(cpu: 1.5, memory: -1, topApp: nil, at: at(23, 14, 50), calendar: cal)
        check("values held to 0…1", d.buckets[2].cpuMax == 1 && d.buckets[2].memory == 0)
        let peaks = d.peaks(count: 2, apart: 60)
        check("peaks keep an hour apart", peaks.count == 1 && peaks[0].minute == 890)
        check("clock", MacDay.clock(860) == "14:20" && MacDay.clock(5) == "00:05")
        check("day key", MacDay.dayKey(at(3, 1), calendar: cal) == "2026-10-03")
        check("average cpu", d.averageCPU.map { abs($0 - (0.2 + 0.4 + 0.95 + 0.7 + 1) / 5) < 1e-9 } == true)
        check("empty day has no average", MacDay(day: "x").averageCPU == nil)
        let json = try? JSONEncoder().encode(d)
        check("round trip", json.flatMap { try? JSONDecoder().decode(MacDay.self, from: $0) } == d)
    }

    static func diaryTests() {
        var diary = BuddyDiary()
        diary.record(on: at(23, 10), calendar: cal) { $0.focusSessions += 1; $0.focusMinutes += 25 }
        diary.record(on: at(23, 18), calendar: cal) { $0.remindersDone += 1 }
        check("one day, both counted", diary.day(at(23, 0), calendar: cal) == BuddyDiary.Day(focusSessions: 1, focusMinutes: 25, remindersDone: 1))
        check("another day empty", diary.day(at(22, 12), calendar: cal) == nil)
        for i in 0..<70 {
            diary.record(on: cal.date(byAdding: .day, value: -i, to: at(23, 12))!, calendar: cal) { $0.timersDone += 1 }
        }
        check("keeps 60 days", diary.days.count == BuddyDiary.keepDays)
        check("keeps the newest", diary.day(at(23, 12), calendar: cal) != nil)
    }

    static func turn(_ project: String, _ start: Date, minutes: Double, files: Int = 1, pill: String = "integration_claude") -> RecapTurn {
        RecapTurn(pillId: pill, project: project, start: start, end: start.addingTimeInterval(minutes * 60),
                  filesChanged: files, linesAdded: 10, linesRemoved: 2, commandsRun: 3, questions: 1)
    }

    static func workTests() {
        let turns = [
            turn("coucou", at(22, 9), minutes: 60, files: 4),
            turn("coucou", at(22, 9, 30), minutes: 60, files: 2),   // overlaps the first
            turn("rea", at(22, 15), minutes: 30),
            turn("old", at(21, 23, 30), minutes: 90),               // starts the day before
        ]
        let decisions = [
            RecapDecision(pillId: "x", date: at(22, 10), decision: "allow"),
            RecapDecision(pillId: "x", date: at(22, 11), decision: "deny"),
            RecapDecision(pillId: "x", date: at(23, 1), decision: "always"),
        ]
        let w = DayWork.from(turns: turns, decisions: decisions, start: at(22, 0), end: at(23, 0), calendar: cal)
        check("sessions that started that day", w.sessions == 3)
        check("overlaps counted once (90 + 30 min)", w.minutes == 120)
        check("files", w.filesChanged == 7)
        check("approvals that day", w.approvals == 1)
        check("top project", w.topProject == "coucou")
        check("by hour", w.byHour[9] == 2 && w.byHour[15] == 1)
        check("empty day", DayWork.from(turns: turns, decisions: [], start: at(10, 0), end: at(11, 0), calendar: cal).isEmpty)
        check("streak of 2", DayWork.streak(turns: turns, endingOn: at(22, 20), calendar: cal) == 2)
        check("no streak on a quiet day", DayWork.streak(turns: turns, endingOn: at(23, 12), calendar: cal) == 0)
        let tie = DayWork.from(turns: [turn("b", at(22, 1), minutes: 5), turn("a", at(22, 2), minutes: 5)],
                               decisions: [], start: at(22, 0), end: at(23, 0), calendar: cal)
        check("ties go to the first name", tie.topProject == "a")
    }

    static func scheduleTests() {
        let m = 8 * 60
        check("first use: before the time, no", !DailyBriefSchedule.shouldShow(trigger: .firstUse, minuteOfDay: m, now: at(23, 7, 59), lastShownDay: nil, calendar: cal))
        check("first use: after it, yes", DailyBriefSchedule.shouldShow(trigger: .firstUse, minuteOfDay: m, now: at(23, 11), lastShownDay: "2026-10-22", calendar: cal))
        check("once a day", !DailyBriefSchedule.shouldShow(trigger: .firstUse, minuteOfDay: m, now: at(23, 11), lastShownDay: "2026-10-23", calendar: cal))
        check("at time: within 15 min", DailyBriefSchedule.shouldShow(trigger: .atTime, minuteOfDay: m, now: at(23, 8, 10), lastShownDay: nil, calendar: cal))
        check("at time: too late", !DailyBriefSchedule.shouldShow(trigger: .atTime, minuteOfDay: m, now: at(23, 8, 20), lastShownDay: nil, calendar: cal))
        check("manual never by itself", !DailyBriefSchedule.shouldShow(trigger: .manual, minuteOfDay: 0, now: at(23, 12), lastShownDay: nil, calendar: cal))
        check("auto period: morning is yesterday", DailyBriefPeriod.auto.day(now: at(23, 9), calendar: cal) == at(22, 0))
        check("auto period: evening is today", DailyBriefPeriod.auto.day(now: at(23, 19), calendar: cal) == at(23, 0))
    }

    static func textTests() {
        check("greeting morning", DailyBriefText.greeting(at: at(23, 8), name: "Aakash", calendar: cal) == "Good morning, Aakash")
        check("greeting evening no name", DailyBriefText.greeting(at: at(23, 20), name: " ", calendar: cal) == "Good evening")
        check("duration", DailyBriefText.duration(minutes: 312) == "5h 12m" && DailyBriefText.duration(minutes: 48) == "48m")
        var w = DayWork()
        w.sessions = 6; w.minutes = 312; w.filesChanged = 31; w.topProject = "coucou"
        check("headline", DailyBriefText.headline(work: w, isToday: false) == "Yesterday: 6 agent sessions, 5h 12m of work, 31 files changed, mostly on coucou.")
        check("quiet headline", DailyBriefText.headline(work: DayWork(), isToday: true).hasPrefix("A quiet day"))
        check("water", DailyBriefText.water(1500) == "1.5 L" && DailyBriefText.water(3000) == "3 L" && DailyBriefText.water(750) == "750 ml")
    }

    static func weatherTests() {
        let times = (0..<24).map { String(format: "2026-10-24T%02d:00", $0) }
        let json: [String: Any] = [
            "current": ["temperature_2m": 26.4, "weather_code": 3],
            "daily": ["temperature_2m_max": [30.2], "temperature_2m_min": [24.6], "precipitation_probability_max": [88]],
            "hourly": ["time": times,
                       "temperature_2m": (0..<24).map { Double(20 + $0 / 3) },
                       "weather_code": (0..<24).map { $0 >= 18 ? 95 : 51 },
                       "precipitation_probability": (0..<24).map { $0 >= 13 ? 70 : 10 }],
        ]
        let w = DailyBriefWeather.parse(json, city: "Chennai")
        check("weather parses", w != nil)
        check("now and range rounded", w?.now == 26 && w?.high == 30 && w?.low == 25)
        check("four hours", w?.hours.map(\.hour) == [9, 12, 15, 18])
        check("hour values", w?.hours.first?.temp == 23 && w?.hours.last?.code == 95)
        check("rain from 13:00", w?.rainFrom == 13)
        check("line", w?.line == "High 30° · Low 25° · Rain likely after 13:00")
        check("no current, no weather", DailyBriefWeather.parse(["daily": json["daily"]!], city: "x") == nil)
        check("codes described", DailyBriefWeather.describe(0) == "Clear" && DailyBriefWeather.describe(63) == "Rain")
    }
}
