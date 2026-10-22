import Foundation

/// The wardrobe (OpenPets' docs/wardrobe.md semantics), on a fixed calendar.
@MainActor
enum BuddyWardrobeTests {
    static var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// 2026: Oct 23 is a Friday.
    static func at(_ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0, year: Int = 2026) -> Date {
        cal.date(from: DateComponents(year: year, month: m, day: d, hour: h, minute: min))!
    }

    static func run() {
        // Parsing
        precondition(BuddyClock("22:00")?.minutes == 1320 && BuddyClock("07:05")?.text == "07:05", "HH:MM")
        for bad in ["24:00", "7:00", "07:60", "0700", "aa:bb"] { precondition(BuddyClock(bad) == nil, "bad time \(bad)") }
        precondition(BuddyDay("02-29") != nil && BuddyDay("12-31")?.text == "12-31", "MM-DD, 02-29 valid")
        for bad in ["02-30", "13-01", "00-10", "1-1", "04-31"] { precondition(BuddyDay(bad) == nil, "bad day \(bad)") }

        // Time: to exclusive, wraps midnight, from == to never
        let night = BuddyTimeRange(from: BuddyClock("22:00")!, to: BuddyClock("07:00")!)
        precondition(BuddyWardrobe.matches(night, minutes: 22 * 60) && BuddyWardrobe.matches(night, minutes: 3 * 60), "night wraps")
        precondition(!BuddyWardrobe.matches(night, minutes: 7 * 60) && !BuddyWardrobe.matches(night, minutes: 21 * 60 + 59), "to exclusive")
        let work = BuddyTimeRange(from: BuddyClock("09:00")!, to: BuddyClock("17:00")!)
        precondition(BuddyWardrobe.matches(work, minutes: 9 * 60) && !BuddyWardrobe.matches(work, minutes: 17 * 60), "plain range")
        precondition(!BuddyWardrobe.matches(BuddyTimeRange(from: BuddyClock("10:00")!, to: BuddyClock("10:00")!), minutes: 600), "from == to never")

        // Dates: inclusive, every year, wraps the new year
        let newYear = BuddyDateRange(from: BuddyDay("12-20")!, to: BuddyDay("01-02")!)
        precondition(BuddyWardrobe.matches(newYear, month: 12, day: 20) && BuddyWardrobe.matches(newYear, month: 1, day: 2), "inclusive ends")
        precondition(BuddyWardrobe.matches(newYear, month: 12, day: 31) && !BuddyWardrobe.matches(newYear, month: 1, day: 3), "wraps")
        precondition(!BuddyWardrobe.matches(newYear, month: 12, day: 19), "before")

        // Conditions are independent: Friday + 22:00–07:00 matches Fri 23:00, not Sat 02:00
        let friNight = BuddyWhen(time: night, days: [.fri])
        precondition(BuddyWardrobe.matches(friNight, at: at(10, 23, 23), calendar: cal), "Fri 23:00")
        precondition(!BuddyWardrobe.matches(friNight, at: at(10, 24, 2), calendar: cal), "not Sat 02:00")
        precondition(!BuddyWardrobe.matches(BuddyWhen(), at: at(1, 1), calendar: cal), "no condition never matches")
        precondition(BuddyWardrobe.matches(BuddyWhen(days: [.sat, .sun]), at: at(10, 25), calendar: cal), "Sunday is weekend")
        precondition(!BuddyWardrobe.matches(BuddyWhen(days: [.sat, .sun]), at: at(10, 26), calendar: cal), "Monday is not")

        // The Buddy's schedule: holidays first, then night, then weekends, then summer
        let s = BuddyWardrobe.defaultSchedule
        func wears(_ d: Date) -> BuddyOutfit { BuddyWardrobe.resolve(always: nil, schedule: s, at: d, calendar: cal) }
        precondition(wears(at(10, 23, 15)) == .pumpkin, "pumpkins in October")
        precondition(wears(at(10, 23, 23)) == .pumpkin, "October wins over the night (first rule wins)")
        precondition(wears(at(11, 4, 23)) == .nightcap && wears(at(11, 5, 6, 59)) == .nightcap, "pajamas at night")
        precondition(wears(at(11, 5, 7)) == .none, "Thursday morning: no outfit")
        precondition(wears(at(11, 7, 15)) == .sunglasses, "a weekend look (Saturday)")
        precondition(wears(at(11, 7, 23)) == .nightcap, "Saturday night: pajamas first")
        precondition(wears(at(12, 25)) == .santaHat && wears(at(12, 31)) == .partyHat && wears(at(1, 2, year: 2027)) == .partyHat, "holidays")
        precondition(wears(at(7, 15, 14)) == .sunglasses, "summer")
        precondition(BuddyWardrobe.activeRule(s, at: at(11, 5, 7), calendar: cal) == nil, "no rule active")
        precondition(BuddyWardrobe.activeRule(s, at: at(11, 4, 23), calendar: cal) == 3, "pajamas rule is the 4th")

        // Always wear wins; disabled rules never match; an empty schedule never changes
        precondition(BuddyWardrobe.resolve(always: .crown, schedule: s, at: at(10, 23), calendar: cal) == .crown, "always wear")
        precondition(BuddyWardrobe.resolve(always: BuddyOutfit.none, schedule: s, at: at(10, 23), calendar: cal) == .none, "always: no outfit")
        var off = s; off[2].enabled = false
        precondition(BuddyWardrobe.resolve(always: nil, schedule: off, at: at(10, 23, 15), calendar: cal) == .none, "disabled rule skipped (Friday 15:00)")
        precondition(BuddyWardrobe.resolve(always: nil, schedule: [], at: at(10, 23), calendar: cal) == .none, "empty schedule")

        // Storage: round trip, malformed rules dropped, at most 32
        let data = BuddyWardrobe.encode(s)!
        precondition(BuddyWardrobe.decode(data) == s, "round trip")
        let json = #"[{"outfit":"crown","when":{"days":["mon"]}},{"outfit":"cape","when":{"days":["mon"]}},{"outfit":"bow","when":{}},{"outfit":"bow","when":{"time":{"from":"25:00","to":"01:00"}}},{"outfit":"scarf","when":{"dates":{"from":"12-01","to":"02-28"}},"enabled":false}]"#
        let parsed = BuddyWardrobe.decode(Data(json.utf8))!
        precondition(parsed.count == 2 && parsed[0].outfit == .crown && parsed[1].outfit == .scarf && !parsed[1].enabled, "bad rules dropped: \(parsed.map(\.outfit))")
        let many = Array(repeating: s[0], count: 40)
        precondition(BuddyWardrobe.decode(BuddyWardrobe.encode(many)!)!.count == 32, "at most 32")
        precondition(BuddyWardrobe.decode(Data("nope".utf8)) == nil, "not JSON")
        precondition(String(decoding: BuddyWardrobe.encode([s[3]])!, as: UTF8.self).contains(#""from":"22:00""#), "stored as HH:MM")

        // Outfits map to Mochi's, the nightcap is the Buddy's own
        precondition(BuddyOutfit.nightcap.engineOutfit == nil && BuddyOutfit.pumpkin.engineOutfit == .pumpkin && BuddyOutfit.none.engineOutfit == Outfit.none, "engine outfits")
        precondition(Outfit.allCases.filter { $0 != .auto }.allSatisfy { BuddyOutfit(rawValue: $0.rawValue) != nil }, "every Mochi outfit is wearable")

        precondition(BuddyWardrobe.describe(BuddyWhen(days: [.sat, .sun])) == "Weekends", "describe weekends")
        precondition(BuddyWardrobe.describe(BuddyWhen(time: night)) == "22:00–07:00", "describe time")
        print("BuddyWardrobe: all cases passed")
    }
}
