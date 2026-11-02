#if !APPSTORE
import Foundation

// MARK: - The Tasks composer's reading of a line (coucou-custom fork)
//
// "Call the bank tomorrow 6pm #personal" → title "Call the bank", tomorrow at 6 PM, the Personal
// list. Dates come from Apple's date detector (on this Mac, no network); `#word` picks the list
// whose name starts with it, else the first whose name has a word starting with it ("#work" →
// "Zoho Pending Work"). Nothing else is guessed: what is not a date or a list stays in the title.

struct ParsedTask: Equatable {
    var title: String
    var due: Date?
    var hasTime: Bool
    var listID: String?
    /// Where the date and the list tag sit in the typed text, to colour them as you type.
    var dateRange: Range<String.Index>?
    var tagRange: Range<String.Index>?
}

enum TaskComposer {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    /// "in 2 hours", "in 30 min", "in 3 days": the date detector leaves these out.
    private static let relativePattern = try? NSRegularExpression(
        pattern: "\\bin (\\d{1,3})\\s*(minutes?|mins?|hours?|hrs?|h|days?)\\b", options: [.caseInsensitive])
    private static let tagPattern = try? NSRegularExpression(pattern: "(?<![\\w#])#([\\p{L}\\p{N}_-]+)")
    /// Words that make a detected date a moment in the day, not just a day.
    private static let timePattern = try? NSRegularExpression(
        pattern: "\\d{1,2}(:\\d{2})?\\s*(am|pm|a\\.m\\.|p\\.m\\.)|\\b\\d{1,2}:\\d{2}\\b|\\bnoon\\b|\\bmidnight\\b|\\bmorning\\b|\\bafternoon\\b|\\bevening\\b|\\btonight\\b|\\bin \\d+\\s*(minutes?|mins?|hours?|hrs?)\\b|\\bat \\d{1,2}\\b",
        options: [.caseInsensitive])
    /// Apple's detector reads "lunch fri 1pm" or "dinner tomorrow" with the meal as part of the date:
    /// the meal word stays in the title.
    private static let mealPattern = try? NSRegularExpression(pattern: "^(lunch|dinner|breakfast|brunch|supper)\\b\\s*", options: [.caseInsensitive])

    /// `readDate` / `readTag` false: that piece is left in the title (its chip was undone).
    static func parse(_ text: String, lists: [(id: String, title: String)], now: Date = .now,
                      readDate: Bool = true, readTag: Bool = true) -> ParsedTask {
        var result = ParsedTask(title: "", due: nil, hasTime: false, listID: nil, dateRange: nil, tagRange: nil)
        let ns = text as NSString

        // The list: the last #word that names a list.
        if readTag, let tagPattern {
            for m in tagPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
                let word = ns.substring(with: m.range(at: 1)).lowercased()
                if let list = group(for: word, in: lists) {
                    result.listID = list.id
                    result.tagRange = Range(m.range, in: text)
                    break
                }
            }
        }

        // The date: "in N minutes/hours/days" first, else the first one the detector finds
        // outside the tag.
        if !readDate {
            // The date chip was undone: no date read, the words stay in the title.
        } else if let relativePattern, let m = relativePattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
           let r = Range(m.range, in: text), result.tagRange.map({ !$0.overlaps(r) }) ?? true,
           let n = Int(ns.substring(with: m.range(at: 1))) {
            let unit = ns.substring(with: m.range(at: 2)).lowercased()
            if unit.hasPrefix("d") {
                result.due = Calendar.current.date(byAdding: .day, value: n, to: Calendar.current.startOfDay(for: now))
            } else {
                let minutes = unit.hasPrefix("m") ? n : n * 60
                result.due = now.addingTimeInterval(TimeInterval(minutes * 60))
                result.hasTime = true
            }
            result.dateRange = r
        } else if let detector {
            let matches = detector.matches(in: text, range: NSRange(location: 0, length: ns.length))
            if let m = matches.first(where: { m in
                guard let r = Range(m.range, in: text) else { return false }
                return result.tagRange.map { !$0.overlaps(r) } ?? true
            }), let date = m.date, var r = Range(m.range, in: text) {
                var phrase = String(text[r])
                if let meal = mealPattern?.firstMatch(in: phrase, range: NSRange(location: 0, length: (phrase as NSString).length)),
                   meal.range.length < (phrase as NSString).length,
                   let cut = Range(meal.range, in: phrase) {
                    r = text.index(r.lowerBound, offsetBy: phrase.distance(from: phrase.startIndex, to: cut.upperBound))..<r.upperBound
                    phrase = String(text[r])
                }
                let timed = timePattern?.firstMatch(in: phrase, range: NSRange(location: 0, length: (phrase as NSString).length)) != nil
                result.due = timed ? date : Calendar.current.startOfDay(for: date)
                result.hasTime = timed
                result.dateRange = r
            }
        }

