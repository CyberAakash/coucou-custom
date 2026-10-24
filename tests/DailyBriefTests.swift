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
        weeklyScheduleTests()
        inputTests()
        weatherTests()
        weekTests()
        planTests()
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

    static func weeklyScheduleTests() {
        // at(day, hour): 23 October 2026 is a Friday.
        let friday = at(23, 9)
        check("weekday: Friday is 5", WeeklyBriefSchedule.weekday(friday, calendar: cal) == 5)
        check("weekday: Monday is 1", WeeklyBriefSchedule.weekday(at(26, 9), calendar: cal) == 1)
        check("its day, after its time", WeeklyBriefSchedule.shouldShow(trigger: .firstUse, weekday: 5, minuteOfDay: 8 * 60, now: friday, lastShownWeek: 0, calendar: cal))
        check("not another day", !WeeklyBriefSchedule.shouldShow(trigger: .firstUse, weekday: 1, minuteOfDay: 8 * 60, now: friday, lastShownWeek: 0, calendar: cal))
        check("not before its time", !WeeklyBriefSchedule.shouldShow(trigger: .firstUse, weekday: 5, minuteOfDay: 10 * 60, now: friday, lastShownWeek: 0, calendar: cal))
        check("once a week", !WeeklyBriefSchedule.shouldShow(trigger: .firstUse, weekday: 5, minuteOfDay: 8 * 60, now: friday,
                                                             lastShownWeek: WeeklyBriefSchedule.weekKey(friday), calendar: cal))
        check("at a time: only its 15 minutes", !WeeklyBriefSchedule.shouldShow(trigger: .atTime, weekday: 5, minuteOfDay: 8 * 60, now: friday, lastShownWeek: 0, calendar: cal)
              && WeeklyBriefSchedule.shouldShow(trigger: .atTime, weekday: 5, minuteOfDay: 8 * 60 + 50, now: friday, lastShownWeek: 0, calendar: cal))
        check("next due: Monday 8:00 after a Friday", WeeklyBriefSchedule.nextDue(weekday: 1, minuteOfDay: 8 * 60, after: friday, calendar: cal) == at(26, 8))
        check("next due: later today", WeeklyBriefSchedule.nextDue(weekday: 5, minuteOfDay: 18 * 60, after: friday, calendar: cal) == at(23, 18))
        check("next due: a week on when past", WeeklyBriefSchedule.nextDue(weekday: 5, minuteOfDay: 8 * 60, after: friday, calendar: cal) == at(30, 8))
    }

    static func inputTests() {
        check("time 8:30", BriefInput.minuteOfDay(from: "8:30") == 510)
        check("time 0830", BriefInput.minuteOfDay(from: "0830") == 510)
        check("time 8", BriefInput.minuteOfDay(from: "8") == 480)
        check("time 8:30 pm", BriefInput.minuteOfDay(from: "8:30 pm") == 20 * 60 + 30)
        check("time 12 am is midnight", BriefInput.minuteOfDay(from: "12 am") == 0)
        check("time 18.05", BriefInput.minuteOfDay(from: "18.05") == 18 * 60 + 5)
        check("time nonsense", BriefInput.minuteOfDay(from: "25:00") == nil && BriefInput.minuteOfDay(from: "8:75") == nil && BriefInput.minuteOfDay(from: "soon") == nil)
        check("seconds", BriefInput.seconds(from: "25") == 25 && BriefInput.seconds(from: "25 s") == 25 && BriefInput.seconds(from: "1 min") == 60)
        check("seconds out of range", BriefInput.seconds(from: "0") == nil && BriefInput.seconds(from: "20 min") == nil && BriefInput.seconds(from: "x") == nil)
    }

    static func textTests() {
        check("greeting morning", DailyBriefText.greeting(at: at(23, 8), name: "Aakash", calendar: cal) == "Good morning, Aakash")
        check("greeting evening no name", DailyBriefText.greeting(at: at(23, 20), name: " ", calendar: cal) == "Good evening")
        check("duration", DailyBriefText.duration(minutes: 312) == "5h 12m" && DailyBriefText.duration(minutes: 48) == "48m")
        var w = DayWork()
        w.sessions = 6; w.minutes = 312; w.filesChanged = 31; w.topProject = "coucou"
        check("headline", DailyBriefText.headline(work: w, isToday: false) == "Yesterday: 6 agent sessions, 5h 12m of work, 31 files changed, mostly on coucou.")
        check("quiet headline", DailyBriefText.headline(work: DayWork(), isToday: true).hasPrefix("A quiet day"))
        let line = DailyBriefText.notchLine(work: w, isToday: false)
        check("notch line", line.lead + line.value + line.tail == "Yesterday you spent 5h 12m with your agents." && line.value == "5h 12m")
        check("quiet notch line has no number", DailyBriefText.notchLine(work: DayWork(), isToday: true).value.isEmpty)
        check("shuffle turns the order round", BriefOrder.rotate([1, 2, 3]) == [2, 3, 1] && BriefOrder.rotate([Int]()).isEmpty)
        check("drag down", BriefOrder.move(1, to: 3, in: [1, 2, 3, 4]) == [2, 3, 1, 4])
        check("drag up", BriefOrder.move(4, to: 2, in: [1, 2, 3, 4]) == [1, 4, 2, 3])
        check("drag onto itself", BriefOrder.move(2, to: 2, in: [1, 2, 3]) == [1, 2, 3])
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

    static func weekTests() {
        // 2026-10-19 is a Monday.
        let turns = [
            turn("coucou", at(19, 9), minutes: 60),
            turn("coucou", at(19, 9, 30), minutes: 60),          // overlaps: 90 min that day
            turn("rea", at(21, 14), minutes: 30, pill: "integration_codex"),
            turn("coucou", at(25, 23), minutes: 120),             // Sunday, last day of the week
            turn("old", at(13, 10), minutes: 45),                 // the week before
            turn("next", at(26, 10), minutes: 30),                // the week after
        ]
        let w = WeekWork.from(turns: turns, decisions: [], weekStart: at(19, 12), calendar: cal)
        check("week starts at Monday's midnight", w.start == at(19, 0))
        check("seven days", w.days.count == 7)
        check("Monday 90 min", w.days[0].minutes == 90)
        check("Wednesday 30 min", w.days[2].minutes == 30)
        check("Sunday counted", w.days[6].minutes == 120)
        check("week total 240 min", w.total.minutes == 240)
        check("4 sessions in the week", w.total.sessions == 4)
        check("active days", w.activeDays == 3)
        check("busiest day Sunday", w.busiestDay == 6)
        check("projects by time", w.projects.map(\.name) == ["coucou", "rea"] && w.projects[0].minutes == 210)
        check("agents by sessions", w.agents.first?.pill == "integration_claude" && w.agents.first?.sessions == 3)
        check("longest session", w.longestSessionMinutes == 120)
        check("week before", w.previousMinutes == 45)
        check("change", w.change.map { abs($0 - (240.0 - 45) / 45) < 1e-9 } == true)
        check("monday of a Thursday", WeekWork.monday(of: at(22, 15), calendar: cal) == at(19, 0))
        check("last week from Monday", WeeklyBriefPeriod.lastWeek.weekStart(now: at(26, 9), calendar: cal) == at(19, 0))
        check("this week", WeeklyBriefPeriod.thisWeek.weekStart(now: at(23, 9), calendar: cal) == at(19, 0))
        check("week headline", DailyBriefText.weekHeadline(w, isThisWeek: false) == "Last week: 4h 0m with your agents over 3 days, mostly on coucou.")
        check("change text", DailyBriefText.change(0.12) == "+12% vs the week before" && DailyBriefText.change(-0.3) == "−30% vs the week before")
        let empty = WeekWork.from(turns: [], decisions: [], weekStart: at(19, 0), calendar: cal)
        check("empty week", empty.busiestDay == nil && empty.change == nil && empty.total.isEmpty)
    }

    static func planTests() {
        // A real get_usage answer (Claude Code, a Team plan), cut to what matters.
        let json = #"{"subscription_type":"team","rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":10,"resets_at":"2026-10-23T23:40:00.441356+00:00"},"seven_day":{"utilization":55,"resets_at":"2026-10-26T15:00:00.441381+00:00"},"seven_day_opus":null,"limits":[{"kind":"session","group":"session","percent":10,"resets_at":"2026-10-23T23:40:00.441356+00:00","scope":null},{"kind":"weekly_all","group":"weekly","percent":55,"resets_at":"2026-10-26T15:00:00.441381+00:00","scope":null},{"kind":"weekly_scoped","group":"weekly","percent":50,"resets_at":"2026-10-26T15:00:00.441609+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}],"model_scoped":[{"display_name":"Fable","utilization":50,"resets_at":"2026-10-26T15:00:00.441609+00:00"}]}}"#
        let obj = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let l = ClaudePlanLimits.parse(obj)
        check("plan parses", l != nil && l?.plan == "team")
        check("three limits in order", l?.limits.map(\.label) == ["Current session", "All models", "Fable"])
        check("session 10 %", l?.session?.percent == 10)
        check("weekly ones", l?.weekly.map(\.percent) == [55, 50])
        check("reset date parsed", l?.session?.resetsAt == ClaudePlanLimits.date("2026-10-23T23:40:00Z")?.addingTimeInterval(0.441356).rounded())
        // Without `limits`: the named windows and model_scoped.
        var old = obj
        var rate = obj["rate_limits"] as! [String: Any]
        rate.removeValue(forKey: "limits")
        old["rate_limits"] = rate
        check("older shape", ClaudePlanLimits.parse(old)?.limits.map(\.label) == ["Current session", "All models", "Fable"])
        check("API key: no limits", ClaudePlanLimits.parse(["rate_limits": NSNull()]) == nil)
        let now = ClaudePlanLimits.date("2026-10-23T20:50:00Z")!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        check("reset in hours", ClaudePlanLimits.resetText(ClaudePlanLimits.date("2026-10-23T23:40:00Z"), now: now, calendar: utc) == "Resets in 2 hr 50 min")
        check("reset in minutes", ClaudePlanLimits.resetText(now.addingTimeInterval(600), now: now, calendar: utc) == "Resets in 10 min")
        check("reset on a day", ClaudePlanLimits.resetText(ClaudePlanLimits.date("2026-10-26T15:00:00Z"), now: now, calendar: utc) == "Resets Mon 15:00")
    }
}

extension Date {
    /// To the microsecond, as ISO 8601 with fractions keeps it.
    func rounded() -> Date { Date(timeIntervalSince1970: (timeIntervalSince1970 * 1000).rounded() / 1000) }
}
