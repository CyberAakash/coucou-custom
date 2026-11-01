#if !APPSTORE
import AppKit
import SwiftUI

// MARK: - The Calendar page in the notch (coucou-custom fork, roadmap phase 3)
//
// The week as a strip of days with each calendar's dots, the chosen day's agenda (all-day events
// on top, a "now" line, a Join button on a meeting about to start), and the composer: type an
// event with a day, a time, "for 30 min" and #calendar; Return adds it, with Undo.

struct CalendarView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var store = CalendarStore.shared
    @Environment(\.islandViewActive) private var active

    @State private var day = Calendar.current.startOfDay(for: .now)
    @State private var text = ""
    @FocusState private var composing: Bool
    @State private var undo: TasksView.UndoNote?

    var body: some View {
        ZStack {
            CardBackground(wash: nil)
            Group {
                switch store.access {
                case .granted: page
                case .unknown: permission(denied: false)
                case .denied: permission(denied: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
            if let undo {
                VStack {
                    Spacer()
                    toast(undo).padding(.bottom, 62)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: undo?.id)
        .onChange(of: active) { _, on in
            if on { day = Calendar.current.startOfDay(for: .now); store.showWeek(of: day); store.reload() }
            composing = on
        }
        .onAppear {
            #if DEBUG
            if let sample = KeepDebug.tasksComposerText { text = sample }
            #endif
            store.showWeek(of: day)
            store.reload()
        }
    }

    // MARK: Permission

    private func permission(denied: Bool) -> some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Image(systemName: "calendar").font(.system(size: 22, weight: .semibold)).foregroundColor(Color(hex: "#0A84FF"))
            Text(denied ? "Coucou can't read your calendars" : "Your day, from your calendars")
                .font(.system(size: 13, weight: .semibold))
            Text(denied ? "Allow Coucou in System Settings → Privacy & Security → Calendars."
                        : "iCloud, Google and Exchange calendars added on this Mac show here; nothing leaves it.")
                .font(.system(size: 11.5)).foregroundColor(Color(hex: "#8E939C"))
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 400)
            Button(denied ? "Open System Settings" : "Allow access to Calendars") {
                if denied { store.openPrivacySettings() } else { Task { await store.requestAccess() } }
            }
            .buttonStyle(HubButtonStyle(primary: true))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Page

    private var page: some View {
        VStack(alignment: .leading, spacing: 8) {
            weekStrip
            dayHeader
            agenda
            composer
        }
    }

    private var weekStrip: some View {
        let cal = Calendar.current
        let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: store.weekStart) }
        return HStack(spacing: 6) {
            arrow("chevron.left") { move(weeks: -1) }
            ForEach(days, id: \.self) { d in
                let on = cal.isDate(d, inSameDayAs: day)
                let today = cal.isDateInToday(d)
                Button { withAnimation(.easeOut(duration: 0.15)) { day = d } } label: {
                    VStack(spacing: 2) {
                        Text(d.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                            .font(.system(size: 8.5, weight: .heavy)).tracking(0.8)
                            .foregroundColor(on ? Color(hex: "#0B0C0E") : (today ? Color(hex: "#0A84FF") : Color(hex: "#8E939C")))
                        Text(d.formatted(.dateTime.day()))
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(on ? Color(hex: "#0B0C0E") : Color(hex: "#F5F6F8"))
                        HStack(spacing: 3) {
                            ForEach(Array(dots(on: d).enumerated()), id: \.offset) { _, c in
                                Circle().fill(c).frame(width: 5, height: 5)
                            }
                        }
                        .frame(height: 5)
                    }
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(on ? Color(hex: "#F5F6F8") : Color.white.opacity(0.04)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointer()
            }
            arrow("chevron.right") { move(weeks: 1) }
        }
    }

    private func arrow(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundColor(Color(hex: "#8E939C"))
                .frame(width: 18, height: 50).contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointer()
    }

    private func move(weeks: Int) {
        guard let d = Calendar.current.date(byAdding: .day, value: 7 * weeks, to: day) else { return }
        day = d
        store.showWeek(of: d)
    }

    /// Up to four dots: the colours of the day's events, one per calendar.
    private func dots(on d: Date) -> [Color] {
        var seen: [String] = []
        for e in events(on: d) where !seen.contains(e.calendarID) { seen.append(e.calendarID) }
        return seen.prefix(4).compactMap { store.calendar($0)?.color }
    }

    private func events(on d: Date) -> [CalEvent] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: d)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
        return store.events.filter { $0.start < end && $0.end > start }
    }

    private var dayHeader: some View {
        let cal = Calendar.current
        let allDay = events(on: day).filter(\.allDay)
        let name = cal.isDateInToday(day) ? "TODAY · " : (cal.isDateInTomorrow(day) ? "TOMORROW · " : "")
        return HStack(spacing: 6) {
            Text(name + day.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                .font(.system(size: 8, weight: .heavy)).tracking(1).foregroundColor(Color(hex: "#6B7079"))
            Spacer(minLength: 6)
            ForEach(allDay.prefix(2)) { e in
                let color = store.calendar(e.calendarID)?.color ?? .blue
                Text("All day · \(e.title)").font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                    .foregroundColor(color)
                    .padding(.horizontal, 9).frame(height: 20)
                    .background(Capsule().fill(color.opacity(0.14)))
            }
            Button("Open Calendar") { store.openCalendarApp(at: day) }
                .buttonStyle(.plain).pointer()
                .font(.system(size: 10, weight: .semibold)).foregroundColor(Color(hex: "#3B9EFF")).fixedSize()
        }
        .padding(.leading, 2)
    }

    private var agenda: some View {
        let timed = events(on: day).filter { !$0.allDay }
        let now = Date.now
        let isToday = Calendar.current.isDateInToday(day)
        // The "now" line goes before the first event that has not ended.
        let nowIndex = isToday ? (timed.firstIndex { $0.end > now } ?? timed.count) : nil
        return Group {
            if timed.isEmpty {
                VStack(spacing: 4) {
                    Spacer(minLength: 0)
                    Text(isToday ? "Nothing else today" : "Nothing on this day").font(.system(size: 13, weight: .semibold))
                    Text("Type an event below: a day, a time and #calendar are picked up.")
                        .font(.system(size: 11.5)).foregroundColor(Color(hex: "#8E939C"))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(timed.enumerated()), id: \.element.id) { i, e in
                            if i == nowIndex { nowLine }
                            row(e)
                        }
                        if nowIndex == timed.count { nowLine }
                    }
                    .padding(.bottom, 2)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var nowLine: some View {
        HStack(spacing: 6) {
            Circle().fill(Color(hex: "#F4505E")).frame(width: 7, height: 7)
            Rectangle().fill(Color(hex: "#F4505E")).frame(height: 1.5)
            Text(Date.now.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 9.5, weight: .bold)).foregroundColor(Color(hex: "#F4505E"))
        }
        .padding(.vertical, 1)
    }

    private func row(_ e: CalEvent) -> some View {
        let now = Date.now
        let cal = store.calendar(e.calendarID)
        let color = cal?.color ?? .blue
        let past = e.end <= now
        let soon = e.start > now ? e.start.timeIntervalSince(now) : nil
        let live = e.start <= now && e.end > now
        let canJoin = e.meeting != nil && (live || (soon ?? .infinity) <= 10 * 60)
        let sub = [cal?.title, e.meeting.map(CalendarStore.meetingApp), e.location.flatMap { $0.contains("http") ? nil : $0 },
                   e.attendees > 1 ? "\(e.attendees) people" : nil].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 10) {
            Rectangle().fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(e.start.formatted(date: .omitted, time: .shortened)) – \(e.end.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit()).foregroundColor(Color(hex: "#8E939C"))
                if live {
                    Text("now").font(.system(size: 10.5, weight: .bold)).foregroundColor(Color(hex: "#67B3FF"))
                } else if let soon, soon <= 60 * 60 {
                    Text("in \(max(1, Int(soon / 60))) min").font(.system(size: 10.5, weight: .bold)).foregroundColor(Color(hex: "#67B3FF"))
                }
            }
            .frame(width: 112, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                if !sub.isEmpty { Text(sub).font(.system(size: 10.5)).foregroundColor(Color(hex: "#8E939C")).lineLimit(1) }
            }
            Spacer(minLength: 6)
            if canJoin {
                Button("Join") { store.join(e) }
                    .buttonStyle(.plain).pointer()
                    .font(.system(size: 11.5, weight: .bold)).foregroundColor(.white)
                    .padding(.horizontal, 14).frame(height: 28)
                    .background(Capsule().fill(Color(hex: "#0A84FF")))
            }
        }
        .padding(.trailing, 10)
        .frame(minHeight: 40)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(live || canJoin ? Color(hex: "#0A84FF").opacity(0.12) : Color.white.opacity(0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .opacity(past ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture { store.openCalendarApp(at: e.start) }
        .pointer()
        .contextMenu {
            if e.meeting != nil { Button("Join") { store.join(e) } }
            Button("Open in Calendar") { store.openCalendarApp(at: e.start) }
            if let url = e.meeting {
                Button("Copy meeting link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
        }
    }

    // MARK: Composer

    private var parsed: ParsedEvent {
        CalendarComposer.parse(text, calendars: store.calendars.filter(\.writable).map { (id: $0.id, title: $0.title) })
    }

    private func target(_ p: ParsedEvent) -> CalCalendar? {
        p.calendarID.flatMap(store.calendar) ?? store.newEventCalendar
    }

    private var composer: some View {
        let p = parsed
        let t = target(p)
        let ready = !p.title.isEmpty && p.start != nil
        return VStack(alignment: .leading, spacing: 5) {
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                HStack(spacing: 6) {
                    Text(ready ? "Will add" : "Add a day or a time").font(.system(size: 9.5)).foregroundColor(Color(hex: "#6B7079"))
                    if let label = CalendarComposer.label(p) {
                        Text(label).font(.system(size: 10.5, weight: .semibold)).foregroundColor(Color(hex: "#67E8F9"))
                            .padding(.horizontal, 9).frame(height: 20)
                            .background(Capsule().fill(Color(hex: "#22D3EE").opacity(0.14)))
                    }
                    if let t {
                        HStack(spacing: 5) {
                            Circle().fill(t.color).frame(width: 7, height: 7)
                            Text(t.title).font(.system(size: 10.5, weight: .semibold)).foregroundColor(Color(hex: "#C5C8CD"))
                        }
                        .padding(.horizontal, 9).frame(height: 20)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                    }
                }
                .padding(.leading, 2)
                .transition(.opacity)
            }
            HStack(spacing: 8) {
                TextField("Add an event to \(t?.title ?? "your calendar")…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focusEffectDisabled()   // the capsule's border already shows focus
                    .focused($composing)
                    .onSubmit(add)
                Button(action: add) {
                    Text("Return").font(.system(size: 10.5, weight: .heavy))
                        .foregroundColor(Color(hex: "#04161A"))
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(Capsule().fill(Color(hex: "#22D3EE").opacity(ready ? 1 : 0.35)))
                }
                .buttonStyle(.plain).pointer(ready)
                .disabled(!ready)
            }
            .padding(.leading, 14).padding(.trailing, 6)
            .frame(height: 34)
            .background(Capsule().fill(Color(hex: "#1F2024")))
            .overlay(Capsule().strokeBorder(Color(hex: "#22D3EE").opacity(composing ? 0.45 : 0.12)))
            Text("Type an event; a day, a time, \"for 30 min\" and #calendar are picked up. Return adds it.")
                .font(.system(size: 9.5)).foregroundColor(Color(hex: "#6B7079")).lineLimit(1).padding(.horizontal, 4)
        }
        .animation(.easeOut(duration: 0.15), value: text.isEmpty)
    }

    private func add() {
        let p = parsed
        guard !p.title.isEmpty, let start = p.start, let end = p.end else { return }
        let t = target(p)
        if let id = store.add(title: p.title, start: start, end: end, allDay: p.allDay, calendarID: t?.id) {
            text = ""
            day = Calendar.current.startOfDay(for: start)
            store.showWeek(of: day)
            say("Added to \(t?.title ?? "your calendar") · \(CalendarComposer.label(p) ?? "")") { store.delete(eventIdentifier: id) }
        } else {
            say("The calendar didn't take it; try another calendar", undo: nil)
        }
    }

    private func say(_ text: String, undo action: (() -> Void)?) {
        let note = TasksView.UndoNote(text: text, action: action)
        undo = note
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if undo?.id == note.id { undo = nil } }
    }

    private func toast(_ note: TasksView.UndoNote) -> some View {
        HStack(spacing: 10) {
            Text(note.text).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
            if let action = note.action {
                Button("Undo") { action(); undo = nil }
                    .buttonStyle(.plain).pointer()
                    .font(.system(size: 11.5, weight: .bold)).foregroundColor(Color(hex: "#22D3EE"))
            }
        }
        .padding(.horizontal, 14).frame(height: 30)
        .background(Capsule().fill(Color(hex: "#24262B")))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
    }
}
#endif