        // The title: the text without the date and the tag, and without a word left dangling
        // before where the date was ("… on", "… at", "… by").
        var title = text
        for r in [result.dateRange, result.tagRange].compactMap({ $0 }).sorted(by: { $0.lowerBound > $1.lowerBound }) {
            title.replaceSubrange(r, with: " ")
        }
        title = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for dangling in [" on", " at", " by", " for", " due"] where title.lowercased().hasSuffix(dangling) {
            title = String(title.dropLast(dangling.count))
        }
        result.title = title.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters.subtracting(CharacterSet(charactersIn: "?!)"))))
        return result
    }

    /// A list name as a tag reads it: lower case, no spaces.
    static func key(_ title: String) -> String {
        title.lowercased().filter { !$0.isWhitespace }
    }

    /// The list (or calendar) a tag word names: the name starting with it, else the first with a
    /// word starting with it.
    static func group(for word: String, in lists: [(id: String, title: String)]) -> (id: String, title: String)? {
        let w = word.lowercased()
        guard !w.isEmpty else { return nil }
        return lists.first(where: { key($0.title).hasPrefix(w) })
            ?? lists.first(where: { words($0.title).contains { $0.hasPrefix(w) } })
    }

    /// The shortest tag that names this list: one of its words if that word leads to it, else the
    /// whole name without spaces ("Zoho Pending Work" → "work" when no other list takes it).
    static func tag(for id: String, in lists: [(id: String, title: String)]) -> String? {
        guard let list = lists.first(where: { $0.id == id }) else { return nil }
        let candidates = (words(list.title) + [key(list.title)]).sorted { $0.count < $1.count }
        return candidates.first { group(for: $0, in: lists)?.id == id } ?? key(list.title)
    }

    /// A list name's words, lower case: "Zoho Pending Work" → zoho, pending, work.
    static func words(_ title: String) -> [String] {
        title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// "Tomorrow 6:00 PM", "Fri 2 Nov", "Today": the chip under the composer and a task's time.
    static func label(_ due: Date, hasTime: Bool, now: Date = .now) -> String {
        let cal = Calendar.current
        let day: String
        if cal.isDateInToday(due) { day = "Today" }
        else if cal.isDateInTomorrow(due) { day = "Tomorrow" }
        else if cal.isDateInYesterday(due) { day = "Yesterday" }
        else if let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: due)).day, (0..<7).contains(days) {
            day = due.formatted(.dateTime.weekday(.wide))
        } else {
            day = due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
        return hasTime ? "\(day) \(due.formatted(date: .omitted, time: .shortened))" : day
    }
}
/// An event typed in the Agenda's composer: the Tasks reading plus a length
/// ("for 30 min", "for 2 hours"; an hour when none), all day when no time is given.
struct ParsedEvent: Equatable {
    var title: String
    var start: Date?
    var end: Date?
    var allDay: Bool
    var calendarID: String?
    /// "for 30 min" was typed: the Agenda's composer suggests an event (it never switches by itself).
    var hasLength = false
}

/// What the Agenda's composer adds: a task unless the line or you say event.
enum AgendaKind { case task, event }

/// "/event" or "/e", "/task" or "/t", as a word of its own anywhere in the line: what it is, and
/// the line without it. The last one typed wins.
enum AgendaCommand {
    private static let pattern = try? NSRegularExpression(pattern: "(?<!\\S)/(event|e|task|t)(?!\\S)", options: [.caseInsensitive])

    static func read(_ text: String) -> (kind: AgendaKind?, rest: String) {
        let ns = text as NSString
        guard let pattern else { return (nil, text) }
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let last = matches.last else { return (nil, text) }
        let kind: AgendaKind = ns.substring(with: last.range(at: 1)).lowercased().hasPrefix("e") ? .event : .task
        var rest = text
        // From the end, so the ranges before stay valid.
        for m in matches.reversed() {
            if let r = Range(m.range, in: rest) { rest.replaceSubrange(r, with: " ") }
        }
        return (kind, rest.split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }
}

enum CalendarComposer {
    private static let lengthPattern = try? NSRegularExpression(
        pattern: "\\bfor (\\d{1,3}(?:[.,]\\d)?)\\s*(minutes?|mins?|m|hours?|hrs?|h)\\b", options: [.caseInsensitive])

