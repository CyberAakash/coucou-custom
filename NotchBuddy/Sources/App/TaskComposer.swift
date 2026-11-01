#if !APPSTORE
import Foundation

// MARK: - The Tasks composer's reading of a line (coucou-custom fork)
//
// "Call the bank tomorrow 6pm #personal" → title "Call the bank", tomorrow at 6 PM, the Personal
// list. Dates come from Apple's date detector (on this Mac, no network); `#word` picks the list
// whose name starts with it. Nothing else is guessed: what is not a date or a list stays in the title.

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

    static func parse(_ text: String, lists: [(id: String, title: String)], now: Date = .now) -> ParsedTask {
        var result = ParsedTask(title: "", due: nil, hasTime: false, listID: nil, dateRange: nil, tagRange: nil)
        let ns = text as NSString

        // The list: the last #word that names a list.
        if let tagPattern {
            for m in tagPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
                let word = ns.substring(with: m.range(at: 1)).lowercased()
                if let list = lists.first(where: { key($0.title).hasPrefix(word) }) {
                    result.listID = list.id
                    result.tagRange = Range(m.range, in: text)
                    break
                }
            }
        }

        // The date: "in N minutes/hours/days" first, else the first one the detector finds
        // outside the tag.
        if let relativePattern, let m = relativePattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
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
            }), let date = m.date, let r = Range(m.range, in: text) {
                let phrase = String(text[r])
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
/// An event typed in the Calendar page's composer: the Tasks reading plus a length
/// ("for 30 min", "for 2 hours"; an hour when none), all day when no time is given.
struct ParsedEvent: Equatable {
    var title: String
    var start: Date?
    var end: Date?
    var allDay: Bool
    var calendarID: String?
}

enum CalendarComposer {
    private static let lengthPattern = try? NSRegularExpression(
        pattern: "\\bfor (\\d{1,3}(?:[.,]\\d)?)\\s*(minutes?|mins?|m|hours?|hrs?|h)\\b", options: [.caseInsensitive])

    static func parse(_ text: String, calendars: [(id: String, title: String)], now: Date = .now) -> ParsedEvent {
        var line = text
        var minutes: Double = 60
        let ns = text as NSString
        if let lengthPattern, let m = lengthPattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
           let r = Range(m.range, in: text),
           let n = Double(ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: ".")) {
            let unit = ns.substring(with: m.range(at: 2)).lowercased()
            minutes = unit.hasPrefix("h") ? n * 60 : n
            line.replaceSubrange(r, with: " ")
        }
        let p = TaskComposer.parse(line, lists: calendars, now: now)
        guard let start = p.due else {
            return ParsedEvent(title: p.title, start: nil, end: nil, allDay: false, calendarID: p.listID)
        }
        if p.hasTime {
            return ParsedEvent(title: p.title, start: start, end: start.addingTimeInterval(max(5, minutes) * 60),
                               allDay: false, calendarID: p.listID)
        }
        let day = Calendar.current.startOfDay(for: start)
        return ParsedEvent(title: p.title, start: day, end: Calendar.current.date(byAdding: .day, value: 1, to: day),
                           allDay: true, calendarID: p.listID)
    }

    /// "Tomorrow 1:00 – 2:00 PM", "Friday, all day".
    static func label(_ e: ParsedEvent) -> String? {
        guard let start = e.start, let end = e.end else { return nil }
        if e.allDay { return TaskComposer.label(start, hasTime: false) + ", all day" }
        let day = TaskComposer.label(start, hasTime: false)
        return "\(day) \(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
    }
}
#endif
