#if !APPSTORE
import AppKit
import EventKit
import SwiftUI

// MARK: - Calendar from macOS (coucou-custom fork, roadmap phase 3)
//
// EventKit reads every calendar the Mac knows: iCloud, Google, Exchange and the others added in
// System Settings → Internet Accounts, through one path. Coucou keeps only which calendars to show
// and where new events go.

/// One calendar, as the notch shows it.
struct CalCalendar: Identifiable, Equatable {
    let id: String          // EKCalendar.calendarIdentifier
    let title: String
    let account: String     // EKSource.title: "iCloud", "you@gmail.com"…
    let color: Color
    let writable: Bool
}

/// One event of the shown week.
struct CalEvent: Identifiable, Equatable {
    let id: String          // eventIdentifier + start (a repeating event has one id per series)
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let calendarID: String
    let location: String?
    /// A Zoom, Meet or Teams link found on the event.
    let meeting: URL?
    let attendees: Int
    /// A loop beside the title in the Agenda.
    var repeats = false
}

/// Settings → Agenda → Calendar: events in the Agenda on or off, the calendars left out, where new events go, the wing
/// and the Join card.
@MainActor
final class CalendarSettings: ObservableObject {
    static let shared = CalendarSettings()
    static let enabledKey = "coucouCalendarEnabled"
    static let hiddenKey = "coucouCalendarHidden"
    static let newKey = "coucouCalendarNew"
    static let wingKey = "coucouCalendarWing"
    static let wingMinutesKey = "coucouCalendarWingMinutes"
    static let joinKey = "coucouCalendarJoin"
    static let joinLeadKey = "coucouCalendarJoinLead"

    private let ud = UserDefaults.standard

    @Published var enabled: Bool { didSet { ud.set(enabled, forKey: Self.enabledKey) } }
    @Published var hidden: Set<String> { didSet { ud.set(Array(hidden).sorted(), forKey: Self.hiddenKey) } }
    /// The calendar new events go to; nil is the Mac's default calendar.
    @Published var newCalendar: String? { didSet { ud.set(newCalendar, forKey: Self.newKey) } }
    /// The next event in the closed notch's right wing, this many minutes before it starts.
    @Published var wing: Bool { didSet { ud.set(wing, forKey: Self.wingKey) } }
    @Published var wingMinutes: Int { didSet { ud.set(wingMinutes, forKey: Self.wingMinutesKey) } }
    /// The Join card below the notch when a meeting with a link starts (minutes before: 0 = at the start).
    @Published var join: Bool { didSet { ud.set(join, forKey: Self.joinKey) } }
    @Published var joinLead: Int { didSet { ud.set(joinLead, forKey: Self.joinLeadKey) } }

    private init() {
        enabled = ud.object(forKey: Self.enabledKey) as? Bool ?? true
        hidden = Set(ud.stringArray(forKey: Self.hiddenKey) ?? [])
        newCalendar = ud.string(forKey: Self.newKey)
        wing = ud.object(forKey: Self.wingKey) as? Bool ?? true
        wingMinutes = ud.object(forKey: Self.wingMinutesKey) as? Int ?? 10
        join = ud.object(forKey: Self.joinKey) as? Bool ?? true
        joinLead = ud.object(forKey: Self.joinLeadKey) as? Int ?? 0
    }
}

@MainActor
final class CalendarStore: ObservableObject {
    static let shared = CalendarStore()

    enum Access { case unknown, granted, denied }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var calendars: [CalCalendar] = []
    /// The shown calendars' events from the start of the shown week, seven days.
    @Published private(set) var events: [CalEvent] = []
    @Published private(set) var weekStart: Date = Calendar.current.startOfDay(for: .now)

    private let store = EKEventStore()
    private var changeObserver: NSObjectProtocol?