    /// Where "for 30 min" sits in a line, for the Details panel to change it.
    static func lengthRange(in text: String) -> Range<String.Index>? {
        lengthPattern?.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)).flatMap { Range($0.range, in: text) }
    }

    /// `defaultMinutes`: an event's length when none is typed (Settings → Agenda → Composer).
    static func parse(_ text: String, calendars: [(id: String, title: String)], now: Date = .now,
                      readDate: Bool = true, readTag: Bool = true, defaultMinutes: Double = 60) -> ParsedEvent {
        var line = text
        var minutes = defaultMinutes
        var hasLength = false
        let ns = text as NSString
        if let lengthPattern, let m = lengthPattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
           let r = Range(m.range, in: text),
           let n = Double(ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: ".")) {
            let unit = ns.substring(with: m.range(at: 2)).lowercased()
            minutes = unit.hasPrefix("h") ? n * 60 : n
            hasLength = true
            line.replaceSubrange(r, with: " ")
        }
        let p = TaskComposer.parse(line, lists: calendars, now: now, readDate: readDate, readTag: readTag)
        guard let start = p.due else {
            return ParsedEvent(title: p.title, start: nil, end: nil, allDay: false, calendarID: p.listID, hasLength: hasLength)
        }
        if p.hasTime {
            return ParsedEvent(title: p.title, start: start, end: start.addingTimeInterval(max(5, minutes) * 60),
                               allDay: false, calendarID: p.listID, hasLength: hasLength)
        }
        let day = Calendar.current.startOfDay(for: start)
        return ParsedEvent(title: p.title, start: day, end: Calendar.current.date(byAdding: .day, value: 1, to: day),
                           allDay: true, calendarID: p.listID, hasLength: hasLength)
    }

    /// "Tomorrow 1:00 – 2:00 PM", "Friday, all day".
    static func label(_ e: ParsedEvent) -> String? {
        guard let start = e.start, let end = e.end else { return nil }
        if e.allDay { return TaskComposer.label(start, hasTime: false) + ", all day" }
        let day = TaskComposer.label(start, hasTime: false)
        return "\(day) \(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
    }
}
// MARK: - The rest of a line: repeat, alerts, priority, place, note, link
//
// "Pay rent every month on 1st alert 1d !! @Bank // bring the cheque" → every month on the 1st, an
// alert a day before, medium priority, at Bank, a note. These words are blanked out of the line
// (same length, spaces) before the day, time and #tag are read, so those keep their places in the
// line and a chip can still swap them.

struct AgendaRepeat: Equatable {
    enum Frequency: Equatable { case daily, weekly, monthly, yearly }
    var frequency: Frequency
    var interval = 1
    /// 1 = Sunday … 7 = Saturday, as Calendar and EventKit count them.
    var weekdays: [Int] = []
    var dayOfMonth: Int?
    var until: Date?
    var count: Int?

    /// "Every weekday", "Every 2 weeks", "Every Mon, Thu", "Every month on the 1st".
    var label: String {
        let names = Calendar.current.shortWeekdaySymbols
        var out: String
        switch frequency {
        case .daily: out = interval == 1 ? "Every day" : "Every \(interval) days"
        case .weekly:
            if weekdays == [2, 3, 4, 5, 6] { out = "Every weekday" }
            else if weekdays == [1, 7] { out = "Every weekend" }
            else if !weekdays.isEmpty { out = (interval == 1 ? "Every " : "Every \(interval) weeks on ") + weekdays.map { names[$0 - 1] }.joined(separator: ", ") }
            else { out = interval == 1 ? "Every week" : "Every \(interval) weeks" }
        case .monthly:
            out = interval == 1 ? "Every month" : "Every \(interval) months"
            if let d = dayOfMonth { out += " on the \(AgendaExtras.ordinal(d))" }
        case .yearly: out = interval == 1 ? "Every year" : "Every \(interval) years"
        }
        if let until { out += " until " + until.formatted(.dateTime.day().month(.abbreviated)) }
        if let count { out += " · \(count) times" }
        return out
    }

    /// A typed date moved to the first day the repeat falls on, its time kept ("every mon 7am"
    /// typed on a Thursday → Monday 7 AM).
    func aligned(_ date: Date, calendar: Calendar = .current) -> Date {
        let day = firstDay(from: date, calendar: calendar)
        let time = calendar.dateComponents([.hour, .minute, .second], from: date)
        return calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: day) ?? date
    }

    /// The first day it falls on from `from` (a weekday or a day of the month), for a line with a
    /// repeat but no date: Reminders and Calendar need one to repeat from.
    func firstDay(from: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: from)
        for offset in 0..<370 {
            guard let d = calendar.date(byAdding: .day, value: offset, to: start) else { break }
            if !weekdays.isEmpty, !weekdays.contains(calendar.component(.weekday, from: d)) { continue }
            if let dom = dayOfMonth, calendar.component(.day, from: d) != dom { continue }
            return d
        }
        return start
    }
}

struct AgendaExtras: Equatable {
    enum Piece: Hashable { case repeating, alerts, priority, place, note, link }

