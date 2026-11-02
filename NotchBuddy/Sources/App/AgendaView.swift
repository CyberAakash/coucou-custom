#if !APPSTORE
import AppKit
import SwiftUI

// MARK: - Agenda: tasks and calendar in one notch page (coucou-custom fork)
//
// Your day as one list: overdue tasks on top of today, then one timeline where calendar events
// (a coloured bar and a time range, Join on a meeting with a link) and timed tasks (a ring at their
// time) sit together, a "now" line through it; undated tasks folded under No time. The week strip
// marks each day's events (dots) and tasks (a ring). One composer: a line with a length or a
// calendar's #name makes an event, anything else a task; Task / Event (or Tab) overrides it.
// The data stays where it lives: Reminders for tasks (TasksStore), the Mac's calendars for events
// (CalendarStore).

struct AgendaView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var tasks = TasksStore.shared
    @ObservedObject private var calendar = CalendarStore.shared
    @ObservedObject private var taskSettings = TasksSettings.shared
    @ObservedObject private var calSettings = CalendarSettings.shared
    @Environment(\.islandViewActive) private var active

    enum Filter: String, CaseIterable { case all = "All", events = "Events", tasks = "Tasks" }
    enum Kind { case task, event }

    struct UndoNote: Identifiable {
        let id = UUID()
        let text: String
        let action: (() -> Void)?
    }

    /// One line of the day: an event, or a task (timed, all-day, overdue or undated).
    enum Entry: Identifiable {
        case event(CalEvent)
        case task(TaskItem)
        var id: String {
            switch self {
            case .event(let e): "e" + e.id
            case .task(let t): "t" + t.id
            }
        }
        var time: Date {
            switch self {
            case .event(let e): e.start
            case .task(let t): t.due ?? .distantFuture
            }
        }
    }

    @State private var day = Calendar.current.startOfDay(for: .now)
    @State private var filter: Filter = .all
    @State private var showUndated = false
    @State private var text = ""
    @State private var kindOverride: Kind?
    @FocusState private var composing: Bool
    @State private var undo: UndoNote?

    private var tasksOn: Bool { taskSettings.enabled && tasks.access == .granted }
    private var eventsOn: Bool { calSettings.enabled && calendar.access == .granted }

    var body: some View {
        ZStack {
            CardBackground(wash: nil)
            Group {
                if !tasksOn && !eventsOn { permission } else { page }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
            if let undo {
                VStack {
                    Spacer()
                    toast(undo).padding(.bottom, 60)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: undo?.id)
        .onChange(of: active) { _, on in
            if on { day = Calendar.current.startOfDay(for: .now); reload() }
            composing = on
        }
        .onAppear {
            #if DEBUG
            if let sample = KeepDebug.tasksComposerText { text = sample }
            if KeepDebug.agendaTasksOnly { filter = .tasks; showUndated = true }
            #endif
            reload()
        }
    }

    private func reload() {
        calendar.showWeek(of: day)
        calendar.reload()
        tasks.reload()
    }

    // MARK: Permission

    private var permission: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Image(systemName: "calendar.badge.checkmark").font(.system(size: 22, weight: .semibold)).foregroundColor(Color(hex: "#0A84FF"))
            Text("Your day: tasks and calendar together").font(.system(size: 13, weight: .semibold))
            Text("Tasks come from Reminders and events from the calendars on this Mac; nothing leaves it.")
                .font(.system(size: 11.5)).foregroundColor(Color(hex: "#8E939C"))
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            HStack(spacing: 8) {
                accessButton("Reminders", access: tasks.access) { Task { await tasks.requestAccess() } } settings: { tasks.openPrivacySettings() }
                accessButton("Calendars", access: calendar.access) { Task { await calendar.requestAccess() } } settings: { calendar.openPrivacySettings() }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func accessButton(_ name: String, access: TasksStore.Access, ask: @escaping () -> Void, settings: @escaping () -> Void) -> some View {
        switch access {
        case .granted: EmptyView()
        case .unknown: Button("Allow \(name)", action: ask).buttonStyle(HubButtonStyle(primary: true))
        case .denied: Button("\(name) in System Settings", action: settings).buttonStyle(HubButtonStyle())
        }
    }

    @ViewBuilder
    private func accessButton(_ name: String, access: CalendarStore.Access, ask: @escaping () -> Void, settings: @escaping () -> Void) -> some View {
        switch access {
        case .granted: EmptyView()
        case .unknown: Button("Allow \(name)", action: ask).buttonStyle(HubButtonStyle(primary: true))
        case .denied: Button("\(name) in System Settings", action: settings).buttonStyle(HubButtonStyle())
        }
    }

    // MARK: Page

    private var page: some View {
        VStack(alignment: .leading, spacing: 7) {
            weekStrip
            dayHeader
            missingAccess
            list
            composer
        }
    }

    /// One allowed and the other not: a slim line to allow it.
    @ViewBuilder private var missingAccess: some View {
        if taskSettings.enabled && tasks.access != .granted {
            accessLine("Tasks from Reminders are not shown.", button: tasks.access == .denied ? "Open System Settings" : "Allow Reminders") {
                if tasks.access == .denied { tasks.openPrivacySettings() } else { Task { await tasks.requestAccess() } }
            }
        } else if calSettings.enabled && calendar.access != .granted {
            accessLine("Calendar events are not shown.", button: calendar.access == .denied ? "Open System Settings" : "Allow Calendars") {
                if calendar.access == .denied { calendar.openPrivacySettings() } else { Task { await calendar.requestAccess() } }
            }
        }
    }

    private func accessLine(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(text).font(.system(size: 10.5)).foregroundColor(Color(hex: "#8E939C"))
            Button(button, action: action).buttonStyle(.plain).pointer()
                .font(.system(size: 10.5, weight: .semibold)).foregroundColor(Color(hex: "#3B9EFF"))
            Spacer(minLength: 0)
        }
        .padding(.leading, 2)
    }

    // MARK: Week

    private var weekStrip: some View {
        let cal = Calendar.current
        let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: calendar.weekStart) }
        return HStack(spacing: 5) {
            arrow("chevron.left") { move(weeks: -1) }
            ForEach(days, id: \.self) { d in
                let on = cal.isDate(d, inSameDayAs: day)
                let today = cal.isDateInToday(d)
                Button { withAnimation(.easeOut(duration: 0.15)) { day = d } } label: {
                    VStack(spacing: 2) {
                        Text(d.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                            .font(.system(size: 8.5, weight: .heavy)).tracking(0.8)
                            .foregroundColor(on ? Color(hex: "#0B0C0E") : (today ? Color(hex: "#0A84FF") : Color(hex: "#8E939C")))
                        Text(d.formatted(.dateTime.day())).font(.system(size: 14, weight: .bold))
                            .foregroundColor(on ? Color(hex: "#0B0C0E") : Color(hex: "#F5F6F8"))
                        HStack(spacing: 3) {
                            ForEach(Array(eventDots(d).enumerated()), id: \.offset) { _, c in
                                Circle().fill(c).frame(width: 5, height: 5)
                            }
                            if hasTasks(d) {
                                Circle().strokeBorder(on ? Color(hex: "#0B0C0E") : Color(hex: "#C5C8CD"), lineWidth: 1.2)
                                    .frame(width: 5, height: 5)
                            }
                        }
                        .frame(height: 5)
                    }
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
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
                .frame(width: 16, height: 46).contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointer()
    }

    private func move(weeks: Int) {
        guard let d = Calendar.current.date(byAdding: .day, value: 7 * weeks, to: day) else { return }
        day = d
        calendar.showWeek(of: d)
    }

    private func eventDots(_ d: Date) -> [Color] {
        guard eventsOn else { return [] }
        var seen: [String] = []
        for e in events(on: d) where !seen.contains(e.calendarID) { seen.append(e.calendarID) }
        return seen.prefix(3).compactMap { calendar.calendar($0)?.color }
    }

    private func hasTasks(_ d: Date) -> Bool {
        guard tasksOn else { return false }
        return shownTasks.contains { t in t.due.map { Calendar.current.isDate($0, inSameDayAs: d) } ?? false }
    }

    // MARK: The day

    private var shownTasks: [TaskItem] {
        let lists = Set(tasks.shownLists.map(\.id))
        return tasks.items.filter { lists.contains($0.listID) }
    }

    private func events(on d: Date) -> [CalEvent] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: d)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
        return calendar.events.filter { $0.start < end && $0.end > start }
    }

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    /// Overdue tasks (today only), tasks due this day without a time, the timeline, undated tasks.
    private var sections: (overdue: [TaskItem], allDayTasks: [TaskItem], timeline: [Entry], undated: [TaskItem]) {
        let cal = Calendar.current
        let showTasks = tasksOn && filter != .events
        let showEvents = eventsOn && filter != .tasks
        var overdue: [TaskItem] = [], allDay: [TaskItem] = [], timeline: [Entry] = [], undated: [TaskItem] = []
        if showTasks {
            for t in shownTasks {
                guard let due = t.due else { if isToday { undated.append(t) }; continue }
                if TaskGroup.of(t) == .overdue { if isToday { overdue.append(t) }; continue }
                guard cal.isDate(due, inSameDayAs: day) else { continue }
                if t.hasTime { timeline.append(.task(t)) } else { allDay.append(t) }
            }
        }
        if showEvents { timeline += events(on: day).filter { !$0.allDay }.map(Entry.event) }
        timeline.sort { $0.time < $1.time }
        return (overdue, allDay, timeline, undated)
    }

    private var dayHeader: some View {
        let cal = Calendar.current
        let allDayEvents = eventsOn && filter != .tasks ? events(on: day).filter(\.allDay) : []
        let name = isToday ? "TODAY · " : (cal.isDateInTomorrow(day) ? "TOMORROW · " : "")
        return HStack(spacing: 6) {
            Text(name + day.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                .font(.system(size: 8, weight: .heavy)).tracking(1).foregroundColor(Color(hex: "#6B7079"))
                .lineLimit(1)
            ForEach(allDayEvents.prefix(1)) { e in
                let color = calendar.calendar(e.calendarID)?.color ?? .blue
                Text("All day · \(e.title)").font(.system(size: 10, weight: .semibold)).lineLimit(1)
                    .foregroundColor(color).padding(.horizontal, 8).frame(height: 18)
                    .background(Capsule().fill(color.opacity(0.14)))
            }
            Spacer(minLength: 6)
            if isToday && tasksOn && tasks.doneToday > 0 {
                Text("Done today · \(tasks.doneToday)").font(.system(size: 9.5)).foregroundColor(Color(hex: "#6B7079")).fixedSize()
            }
            filterSwitch
        }
        .padding(.leading, 2)
    }

    private var filterSwitch: some View {
        HStack(spacing: 2) {
            ForEach(Filter.allCases, id: \.self) { f in
                Button { withAnimation(.easeOut(duration: 0.15)) { filter = f } } label: {
                    Text(f.rawValue).font(.system(size: 10, weight: .semibold))
                        .foregroundColor(filter == f ? Color(hex: "#F5F6F8") : Color(hex: "#8E939C"))
                        .padding(.horizontal, 9).frame(height: 20)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(filter == f ? Color.white.opacity(0.1) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointer()
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
        .fixedSize()
    }

    private var list: some View {
        let s = sections
        let now = Date.now
        // The now line goes before the first entry that has not ended.
        let nowIndex: Int? = isToday ? (s.timeline.firstIndex { entry in
            switch entry {
            case .event(let e): return e.end > now
            case .task(let t): return (t.due ?? now) > now
            }
        } ?? s.timeline.count) : nil
        let empty = s.overdue.isEmpty && s.allDayTasks.isEmpty && s.timeline.isEmpty && s.undated.isEmpty
        return Group {
            if empty {
                VStack(spacing: 4) {
                    Spacer(minLength: 0)
                    Text(isToday ? "Nothing else today" : "Nothing on this day").font(.system(size: 13, weight: .semibold))
                    Text("Type below: a task, or an event with a length or #calendar.")
                        .font(.system(size: 11.5)).foregroundColor(Color(hex: "#8E939C"))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(s.overdue) { taskRow($0, overdue: true) }
                        ForEach(s.allDayTasks) { taskRow($0, overdue: false) }
                        ForEach(Array(s.timeline.enumerated()), id: \.element.id) { i, entry in
                            if i == nowIndex { nowLine }
                            switch entry {
                            case .event(let e): eventRow(e)
                            case .task(let t): taskRow(t, overdue: false)
                            }
                        }
                        if nowIndex == s.timeline.count, !s.timeline.isEmpty { nowLine }
                        if s.overdue.isEmpty && s.allDayTasks.isEmpty && s.timeline.isEmpty {
                            Text(filter == .tasks ? "No tasks due today" : (filter == .events ? "No events today" : "Nothing scheduled today"))
                                .font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: "#8E939C"))
                                .padding(.leading, 2).padding(.top, 2)
                        }
                        if !s.undated.isEmpty { undatedSection(s.undated) }
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

    private func undatedSection(_ items: [TaskItem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(.easeOut(duration: 0.2)) { showUndated.toggle() } } label: {
                HStack(spacing: 6) {
                    Text("NO TIME · \(items.count)").font(.system(size: 8, weight: .heavy)).tracking(1)
                    Image(systemName: showUndated ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold))
                    Text(showUndated ? "hide" : "show").font(.system(size: 9.5))
                }
                .foregroundColor(Color(hex: "#6B7079"))
                .padding(.leading, 2).padding(.top, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointer()
            if showUndated { ForEach(items) { taskRow($0, overdue: false) } }
        }
    }

    // MARK: Rows

    private func eventRow(_ e: CalEvent) -> some View {
        let now = Date.now
        let cal = calendar.calendar(e.calendarID)
        let color = cal?.color ?? .blue
        let past = e.end <= now
        let soon = e.start > now ? e.start.timeIntervalSince(now) : nil
        let live = e.start <= now && e.end > now
        let canJoin = e.meeting != nil && (live || (soon ?? .infinity) <= 10 * 60)
        let sub = [cal?.title, e.meeting.map(CalendarStore.meetingApp),
                   e.location.flatMap { $0.contains("http") ? nil : $0 },
                   e.attendees > 1 ? "\(e.attendees) people" : nil].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 10) {
            Rectangle().fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(e.start.formatted(date: .omitted, time: .shortened)) – \(e.end.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundColor(Color(hex: "#8E939C"))
                if live {
                    Text("now").font(.system(size: 10, weight: .bold)).foregroundColor(Color(hex: "#67B3FF"))
                } else if let soon, soon <= 60 * 60 {
                    Text("in \(max(1, Int(soon / 60))) min").font(.system(size: 10, weight: .bold)).foregroundColor(Color(hex: "#67B3FF"))
                }
            }
            .frame(width: 104, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if !sub.isEmpty { Text(sub).font(.system(size: 10)).foregroundColor(Color(hex: "#8E939C")).lineLimit(1) }
            }
            Spacer(minLength: 6)
            if canJoin {
                Button("Join") { calendar.join(e) }
                    .buttonStyle(.plain).pointer()
                    .font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                    .padding(.horizontal, 13).frame(height: 26)
                    .background(Capsule().fill(Color(hex: "#0A84FF")))
            }
        }
        .padding(.trailing, 10)
        .frame(minHeight: 36)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(live || canJoin ? Color(hex: "#0A84FF").opacity(0.12) : Color.white.opacity(0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .opacity(past ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture { calendar.openCalendarApp(at: e.start) }
        .pointer()
        .contextMenu {
            if e.meeting != nil { Button("Join") { calendar.join(e) } }
            Button("Open in Calendar") { calendar.openCalendarApp(at: e.start) }
            if let url = e.meeting {
                Button("Copy meeting link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
        }
    }

    private func taskRow(_ t: TaskItem, overdue: Bool) -> some View {
        let list = tasks.list(t.listID)
        let when: String = {
            guard let due = t.due else { return "" }
            if overdue {
                return "Missed " + (t.hasTime && Calendar.current.isDateInToday(due)
                    ? due.formatted(date: .omitted, time: .shortened) : TaskComposer.label(due, hasTime: t.hasTime))
            }
            return t.hasTime ? due.formatted(date: .omitted, time: .shortened) : "All day"
        }()
        let sub = [when.isEmpty ? nil : when, list?.title].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 10) {
            Button { complete(t) } label: {
                Circle().strokeBorder(overdue ? Color(hex: "#F4505E") : (list?.color ?? Color(hex: "#6B7079")), lineWidth: 1.6)
                    .frame(width: 13, height: 13).contentShape(Circle())
            }
            .buttonStyle(.plain).pointer().help("Done")
            Text(t.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 6)
            Text(sub).font(.system(size: 10, weight: .medium))
                .foregroundColor(overdue ? Color(hex: "#F4505E") : Color(hex: "#8E939C")).lineLimit(1).fixedSize()
        }
        .padding(.leading, 13).padding(.trailing, 10)
        .frame(minHeight: 30)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(overdue ? Color(hex: "#F4505E").opacity(0.08) : Color.clear))
        .contextMenu {
            Menu("Move to list") {
                ForEach(tasks.lists) { l in
                    Button { tasks.move(t.id, to: l.id) } label: {
                        if l.id == t.listID { Label(l.title, systemImage: "checkmark") } else { Text(l.title) }
                    }
                }
            }
            Menu("Time") {
                Button("In an hour") { tasks.setDue(t.id, Date().addingTimeInterval(3600), hasTime: true) }
                Button("Tomorrow morning") {
                    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now)) ?? .now
                    tasks.setDue(t.id, Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow), hasTime: true)
                }
                Button("Today") { tasks.setDue(t.id, Calendar.current.startOfDay(for: .now), hasTime: false) }
                Button("No time") { tasks.setDue(t.id, nil, hasTime: false) }
            }
            Divider()
            Button("Open in Reminders") { tasks.openReminders() }
            Button("Delete", role: .destructive) {
                tasks.delete(t.id)
                say("Deleted · \(t.title)") { tasks.add(title: t.title, due: t.due, hasTime: t.hasTime, listID: t.listID) }
            }
        }
    }

    private func complete(_ t: TaskItem) {
        tasks.setDone(t.id, true)
        say("Done · \(t.title)") { tasks.setDone(t.id, false) }
    }

    // MARK: Composer

    private var parsedTask: ParsedTask {
        TaskComposer.parse(text, lists: tasks.lists.map { (id: $0.id, title: $0.title) })
    }

    private var parsedEvent: ParsedEvent {
        CalendarComposer.parse(text, calendars: calendar.calendars.filter(\.writable).map { (id: $0.id, title: $0.title) })
    }

    /// An event when a length was typed or the #name is a calendar's and not a list's; the filter
    /// shown leans it; Task / Event (or Tab) overrides all of it.
    private var kind: Kind {
        if let kindOverride { return kindOverride }
        if !eventsOn { return .task }
        if !tasksOn { return .event }
        let e = parsedEvent, t = parsedTask
        if e.hasLength || (e.calendarID != nil && t.listID == nil) { return .event }
        if filter == .events { return .event }
        return .task
    }

    private var composer: some View {
        let k = kind
        let t = parsedTask, e = parsedEvent
        let ready = k == .task ? !t.title.isEmpty : (!e.title.isEmpty && e.start != nil)
        let typing = !text.trimmingCharacters(in: .whitespaces).isEmpty
        return VStack(alignment: .leading, spacing: 5) {
            if typing {
                HStack(spacing: 6) {
                    Text(ready ? "Will add" : (k == .event ? "Add a day or a time" : "Type a task")).font(.system(size: 9.5)).foregroundColor(Color(hex: "#6B7079"))
                    if tasksOn && eventsOn { kindSwitch(k) }
                    if k == .task {
                        chip(t.due.map { TaskComposer.label($0, hasTime: t.hasTime) } ?? "No time", accent: t.due != nil)
                        if let l = t.listID.flatMap(tasks.list) ?? tasks.newTaskList { colourChip(l.title, l.color) }
                    } else {
                        if let label = CalendarComposer.label(e) { chip(label, accent: true) }
                        if let c = e.calendarID.flatMap(calendar.calendar) ?? calendar.newEventCalendar { colourChip(c.title, c.color) }
                    }
                }
                .padding(.leading, 2)
                .transition(.opacity)
            }
            HStack(spacing: 8) {
                TextField(tasksOn && eventsOn ? "Add a task, or an event with a length or #calendar…" : (eventsOn ? "Add an event…" : "Add a task…"), text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focusEffectDisabled()   // the capsule's border already shows focus
                    .focused($composing)
                    .onSubmit(add)
                    .onKeyPress(.tab) {
                        guard tasksOn && eventsOn, typing else { return .ignored }
                        kindOverride = kind == .task ? .event : .task
                        return .handled
                    }
                    .onChange(of: text) { _, new in if new.isEmpty { kindOverride = nil } }
                Button(action: add) {
                    Text("Return").font(.system(size: 10, weight: .heavy)).foregroundColor(Color(hex: "#04161A"))
                        .padding(.horizontal, 10).frame(height: 22)
                        .background(Capsule().fill(Color(hex: "#22D3EE").opacity(ready ? 1 : 0.35)))
                }
                .buttonStyle(.plain).pointer(ready).disabled(!ready)
            }
            .padding(.leading, 14).padding(.trailing, 6)
            .frame(height: 32)
            .background(Capsule().fill(Color(hex: "#1F2024")))
            .overlay(Capsule().strokeBorder(Color(hex: "#22D3EE").opacity(composing ? 0.45 : 0.12)))
        }
        .animation(.easeOut(duration: 0.15), value: typing)
    }

    private func kindSwitch(_ k: Kind) -> some View {
        HStack(spacing: 2) {
            ForEach([Kind.task, .event], id: \.self) { option in
                Button { kindOverride = option } label: {
                    Text(option == .task ? "Task" : "Event").font(.system(size: 10, weight: .bold))
                        .foregroundColor(k == option ? (option == .event ? Color(hex: "#CFE5FF") : Color(hex: "#F5F6F8")) : Color(hex: "#8E939C"))
                        .padding(.horizontal, 8).frame(height: 18)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(k == option ? (option == .event ? Color(hex: "#0A84FF").opacity(0.3) : Color.white.opacity(0.12)) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointer()
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.3)))
        .help("Tab switches")
    }

    private func chip(_ text: String, accent: Bool) -> some View {
        Text(text).font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(accent ? Color(hex: "#67E8F9") : Color(hex: "#8E939C"))
            .padding(.horizontal, 9).frame(height: 20)
            .background(Capsule().fill(accent ? Color(hex: "#22D3EE").opacity(0.14) : Color.white.opacity(0.06)))
    }

    private func colourChip(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundColor(Color(hex: "#C5C8CD"))
        }
        .padding(.horizontal, 9).frame(height: 20)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }

    private func add() {
        if kind == .task {
            let p = parsedTask
            guard !p.title.isEmpty else { return }
            let list = p.listID.flatMap(tasks.list) ?? tasks.newTaskList
            if let id = tasks.add(title: p.title, due: p.due, hasTime: p.hasTime, listID: list?.id) {
                text = ""
                if let due = p.due { day = Calendar.current.startOfDay(for: due); calendar.showWeek(of: day) }
                let when = p.due.map { " · " + TaskComposer.label($0, hasTime: p.hasTime) } ?? ""
                say("Task added to \(list?.title ?? "Reminders")\(when)") { tasks.delete(id) }
            } else {
                say("Reminders didn't take it; try again", undo: nil)
            }
        } else {
            let p = parsedEvent
            guard !p.title.isEmpty, let start = p.start, let end = p.end else { return }
            let target = p.calendarID.flatMap(calendar.calendar) ?? calendar.newEventCalendar
            if let id = calendar.add(title: p.title, start: start, end: end, allDay: p.allDay, calendarID: target?.id) {
                text = ""
                day = Calendar.current.startOfDay(for: start)
                calendar.showWeek(of: day)
                say("Event added to \(target?.title ?? "your calendar") · \(CalendarComposer.label(p) ?? "")") { calendar.delete(eventIdentifier: id) }
            } else {
                say("The calendar didn't take it; try another calendar", undo: nil)
            }
        }
    }

    // MARK: Undo

    private func say(_ text: String, undo action: (() -> Void)?) {
        let note = UndoNote(text: text, action: action)
        undo = note
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if undo?.id == note.id { undo = nil } }
    }

    private func toast(_ note: UndoNote) -> some View {
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
