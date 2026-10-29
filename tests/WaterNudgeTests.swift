import Foundation

@main
enum WaterNudgeTests {
    static var failures = 0
    static func check(_ label: String, _ ok: Bool) { if !ok { failures += 1; print("FAIL \(label)") } }

    static func main() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
            cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
        }
        var plan = BuddyWaterPlan()
        plan.from = 11 * 60; plan.to = 19 * 60; plan.every = 60; plan.days = [2, 3, 4, 5, 6]; plan.stopAtGoal = false
        let noon = at(2026, 10, 29, 12, 0)   // Thursday, inside the hours

        // Launch keeps a stored nudge that is still ahead.
        let stored = at(2026, 10, 29, 12, 20)
        check("stored ahead is kept", BuddyWater.nextOnLaunch(stored: stored, now: noon, plan: plan, calendar: cal) == stored)
        // A stored nudge that came due while closed is due now, not an interval away.
        check("stored past is due now", BuddyWater.nextOnLaunch(stored: at(2026, 10, 29, 11, 30), now: noon, plan: plan, calendar: cal) == noon)
        // Nothing stored: a fresh interval.
        check("nothing stored → fresh", BuddyWater.nextOnLaunch(stored: nil, now: noon, plan: plan, calendar: cal) == at(2026, 10, 29, 13, 0))
        // A stored nudge further away than a fresh one (the interval was shortened): fresh wins.
        check("stored too far → fresh", BuddyWater.nextOnLaunch(stored: at(2026, 10, 29, 15, 0), now: noon, plan: plan, calendar: cal) == at(2026, 10, 29, 13, 0))
        // The bug: three restarts in a row must not move the nudge.
        var next = BuddyWater.nextOnLaunch(stored: nil, now: noon, plan: plan, calendar: cal)
        for m in [5, 10, 15] { next = BuddyWater.nextOnLaunch(stored: next, now: noon.addingTimeInterval(Double(m) * 60), plan: plan, calendar: cal) }
        check("restarts keep the cadence", next == at(2026, 10, 29, 13, 0))

        // Countdown words.
        let t = { (n: Date?, now: Date, today: Int) in BuddyWater.nextNudgeText(next: n, now: now, enabled: true, plan: plan, today: today, calendar: cal) }
        check("minutes", t(at(2026, 10, 29, 12, 42), noon, 500) == "Next nudge in 42 min (12:42 PM)." || t(at(2026, 10, 29, 12, 42), noon, 500).hasPrefix("Next nudge in 42 min"))
        check("hours", t(at(2026, 10, 29, 13, 5), noon, 500).hasPrefix("Next nudge in 1 h 05 min"))
        check("under a minute", t(noon.addingTimeInterval(30), noon, 500).hasPrefix("Next nudge in under a minute"))
        check("due now while away", t(noon.addingTimeInterval(-10), noon, 500).hasPrefix("Due now"))
        check("quiet outside hours", t(at(2026, 10, 30, 11, 0), at(2026, 10, 29, 22, 0), 500).hasPrefix("Quiet until") && t(at(2026, 10, 30, 11, 0), at(2026, 10, 29, 22, 0), 500).contains("tomorrow"))
        var stop = plan; stop.stopAtGoal = true
        check("goal reached", BuddyWater.nextNudgeText(next: at(2026, 10, 29, 13, 0), now: noon, enabled: true, plan: stop, today: 3000, calendar: cal) == "Done for today: goal reached.")
        check("off", BuddyWater.nextNudgeText(next: nil, now: noon, enabled: false, plan: plan, today: 0, calendar: cal) == "Reminders are off.")

        if failures == 0 { print("WaterNudgeTests: all passed") } else { exit(1) }
    }
}