    var repeating: AgendaRepeat?
    /// Seconds before the time; 0 is at the time.
    var alerts: [TimeInterval] = []
    /// 0 none, 1 low (!), 2 medium (!!), 3 high (!!!).
    var priority = 0
    var place: String?
    var note: String?
    var link: URL?
    /// Where each piece sat in the line (UTF-16), to blank it and to swap it from a chip.
    var ranges: [Piece: NSRange] = [:]

    static let none = AgendaExtras()

    /// Reminders' numbers: 1 high, 5 medium, 9 low, 0 none.
    var reminderPriority: Int { [0, 9, 5, 1][max(0, min(3, priority))] }

    static func alertLabel(_ seconds: TimeInterval) -> String {
        if seconds == 0 { return "At the time" }
        let m = Int(seconds / 60)
        if m % 1440 == 0 { return m == 1440 ? "1 day before" : "\(m / 1440) days before" }
        if m % 60 == 0 { return m == 60 ? "1 hour before" : "\(m / 60) hours before" }
        return "\(m) min before"
    }

    static func ordinal(_ n: Int) -> String {
        let suffix = (11...13).contains(n % 100) ? "th" : ["th", "st", "nd", "rd", "th", "th", "th", "th", "th", "th"][n % 10]
        return "\(n)\(suffix)"
    }

    private static let weekdayWords: [(String, Int)] = [
        ("sunday", 1), ("sundays", 1), ("sun", 1), ("monday", 2), ("mondays", 2), ("mon", 2),
        ("tuesday", 3), ("tuesdays", 3), ("tues", 3), ("tue", 3), ("wednesday", 4), ("wednesdays", 4), ("wed", 4),
        ("thursday", 5), ("thursdays", 5), ("thurs", 5), ("thu", 5), ("friday", 6), ("fridays", 6), ("fri", 6),
        ("saturday", 7), ("saturdays", 7), ("sat", 7),
    ]
    private static let weekdayAlternation = weekdayWords.map(\.0).sorted { $0.count > $1.count }.joined(separator: "|")

