import Foundation

// coucou-custom fork: the Buddy's wardrobe — OpenPets' model (github.com/OpenPetsHQ/openpets,
// docs/wardrobe.md, pet-wardrobe-core.ts) applied to Mochi's outfits. A schedule is an ordered list
// of rules; the first enabled rule whose conditions all match wins; no match means no outfit. The
// user can always wear one outfit ("Always wear"), or follow the schedule ("Automatic"). Pure
// logic, so `scripts/test-buddy.sh` compiles it on its own.

/// What the Buddy can wear: Mochi's outfits, plus the Buddy's own nightcap ("pajamas"), drawn by
/// the Buddy (the shared outfit list also feeds the notch's wardrobe, which stays as it is).
enum BuddyOutfit: String, CaseIterable, Codable, Identifiable {
    case none, nightcap
    case partyHat, beanie, crown, sunglasses, roundGlasses, bow, scarf, witchHat, pumpkin, santaHat, bunnyEars

    var id: String { rawValue }

    var name: String {
        switch self {
        case .none: return "No outfit"
        case .nightcap: return "Pajamas"
        case .partyHat: return "Party hat"
        case .beanie: return "Beanie"
        case .crown: return "Crown"
        case .sunglasses: return "Sunglasses"
        case .roundGlasses: return "Round glasses"
        case .bow: return "Bow"
        case .scarf: return "Scarf"
        case .witchHat: return "Witch hat"
        case .pumpkin: return "Pumpkin"
        case .santaHat: return "Santa hat"
        case .bunnyEars: return "Bunny ears"
        }
    }

    /// The shared outfit BotEngine draws; nil for the Buddy's own (the nightcap).
    var engineOutfit: Outfit? {
        switch self {
        case .none: return Outfit.none
        case .nightcap: return nil
        default: return Outfit(rawValue: rawValue)
        }
    }
}

// MARK: - Rules

enum BuddyWeekday: String, CaseIterable, Codable, Identifiable {
    case sun, mon, tue, wed, thu, fri, sat
    var id: String { rawValue }
    /// Calendar's weekday (1 = Sunday).
    var calendarWeekday: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
    var short: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// Minutes since midnight, "HH:MM".
struct BuddyClock: Codable, Equatable, Comparable {
    let minutes: Int

    init(minutes: Int) { self.minutes = ((minutes % 1440) + 1440) % 1440 }
    init(hour: Int, minute: Int) { self.init(minutes: hour * 60 + minute) }

    init?(_ text: String) {
        let p = text.split(separator: ":")
        guard p.count == 2, p[0].count == 2, p[1].count == 2, let h = Int(p[0]), let m = Int(p[1]),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        self.init(hour: h, minute: m)
    }

    var text: String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
    static func < (a: BuddyClock, b: BuddyClock) -> Bool { a.minutes < b.minutes }

    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let c = BuddyClock(s) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "HH:MM")) }
        self = c
    }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(text) }
}

/// A day of the year, "MM-DD" (02-29 allowed).
struct BuddyDay: Codable, Equatable {
    let month: Int, day: Int

    init?(month: Int, day: Int) {
        let max = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...12).contains(month), (1...max[month - 1]).contains(day) else { return nil }
        self.month = month
        self.day = day
    }

    init?(_ text: String) {
        let p = text.split(separator: "-")
        guard p.count == 2, p[0].count == 2, p[1].count == 2, let m = Int(p[0]), let d = Int(p[1]) else { return nil }
        self.init(month: m, day: d)
    }

    var text: String { String(format: "%02d-%02d", month, day) }
    var ordinal: Int { month * 100 + day }

    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let d = BuddyDay(s) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "MM-DD")) }
        self = d
    }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(text) }
}

struct BuddyTimeRange: Codable, Equatable { var from: BuddyClock; var to: BuddyClock }
struct BuddyDateRange: Codable, Equatable { var from: BuddyDay; var to: BuddyDay }

/// `when`: every condition present must match; at least one is present.
struct BuddyWhen: Codable, Equatable {
    var time: BuddyTimeRange?
    var days: [BuddyWeekday]?
    var dates: BuddyDateRange?

    var isEmpty: Bool { time == nil && (days ?? []).isEmpty && dates == nil }
}

struct BuddyWardrobeRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var outfit: BuddyOutfit
    var when: BuddyWhen
    var enabled = true

    enum CodingKeys: String, CodingKey { case outfit, when, enabled }

    init(outfit: BuddyOutfit, when: BuddyWhen, enabled: Bool = true) {
        self.outfit = outfit
        self.when = when
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outfit = try c.decode(BuddyOutfit.self, forKey: .outfit)
        when = try c.decode(BuddyWhen.self, forKey: .when)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(outfit, forKey: .outfit)
        try c.encode(when, forKey: .when)
        if !enabled { try c.encode(false, forKey: .enabled) }
    }

    static func == (a: Self, b: Self) -> Bool { a.outfit == b.outfit && a.when == b.when && a.enabled == b.enabled }
}

// MARK: - Matching and resolving