    private init() {
        access = Self.currentAccess()
        changeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            MainActor.assumeIsolated { CalendarStore.shared.reload() }
        }
        if access == .granted { reload() }
    }

    static var reallyGranted: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .unknown
        default: return .denied
        }
    }

    func requestAccess() async {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        access = granted ? .granted : Self.currentAccess()
        appendAppLog("nb.log", "[Calendar] access: \(granted ? "granted" : "refused")")
        if granted { reload() }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    /// System Settings → Internet Accounts, where a Google or Exchange account is added.
    func openInternetAccounts() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func openCalendarApp(at date: Date? = nil) {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: app, configuration: .init(), completionHandler: nil)
        }
    }

    var shownCalendars: [CalCalendar] { calendars.filter { !CalendarSettings.shared.hidden.contains($0.id) } }

    func calendar(_ id: String) -> CalCalendar? { calendars.first { $0.id == id } }

    /// Where a new event goes: the chosen calendar when it still exists and takes events, else the default.
    var newEventCalendar: CalCalendar? {
        if let id = CalendarSettings.shared.newCalendar, let c = calendar(id), c.writable { return c }
        if let d = store.defaultCalendarForNewEvents { return calendar(d.calendarIdentifier) }
        return calendars.first { $0.writable }
    }

    /// The week shown: the one holding `day` (from Sunday or Monday, as the Mac's calendar starts).
    func showWeek(of day: Date) {
        let cal = Calendar.current
        let start = cal.dateInterval(of: .weekOfYear, for: day)?.start ?? cal.startOfDay(for: day)
        if start != weekStart { weekStart = start; reload() }
    }

    // MARK: Reading

    func reload() {
        #if DEBUG
        if debugFrozen { return }
        #endif
        guard access == .granted else { return }
        let all = store.calendars(for: .event)
        calendars = all.map {
            CalCalendar(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "On My Mac",
                        color: Color(nsColor: $0.color ?? .systemBlue), writable: $0.allowsContentModifications)
        }
        .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
        let shown = all.filter { !CalendarSettings.shared.hidden.contains($0.calendarIdentifier) }
        guard !shown.isEmpty, let end = Calendar.current.date(byAdding: .day, value: 7, to: weekStart) else { events = []; return }
        // The week shown, and today's and tomorrow's for the wing and the Join card when the
        // week shown is another one.
        let from = min(weekStart, Calendar.current.startOfDay(for: .now))
        let to = max(end, Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: .now)) ?? end)
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: shown)
        events = store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .map(Self.event)
            .sorted { ($0.allDay ? 0 : 1, $0.start) < ($1.allDay ? 0 : 1, $1.start) }
    }

    private static func event(_ e: EKEvent) -> CalEvent {
        CalEvent(id: (e.eventIdentifier ?? UUID().uuidString) + "@\(e.startDate.timeIntervalSince1970)",
                 title: e.title ?? "Event", start: e.startDate, end: e.endDate, allDay: e.isAllDay,
                 calendarID: e.calendar.calendarIdentifier,
                 location: e.location?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                 meeting: meetingLink(url: e.url, location: e.location, notes: e.notes),
                 attendees: e.attendees?.count ?? 0, repeats: e.hasRecurrenceRules)
    }

    /// The first Zoom, Google Meet or Teams link on an event.
    static func meetingLink(url: URL?, location: String?, notes: String?) -> URL? {
        if let url, isMeeting(url) { return url }
        let text = [location, notes].compactMap { $0 }.joined(separator: "\n")
        guard !text.isEmpty, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap(\.url).first(where: isMeeting)
    }

    static func isMeeting(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host.hasSuffix("zoom.us") || host == "meet.google.com" || host.hasSuffix("teams.microsoft.com")
            || host.hasSuffix("teams.live.com") || host.hasSuffix("webex.com")
    }

    static func meetingApp(_ url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        if host.hasSuffix("zoom.us") { return "Zoom" }
        if host == "meet.google.com" { return "Meet" }
        if host.contains("teams") { return "Teams" }
        if host.hasSuffix("webex.com") { return "Webex" }
        return "meeting"
    }

    /// Opens a meeting in its app: a Zoom link as zoommtg:// when Zoom is installed, the others as they are.
    func join(_ event: CalEvent) {
        guard let url = event.meeting else { return }
        appendAppLog("nb.log", "[Calendar] join \(Self.meetingApp(url))")
        if Self.meetingApp(url) == "Zoom", let app = zoomAppURL(url),
           NSWorkspace.shared.urlForApplication(toOpen: app) != nil {
            NSWorkspace.shared.open(app)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// https://…zoom.us/j/123?pwd=x → zoommtg://zoom.us/join?confno=123&pwd=x
    private func zoomAppURL(_ url: URL) -> URL? {
        let parts = url.pathComponents
        guard let i = parts.firstIndex(of: "j"), i + 1 < parts.count else { return nil }
        var c = URLComponents()
        c.scheme = "zoommtg"
        c.host = "zoom.us"
        c.path = "/join"
        var items = [URLQueryItem(name: "confno", value: parts[i + 1])]
        if let pwd = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "pwd" })?.value {
            items.append(URLQueryItem(name: "pwd", value: pwd))
        }
        c.queryItems = items
        return c.url
    }

    // MARK: Writing

    /// Adds an event with what the composer read besides the time (repeat, alerts, place, note,
    /// link); returns its identifier, or nil when the calendar refused it.
    @discardableResult
    func add(title: String, start: Date, end: Date, allDay: Bool, calendarID: String?, extras: AgendaExtras = .none) -> String? {
        guard access == .granted else { return nil }
        let e = EKEvent(eventStore: store)
        e.title = title
        e.startDate = start
        e.endDate = end
        e.isAllDay = allDay
        e.calendar = calendarID.flatMap { id in store.calendars(for: .event).first { $0.calendarIdentifier == id } }
            ?? store.defaultCalendarForNewEvents
        extras.alerts.forEach { e.addAlarm(EKAlarm(relativeOffset: -$0)) }
        if let rule = extras.repeating.map(TasksStore.rule) { e.addRecurrenceRule(rule) }
        e.location = extras.place
        e.notes = extras.note
        e.url = extras.link
        do {
            try store.save(e, span: .thisEvent, commit: true)
            appendAppLog("nb.log", "[Calendar] added to \(e.calendar.title)")
            reload()
            return e.eventIdentifier
        } catch {
            appendAppLog("nb.log", "[Calendar] add failed: \(error.localizedDescription)")
            return nil
        }
    }

    func delete(eventIdentifier: String) {
        guard let e = store.event(withIdentifier: eventIdentifier) else { return }
        do {
            try store.remove(e, span: .thisEvent, commit: true)
            reload()
        } catch {
            appendAppLog("nb.log", "[Calendar] delete failed: \(error.localizedDescription)")
        }
    }

    #if DEBUG
    private var debugFrozen = false

    /// Save tests only: a "Coucou test" calendar made, read back in nb.log, and removed with its events.
    func debugTest(_ action: String) {
        let name = "Coucou test"
        let mine = store.calendars(for: .event).filter { $0.title == name }
        // No test calendar: an empty calendar filter means every calendar.
        guard action == "setup" || !mine.isEmpty else { return }
        switch action {
        case "setup" where mine.isEmpty:
            let c = EKCalendar(for: .event, eventStore: store)
            c.title = name
            c.source = store.defaultCalendarForNewEvents?.source
            do { try store.saveCalendar(c, commit: true); appendAppLog("nb.log", "[Test] calendar made") }
            catch { appendAppLog("nb.log", "[Test] calendar failed: \(error.localizedDescription)") }
            reload()
        case "dump":
            let from = Calendar.current.startOfDay(for: .now)
            guard !mine.isEmpty, let to = Calendar.current.date(byAdding: .day, value: 14, to: from) else { return }
            var seen = Set<String>()
            for e in store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: mine)) where seen.insert(e.eventIdentifier ?? "").inserted {
                appendAppLog("nb.log", "[Test] event '\(e.title ?? "")' \(e.startDate.formatted()) – \(e.endDate.formatted(date: .omitted, time: .shortened)) allDay=\(e.isAllDay) alarms=\((e.alarms ?? []).map(\.relativeOffset)) rule=\(e.recurrenceRules?.first?.description ?? "-") place=\(e.location ?? "-") note=\(e.notes ?? "-") url=\(e.url?.absoluteString ?? "-")")
            }
        case "teardown":
            for c in mine {
                do { try store.removeCalendar(c, commit: true); appendAppLog("nb.log", "[Test] calendar removed") }
                catch { appendAppLog("nb.log", "[Test] calendar remove failed: \(error.localizedDescription)") }
            }
            reload()
        default: break
        }
    }

    /// Snapshots only: a sample week, as if the calendars had answered (never written anywhere).
    func debugFill() {
        debugFrozen = true
        access = .granted
        let cal = Calendar.current, now = Date.now, today = cal.startOfDay(for: now)
        weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        calendars = [CalCalendar(id: "w", title: "Work", account: "you@gmail.com", color: Color(hex: "#0A84FF"), writable: true),
                     CalCalendar(id: "p", title: "Personal", account: "iCloud", color: Color(hex: "#FF9F0A"), writable: true),
                     CalCalendar(id: "f", title: "Family", account: "iCloud", color: Color(hex: "#30D158"), writable: true)]
        func ev(_ id: String, _ title: String, start: Date, minutes: Double, _ c: String, meet: String? = nil, people: Int = 0, place: String? = nil,
                repeats: Bool = false) -> CalEvent {
            CalEvent(id: id, title: title, start: start, end: start.addingTimeInterval(minutes * 60), allDay: false, calendarID: c,
                     location: place, meeting: meet.flatMap(URL.init(string:)), attendees: people, repeats: repeats)
        }
        events = [
            CalEvent(id: "a", title: "Diwali leave plan", start: today, end: today.addingTimeInterval(86400), allDay: true,
                     calendarID: "p", location: nil, meeting: nil, attendees: 0),
            ev("1", "Inbox zero", start: now.addingTimeInterval(-90 * 60), minutes: 30, "w"),
            ev("2", "IM stand-up", start: now.addingTimeInterval(8 * 60), minutes: 30, "w", meet: "https://zoho.zoom.us/j/123456789?pwd=abc", people: 6, repeats: true),
            ev("3", "MICS tracker review", start: now.addingTimeInterval(4 * 3600), minutes: 60, "w", meet: "https://meet.google.com/abc-defg-hij"),
            ev("4", "Dinner with Priya", start: now.addingTimeInterval(9 * 3600), minutes: 60, "p", place: "Indiranagar"),
            ev("5", "School pickup", start: today.addingTimeInterval(86400 * 2 + 15 * 3600), minutes: 30, "f"),
            ev("6", "Sprint planning", start: today.addingTimeInterval(86400 * 1 + 11 * 3600), minutes: 60, "w"),
        ].sorted { ($0.allDay ? 0 : 1, $0.start) < ($1.allDay ? 0 : 1, $1.start) }
    }
    #endif

    // MARK: Now and next

    /// The next timed event not yet started (or started within the last minute), of the shown calendars.
    func nextEvent(now: Date = .now) -> CalEvent? {
        events.filter { !$0.allDay && $0.start > now.addingTimeInterval(-60) }.min { $0.start < $1.start }
    }
}

extension String {
    /// Nil for an empty string: an event's or a reminder's blank place or note.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
#endif