    private static func regex(_ p: String) -> NSRegularExpression? { try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
    private static let linkPattern = regex("https?://\\S+")
    /// A note runs to the end of the line, but a #tag ending the line is still the list.
    private static let notePattern = regex("(?<!\\S)//\\s*(.*?)(\\s+#[\\p{L}\\p{N}_-]+)?\\s*$")
    private static let priorityPattern = regex("(?<!\\S)(!{1,3})(?!\\S)")
    private static let alertPattern = regex("\\balerts?\\s+((?:(?:at\\s+(?:the\\s+)?(?:time|start)|\\d{1,3}\\s*(?:minutes?|mins?|m|hours?|hrs?|h|days?|d|weeks?|w))(?:\\s*(?:,|and|&)\\s*|\\s+(?=\\d))?)+)(?:\\s+before)?")
    private static let alertPart = regex("at\\s+(?:the\\s+)?(?:time|start)|(\\d{1,3})\\s*(minutes?|mins?|m|hours?|hrs?|h|days?|d|weeks?|w)")
    private static let repeatPattern = regex(
        "\\b(?:every\\s+(?:(other)\\s+|(\\d{1,2})\\s+)?(days?|weeks?|months?|years?|weekdays?|weekends?|(?:\(weekdayAlternation))(?:\\s*(?:,|and|&)\\s*(?:\(weekdayAlternation)))*)(?:\\s+on\\s+(?:the\\s+)?(\\d{1,2})(?:st|nd|rd|th)?)?|(daily|weekly|monthly|yearly|annually))\\b")
    private static let untilPattern = regex("\\buntil\\s+(.+)$")
    /// "every 2 weeks" followed by " on mon and thu".
    private static let onDaysPattern = regex("^\\s+on\\s+((?:\(weekdayAlternation))(?:\\s*(?:,|and|&)\\s*(?:\(weekdayAlternation)))*)\\b")
    private static let countPattern = regex("\\b(?:for\\s+)?(\\d{1,3})\\s*times\\b")
    private static let placePattern = regex("(?<!\\S)@(\\S.*?)(?=\\s+(?:#|!|//|/[a-z]|alerts?\\b|every\\b|until\\b|daily\\b|weekly\\b|monthly\\b|yearly\\b|https?://)|$)")
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    /// The pieces of `text` (but those in `skip`, which stay plain words), and the line with them
    /// blanked out for the date and #tag reading.
    static func read(_ text: String, skip: Set<Piece> = [], now: Date = .now) -> (extras: AgendaExtras, masked: String) {
        var x = AgendaExtras()
        let masked = NSMutableString(string: text)
        let full = { NSRange(location: 0, length: masked.length) }
        func blank(_ r: NSRange) {
            masked.replaceCharacters(in: r, with: String(repeating: " ", count: r.length))
        }
        func first(_ re: NSRegularExpression?) -> NSTextCheckingResult? { re?.firstMatch(in: masked as String, range: full()) }
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            let r = m.range(at: i); return r.location == NSNotFound ? nil : masked.substring(with: r)
        }

        // A link anywhere; then the note runs to the end of the line.
        if !skip.contains(.link), let m = first(linkPattern) {
            x.link = URL(string: masked.substring(with: m.range)); x.ranges[.link] = m.range; blank(m.range)
        }
        if !skip.contains(.note), let m = first(notePattern) {
            let note = (group(m, 1) ?? "").trimmingCharacters(in: .whitespaces)
            if !note.isEmpty { x.note = note }
            let tag = m.range(at: 2)
            let r = tag.location == NSNotFound ? m.range : NSRange(location: m.range.location, length: tag.location - m.range.location)
            x.ranges[.note] = r; blank(r)
        }
        if !skip.contains(.priority), let m = first(priorityPattern) {
            x.priority = m.range(at: 1).length; x.ranges[.priority] = m.range; blank(m.range)
        }
        if !skip.contains(.alerts), let m = first(alertPattern), let list = group(m, 1) {
            let ns = list as NSString
            for part in alertPart?.matches(in: list, range: NSRange(location: 0, length: ns.length)) ?? [] {
                if part.range(at: 1).location == NSNotFound { x.alerts.append(0); continue }
                let n = Double(ns.substring(with: part.range(at: 1))) ?? 0
                let unit = ns.substring(with: part.range(at: 2)).lowercased()
                let minutes = unit.hasPrefix("w") ? n * 10080 : unit.hasPrefix("d") ? n * 1440 : unit.hasPrefix("h") ? n * 60 : n
                x.alerts.append(minutes * 60)
            }
            x.alerts = Array(Set(x.alerts)).sorted()
            x.ranges[.alerts] = m.range; blank(m.range)
        }
        if !skip.contains(.repeating), let m = first(repeatPattern) {
            var r = AgendaRepeat(frequency: .weekly)
            if let word = group(m, 5)?.lowercased() {
                r.frequency = word == "daily" ? .daily : word == "weekly" ? .weekly : word == "monthly" ? .monthly : .yearly
            } else if let what = group(m, 3)?.lowercased() {
                if group(m, 1) != nil { r.interval = 2 }
                if let n = group(m, 2).flatMap(Int.init) { r.interval = max(1, n) }
                if what.hasPrefix("day") { r.frequency = .daily }
                else if what.hasPrefix("weekday") { r.frequency = .weekly; r.weekdays = [2, 3, 4, 5, 6] }
                else if what.hasPrefix("weekend") { r.frequency = .weekly; r.weekdays = [1, 7] }
                else if what.hasPrefix("week") { r.frequency = .weekly }
                else if what.hasPrefix("month") { r.frequency = .monthly }
                else if what.hasPrefix("year") { r.frequency = .yearly }
                else {
                    r.frequency = .weekly
                    let words = what.split(whereSeparator: { !$0.isLetter }).map(String.init)
                    r.weekdays = Array(Set(words.compactMap { w in weekdayWords.first { $0.0 == w }?.1 })).sorted()
                }
                if let d = group(m, 4).flatMap(Int.init), (1...31).contains(d) { r.dayOfMonth = d; if r.frequency != .monthly { r.dayOfMonth = nil } }
            }
            var span = m.range
            if r.frequency == .weekly, r.weekdays.isEmpty, let onDaysPattern {
                let after = NSRange(location: m.range.location + m.range.length, length: masked.length - m.range.location - m.range.length)
                if let on = onDaysPattern.firstMatch(in: masked as String, options: .anchored, range: after) {
                    let words = masked.substring(with: on.range(at: 1)).lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
                    r.weekdays = Array(Set(words.compactMap { w in weekdayWords.first { $0.0 == w }?.1 })).sorted()
                    span = NSUnionRange(span, on.range)
                }
            }
            x.ranges[.repeating] = span; blank(span)
            // When it stops: "until <a date>" or "10 times".
            if let u = first(untilPattern), let detector {
                let phrase = masked.substring(with: u.range(at: 1))
                if let d = detector.firstMatch(in: phrase, range: NSRange(location: 0, length: (phrase as NSString).length)),
                   d.range.location == 0, let date = d.date {
                    r.until = Calendar.current.startOfDay(for: date)
                    let span = NSRange(location: u.range.location, length: u.range(at: 1).location - u.range.location + d.range.length)
                    x.ranges[.repeating] = NSUnionRange(x.ranges[.repeating]!, span)
                    blank(span)
                }
            }
            if let c = first(countPattern), let n = group(c, 1).flatMap(Int.init), n > 0 {
                r.count = n
                x.ranges[.repeating] = NSUnionRange(x.ranges[.repeating]!, c.range)
                blank(c.range)
            }
            x.repeating = r
        }
        if !skip.contains(.place), let m = first(placePattern) {
            var r = m.range(at: 1)
            // A day or time written after the place belongs to the date, not the place.
            if let d = detector?.firstMatch(in: masked as String, range: r), d.range.location > r.location {
                r.length = d.range.location - r.location
            }
            let place = masked.substring(with: r).trimmingCharacters(in: .whitespaces)
            if !place.isEmpty {
                x.place = place
                let span = NSRange(location: m.range.location, length: r.location + r.length - m.range.location)
                x.ranges[.place] = span; blank(span)
            }
        }
        return (x, masked as String)
    }

