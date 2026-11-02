#if !APPSTORE
import AppKit
import SwiftUI

// MARK: - The Join card (coucou-custom fork, roadmap phase 3)
//
// When a meeting with a Zoom, Meet, Teams or Webex link starts (or the minutes before it chosen in
// Settings → Agenda → Calendar), a card hangs below the notch: Join opens it, In 5 min asks again, Dismiss
// closes it. It waits while another card is open and never shows twice for the same meeting.

@MainActor
final class MeetingWatcher: ObservableObject {
    static let shared = MeetingWatcher()

    @Published private(set) var current: CalEvent?
    private var announced: Set<String> = []
    private var snoozed: [String: Date] = [:]
    private var timer: Timer?

    private init() {}

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            MainActor.assumeIsolated { MeetingWatcher.shared.tick() }
        }
        timer?.tolerance = 3
    }

    func tick(now: Date = .now) {
        let settings = CalendarSettings.shared
        let store = CalendarStore.shared
        guard settings.enabled, settings.join, store.access == .granted else { return }
        let lead = TimeInterval(settings.joinLead * 60)
        let due = store.events.filter { e in
            guard e.meeting != nil, !e.allDay, !announced.contains(e.id) else { return false }
            if let until = snoozed[e.id] { return now >= until }
            // From the chosen lead until ten minutes in: a late Mac still offers it.
            return now >= e.start.addingTimeInterval(-lead) && now < e.start.addingTimeInterval(10 * 60)
        }
        guard let e = due.min(by: { $0.start < $1.start }) else { return }
        let state = AppState.shared
        // Another card is open: try again on the next tick.
        guard state.mode != .expanded || state.view == .meeting else { return }
        announced.insert(e.id)
        snoozed[e.id] = nil
        current = e
        appendAppLog("nb.log", "[Calendar] meeting card: \(e.title)")
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.meeting)
    }

    func join() {
        if let e = current { CalendarStore.shared.join(e) }
        close()
    }

    func snooze() {
        if let e = current {
            announced.remove(e.id)
            snoozed[e.id] = Date.now.addingTimeInterval(5 * 60)
        }
        close()
    }

    func close() {
        current = nil
        NotificationCenter.default.post(name: .islandCollapse, object: nil)
    }

    #if DEBUG
    /// Snapshots only: the card for a sample meeting, without opening the island.
    func debugShow(_ e: CalEvent) { current = e }
    #endif
}

// MARK: - Event alerts (coucou-custom fork, roadmap phase 3)
//
// Every timed event gets a card at its own alert times (as set in Calendar, or "alert 10m" in the
// Agenda), or the chosen minutes before when it has none, shown where Settings → Agenda →
// Calendar says (the Buddy's card, the notch, the full screen), with In 5 min, Dismiss and Open
// (Join for a meeting link). A meeting with a link and the Join card on is the Join card's.
// All-day events get one card at 9 AM. Nothing from before launch is raised again.

@MainActor
final class EventAlerts {
    static let shared = EventAlerts()

    /// "event id@seconds before": one card per alert of each occurrence.
    private var fired: Set<String> = []
    private var snoozed: [String: Date] = [:]
    /// Events of the alerts shown, to open them from the card after the week shown changed.
    private var known: [String: CalEvent] = [:]
    private var startedAt = Date.now
    private var timer: Timer?

    private init() {}

