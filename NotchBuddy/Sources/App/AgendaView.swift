#if !APPSTORE
import AppKit
import SwiftUI

// MARK: - Agenda: tasks and calendar in one notch page (coucou-custom fork)
//
// Your day as one list: overdue tasks on top of today, then one timeline where calendar events
// (a coloured bar and a time range, Join on a meeting with a link) and timed tasks (a ring at their
// time) sit together, a "now" line through it; undated tasks folded under No time. The week strip
// marks each day's events (dots) and tasks (a ring). One composer: a line is a task unless it says
// /event (or /e), or you pick Event or press Tab; a length only suggests an event.
// The data stays where it lives: Reminders for tasks (TasksStore), the Mac's calendars for events
// (CalendarStore).

struct AgendaView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var tasks = TasksStore.shared
    @ObservedObject private var calendar = CalendarStore.shared
    @ObservedObject private var taskSettings = TasksSettings.shared
    @ObservedObject private var calSettings = CalendarSettings.shared
    @ObservedObject private var composerSettings = AgendaComposerSettings.shared
    @Environment(\.islandViewActive) private var active

    enum Filter: String, CaseIterable { case all = "All", events = "Events", tasks = "Tasks" }

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
    @State private var kindOverride: AgendaKind?
    /// The suggestions menu: what opened it when not the word being typed, the row chosen, and
    /// Escape closing it until the line changes.
    enum MenuSource: Equatable { case slash(AgendaSuggest.ChoiceSet), chip(AgendaSuggest.ChoiceSet), groupChip }
    @State private var menuSource: MenuSource?
    @State private var menuRow = 0
    @State private var menuClosed = false
    @State private var helpOpen = false
    @State private var detailsOpen = false
    /// A chip's ×: that piece stays plain title text for this line.
    @State private var skipDate = false
    @State private var skipTag = false
    @State private var skipPieces: Set<AgendaExtras.Piece> = []
    @FocusState private var composing: Bool
    @State private var undo: UndoNote?
    /// The row under the pointer: it lifts and shows its quick actions.
    @State private var hoverRow: String?
    /// The task whose Later choices are open in its row (they stay when the pointer leaves).
    @State private var laterRow: String?

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
        #if DEBUG
        // `debug.agendaDump`: the composer's state in nb.log, to check the keys from a terminal.
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("fr.louisraille.NotchBuddy.debug.agendaDump"))) { _ in
            let menu = menuItems?.map(\.title).joined(separator: "|") ?? "-"
            appendAppLog("nb.log", "[Agenda] text='\(text)' kind=\(kind) menu=[\(menu)] row=\(menuRow) help=\(helpOpen) focus=\(composing) skipDate=\(skipDate) key=\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "none")")
        }
        // `debug.agendaTest` "setup|dump|tick|deleteundo|teardown" on the test list and calendar;
        // `debug.agendaType` "line" puts a line in the composer; `debug.agendaSubmit` adds it.
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("fr.louisraille.NotchBuddy.debug.agendaTest"))) { note in
            let action = note.object as? String ?? ""
            tasks.debugTest(action)
            calendar.debugTest(action)
            if action == "teardown" {
                // The test events' alert cards still waiting go too.
                let routines = BuddyRoutineController.shared
                for a in routines.alerts where a.title.hasPrefix("Coucou ") { routines.dismiss(a) }
                if RoutineNotchModel.shared.moment?.alert?.title.hasPrefix("Coucou ") == true { RoutineNotchModel.shared.close() }
            }
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("fr.louisraille.NotchBuddy.debug.agendaType"))) { note in
            text = note.object as? String ?? ""
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("fr.louisraille.NotchBuddy.debug.agendaSubmit"))) { _ in
            appendAppLog("nb.log", "[Agenda] submit '\(text)' as \(kind)")
            add()
        }
        // `debug.agendaDetail` "name": what a Details control does, by name (the clicks a terminal can't make).
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("fr.louisraille.NotchBuddy.debug.agendaDetail"))) { note in
            let x = extras
            switch note.object as? String ?? "" {
            case "weekly": set(AgendaLine.repeating(AgendaRepeat(frequency: .weekly)), at: range(of: .repeating))
            case "thu": var r = x.repeating ?? AgendaRepeat(frequency: .weekly); r.weekdays = (r.weekdays + [5]).sorted(); set(AgendaLine.repeating(r), at: range(of: .repeating))
            case "never": set(nil, at: range(of: .repeating))
            case "until": var r = x.repeating ?? AgendaRepeat(frequency: .weekly); r.until = Calendar.current.date(from: DateComponents(year: 2027, month: 3, day: 1)); set(AgendaLine.repeating(r), at: range(of: .repeating))
            case "alert": set(AgendaLine.alerts(x.alerts + [600]), at: range(of: .alerts))
            case "priority": set(AgendaLine.priority(3), at: range(of: .priority))
            case "place": set("@Office 2", at: range(of: .place))
            case "note": text = withCommand(AgendaLine.put("// call first", at: range(of: .note), in: command.rest, before: nil))
            case "group": if let g = groups.last { set("#" + (TaskComposer.tag(for: g.id, in: groups) ?? ""), at: pieces.tag) }
            case "date": set(AgendaLine.date(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 16, minute: 30))!, hasTime: true), at: pieces.date)
            case "allday": if let d = parsedTask.due { set(AgendaLine.date(d, hasTime: false), at: pieces.date) }
            default: break
            }
        }
        // `debug.composerEdit` "standup" | "" | "help": the template editor open in the next hub snapshot.
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("fr.louisraille.NotchBuddy.debug.composerEdit"))) { note in
            KeepDebug.composerEditing = note.object as? String
        }
        // `debug.agendaDeleteTask` "title": deletes the open tasks with exactly that title (a key test's leftover).
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("fr.louisraille.NotchBuddy.debug.agendaDeleteTask"))) { note in
            guard let title = note.object as? String, !title.isEmpty else { return }
            let hits = tasks.items.filter { $0.title == title }
            appendAppLog("nb.log", "[Agenda] debug delete '\(title)': \(hits.count) found")
            hits.forEach { tasks.delete($0.id) }
        }
        // `debug.agendaKeys` "8,0,20s": key presses posted to Coucou alone (never to the app in front);
        // "s" after a code holds Shift.
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("fr.louisraille.NotchBuddy.debug.agendaKeys"))) { note in
            let items = (note.object as? String ?? "").split(separator: ",").map(String.init)
            for (i, item) in items.enumerated() {
                let shift = item.hasSuffix("s")
                guard let code = UInt16(shift ? String(item.dropLast()) : item) else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 * Double(i)) {
                    let pid = getpid()
                    for down in [true, false] {
                        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
                        if shift { e?.flags = .maskShift }
                        e?.postToPid(pid)
                    }
                }
            }
        }
        #endif
        .onAppear {
            #if DEBUG
            if let sample = KeepDebug.tasksComposerText { text = sample }
            if KeepDebug.agendaTasksOnly { filter = .tasks; showUndated = true }
            hoverRow = KeepDebug.agendaHover
            laterRow = KeepDebug.agendaLater
            // After the sample text's own change has closed any menu.
            DispatchQueue.main.async {
                switch KeepDebug.agendaOpen {
                case "help"?: helpOpen = true
                case "details"?, "edetails"?: detailsOpen = true
                case "when"?: menuSource = .chip(.when)
                case "repeat"?: menuSource = .chip(.repeating)
                case "group"?: menuSource = .groupChip
                default: break
                }
            }
            #endif
            reload()
            // Opened straight on the Agenda: active from the start, so its onChange never fires.
            if active { composing = true }
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
            // Details takes the whole page while open: it shows every piece the chips would.
            if !detailsOpen {
                weekStrip
                dayHeader
            }
            missingAccess
            ZStack(alignment: .top) {
                list
                if helpOpen { help.transition(.opacity) }
                if detailsOpen { details.transition(.opacity) }
                // The menu sits on the list's bottom edge, right above the composer, whatever
                // the composer's height (one or two rows of chips).
                if let items = menuItems, !items.isEmpty {
                    suggestions(items)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: helpOpen)
            .animation(.easeOut(duration: 0.15), value: detailsOpen)
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
                HStack(spacing: 5) {
                    Text(e.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if e.repeats { repeatIcon }
                }
                if !sub.isEmpty { Text(sub).font(.system(size: 10)).foregroundColor(Color(hex: "#8E939C")).lineLimit(1) }
            }
            Spacer(minLength: 6)
            let hovered = hoverRow == "e" + e.id
            if hovered, let url = e.meeting {
                quickIcon("link", "Copy the meeting link") { copy(url.absoluteString, what: "Meeting link") }
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            if hovered && !canJoin {
                Button(e.meeting != nil ? "Join" : "Open") { e.meeting != nil ? calendar.join(e) : calendar.openCalendarApp(at: e.start) }
                    .buttonStyle(.plain).pointer()
                    .font(.system(size: 11, weight: .bold)).foregroundColor(Color(hex: "#F5F6F8"))
                    .padding(.horizontal, 13).frame(height: 26)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
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
            .fill(live || canJoin ? Color(hex: "#0A84FF").opacity(0.12) : Color.white.opacity(hoverRow == "e" + e.id ? 0.09 : 0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .modifier(RowLift(on: hoverRow == "e" + e.id))
        .opacity(past && hoverRow != "e" + e.id ? 0.5 : 1)
        .contentShape(Rectangle())
        .onHover { over in withAnimation(.easeOut(duration: 0.15)) { hoverRow = over ? "e" + e.id : (hoverRow == "e" + e.id ? nil : hoverRow) } }
        .onTapGesture { calendar.openCalendarApp(at: e.start) }
        .pointer()
        .contextMenu {
            if e.meeting != nil { Button("Join") { calendar.join(e) } }
            Button("Open in Calendar") { calendar.openCalendarApp(at: e.start) }
            if let url = e.meeting {
                Button("Copy meeting link") { copy(url.absoluteString, what: "Meeting link") }
            }
        }
    }

    private var repeatIcon: some View {
        Image(systemName: "repeat").font(.system(size: 9, weight: .bold)).foregroundColor(Color(hex: "#8E939C")).help("Repeats")
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
        let sub = [when.isEmpty ? nil : when, t.place, list?.title].compactMap { $0 }.joined(separator: " · ")
        // Reminders' priority numbers: 1–4 high, 5 medium, 6–9 low.
        let marks = t.priority == 0 ? 0 : (t.priority < 5 ? 3 : (t.priority == 5 ? 2 : 1))
        let choosing = laterRow == t.id
        let hovered = hoverRow == "t" + t.id || choosing
        return HStack(spacing: 10) {
            // The list's colour (red when missed): done and the rest are on hover and on a swipe.
            Circle().fill(overdue ? Color(hex: "#F4505E") : (list?.color ?? Color(hex: "#6B7079")))
                .frame(width: 8, height: 8).frame(width: 13)
            Text(t.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            if marks > 0 {
                Text(String(repeating: "!", count: marks)).font(.system(size: 11, weight: .heavy)).foregroundColor(Color(hex: "#F4505E"))
                    .help(["", "Low", "Medium", "High"][marks] + " priority")
            }
            Spacer(minLength: 6)
            if choosing {
                HStack(spacing: 4) {
                    ForEach(laterChoices, id: \.title) { c in
                        Button(c.short) { laterRow = nil; later(t, to: c.due, hasTime: c.hasTime, title: c.title) }
                            .buttonStyle(.plain).pointer().help(c.title)
                            .font(.system(size: 10.5, weight: .semibold)).foregroundColor(Color(hex: "#FDE68A"))
                            .padding(.horizontal, 9).frame(height: 24)
                            .background(Capsule().fill(Color(hex: "#F59E0B").opacity(0.16)))
                    }
                    quickIcon("xmark", "Close") { laterRow = nil }
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else if hovered {
                HStack(spacing: 4) {
                    quickIcon("checkmark", "Done", tint: Color(hex: "#4ADE80"), fill: Color(hex: "#30D158").opacity(0.18)) { complete(t) }
                    quickIcon("clock", "Later") { withAnimation(.easeOut(duration: 0.15)) { laterRow = t.id } }
                    quickIcon("trash", "Delete", tint: Color(hex: "#F4A3AA")) { deleteTask(t) }
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                if t.repeats { repeatIcon }
                Text(sub).font(.system(size: 10, weight: .medium))
                    .foregroundColor(overdue ? Color(hex: "#F4505E") : Color(hex: "#8E939C")).lineLimit(1).fixedSize()
                    .transition(.opacity)
            }
        }
        .padding(.leading, 13).padding(.trailing, hovered ? 5 : 10)
        .frame(minHeight: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(overdue ? Color(hex: "#F4505E").opacity(hovered ? 0.14 : 0.08) : Color.white.opacity(hovered ? 0.07 : 0)))
        .modifier(RowLift(on: hovered))
        .contentShape(Rectangle())
        .onHover { over in withAnimation(.easeOut(duration: 0.15)) { hoverRow = over ? "t" + t.id : (hoverRow == "t" + t.id ? nil : hoverRow) } }
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
            Button("Delete", role: .destructive) { deleteTask(t) }
        }
    }

    // MARK: Quick actions

    private func deleteTask(_ t: TaskItem) {
        let restore = tasks.delete(t.id)
        say("Deleted · \(t.title)", undo: restore)
    }

    /// The times "Later" offers, from now: this evening only while it is still ahead.
    private var laterChoices: [(title: String, short: String, due: Date, hasTime: Bool)] {
        let cal = Calendar.current, now = Date.now
        let today = cal.startOfDay(for: now)
        func at(_ h: Int, dayOffset: Int) -> Date {
            cal.date(bySettingHour: h, minute: 0, second: 0, of: cal.date(byAdding: .day, value: dayOffset, to: today) ?? today) ?? now
        }
        var out: [(title: String, short: String, due: Date, hasTime: Bool)] = [("In an hour", "1 hour", now.addingTimeInterval(3600), true)]
        if cal.component(.hour, from: now) < 18 { out.append(("This evening, 7 PM", "Evening", at(19, dayOffset: 0), true)) }
        out.append(("Tomorrow, 9 AM", "Tomorrow", at(9, dayOffset: 1), true))
        let toMonday = (9 - cal.component(.weekday, from: now)) % 7
        out.append(("Next week, Monday 9 AM", "Next week", at(9, dayOffset: toMonday == 0 ? 7 : toMonday), true))
        return out
    }

    /// Moves a task to a later time, with Undo back to its time before.
    private func later(_ t: TaskItem, to due: Date, hasTime: Bool, title: String) {
        let before = (due: t.due, hasTime: t.hasTime)
        tasks.setDue(t.id, due, hasTime: hasTime)
        say("Moved · \(title)") { tasks.setDue(t.id, before.due, hasTime: before.hasTime) }
    }

    private func quickIcon(_ symbol: String, _ help: String, tint: Color = Color(hex: "#C5C8CD"), fill: Color = Color.white.opacity(0.08),
                           _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundColor(tint)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointer().help(help)
    }

    private func copy(_ string: String, what: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        say("\(what) copied", undo: nil)
    }

    private func complete(_ t: TaskItem) {
        tasks.setDone(t.id, true)
        say("Done · \(t.title)") { tasks.setDone(t.id, false) }
    }

    // MARK: Composer

    private var command: (kind: AgendaKind?, rest: String) { AgendaCommand.read(text) }

    private var listGroups: [(id: String, title: String)] { tasks.lists.map { (id: $0.id, title: $0.title) } }
    private var calendarGroups: [(id: String, title: String)] { calendar.calendars.filter(\.writable).map { (id: $0.id, title: $0.title) } }
    /// The lists for a task, the calendars for an event: what #word picks from.
    private var groups: [(id: String, title: String)] { kind == .task ? listGroups : calendarGroups }

    /// Repeat, alerts, priority, place, note and link, and the line with them blanked out.
    /// Priority is a task's: on an event "!!" stays in the title.
    private var extrasRead: (extras: AgendaExtras, masked: String) {
        AgendaExtras.read(command.rest, skip: kind == .event ? skipPieces.union([.priority]) : skipPieces)
    }
    private var extras: AgendaExtras { extrasRead.extras }

    private var parsedTask: ParsedTask {
        var p = TaskComposer.parse(extrasRead.masked, lists: listGroups, readDate: !skipDate, readTag: !skipTag)
        // A repeat on set days starts on the first of them; with no date, on the first one from today.
        if let r = extras.repeating {
            if let due = p.due { p.due = r.aligned(due) } else { p.due = r.firstDay(from: .now); p.hasTime = false }
        }
        return p
    }

    private var parsedEvent: ParsedEvent {
        var e = CalendarComposer.parse(extrasRead.masked, calendars: calendarGroups, readDate: !skipDate, readTag: !skipTag,
                                       defaultMinutes: Double(composerSettings.eventMinutes))
        if let r = extras.repeating {
            if let start = e.start, let end = e.end {
                let moved = e.allDay ? r.firstDay(from: start) : r.aligned(start)
                e.start = moved
                e.end = end.addingTimeInterval(moved.timeIntervalSince(start))
            } else {
                let day = r.firstDay(from: .now)
                e.start = day
                e.end = Calendar.current.date(byAdding: .day, value: 1, to: day)
                e.allDay = true
            }
        }
        return e
    }

    /// Where the date and the tag sit in the line itself, read even when their chip was undone, so
    /// a choice from a chip's menu takes their place.
    private var pieces: (date: Range<String.Index>?, tag: Range<String.Index>?) {
        let full = AgendaExtras.read(command.rest)
        let p = TaskComposer.parse(full.masked, lists: groups)
        return (AgendaExtras.same(p.dateRange, from: full.masked, in: command.rest),
                AgendaExtras.same(p.tagRange, from: full.masked, in: command.rest))
    }

    /// Where a repeat, alert or priority sits in the line itself.
    private func range(of piece: AgendaExtras.Piece) -> Range<String.Index>? {
        AgendaExtras.read(command.rest).extras.ranges[piece].flatMap { Range($0, in: command.rest) }
    }

    /// A task unless /event is typed or Event picked (Task / Event and Tab win over the line);
    /// only one kind when the other is off or not allowed.
    private var kind: AgendaKind {
        if !eventsOn { return .task }
        if !tasksOn { return .event }
        return kindOverride ?? command.kind ?? (composerSettings.eventsFirst ? .event : .task)
    }

    /// A length was typed on what is still a task by default: offer the switch, never make it.
    private var looksLikeEvent: Bool {
        tasksOn && eventsOn && composerSettings.eventHint && !composerSettings.eventsFirst
            && kindOverride == nil && command.kind == nil && parsedEvent.hasLength
    }

    private var composer: some View {
        let k = kind
        let t = parsedTask, e = parsedEvent
        let ready = k == .task ? !t.title.isEmpty : (!e.title.isEmpty && e.start != nil)
        let typing = !text.trimmingCharacters(in: .whitespaces).isEmpty
        return VStack(alignment: .leading, spacing: 5) {
            if typing && !detailsOpen {
                // Wraps to a second row when a line has many pieces, so none is hidden.
                ChipFlowLayout(spacing: 6) {
                    Text(ready ? "Will add" : (k == .event ? "Add a day or a time" : "Type a task")).font(.system(size: 9.5)).foregroundColor(Color(hex: "#6B7079"))
                        .frame(height: 20)
                    if tasksOn && eventsOn { kindSwitch(k) }
                    if k == .task {
                        whenChip(t.due.map { TaskComposer.label($0, hasTime: t.hasTime) } ?? "No time", read: t.due != nil)
                        if let l = t.listID.flatMap(tasks.list) ?? tasks.newTaskList { groupChip(l.title, l.color, read: t.listID != nil) }
                    } else {
                        whenChip(CalendarComposer.label(e) ?? "Add a day or a time", read: e.start != nil)
                        if let c = e.calendarID.flatMap(calendar.calendar) ?? calendar.newEventCalendar { groupChip(c.title, c.color, read: e.calendarID != nil) }
                    }
                    extraChips(k)
                    if k == .task && looksLikeEvent { eventHint }
                }
                .padding(.leading, 2)
                .transition(.opacity)
            }
            HStack(spacing: 8) {
                TextField(tasksOn && eventsOn ? (composerSettings.eventsFirst ? "Add an event… start with /t for a task" : "Add a task… start with /e for an event") : (eventsOn ? "Add an event…" : "Add a task…"), text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focusEffectDisabled()   // the capsule's border already shows focus
                    .focused($composing)
                    .onSubmit(add)
                    .onKeyPress(keys: [.upArrow, .downArrow, .return, .tab]) { press in
                        // ⌘Return opens or closes Details; the rest is the menu's or Tab's.
                        if press.key == .return, press.modifiers.contains(.command) { openDetails(!detailsOpen); return .handled }
                        return key(press.key)
                    }
                    .onExitCommand(perform: escape)
                    .onChange(of: text) { _, new in
                        menuClosed = false
                        menuRow = 0
                        menuSource = nil   // typing closes a chip's or /at's menu
                        if new == "?" { text = ""; helpOpen = true }
                        // "/standup" and a space: the template's line, as text to change.
                        if let expanded = AgendaTemplate.expand(new, templates: composerSettings.templates) { text = expanded }
                        if new.isEmpty { kindOverride = nil; skipDate = false; skipTag = false; skipPieces = []; menuSource = nil }
                    }
                Button { openDetails(!detailsOpen) } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 10, weight: .bold))
                        .foregroundColor(detailsOpen ? Color(hex: "#04161A") : Color(hex: "#8E939C"))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(detailsOpen ? Color(hex: "#22D3EE") : Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain).pointer().help("Details: repeat, alerts, place, note (⌘Return)")
                Button { helpOpen.toggle(); if helpOpen { detailsOpen = false } } label: {
                    Text("?").font(.system(size: 11, weight: .heavy)).foregroundColor(helpOpen ? Color(hex: "#04161A") : Color(hex: "#8E939C"))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(helpOpen ? Color(hex: "#22D3EE") : Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain).pointer().help("What you can type")
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

    // MARK: Suggestions

    /// The menu now: a chip's or /at's choices, else what the word being typed asks for.
    private var menuItems: [AgendaSuggestion]? {
        guard !helpOpen, !detailsOpen else { return nil }
        switch menuSource {
        case .slash(let set)?, .chip(let set)?: return AgendaSuggest.choices(set)
        case .groupChip?: return AgendaSuggest.menu(for: "#", groups: groups, groupKind: kind == .task ? "list" : "calendar", templates: [])
        case nil:
            guard !menuClosed, composerSettings.suggestions else { return nil }
            return AgendaSuggest.menu(for: text, groups: groups, groupKind: kind == .task ? "list" : "calendar",
                                      templates: composerSettings.templates)
        }
    }

    private func key(_ key: KeyEquivalent) -> KeyPress.Result {
        if let items = menuItems, !items.isEmpty {
            switch key {
            case .upArrow: menuRow = (menuRow - 1 + items.count) % items.count
            case .downArrow: menuRow = (menuRow + 1) % items.count
            default: pick(items[min(menuRow, items.count - 1)])
            }
            return .handled
        }
        guard key == .tab, tasksOn && eventsOn, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return .ignored }
        kindOverride = kind == .task ? .event : .task
        return .handled
    }

    /// Escape closes the help, then the menu; with neither open the notch closes as anywhere else.
    private func escape() {
        if helpOpen { helpOpen = false; return }
        if detailsOpen { detailsOpen = false; composing = true; return }
        if menuSource != nil { menuSource = nil; return }
        if let items = menuItems, !items.isEmpty { menuClosed = true; return }
        NotificationCenter.default.post(name: .islandCollapse, object: nil)
    }

    /// The line again with the /e or /t it had, after a piece of the rest changed.
    private func withCommand(_ rest: String) -> String {
        switch command.kind {
        case .event?: return "/e " + rest
        case .task?: return "/t " + rest
        case nil: return rest
        }
    }

    private func pick(_ item: AgendaSuggestion) {
        switch item.action {
        case .choices(let set):
            menuSource = .slash(set)
        case .help:
            text = AgendaSuggest.apply("", to: text).trimmingCharacters(in: .whitespaces)
            helpOpen = true
        case .insert(let words):
            switch menuSource {
            case .chip(.when)?:
                text = withCommand(AgendaSuggest.replace(pieces.date, in: command.rest, with: words))
                skipDate = false
            case .chip(let set)?:
                // The chip's piece swapped for the choice.
                let piece: AgendaExtras.Piece = set == .repeating ? .repeating : set == .alert ? .alerts : .priority
                text = withCommand(AgendaSuggest.replace(range(of: piece), in: command.rest, with: words))
                skipPieces.remove(piece)
            case .groupChip?:
                text = withCommand(AgendaSuggest.replace(pieces.tag, in: command.rest, with: words))
                skipTag = false
            case .slash(let set)?:
                text = AgendaSuggest.apply(words, to: text)
                switch set {
                case .when: skipDate = false
                case .repeating: skipPieces.remove(.repeating)
                case .alert: skipPieces.remove(.alerts)
                case .priority: skipPieces.remove(.priority)
                }
            case nil:
                text = AgendaSuggest.apply(words, to: text)
                if words.hasPrefix("#") { skipTag = false }
            }
            menuSource = nil
        }
        menuRow = 0
        composing = true
    }

    private func menuRowView(_ item: AgendaSuggestion, chosen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let id = item.groupID {
                    Circle().fill((kind == .task ? tasks.list(id)?.color : calendar.calendar(id)?.color) ?? .gray).frame(width: 8, height: 8)
                } else if !item.symbol.hasPrefix("/") {
                    Image(systemName: item.symbol).font(.system(size: 10, weight: .semibold)).foregroundColor(Color(hex: "#67E8F9")).frame(width: 14)
                } else {
                    Text(item.symbol).font(.system(size: 11, design: .monospaced)).foregroundColor(Color(hex: "#67E8F9")).frame(width: 70, alignment: .leading)
                }
                Text(item.title).font(.system(size: 11.5, weight: chosen ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 8)
                Text(item.detail).font(.system(size: 10.5)).foregroundColor(Color(hex: "#6B7079")).lineLimit(1)
            }
            .padding(.horizontal, 9).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(chosen ? Color(hex: "#22D3EE").opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointer()
    }

    private func suggestions(_ items: [AgendaSuggestion]) -> some View {
        let row = min(menuRow, items.count - 1)
        return VStack(alignment: .leading, spacing: 1) {
            // Up to seven rows show; more scroll, and the chosen one is kept in view.
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: items.count > 7) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                            menuRowView(item, chosen: i == row) { pick(item) }
                                .id(item.id)
                                .onHover { if $0 { menuRow = i } }
                        }
                    }
                }
                .frame(height: CGFloat(min(items.count, 7)) * 27)
                .onChange(of: menuRow) { _, r in
                    if items.indices.contains(r) { proxy.scrollTo(items[r].id) }
                }
            }
            HStack(spacing: 12) {
                Text("↑↓ choose"); Text("Return pick"); Text("Esc close"); Text("? help")
            }
            .font(.system(size: 9.5)).foregroundColor(Color(hex: "#6B7079"))
            .padding(.horizontal, 9).padding(.top, 3).padding(.bottom, 1)
        }
        .padding(5)
        .frame(width: 380)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: "#1B1C20")))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
    }

    // MARK: Chips

    /// The day and time read: click to choose another, × to leave the words in the title.
    private func whenChip(_ label: String, read: Bool) -> some View {
        chipButton(label, accent: read, color: nil, undo: read ? { skipDate = true } : nil) {
            menuSource = menuSource == .chip(.when) ? nil : .chip(.when)
            composing = true
        }
    }

    /// The list or calendar: click to choose another, × (when a #tag was read) to leave it in the title.
    private func groupChip(_ title: String, _ color: Color, read: Bool) -> some View {
        chipButton(title, accent: false, color: color, undo: read ? { skipTag = true } : nil) {
            menuSource = menuSource == .groupChip ? nil : .groupChip
            composing = true
        }
    }

    /// Repeat, alerts, priority (tasks), place, note and link: click the first three to choose
    /// another, × to keep the words as title text.
    @ViewBuilder
    private func extraChips(_ k: AgendaKind) -> some View {
        let x = extras
        if let r = x.repeating {
            chipButton(r.label, accent: true, color: nil, undo: { skipPieces.insert(.repeating) }) { toggle(.chip(.repeating)) }
        }
        if !x.alerts.isEmpty {
            chipButton("Alert " + x.alerts.map(AgendaExtras.alertLabel).joined(separator: ", "), accent: true, color: nil,
                       undo: { skipPieces.insert(.alerts) }) { toggle(.chip(.alert)) }
        }
        if k == .task, x.priority > 0 {
            chipButton(String(repeating: "!", count: x.priority) + " " + ["", "Low", "Medium", "High"][x.priority], accent: false, color: nil,
                       undo: { skipPieces.insert(.priority) }) { toggle(.chip(.priority)) }
        }
        if let place = x.place {
            chipButton(place, accent: false, color: nil, undo: { skipPieces.insert(.place) }) { composing = true }
        }
        if x.note != nil {
            chipButton("Note", accent: false, color: nil, undo: { skipPieces.insert(.note) }) { composing = true }
        }
        if let link = x.link {
            chipButton(link.host ?? "Link", accent: false, color: nil, undo: { skipPieces.insert(.link) }) { composing = true }
        }
    }

    private func toggle(_ source: MenuSource) {
        menuSource = menuSource == source ? nil : source
        composing = true
    }

    private func chipButton(_ title: String, accent: Bool, color: Color?, undo: (() -> Void)?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Button(action: action) {
                HStack(spacing: 5) {
                    if let color { Circle().fill(color).frame(width: 7, height: 7) }
                    Text(title).font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(accent ? Color(hex: "#67E8F9") : (color != nil ? Color(hex: "#C5C8CD") : Color(hex: "#8E939C")))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointer()
            if let undo {
                Button(action: undo) {
                    Image(systemName: "xmark").font(.system(size: 7, weight: .heavy)).foregroundColor(Color(hex: "#8E939C"))
                        .frame(width: 14, height: 14).background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain).pointer().help("Don't read this: keep the words in the title")
            }
        }
        .padding(.leading, 9).padding(.trailing, undo == nil ? 9 : 3).frame(height: 20)
        .background(Capsule().fill(accent ? Color(hex: "#22D3EE").opacity(0.14) : Color.white.opacity(0.06)))
    }

    // MARK: Details

    private func openDetails(_ open: Bool) {
        detailsOpen = open
        if open { helpOpen = false; menuSource = nil }
        composing = true
    }

    /// One piece of the line set from Details: its words in its place, or removed.
    private func set(_ phrase: String?, at range: Range<String.Index>?) {
        text = withCommand(AgendaLine.put(phrase, at: range, in: command.rest, before: self.range(of: .note)))
    }

    private var details: some View {
        let k = kind
        let x = extras
        let t = parsedTask, e = parsedEvent
        let date = k == .task ? t.due : e.start
        let timed = k == .task ? t.hasTime : (e.start != nil && !e.allDay)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Details").font(.system(size: 13, weight: .bold))
                Text("They write the line below, and the line writes them.").font(.system(size: 10.5)).foregroundColor(Color(hex: "#8E939C"))
                Spacer(minLength: 0)
                Button { openDetails(false) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundColor(Color(hex: "#8E939C"))
                        .frame(width: 20, height: 20).background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain).pointer().help("Close (Esc or ⌘Return)")
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 7) {
                    if tasksOn && eventsOn { detailRow("Kind") { kindSwitch(k) } }
                    detailRow("When") { whenControls(date: date, timed: timed, k: k, e: e) }
                    detailRow("Repeat") { repeatControls(x.repeating, hasDate: date != nil) }
                    if let r = x.repeating { detailRow("Ends") { endControls(r) } }
                    detailRow("Alerts") { alertControls(x.alerts) }
                    detailRow(k == .task ? "List" : "Calendar") { groupControl(k, t: t, e: e) }
                    if k == .task {
                        detailRow("Priority") {
                            segments(["None", "Low", "Medium", "High"], selected: x.priority) { set(AgendaLine.priority($0), at: range(of: .priority)) }
                        }
                    }
                    detailRow("Place") {
                        detailField("A place", value: x.place ?? "") { set($0.isEmpty ? nil : "@" + $0, at: range(of: .place)) }
                    }
                    detailRow("Note") {
                        detailField("A note, or paste a link", value: x.note ?? "") { new in
                            // The note runs to the end of the line: added there, never before another piece.
                            text = withCommand(AgendaLine.put(new.isEmpty ? nil : "// " + new, at: range(of: .note), in: command.rest, before: nil))
                        }
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(hex: "#141518")))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }

    private func detailRow<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label).font(.system(size: 10.5, weight: .bold)).foregroundColor(Color(hex: "#8E939C"))
                .frame(width: 58, height: 24, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .frame(minHeight: 24)
    }

    @ViewBuilder
    private func whenControls(date: Date?, timed: Bool, k: AgendaKind, e: ParsedEvent) -> some View {
        if let date {
            DatePicker("", selection: Binding(get: { date }, set: { set(AgendaLine.date($0, hasTime: timed), at: pieces.date) }),
                       displayedComponents: timed ? [.date, .hourAndMinute] : [.date])
                .labelsHidden().datePickerStyle(.field).fixedSize()
            Toggle("All day", isOn: Binding(get: { !timed }, set: { allDay in
                let base = allDay ? date : (Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date)
                set(AgendaLine.date(base, hasTime: !allDay), at: pieces.date)
            }))
            .toggleStyle(.checkbox).font(.system(size: 11))
            if k == .event, timed, let start = e.start, let end = e.end {
                let minutes = Int(end.timeIntervalSince(start) / 60)
                Picker("", selection: Binding(get: { minutes }, set: { set(AgendaLine.length(minutes: $0), at: CalendarComposer.lengthRange(in: command.rest)) })) {
                    ForEach(Array(Set([15, 30, 45, 60, 90, 120, minutes])).sorted(), id: \.self) { m in
                        Text(m % 60 == 0 ? "for \(m / 60) h" : (m > 60 ? "for \(m / 60) h \(m % 60) min" : "for \(m) min")).tag(m)
                    }
                }
                .labelsHidden().fixedSize()
            }
            Button("Clear") { set(nil, at: pieces.date) }.buttonStyle(.plain).pointer()
                .font(.system(size: 11, weight: .semibold)).foregroundColor(Color(hex: "#8E939C"))
        } else {
            Button("Add a day and time") {
                let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now)) ?? .now
                set(AgendaLine.date(Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow, hasTime: true), at: nil)
            }
            .buttonStyle(HubButtonStyle())
        }
    }

    @ViewBuilder
    private func repeatControls(_ r: AgendaRepeat?, hasDate: Bool) -> some View {
        let options = ["Never", "Daily", "Weekdays", "Weekly", "Monthly", "Yearly"]
        let current: Int = {
            guard let r else { return 0 }
            switch r.frequency {
            case .daily: return 1
            case .weekly: return r.weekdays == [2, 3, 4, 5, 6] && r.interval == 1 ? 2 : 3
            case .monthly: return 4
            case .yearly: return 5
            }
        }()
        VStack(alignment: .leading, spacing: 6) {
            segments(options, selected: current) { i in
                var new: AgendaRepeat? = [nil, AgendaRepeat(frequency: .daily), AgendaRepeat(frequency: .weekly, weekdays: [2, 3, 4, 5, 6]),
                                          AgendaRepeat(frequency: .weekly), AgendaRepeat(frequency: .monthly), AgendaRepeat(frequency: .yearly)][i]
                new?.until = r?.until
                new?.count = r?.count
                set(AgendaLine.repeating(new), at: range(of: .repeating))
            }
            if let r, r.frequency != .weekly || !(r.weekdays == [2, 3, 4, 5, 6] && r.interval == 1) {
                HStack(spacing: 6) {
                    Stepper(value: Binding(get: { r.interval }, set: { n in var c = r; c.interval = max(1, n); set(AgendaLine.repeating(c), at: range(of: .repeating)) }), in: 1...99) {
                        Text(r.interval == 1 ? "Every \(unit(r))" : "Every \(r.interval) \(unit(r))").font(.system(size: 11))
                    }
                    .fixedSize()
                    if r.frequency == .weekly {
                        ForEach(1...7, id: \.self) { d in
                            let on = r.weekdays.contains(d)
                            Button {
                                var c = r
                                c.weekdays = on ? c.weekdays.filter { $0 != d } : (c.weekdays + [d]).sorted()
                                set(AgendaLine.repeating(c), at: range(of: .repeating))
                            } label: {
                                Text(Calendar.current.veryShortWeekdaySymbols[d - 1]).font(.system(size: 10, weight: .bold))
                                    .foregroundColor(on ? Color(hex: "#04161A") : Color(hex: "#8E939C"))
                                    .frame(width: 22, height: 22)
                                    .background(Circle().fill(on ? Color(hex: "#22D3EE") : Color.white.opacity(0.06)))
                            }
                            .buttonStyle(.plain).pointer()
                        }
                    }
                }
            }
        }
    }

    private func unit(_ r: AgendaRepeat) -> String {
        let one = r.interval == 1
        switch r.frequency {
        case .daily: return one ? "day" : "days"
        case .weekly: return one ? "week" : "weeks"
        case .monthly: return one ? "month" : "months"
        case .yearly: return one ? "year" : "years"
        }
    }

    @ViewBuilder
    private func endControls(_ r: AgendaRepeat) -> some View {
        let mode = r.until != nil ? 1 : (r.count != nil ? 2 : 0)
        segments(["Never", "On a day", "After"], selected: mode) { i in
            var c = r
            c.until = i == 1 ? (Calendar.current.date(byAdding: .month, value: 1, to: Calendar.current.startOfDay(for: .now))) : nil
            c.count = i == 2 ? 10 : nil
            set(AgendaLine.repeating(c), at: range(of: .repeating))
        }
        if let until = r.until {
            DatePicker("", selection: Binding(get: { until }, set: { d in var c = r; c.until = Calendar.current.startOfDay(for: d); set(AgendaLine.repeating(c), at: range(of: .repeating)) }),
                       displayedComponents: [.date])
                .labelsHidden().datePickerStyle(.field).fixedSize()
        }
        if let count = r.count {
            Stepper(value: Binding(get: { count }, set: { n in var c = r; c.count = max(1, n); set(AgendaLine.repeating(c), at: range(of: .repeating)) }), in: 1...999) {
                Text("\(count) times").font(.system(size: 11))
            }
            .fixedSize()
        }
    }

    @ViewBuilder
    private func alertControls(_ alerts: [TimeInterval]) -> some View {
        ForEach(alerts, id: \.self) { a in
            chipButton(AgendaExtras.alertLabel(a), accent: true, color: nil, undo: {
                set(AgendaLine.alerts(alerts.filter { $0 != a }), at: range(of: .alerts))
            }) {}
        }
        Menu {
            ForEach(AgendaSuggest.alerts) { choice in
                if case .insert(let words) = choice.action, let offset = AgendaExtras.read("x " + words).extras.alerts.first, !alerts.contains(offset) {
                    Button(choice.title) { set(AgendaLine.alerts(alerts + [offset]), at: range(of: .alerts)) }
                }
            }
        } label: {
            Text("+ Alert").font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    @ViewBuilder
    private func groupControl(_ k: AgendaKind, t: ParsedTask, e: ParsedEvent) -> some View {
        let current = k == .task ? (t.listID ?? tasks.newTaskList?.id) : (e.calendarID ?? calendar.newEventCalendar?.id)
        Menu {
            ForEach(groups, id: \.id) { g in
                Button {
                    set("#" + (TaskComposer.tag(for: g.id, in: groups) ?? TaskComposer.key(g.title)), at: pieces.tag)
                } label: {
                    if g.id == current { Label(g.title, systemImage: "checkmark") } else { Text(g.title) }
                }
            }
        } label: {
            Text(groups.first { $0.id == current }?.title ?? "Choose").font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    /// A row of choices like the Task / Event switch.
    private func segments(_ options: [String], selected: Int, _ pick: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                Button { pick(i) } label: {
                    Text(option).font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(i == selected ? Color(hex: "#F5F6F8") : Color(hex: "#8E939C"))
                        .padding(.horizontal, 9).frame(height: 20)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(i == selected ? Color.white.opacity(0.12) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointer()
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.3)))
    }

    private func detailField(_ placeholder: String, value: String, _ change: @escaping (String) -> Void) -> some View {
        TextField(placeholder, text: Binding(get: { value }, set: change))
            .textFieldStyle(.plain).font(.system(size: 11.5))
            .focusEffectDisabled()
            .padding(.horizontal, 8).frame(height: 22).frame(maxWidth: 320)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(hex: "#1F2024")))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }

    // MARK: Help

    private var help: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text("Adding to your Agenda").font(.system(size: 13, weight: .bold))
                Text("Just type; everything here is optional.").font(.system(size: 10.5)).foregroundColor(Color(hex: "#8E939C"))
                Spacer(minLength: 0)
                Button { helpOpen = false } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundColor(Color(hex: "#8E939C"))
                        .frame(width: 20, height: 20).background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain).pointer().help("Close (Esc)")
            }
            ScrollView(.vertical, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    helpLabel("WHAT IT IS")
                    helpRow("Task", "the default", plain: true)
                    helpRow("/event /e", "an event")
                    helpRow("/task /t", "a task")
                    helpRow("Tab", "switch kind")
                    helpLabel("WHEN").padding(.top, 4)
                    helpRow("tomorrow 6pm", "day and time")
                    helpRow("fri 2pm", "a weekday")
                    helpRow("in 2 hours", "from now")
                    helpRow("for 45m", "event length")
                    helpRow("/at", "pick a time")
                }
                VStack(alignment: .leading, spacing: 5) {
                    helpLabel("MORE")
                    helpRow("#word", "list or calendar")
                    helpRow("!  !!  !!!", "priority (tasks)")
                    helpRow("@Room 4", "place")
                    helpRow("every weekday", "repeat")
                    helpRow("until 31 dec", "or 10 times")
                    helpRow("alert 10m", "alert before")
                    helpRow("// text", "note, or a link")
                    helpRow("/", "every command")
                    if let t = composerSettings.templates.first { helpRow("/" + t.name, "your template") }
                }
                VStack(alignment: .leading, spacing: 5) {
                    helpLabel("TRY ONE")
                    ForEach(helpExamples, id: \.self) { example in
                        Button {
                            text = example
                            helpOpen = false
                            composing = true
                        } label: {
                            HStack {
                                Text(example).font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.85)
                                Spacer(minLength: 4)
                                Text(AgendaCommand.read(example).kind == .event ? "event" : "task").font(.system(size: 9.5)).foregroundColor(Color(hex: "#6B7079"))
                            }
                            .padding(.horizontal, 8).frame(height: 24)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.05)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).pointer()
                    }
                }
                .frame(width: 184)
            }
            }
            Text("↑↓ Return pick · click a chip to change it, × keeps it as text · ⌘Return or the sliders: Details · Esc closes")
                .font(.system(size: 10)).foregroundColor(Color(hex: "#6B7079"))
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(hex: "#141518")))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }

    private var helpExamples: [String] {
        var out = ["Call the bank tomorrow 6pm !!", "Pay rent every month on 1st", "Water plants every other day"]
        if tasksOn && eventsOn { out += ["/e Lunch fri 1pm for 1h @Cafe", "/e Gym every mon 7am for 1h"] }
        return out
    }

    private func helpLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 8.5, weight: .heavy)).tracking(1).foregroundColor(Color(hex: "#6B7079"))
    }

    private func helpRow(_ code: String, _ meaning: String, plain: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(code).font(plain ? .system(size: 11) : .system(size: 10.5, design: .monospaced))
                .foregroundColor(plain ? Color(hex: "#C5C8CD") : Color(hex: "#67E8F9"))
                .frame(width: 88, alignment: .leading)
            Text(meaning).font(.system(size: 10.5)).foregroundColor(Color(hex: "#8E939C")).lineLimit(1).fixedSize()
        }
    }

    private var eventHint: some View {
        Button { kindOverride = .event } label: {
            HStack(spacing: 6) {
                Text("Looks like an event")
                Text("Tab").font(.system(size: 9, weight: .heavy))
                    .padding(.horizontal, 4).frame(height: 14)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(hex: "#9CCBFF").opacity(0.5)))
            }
            .font(.system(size: 10.5, weight: .semibold)).foregroundColor(Color(hex: "#9CCBFF"))
            .padding(.horizontal, 9).frame(height: 20)
            .background(Capsule().fill(Color(hex: "#0A84FF").opacity(0.14)))
        }
        .buttonStyle(.plain).pointer()
        .help("Make it an event")
    }

    private func kindSwitch(_ k: AgendaKind) -> some View {
        HStack(spacing: 2) {
            ForEach([AgendaKind.task, .event], id: \.self) { option in
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

    private func add() {
        if kind == .task {
            let p = parsedTask
            guard !p.title.isEmpty else { return }
            let list = p.listID.flatMap(tasks.list) ?? tasks.newTaskList
            if let id = tasks.add(title: p.title, due: p.due, hasTime: p.hasTime, listID: list?.id, extras: extras) {
                text = ""
                if let due = p.due { day = Calendar.current.startOfDay(for: due); calendar.showWeek(of: day) }
                let when = p.due.map { " · " + TaskComposer.label($0, hasTime: p.hasTime) } ?? ""
                say("Task added to \(list?.title ?? "Reminders")\(when)") { _ = tasks.delete(id) }
            } else {
                say("Reminders didn't take it; try again", undo: nil)
            }
        } else {
            let p = parsedEvent
            guard !p.title.isEmpty, let start = p.start, let end = p.end else { return }
            let target = p.calendarID.flatMap(calendar.calendar) ?? calendar.newEventCalendar
            var x = extras
            // Settings → Agenda → Composer: an alert kept on the event when none was typed.
            if x.alerts.isEmpty, composerSettings.newEventAlert >= 0 { x.alerts = [TimeInterval(composerSettings.newEventAlert * 60)] }
            if let id = calendar.add(title: p.title, start: start, end: end, allDay: p.allDay, calendarID: target?.id, extras: x) {
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
/// A row under the pointer: a soft shadow and a hair of scale, so it reads as the one you act on.
private struct RowLift: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        content
            .shadow(color: .black.opacity(on ? 0.35 : 0), radius: on ? 8 : 0, y: on ? 3 : 0)
            .scaleEffect(on ? 1.006 : 1)
    }
}
#endif