    /// A range found in the blanked line, as the same range of the line itself (same UTF-16 length).
    static func same(_ r: Range<String.Index>?, from masked: String, in original: String) -> Range<String.Index>? {
        guard let r else { return nil }
        return Range(NSRange(r, in: masked), in: original)
    }
}

// MARK: - Writing a piece back into the line (the Details panel)
//
// The Details panel edits the line itself, so the line stays the one truth: each control puts
// the words for its piece in that piece's place (or removes them), in a form `read` and the
// date reader take back exactly.

enum AgendaLine {
    private static let words = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    /// `phrase` in `range` of `line` (nil `phrase` removes it); with no range, added before the
    /// note (which runs to the end) or at the end.
    static func put(_ phrase: String?, at range: Range<String.Index>?, in line: String, before note: Range<String.Index>?) -> String {
        var t = line
        if let range {
            t.replaceSubrange(range, with: phrase.map { " \($0) " } ?? " ")
        } else if let phrase {
            if let note { t.insert(contentsOf: phrase + " ", at: note.lowerBound) } else { t += " " + phrase }
        }
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// "5 nov 2026" or "5 nov 2026 7:00am": what the date reader takes back as that day and time.
    static func date(_ date: Date, hasTime: Bool) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        var out = "\(c.day ?? 1) \(months[(c.month ?? 1) - 1]) \(c.year ?? 2026)"
        if hasTime, let h = c.hour, let m = c.minute {
            out += " \(h % 12 == 0 ? 12 : h % 12):\(String(format: "%02d", m))\(h < 12 ? "am" : "pm")"
        }
        return out
    }

    /// "for 45m", "for 2h", "for 90m".
    static func length(minutes: Int) -> String {
        minutes % 60 == 0 ? "for \(minutes / 60)h" : "for \(minutes)m"
    }

    static func alerts(_ offsets: [TimeInterval]) -> String? {
        guard !offsets.isEmpty else { return nil }
        return "alert " + offsets.sorted().map { s in
            let m = Int(s / 60)
            if m == 0 { return "at the time" }
            if m % 1440 == 0 { return "\(m / 1440)d" }
            if m % 60 == 0 { return "\(m / 60)h" }
            return "\(m)m"
        }.joined(separator: ", ")
    }

    static func priority(_ n: Int) -> String? { n > 0 ? String(repeating: "!", count: min(3, n)) : nil }

    /// The repeat as words `read` takes back to the same rule.
    static func repeating(_ r: AgendaRepeat?) -> String? {
        guard let r else { return nil }
        let days = r.weekdays.map { words[$0 - 1] }.joined(separator: " and ")
        var out: String
        switch r.frequency {
        case .daily: out = r.interval == 1 ? "every day" : (r.interval == 2 ? "every other day" : "every \(r.interval) days")
        case .weekly:
            if r.weekdays == [2, 3, 4, 5, 6] && r.interval == 1 { out = "every weekday" }
            else if r.weekdays == [1, 7] && r.interval == 1 { out = "every weekend" }
            else if r.weekdays.isEmpty { out = r.interval == 1 ? "every week" : (r.interval == 2 ? "every other week" : "every \(r.interval) weeks") }
            else { out = r.interval == 1 ? "every \(days)" : "every \(r.interval) weeks on \(days)" }
        case .monthly:
            out = r.interval == 1 ? "every month" : (r.interval == 2 ? "every other month" : "every \(r.interval) months")
            if let d = r.dayOfMonth { out += " on \(AgendaExtras.ordinal(d))" }
        case .yearly: out = r.interval == 1 ? "every year" : (r.interval == 2 ? "every other year" : "every \(r.interval) years")
        }
        if let until = r.until { out += " until " + date(until, hasTime: false) }
        else if let count = r.count { out += " \(count) times" }
        return out
    }
}

// MARK: - Templates: your own slash commands (Settings → Agenda → Composer)
//
// "/standup" and a space (or picking it from the / menu) puts its line in the composer, as text
// you then change like any other line: nothing is hidden behind the name.