    func start() {
        guard timer == nil else { return }
        startedAt = .now
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated { EventAlerts.shared.tick() }
        }
        timer?.tolerance = 3
    }

    /// The alert times of one event: its own, else the default minutes, none when that is off.
    static func offsets(_ e: CalEvent, defaultMinutes: Int) -> [TimeInterval] {
        if !e.alertOffsets.isEmpty { return Array(Set(e.alertOffsets)).sorted() }
        return defaultMinutes >= 0 ? [TimeInterval(defaultMinutes * 60)] : []
    }

    /// The cards due at `now`: an alert time passed since launch, and the event not over.
    static func due(_ events: [CalEvent], now: Date, since: Date, defaultMinutes: Int, joinCardTakes: Bool,
                    fired: Set<String>) -> [(event: CalEvent, key: String, before: TimeInterval)] {
        var out: [(event: CalEvent, key: String, before: TimeInterval)] = []
        for e in events where !e.allDay && e.end > now {
            if joinCardTakes && e.meeting != nil { continue }
            for before in offsets(e, defaultMinutes: defaultMinutes) {
                let at = e.start.addingTimeInterval(-before)
                let key = e.id + "@\(Int(before))"
                guard now >= at, at >= since.addingTimeInterval(-60), !fired.contains(key) else { continue }
                out.append((e, key, before))
            }
        }
        return out
    }

    func tick(now: Date = .now) {
        let settings = CalendarSettings.shared
        let store = CalendarStore.shared
        guard settings.enabled, settings.alerts, store.access == .granted else { return }
        var shown = Set<String>()
        for (e, key, _) in Self.due(store.events, now: now, since: startedAt, defaultMinutes: settings.alertLead,
                                    joinCardTakes: settings.join, fired: fired) {
            fired.insert(key)
            // Several alerts of one event passed together (the Mac was asleep): one card.
            if shown.insert(e.id).inserted { show(e, now: now) }
        }
        for (id, at) in snoozed where now >= at {
            snoozed[id] = nil
            if let e = store.events.first(where: { $0.id == id }) ?? known[id], e.end > now { show(e, now: now) }
        }
        // All-day events: one card from 9 AM, once a day.
        let cal = Calendar.current
        let dayKey = "allday@\(cal.startOfDay(for: now).timeIntervalSince1970)"
        if settings.allDayCard, cal.component(.hour, from: now) >= 9, !fired.contains(dayKey) {
            let today = store.events.filter { $0.allDay && cal.isDate($0.start, inSameDayAs: now) || ($0.allDay && $0.start <= now && $0.end > now) }
            let nineToday = cal.date(bySettingHour: 9, minute: 0, second: 0, of: now) ?? now
            fired.insert(dayKey)
            // Launched after 9: only if it is still the morning, so a late start is not a surprise.
            if !today.isEmpty, startedAt <= nineToday.addingTimeInterval(3 * 3600) {
                let titles = today.map(\.title)
                appendAppLog("nb.log", "[Calendar] all-day card: \(titles.count)")
                BuddyRoutineController.shared.raiseEvent(BuddyAlert(kind: .event(id: "allday"), title: "Today",
                                                                     detail: titles.prefix(3).joined(separator: " · ")))
            }
        }
    }

    private func show(_ e: CalEvent, now: Date) {
        known[e.id] = e
        let minutes = Int((e.start.timeIntervalSince(now) / 60).rounded(.up))
        let when = minutes <= 0 ? "now" : "in \(minutes) min"
        let store = CalendarStore.shared
        let detail = ["\(e.start.formatted(date: .omitted, time: .shortened)) – \(e.end.formatted(date: .omitted, time: .shortened))",
                      e.location, store.calendar(e.calendarID)?.title].compactMap { $0 }.joined(separator: " · ")
        appendAppLog("nb.log", "[Calendar] event alert: \(when)")
        BuddyRoutineController.shared.raiseEvent(BuddyAlert(kind: .event(id: e.id), title: "\(e.title) · \(when)", detail: detail))
    }

    func snooze(_ id: String, minutes: Int) {
        guard id != "preview", id != "allday" else { return }
        snoozed[id] = Date.now.addingTimeInterval(TimeInterval(minutes * 60))
    }

    func hasMeeting(_ id: String) -> Bool { event(id)?.meeting != nil }

    /// Join for a meeting link, else Calendar at the event's day.
    func open(_ id: String) {
        let store = CalendarStore.shared
        if id == "allday" { store.openCalendarApp(at: .now); return }
        guard let e = event(id) else { return }
        if e.meeting != nil { store.join(e) } else { store.openCalendarApp(at: e.start) }
    }

    private func event(_ id: String) -> CalEvent? { CalendarStore.shared.events.first { $0.id == id } ?? known[id] }

    /// Settings' Test alert: the card for a sample event starting in 10 minutes, where it is set
    /// to show; its buttons do nothing.
    func test() {
        let now = Date.now
        show(CalEvent(id: "preview", title: "Design review", start: now.addingTimeInterval(600), end: now.addingTimeInterval(4200),
                      allDay: false, calendarID: "", location: "Room 4", meeting: nil, attendees: 0), now: now)
    }
}

/// The card: Mochi sits on the left (the island's, as on the routine card); the meeting, then the buttons.
struct MeetingCard: View {
    @ObservedObject private var watcher = MeetingWatcher.shared
    @ObservedObject private var store = CalendarStore.shared

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: .indigo)
            if let e = watcher.current {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(e.title) · \(e.start <= .now ? "starting now" : "in \(max(1, Int(e.start.timeIntervalSinceNow / 60))) min")")
                            .font(.system(size: 13.5, weight: .bold)).lineLimit(1)
                        Text(detail(e)).font(.system(size: 11.5)).foregroundColor(Color(hex: "#B7BBC2")).lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        SecondaryButton("In 5 min") { watcher.snooze() }
                        SecondaryButton("Dismiss") { watcher.close() }
                        Spacer(minLength: 0)
                        Button { watcher.join() } label: {
                            Text("Join \(e.meeting.map(CalendarStore.meetingApp) ?? "")")
                                .font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                                .padding(.horizontal, 16).frame(height: 30)
                                .background(Capsule().fill(Color(hex: "#0A84FF")))
                        }
                        .buttonStyle(.plain).pointer()
                    }
                }
                .padding(.leading, 116)
                .padding(.trailing, 16)
            }
        }
    }

    private func detail(_ e: CalEvent) -> String {
        let time = "\(e.start.formatted(date: .omitted, time: .shortened)) – \(e.end.formatted(date: .omitted, time: .shortened))"
        return [time, e.meeting.map(CalendarStore.meetingApp), store.calendar(e.calendarID)?.title,
                e.attendees > 1 ? "\(e.attendees) people" : nil].compactMap { $0 }.joined(separator: " · ")
    }
}
#endif
