#if !APPSTORE
import AppKit
import SwiftUI

// MARK: - The Join card (coucou-custom fork, roadmap phase 3)
//
// When a meeting with a Zoom, Meet, Teams or Webex link starts (or the minutes before it chosen in
// Settings → Calendar), a card hangs below the notch: Join opens it, In 5 min asks again, Dismiss
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