struct AgendaTemplate: Codable, Equatable, Identifiable {
    var name: String     // without the slash, lower case
    var line: String
    var id: String { name }

    /// The composer's own commands: a template may not take their names.
    static let reserved: Set<String> = ["e", "t", "event", "task", "at", "today", "tomorrow", "repeat", "alert",
                                        "priority", "place", "note", "help"]

    /// What is wrong with a name, or nil when it can be used ("standup", "gym-am").
    static func problem(_ name: String, others: [AgendaTemplate]) -> String? {
        let n = name.lowercased()
        if n.isEmpty { return "Give it a name." }
        if n.range(of: "^[a-z0-9][a-z0-9_-]{0,23}$", options: .regularExpression) == nil {
            return "Letters, digits, - and _ only, no spaces, up to 24."
        }
        if reserved.contains(n) { return "/\(n) is one of the composer's own commands." }
        if others.contains(where: { $0.name == n }) { return "/\(n) is already a template." }
        return nil
    }

    /// The line with "/name " (just completed by a space) replaced by that template's line;
    /// nil when the word just finished is not a template.
    static func expand(_ text: String, templates: [AgendaTemplate]) -> String? {
        guard let last = text.last, last.isWhitespace else { return nil }
        let body = text.dropLast()
        let start = body.lastIndex(where: \.isWhitespace).map { body.index(after: $0) } ?? body.startIndex
        let word = body[start...]
        guard word.hasPrefix("/"), let t = templates.first(where: { "/" + $0.name == word.lowercased() }) else { return nil }
        return String(body[..<start]) + t.line + " "
    }
}

// MARK: - Suggestions while typing (the Agenda's composer)
//
// The last word being typed decides the menu: "/…" the commands, "#…" the lists (a task) or the
// calendars (an event). Picking one puts its words in the line, so the line stays the one truth:
// what the chips show is what the parser reads.

struct AgendaSuggestion: Equatable, Identifiable {
    enum Action: Equatable {
        case insert(String)                      // replace the word being typed with this (and a space)
        case choices(AgendaSuggest.ChoiceSet)    // open a list of choices
        case help                                // open the help sheet
    }
    let title: String
    let detail: String
    /// What the row shows on its left: "/event", or a list's id for its colour dot.
    let symbol: String
    let groupID: String?
    let action: Action
    var id: String { symbol + title }
}

enum AgendaSuggest {
    /// The lists of choices a command or a chip opens.
    enum ChoiceSet: Equatable { case when, repeating, alert, priority }

    /// The word being typed: the last one, when the line does not end with a space.
    static func lastWord(_ text: String) -> Substring? {
        guard let last = text.last, !last.isWhitespace else { return nil }
        let start = text.lastIndex(where: \.isWhitespace).map { text.index(after: $0) } ?? text.startIndex
        return text[start...]
    }

    static let commands: [AgendaSuggestion] = [
        AgendaSuggestion(title: "Make it an event", detail: "or /e, or Tab", symbol: "/event", groupID: nil, action: .insert("/e")),
        AgendaSuggestion(title: "Make it a task", detail: "or /t", symbol: "/task", groupID: nil, action: .insert("/t")),
        AgendaSuggestion(title: "A day and a time", detail: "choose from a list", symbol: "/at", groupID: nil, action: .choices(.when)),
        AgendaSuggestion(title: "Today", detail: "add a time after it", symbol: "/today", groupID: nil, action: .insert("today")),
        AgendaSuggestion(title: "Tomorrow", detail: "add a time after it", symbol: "/tomorrow", groupID: nil, action: .insert("tomorrow")),
        AgendaSuggestion(title: "Repeat", detail: "every day, weekday, week…", symbol: "/repeat", groupID: nil, action: .choices(.repeating)),
        AgendaSuggestion(title: "Alerts", detail: "10 min, 1 hour, 1 day before", symbol: "/alert", groupID: nil, action: .choices(.alert)),
        AgendaSuggestion(title: "Priority", detail: "tasks: ! !! !!!", symbol: "/priority", groupID: nil, action: .choices(.priority)),
        AgendaSuggestion(title: "A place", detail: "@Room 4", symbol: "/place", groupID: nil, action: .insert("@")),
        AgendaSuggestion(title: "A note or a link", detail: "// text, a pasted link", symbol: "/note", groupID: nil, action: .insert("// ")),
        AgendaSuggestion(title: "Everything you can type", detail: "or type ?", symbol: "/help", groupID: nil, action: .help),
    ]