enum BuddyWardrobe {
    static let maxRules = 32

    /// The Buddy's own schedule ("the creator schedule"): holidays first, then the time of day,
    /// then broad rules, as OpenPets recommends.
    static let defaultSchedule: [BuddyWardrobeRule] = [
        .init(outfit: .partyHat, when: .init(dates: .init(from: BuddyDay(month: 12, day: 31)!, to: BuddyDay(month: 1, day: 2)!))),
        .init(outfit: .santaHat, when: .init(dates: .init(from: BuddyDay(month: 12, day: 1)!, to: BuddyDay(month: 12, day: 26)!))),
        .init(outfit: .pumpkin, when: .init(dates: .init(from: BuddyDay(month: 10, day: 1)!, to: BuddyDay(month: 10, day: 31)!))),
        .init(outfit: .nightcap, when: .init(time: .init(from: BuddyClock(hour: 22, minute: 0), to: BuddyClock(hour: 7, minute: 0)))),
        .init(outfit: .sunglasses, when: .init(days: [.sat, .sun])),
        .init(outfit: .sunglasses, when: .init(dates: .init(from: BuddyDay(month: 6, day: 21)!, to: BuddyDay(month: 8, day: 31)!))),
    ]

    /// Time: local, `to` exclusive, wraps midnight when `to` < `from`; `from` == `to` never matches.
    static func matches(_ r: BuddyTimeRange, minutes m: Int) -> Bool {
        let f = r.from.minutes, t = r.to.minutes
        if f == t { return false }
        return f < t ? (m >= f && m < t) : (m >= f || m < t)
    }

    /// Dates: inclusive, every year, wraps the new year when `to` < `from`.
    static func matches(_ r: BuddyDateRange, month: Int, day: Int) -> Bool {
        let x = month * 100 + day, f = r.from.ordinal, t = r.to.ordinal
        return f <= t ? (x >= f && x <= t) : (x >= f || x <= t)
    }

    static func matches(_ w: BuddyWhen, at date: Date, calendar: Calendar) -> Bool {
        guard !w.isEmpty else { return false }
        let c = calendar.dateComponents([.hour, .minute, .weekday, .month, .day], from: date)
        if let t = w.time, !matches(t, minutes: (c.hour ?? 0) * 60 + (c.minute ?? 0)) { return false }
        if let d = w.days, !d.isEmpty, !d.contains(where: { $0.calendarWeekday == c.weekday }) { return false }
        if let r = w.dates, !matches(r, month: c.month ?? 1, day: c.day ?? 1) { return false }
        return true
    }

    /// The first enabled matching rule, if any.
    static func activeRule(_ schedule: [BuddyWardrobeRule], at date: Date, calendar: Calendar) -> Int? {
        schedule.firstIndex { $0.enabled && matches($0.when, at: date, calendar: calendar) }
    }

    /// What the Buddy wears: "Always wear" first, then the schedule, then no outfit.
    static func resolve(always: BuddyOutfit?, schedule: [BuddyWardrobeRule], at date: Date, calendar: Calendar) -> BuddyOutfit {
        if let always { return always }
        return activeRule(schedule, at: date, calendar: calendar).map { schedule[$0].outfit } ?? .none
    }

    /// A stored schedule, dropping what is malformed (empty conditions), at most 32 rules
    /// (OpenPets normalizes the same way instead of rejecting the whole state).
    static func decode(_ data: Data) -> [BuddyWardrobeRule]? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        let rules = raw.compactMap { item -> BuddyWardrobeRule? in
            guard let d = try? JSONSerialization.data(withJSONObject: item),
                  let r = try? JSONDecoder().decode(BuddyWardrobeRule.self, from: d), !r.when.isEmpty else { return nil }
            return r
        }
        return Array(rules.prefix(maxRules))
    }

    static func encode(_ rules: [BuddyWardrobeRule]) -> Data? {
        try? JSONEncoder().encode(Array(rules.prefix(maxRules)))
    }

    /// A short description of a rule's conditions, for the schedule list.
    static func describe(_ w: BuddyWhen) -> String {
        var parts: [String] = []
        if let d = w.days, !d.isEmpty {
            let set = Set(d)
            if set == [.sat, .sun] { parts.append("Weekends") }
            else if set == [.mon, .tue, .wed, .thu, .fri] { parts.append("Weekdays") }
            else { parts.append(BuddyWeekday.allCases.filter(set.contains).map(\.short).joined(separator: ", ")) }
        }
        if let t = w.time { parts.append("\(t.from.text)–\(t.to.text)") }
        if let r = w.dates {
            let f = DateFormatter(); f.dateFormat = "MMM d"
            func label(_ d: BuddyDay) -> String {
                guard let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2024, month: d.month, day: d.day)) else { return d.text }
                return f.string(from: date)
            }
            parts.append(r.from == r.to ? label(r.from) : "\(label(r.from)) – \(label(r.to))")
        }
        return parts.isEmpty ? "Never" : parts.joined(separator: " · ")
    }
}
