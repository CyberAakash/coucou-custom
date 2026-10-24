import Foundation

/// The Buddy's routines (BuddyRoutines) and the chat's tools (BuddyToolCatalog), on a fixed calendar.
@MainActor
enum BuddyRoutinesTests {
    static var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func at(_ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: min))!
    }

    static func run() {
        testReminderTimes()
        testFocus()
        testCountdown()
        testWater()
        testAlertStyle()
        testBreathing()
        testText()
        testTools()
        testSlash()
        testSettings()
        print("BuddyRoutinesTests passed")
    }

    static func testReminderTimes() {
        let now = at(10, 23, 14, 0)
        precondition(BuddyReminders.due(inMinutes: 10, at: nil, now: now, calendar: cal) == now.addingTimeInterval(600), "in 10 min")
        precondition(BuddyReminders.due(inMinutes: 0, at: nil, now: now, calendar: cal) == nil, "0 min")
        precondition(BuddyReminders.due(inMinutes: -5, at: nil, now: now, calendar: cal) == nil, "negative")
        precondition(BuddyReminders.due(inMinutes: nil, at: "15:30", now: now, calendar: cal) == at(10, 23, 15, 30), "15:30 today")
        precondition(BuddyReminders.due(inMinutes: nil, at: "9:05", now: now, calendar: cal) == at(10, 24, 9, 5), "past time is tomorrow")
        precondition(BuddyReminders.due(inMinutes: nil, at: "3pm", now: now, calendar: cal) == at(10, 23, 15), "3pm")
        precondition(BuddyReminders.due(inMinutes: nil, at: "3:30 PM", now: now, calendar: cal) == at(10, 23, 15, 30), "3:30 PM")
        precondition(BuddyReminders.due(inMinutes: nil, at: "12am", now: now, calendar: cal) == at(10, 24, 0), "12am is midnight")
        precondition(BuddyReminders.due(inMinutes: nil, at: "12pm", now: now, calendar: cal) == at(10, 24, 12), "12pm is noon (tomorrow, past)")
        precondition(BuddyReminders.due(inMinutes: nil, at: "noon", now: at(10, 23, 9), calendar: cal) == at(10, 23, 12), "noon")
        precondition(BuddyReminders.due(inMinutes: nil, at: "2026-10-24T09:00", now: now, calendar: cal) == at(10, 24, 9), "local date-time")
        precondition(BuddyReminders.due(inMinutes: nil, at: "2026-10-24T09:00:00Z", now: now, calendar: cal) == at(10, 24, 9), "ISO with zone")
        precondition(BuddyReminders.due(inMinutes: nil, at: "2026-10-22T09:00", now: now, calendar: cal) == nil, "past date-time")
        for bad in ["", "soon", "25:00", "13pm", "7", "10:61", "0am"] {
            precondition(BuddyReminders.due(inMinutes: nil, at: bad, now: now, calendar: cal) == nil, "bad time \(bad)")
        }
        // in_minutes wins over at
        precondition(BuddyReminders.due(inMinutes: 5, at: "15:30", now: now, calendar: cal) == now.addingTimeInterval(300), "in_minutes first")

        let a = BuddyReminder(text: "b", due: now.addingTimeInterval(60)), b = BuddyReminder(text: "a", due: now)
        precondition(BuddyReminders.sorted([a, b]).map(\.text) == ["a", "b"], "soonest first")
        precondition(BuddyReminders.decode(BuddyReminders.encode([a, b])!) == [a, b], "round trip")
        precondition(a.id.count == 6 && a.id != b.id, "short ids")
    }

    static func testFocus() {
        let t0 = at(10, 23, 9)
        var f = BuddyFocusSession.start(.standard, at: t0)
        precondition(f.phase == .focus && f.round == 1 && f.remaining(at: t0) == 25 * 60, "starts 25 min")
        precondition(!f.isOver(at: t0.addingTimeInterval(24 * 60)) && f.isOver(at: t0.addingTimeInterval(25 * 60)), "over at 25")

        // Pause keeps the time left; resume picks it up.
        f.pause(at: t0.addingTimeInterval(600))
        precondition(f.isPaused && f.remaining(at: t0.addingTimeInterval(9999)) == 15 * 60, "paused keeps 15 min")
        precondition(!f.isOver(at: t0.addingTimeInterval(99999)), "paused is never over")
        f.resume(at: t0.addingTimeInterval(1200))
        precondition(f.remaining(at: t0.addingTimeInterval(1200)) == 15 * 60, "resumed 15 min")

        // focus → short break ×3, the 4th → long break; a break → next round.
        var g = BuddyFocusSession.start(.standard, at: t0)
        var phases: [BuddyFocusPhase] = []
        for _ in 0..<8 { g.advance(at: t0); phases.append(g.phase) }
        precondition(phases == [.shortBreak, .focus, .shortBreak, .focus, .shortBreak, .focus, .longBreak, .focus], "cycle \(phases)")
        precondition(g.round == 5 && g.completed == 4, "rounds \(g.round) done \(g.completed)")
        g = BuddyFocusSession.start(.standard, at: t0)
        g.advance(at: t0)
        precondition(g.remaining(at: t0) == 5 * 60, "short break 5")
        // A plan of 0 rounds never divides by zero.
        var z = BuddyFocusSession.start(BuddyFocusPlan(focus: 1, shortBreak: 1, longBreak: 2, roundsBeforeLong: 0), at: t0)
        z.advance(at: t0)
        precondition(z.phase == .longBreak, "0 rounds: always long")
        // Skip while paused unpauses into the next phase.
        var p = BuddyFocusSession.start(.standard, at: t0)
        p.pause(at: t0)
        p.advance(at: t0)
        precondition(!p.isPaused && p.phase == .shortBreak, "skip from paused")
    }

    static func testCountdown() {
        let t0 = at(10, 23, 9)
        precondition(BuddyCountdown.start(seconds: 0, label: "", at: t0) == nil, "0 s")
        precondition(BuddyCountdown.start(seconds: 25 * 3600, label: "", at: t0) == nil, "over 24 h")
        var c = BuddyCountdown.start(seconds: 600, label: "Tea", at: t0)!
        precondition(c.remaining(at: t0.addingTimeInterval(100)) == 500, "running")
        c.pause(at: t0.addingTimeInterval(100))
        c.add(300, at: t0.addingTimeInterval(200))
        precondition(c.isPaused && c.remaining(at: t0.addingTimeInterval(500)) == 800 && c.total == 900, "add while paused")
        c.resume(at: t0.addingTimeInterval(1000))
        precondition(c.isOver(at: t0.addingTimeInterval(1800)) && !c.isOver(at: t0.addingTimeInterval(1799)), "over after resume")
        c.add(300, at: t0.addingTimeInterval(1000))
        precondition(c.remaining(at: t0.addingTimeInterval(1000)) == 1100, "add while running")
    }

    static func testAlertStyle() {
        precondition(RoutineAlertStyle.buddy.resolved(buddyShown: true) == .buddy, "the card, with the Buddy")
        precondition(RoutineAlertStyle.buddy.resolved(buddyShown: false) == .notch, "no Buddy: the notch")
        precondition(RoutineAlertStyle.fullScreen.resolved(buddyShown: false) == .fullScreen, "full screen needs no Buddy")
        precondition(RoutineAlertStyle.notch.resolved(buddyShown: true) == .notch, "the notch stays the notch")
    }

    static func testWater() {
        let due = at(10, 23, 10)
        precondition(BuddyWater.shouldNudge(due: due, now: due, userIdle: 5), "due and here")
        precondition(!BuddyWater.shouldNudge(due: due, now: due.addingTimeInterval(-1), userIdle: 5), "not yet")
        precondition(!BuddyWater.shouldNudge(due: due, now: due, userIdle: 300), "away waits")

        // Hours and days (Oct 23 2026 is a Friday, weekday 6)
        var p = BuddyWaterPlan.standard   // 09:00–21:00, every day, 60 min
        precondition(BuddyWater.isActive(p, at: at(10, 23, 9), calendar: cal) && !BuddyWater.isActive(p, at: at(10, 23, 21), calendar: cal), "09:00 in, 21:00 out")
        precondition(!BuddyWater.isActive(p, at: at(10, 23, 8, 59), calendar: cal), "before")
        p.days = [2, 3, 4, 5, 6]   // weekdays
        precondition(BuddyWater.isActive(p, at: at(10, 23, 12), calendar: cal) && !BuddyWater.isActive(p, at: at(10, 24, 12), calendar: cal), "Friday yes, Saturday no")
        var night = BuddyWaterPlan.standard
        night.from = 22 * 60; night.to = 2 * 60; night.days = [6]
        precondition(BuddyWater.isActive(night, at: at(10, 23, 23), calendar: cal), "Fri 23:00")
        precondition(BuddyWater.isActive(night, at: at(10, 24, 1), calendar: cal), "Sat 01:00 is still Friday's night")
        precondition(!BuddyWater.isActive(night, at: at(10, 24, 23), calendar: cal), "Sat 23:00 is Saturday's")
        var all = BuddyWaterPlan.standard; all.from = 0; all.to = 0
        precondition(BuddyWater.isActive(all, at: at(10, 23, 3), calendar: cal), "from == to: all day")

        // Next nudges
        let std = BuddyWaterPlan.standard
        precondition(BuddyWater.next(after: at(10, 23, 10), plan: std, calendar: cal) == at(10, 23, 11), "an hour on")
        precondition(BuddyWater.next(after: at(10, 23, 20, 30), plan: std, calendar: cal) == at(10, 24, 9), "past 21:00: tomorrow 09:00")
        precondition(BuddyWater.next(after: at(10, 23, 6), plan: std, calendar: cal) == at(10, 23, 9), "early: 09:00")
        precondition(BuddyWater.next(after: at(10, 23, 20, 30), plan: p, calendar: cal) == at(10, 26, 9), "weekdays: Friday evening → Monday 09:00")
        var none = std; none.days = []
        precondition(BuddyWater.next(after: at(10, 23, 10), plan: none, calendar: cal) == nil, "no day, no nudge")

        // Amounts and the log
        precondition(BuddyWater.amount(750) == "750 ml" && BuddyWater.amount(2000) == "2 L" && BuddyWater.amount(1250) == "1.25 L" && BuddyWater.amount(1500) == "1.5 L", "amounts")
        precondition(BuddyWater.dayKey(at(1, 5, 23, 59), calendar: cal) == "2026-01-05", "day key")
        var log = BuddyWaterLog()
        log.add(250, on: at(10, 23, 9), calendar: cal)
        log.add(500, on: at(10, 23, 18), calendar: cal)
        log.add(330, on: at(10, 22, 12), calendar: cal)
        log.add(-1000, on: at(10, 22, 13), calendar: cal)
        precondition(log.total(on: at(10, 23, 23), calendar: cal) == 750 && log.total(on: at(10, 22, 1), calendar: cal) == 0, "per day, never below 0")
        let week = log.history(7, upTo: at(10, 23, 15), calendar: cal)
        precondition(week.count == 7 && week.last?.ml == 750 && week.first?.day == at(10, 17, 0), "seven days, oldest first")
        for d in 1...70 { log.add(100, on: cal.date(byAdding: .day, value: -d, to: at(10, 23, 12))!, calendar: cal) }
        precondition(log.days.count == BuddyWaterLog.keepDays && log.total(on: at(10, 23, 1), calendar: cal) == 750, "keeps the last 60 days, today included")
        precondition(try! JSONDecoder().decode(BuddyWaterLog.self, from: JSONEncoder().encode(log)) == log, "log round trip")
        precondition(try! JSONDecoder().decode(BuddyWaterPlan.self, from: JSONEncoder().encode(p)) == p, "plan round trip")
    }

    static func testBreathing() {
        let box = BuddyBreathing.box
        precondition(box.breathSeconds == 16 && box.cycles == 8 && box.totalSeconds == 128 && box.pace == "3.8", "box timing \(box.pace)")
        precondition(BuddyBreathing.calm.pace == "6" && BuddyBreathing.calm.steps.map(\.0) == [.inhale, .exhale], "calm 4-6, 6 a minute")
        precondition(BuddyBreathing.allCases.map(\.cycles) == [10, 8, 4, 8, 6], "OpenPets' cycle counts")
        let p0 = box.position(elapsed: 0)!
        precondition(p0.step == .inhale && p0.left == 4 && p0.cycle == 1 && p0.index == 0, "starts breathing in")
        let p1 = box.position(elapsed: 5.5)!
        precondition(p1.step == .holdFull && p1.left == 3 && abs(p1.progress - 0.375) < 0.001 && p1.index == 1, "hold at 5.5 s")
        precondition(box.position(elapsed: 13)!.step == .holdEmpty, "box ends lungs empty")
        precondition(box.position(elapsed: 16)!.cycle == 2, "second breath")
        precondition(box.position(elapsed: 128) == nil && box.position(elapsed: -1) == nil, "done")
        precondition(BuddyBreathing.calming.position(elapsed: 11.5)!.step == .exhale, "exhale after 11 s")
        precondition(BuddyBreathing.fullness(step: .inhale, progress: 0) == 0 && abs(BuddyBreathing.fullness(step: .inhale, progress: 1) - 1) < 1e-9, "fills up")
        precondition(BuddyBreathing.fullness(step: .holdFull, progress: 0.5) == 1 && BuddyBreathing.fullness(step: .holdEmpty, progress: 0.5) == 0, "full, empty")
        precondition(abs(BuddyBreathing.scale(step: .exhale, progress: 1) - 1) < 1e-9 && abs(BuddyBreathing.scale(step: .holdFull, progress: 0) - 1.12) < 1e-9, "Mochi's size")

        // A session: settling in, breathing, pauses, done, restart
        let t0 = at(10, 23, 9)
        var s = BuddyBreathSession(pattern: .calm, at: t0)
        precondition(s.phase(at: t0) == .settling(left: 3) && s.phase(at: t0.addingTimeInterval(2.5)) == .settling(left: 1), "3 s to settle")
        guard case .breathing(let b) = s.phase(at: t0.addingTimeInterval(3)) else { preconditionFailure("breathing at 3 s") }
        precondition(b.step == .inhale && b.cycle == 1, "first breath in")
        s.pause(at: t0.addingTimeInterval(10))
        precondition(s.isPaused && s.elapsed(at: t0.addingTimeInterval(500)) == 7, "paused keeps the time")
        s.resume(at: t0.addingTimeInterval(60))
        precondition(s.elapsed(at: t0.addingTimeInterval(61)) == 8 && s.remaining(at: t0.addingTimeInterval(61)) == 92, "resumed")
        precondition(s.phase(at: t0.addingTimeInterval(60 + 7 + 100)) == .done, "done after 100 s of breathing")
        var done = s
        done.pause(at: t0.addingTimeInterval(1000))
        precondition(!done.isPaused, "no pause once done")
        s.restart(.box, at: t0.addingTimeInterval(2000))
        precondition(s.pattern == .box && s.pausedTotal == 0 && s.phase(at: t0.addingTimeInterval(2000)) == .settling(left: 3), "restart on another rhythm")
        precondition(BuddyBreathSession(pattern: .box, at: t0).remaining(at: t0) == 128, "remaining counts breathing only")
    }

    static func testSlash() {
        func tool(_ t: String) -> (String, [String: String])? {
            if case .success(.tool(let n, let i))? = BuddySlash.parse(t) { return (n, i) }
            return nil
        }
        func bad(_ t: String) -> Bool { if case .failure? = BuddySlash.parse(t) { return true }; return false }

        precondition(BuddySlash.parse("hello") == nil && BuddySlash.parse("/") == nil && BuddySlash.parse("/nope") == nil, "not commands")
        precondition(tool("/focus")! == ("focus_session", ["action": "start"]), "/focus")
        precondition(tool("/focus 50")!.1 == ["action": "start", "minutes": "50"] && tool("/focus 1h")!.1["minutes"] == "60", "/focus 50, 1h")
        precondition(tool("/focus pause")!.1 == ["action": "pause"] && tool("/FOCUS stop")!.1 == ["action": "end"], "/focus controls")
        precondition(bad("/focus soon") && bad("/focus 30s"), "/focus bad")
        precondition(tool("/timer 10")!.1 == ["action": "start", "seconds": "600"], "/timer 10")
        precondition(tool("/timer 10 tea time")!.1 == ["action": "start", "seconds": "600", "label": "tea time"], "/timer label")
        precondition(tool("/timer 10 minutes tea")!.1 == ["action": "start", "seconds": "600", "label": "tea"], "/timer 10 minutes")
        precondition(tool("/timer 1h30m")!.1["seconds"] == "5400" && tool("/timer 90s")!.1["seconds"] == "90", "/timer units")
        precondition(tool("/timer +5")!.1 == ["action": "add", "seconds": "300"] && tool("/timer cancel")!.1 == ["action": "cancel"], "/timer +5, cancel")
        precondition(bad("/timer") && bad("/timer tea"), "/timer bad")
        precondition(tool("/remind in 10m stretch")!.1 == ["in_minutes": "10.0", "text": "stretch"], "/remind in 10m")
        precondition(tool("/remind 10 minutes to stretch")!.1 == ["in_minutes": "10.0", "text": "stretch"], "/remind 10 minutes to")
        precondition(tool("/remind at 3:30 pm call Sam")!.1 == ["at": "3:30pm", "text": "call Sam"], "/remind at 3:30 pm")
        precondition(tool("/remind 15:30 call Sam")!.1 == ["at": "15:30", "text": "call Sam"], "/remind 15:30")
        precondition(tool("/remind 1h30m stand up")!.1["in_minutes"] == "90.0", "/remind 1h30m")
        precondition(bad("/remind") && bad("/remind stretch") && bad("/remind in 10m") && bad("/remind in 15:30 x"), "/remind bad")
        precondition(tool("/water")! == ("log_water", [:]) && tool("/water 330")!.1 == ["ml": "330"] && tool("/water 330ml")!.1 == ["ml": "330"], "/water ml")
        precondition(tool("/water 0.5l")!.1 == ["ml": "500"] && tool("/water 2 glasses")!.1 == ["glasses": "2.0"], "/water litres, glasses")
        precondition(tool("/water status")!.0 == "water_status" && tool("/water off")!.1 == ["enabled": "false"] && bad("/water lots"), "/water status, off, bad")
        precondition(tool("/breathe")!.1 == ["pattern": "calm"] && tool("/breathe 478")!.1 == ["pattern": "calming"] && tool("/breathe quick")!.1 == ["pattern": "quick_reset"], "/breathe")
        precondition(bad("/breathe fast"), "/breathe bad")
        precondition(tool("/status")!.0 == "system_status" && tool("/summary")!.0 == "activity_summary" && tool("/dance")!.1 == ["action": "dance"], "plain ones")
        precondition(BuddySlash.parse("/clear") == .success(.clear) && BuddySlash.parse("/help") == .success(.help), "/clear, /help")
        // Every command the parser builds names a real tool.
        for t in ["/focus", "/timer 5", "/remind in 5m x", "/reminders", "/water", "/water status", "/water on", "/breathe", "/status", "/summary", "/dance"] {
            precondition(BuddyToolCatalog.names.contains(tool(t)!.0), "\(t) → a real tool")
        }
        // The list while typing
        precondition(BuddySlash.suggestions(for: "/").count == BuddySlash.commands.count && BuddySlash.suggestions(for: "hi").isEmpty, "all, none")
        precondition(BuddySlash.suggestions(for: "/re").map(\.name) == ["remind", "reminders"] && BuddySlash.suggestions(for: "/timer 5").map(\.name) == ["timer"], "prefix, then the named one")
        precondition(BuddySlash.duration("25") == 1500 && BuddySlash.duration("1.5h") == 5400 && BuddySlash.duration("10min") == 600 && BuddySlash.duration("2hours") == 7200, "durations")
        precondition(BuddySlash.duration("") == nil && BuddySlash.duration("0") == nil && BuddySlash.duration("10x") == nil && BuddySlash.duration("m") == nil, "bad durations")
        precondition(BuddySlash.helpText.contains("`/remind <in 10m | at 15:30> <what>`"), "help lists them")
    }

    static func testText() {
        precondition(BuddyTimeText.left(25 * 60) == "25 min left" && BuddyTimeText.left(24 * 60 + 1) == "25 min left", "rounds up")
        precondition(BuddyTimeText.left(45) == "45 s left" && BuddyTimeText.left(3900) == "1 h 5 min left" && BuddyTimeText.left(7200) == "2 h left", "left")
        precondition(BuddyTimeText.clock(245) == "4:05" && BuddyTimeText.clock(3723) == "1:02:03" && BuddyTimeText.clock(0) == "0:00", "clock")
        precondition(BuddyTimeText.duration(600) == "10 minutes" && BuddyTimeText.duration(60) == "1 minute", "minutes")
        precondition(BuddyTimeText.duration(5400) == "1 hour 30 minutes" && BuddyTimeText.duration(7200) == "2 hours" && BuddyTimeText.duration(1) == "1 second", "duration")
        precondition(BuddyGreeting.line(hour: 8, name: "Sam") == "Good morning, Sam!", "morning")
        precondition(BuddyGreeting.line(hour: 13, name: nil) == "Good afternoon!", "afternoon, no name")
        precondition(BuddyGreeting.line(hour: 20, name: "") == "Good evening!" && BuddyGreeting.line(hour: 2, name: "Sam") == "Hi Sam! Up late?" && BuddyGreeting.line(hour: 23, name: nil) == "Hi! Up late?", "evening, night")
    }

    static func testTools() {
        let tools = BuddyToolCatalog.tools
        let names = BuddyToolCatalog.names
        precondition(Set(names).count == names.count && names.count == 12, "12 unique tools")
        for t in tools {
            let name = t["name"] as! String
            precondition(name.range(of: "^[a-z_]{1,64}$", options: .regularExpression) != nil, "name \(name)")
            precondition(!(t["description"] as! String).isEmpty, "\(name) described")
            let schema = t["input_schema"] as! [String: Any]
            precondition(schema["type"] as? String == "object" && schema["properties"] is [String: Any], "\(name) schema")
            let props = schema["properties"] as! [String: Any]
            for r in schema["required"] as? [String] ?? [] { precondition(props[r] != nil, "\(name) requires a declared \(r)") }
            // Every tool's schema survives JSON, as it is sent.
            precondition(JSONSerialization.isValidJSONObject(t), "\(name) is JSON")
        }
        let openAI = BuddyToolCatalog.openAI
        precondition(openAI.count == tools.count, "openAI count")
        let fn = openAI[0]["function"] as! [String: Any]
        precondition(openAI[0]["type"] as? String == "function" && fn["name"] as? String == "create_reminder" && fn["parameters"] != nil, "openAI shape")
        precondition(JSONSerialization.isValidJSONObject(openAI), "openAI JSON")

        // Titles, as the chat shows them.
        precondition(BuddyToolCatalog.title("create_reminder", ["text": "Stretch", "in_minutes": 10]) == "Create a reminder in 10 minutes · Stretch", "reminder title")
        precondition(BuddyToolCatalog.title("create_reminder", ["text": "Call", "at": "15:30"]) == "Create a reminder at 15:30 · Call", "reminder at")
        precondition(BuddyToolCatalog.title("focus_session", ["action": "start", "minutes": "25"]) == "Start a focus session for 25 minutes", "focus title, string number")
        precondition(BuddyToolCatalog.title("focus_session", ["action": "pause"]) == "Pause the focus session", "pause")
        precondition(BuddyToolCatalog.title("timer", ["action": "start", "minutes": 1, "seconds": 30]) == "Start a timer for 1 minute", "90 s shows whole minutes")
        precondition(BuddyToolCatalog.title("timer", ["action": "start", "seconds": 45]) == "Start a timer for 45 seconds", "seconds")
        precondition(BuddyToolCatalog.title("system_status", [:]) == "Check system status" && BuddyToolCatalog.title("nope", [:]) == "nope", "plain")
        precondition(BuddyToolCatalog.number("2.5") == 2.5 && BuddyToolCatalog.number(3) == 3 && BuddyToolCatalog.number(NSNumber(value: 4.5)) == 4.5
            && BuddyToolCatalog.number("x") == nil && BuddyToolCatalog.number(nil) == nil, "numbers")

        let line = BuddyToolCatalog.systemLine(now: at(10, 23, 14, 5), timeZone: TimeZone(identifier: "UTC")!)
        precondition(line.contains("Friday 2026-10-23 14:05 (GMT)"), "system line has the local time: \(line)")
    }

    static func testSettings() {
        let suite = "buddy-routines-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let s = BuddyRoutineSettings(defaults: d)
        precondition(s.assistantTools && !s.waterEnabled && s.waterPlan == .standard && s.launchGreeting && !s.launchGreetingSound && s.alertSound, "defaults")
        precondition(s.breathingCues && s.lastBreathing == .calm && s.waterLog == BuddyWaterLog(), "breathing and water defaults")
        precondition(s.focusPlan == .standard && s.reminders.isEmpty, "plan, no reminders")
        s.focusPlan.focus = 50
        s.waterPlan.every = 5
        s.waterPlan.goal = 99_000
        s.lastBreathing = .box
        var log = BuddyWaterLog(); log.add(500, on: .now)
        s.waterLog = log
        s.waterEnabled = true
        let r = BuddyReminder(text: "x", due: at(10, 23, 9))
        s.reminders = [r]
        let again = BuddyRoutineSettings(defaults: d)
        precondition(again.focusPlan.focus == 50 && again.waterPlan.every == 10 && again.waterPlan.goal == 6000 && again.waterEnabled && again.reminders == [r], "persisted, clamped")
        precondition(again.lastBreathing == .box && again.waterLog == log, "breathing and water persisted")
        // The interval from before the plan carries over.
        let suite2 = "buddy-routines-old-\(UUID().uuidString)"
        let old = UserDefaults(suiteName: suite2)!
        defer { old.removePersistentDomain(forName: suite2) }
        old.set(45, forKey: BuddyRoutineSettings.waterIntervalKey)
        precondition(BuddyRoutineSettings(defaults: old).waterPlan.every == 45, "old interval migrates")
    }
}