    /// Day-and-time choices: phrases the parser reads.
    static let when: [AgendaSuggestion] = [
        ("In an hour", "in 1 hour"), ("Today 6 PM", "today 6pm"), ("Tonight 9 PM", "today 9pm"),
        ("Tomorrow 9 AM", "tomorrow 9am"), ("Tomorrow 6 PM", "tomorrow 6pm"),
        ("Next Monday 9 AM", "next monday 9am"), ("Tomorrow, no time", "tomorrow"),
    ].map { AgendaSuggestion(title: $0.0, detail: $0.1, symbol: "clock", groupID: nil, action: .insert($0.1)) }

    static let repeats: [AgendaSuggestion] = [
        ("Every day", "every day"), ("Every weekday", "every weekday"), ("Every week", "every week"),
        ("Every other week", "every other week"), ("Every month", "every month"), ("Every year", "every year"),
    ].map { AgendaSuggestion(title: $0.0, detail: $0.1, symbol: "repeat", groupID: nil, action: .insert($0.1)) }

    static let alerts: [AgendaSuggestion] = [
        ("At the time", "alert at the time"), ("5 min before", "alert 5m"), ("10 min before", "alert 10m"),
        ("30 min before", "alert 30m"), ("1 hour before", "alert 1h"), ("1 day before", "alert 1d"),
    ].map { AgendaSuggestion(title: $0.0, detail: $0.1, symbol: "bell", groupID: nil, action: .insert($0.1)) }

    static let priorities: [AgendaSuggestion] = [("Low", "!"), ("Medium", "!!"), ("High", "!!!")]
        .map { AgendaSuggestion(title: $0.0, detail: $0.1, symbol: "exclamationmark", groupID: nil, action: .insert($0.1)) }

    static func choices(_ set: ChoiceSet) -> [AgendaSuggestion] {
        switch set {
        case .when: when
        case .repeating: repeats
        case .alert: alerts
        case .priority: priorities
        }
    }

    /// The menu for the word being typed, or nil when it is not "/…" or "#…".
    static func menu(for text: String, groups: [(id: String, title: String)], groupKind: String,
                     templates: [AgendaTemplate]) -> [AgendaSuggestion]? {
        guard let word = lastWord(text) else { return nil }
        if word.hasPrefix("/") {
            let q = word.dropFirst().lowercased()
            // "/e", "/t", "/event" and "/task" typed in full are commands already: no menu over them.
            if ["e", "t", "event", "task"].contains(q) { return nil }
            // Your templates first: they are why you typed a name of your own.
            let mine = templates.filter { $0.name.hasPrefix(q) }.map {
                AgendaSuggestion(title: $0.line, detail: "your template", symbol: "/" + $0.name, groupID: nil, action: .insert($0.line))
            }
            let hits = mine + commands.filter { $0.symbol.dropFirst().hasPrefix(q) }
            return finished(hits, word) ? nil : hits
        }
        if word.hasPrefix("#") {
            let q = String(word.dropFirst())
            let hits = q.isEmpty ? groups : groups.filter { g in
                TaskComposer.key(g.title).hasPrefix(q.lowercased()) || TaskComposer.words(g.title).contains { $0.hasPrefix(q.lowercased()) }
            }
            let items = hits.map { g in
                AgendaSuggestion(title: g.title, detail: groupKind, symbol: "#", groupID: g.id,
                                 action: .insert("#" + (TaskComposer.tag(for: g.id, in: groups) ?? TaskComposer.key(g.title))))
            }
            return finished(items, word) ? nil : items
        }
        return nil
    }

    /// Nothing left to choose: no row, or the one row is what is typed already ("#personal",
    /// "/today"), so Return adds the line instead of picking it again.
    private static func finished(_ items: [AgendaSuggestion], _ word: Substring) -> Bool {
        guard items.count <= 1 else { return false }
        guard let only = items.first else { return true }
        let w = word.lowercased()
        if only.symbol.lowercased() == w { return true }
        if case .insert(let words) = only.action, words.lowercased() == w { return true }
        if only.groupID != nil, w.hasPrefix("#") { return TaskComposer.key(only.title) == String(w.dropFirst()) }
        return false
    }

    /// The line with the word being typed replaced by `words` and a space (or `words` added).
    /// A marker the next words belong to ("@", "// ") takes no space of its own after it.
    static func apply(_ words: String, to text: String, replacingLastWord: Bool = true) -> String {
        let end = words.hasSuffix("@") || words.hasSuffix(" ") ? "" : " "
        if replacingLastWord, let w = lastWord(text) {
            return String(text[..<w.startIndex]) + words + end
        }
        let base = text.isEmpty || text.last?.isWhitespace == true ? text : text + " "
        return base + words + end
    }

    /// The line with one recognised piece swapped for other words (a chip changed).
    static func replace(_ range: Range<String.Index>?, in text: String, with words: String) -> String {
        guard let range else { return apply(words, to: text, replacingLastWord: false) }
        var t = text
        t.replaceSubrange(range, with: words)
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ") + " "
    }
}
#endif
