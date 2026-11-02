#if !APPSTORE
import AppKit
import Combine
import EventKit
import SwiftUI

// MARK: - Tasks from Apple Reminders (coucou-custom fork, roadmap phase 2)
//
// Reminders is the store: Coucou reads and writes it through EventKit, so a task added in the
// notch shows on the iPhone and the Watch, and the other way round. Coucou keeps nothing of its
// own but which lists to show and where new tasks go. Done tasks stay in Reminders: the notch
// shows the open ones and only a count of today's done ones.

/// One Reminders list, as the notch shows it.
struct TaskList: Identifiable, Equatable {
    let id: String          // EKCalendar.calendarIdentifier
    let title: String
    let color: Color
}

/// One open (or done today) reminder.
struct TaskItem: Identifiable, Equatable {
    let id: String          // EKReminder.calendarItemIdentifier
    var title: String
    var due: Date?
    /// Whether `due` carries a time of day, or only a day.
    var hasTime: Bool
    var listID: String
    var done: Bool
    var completedAt: Date?
}

/// The groups the page shows, in order.
enum TaskGroup: String, CaseIterable {
    case overdue, today, later, noTime

    var label: String {
        switch self {
        case .overdue: "OVERDUE"
        case .today: "TODAY"
        case .later: "LATER"
        case .noTime: "NO TIME"
        }
    }

    /// The page's sections, by deadline: Overdue, Today, Tomorrow, each of the next days by name,
    /// then later ones by date, then No time; inside one, by time (the store's order).
    static func sections(_ items: [TaskItem], now: Date = .now, calendar: Calendar = .current) -> [(label: String, overdue: Bool, items: [TaskItem])] {
        var out: [(label: String, overdue: Bool, items: [TaskItem])] = []
        func add(_ label: String, overdue: Bool, _ item: TaskItem) {
            if let i = out.firstIndex(where: { $0.label == label }) { out[i].items.append(item) }
            else { out.append((label, overdue, [item])) }
        }
        let today = calendar.startOfDay(for: now)
        for item in items where item.due != nil {
            let due = item.due!
            if of(item, now: now, calendar: calendar) == .overdue { add("OVERDUE", overdue: true, item); continue }
            let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: due)).day ?? 0
            let label: String
            switch days {
            case ...0: label = "TODAY"
            case 1: label = "TOMORROW"
            case 2...6: label = due.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased()
            default: label = due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year()).uppercased()
            }
            add(label, overdue: false, item)
        }
        let undated = items.filter { $0.due == nil }
        if !undated.isEmpty { out.append(("NO TIME", false, undated)) }
        // Overdue first, then by day (the items arrive sorted by deadline).
        return out
    }

    static func of(_ item: TaskItem, now: Date = .now, calendar: Calendar = .current) -> TaskGroup {
        guard let due = item.due else { return .noTime }
        if item.hasTime ? due < now : calendar.startOfDay(for: due) < calendar.startOfDay(for: now) { return .overdue }
        return calendar.isDate(due, inSameDayAs: now) ? .today : .later
    }
}

/// Settings → Agenda → Tasks: whether tasks show in the Agenda, which lists it shows, where new tasks go.
@MainActor
final class TasksSettings: ObservableObject {
    static let shared = TasksSettings()
    static let enabledKey = "coucouTasksEnabled"
    static let hiddenListsKey = "coucouTasksHiddenLists"
    static let newListKey = "coucouTasksNewList"

    private let ud = UserDefaults.standard

    @Published var enabled: Bool { didSet { ud.set(enabled, forKey: Self.enabledKey) } }
    /// Lists left out of the notch (by identifier); every other list shows, new ones included.
    @Published var hiddenLists: Set<String> { didSet { ud.set(Array(hiddenLists).sorted(), forKey: Self.hiddenListsKey) } }
    /// The list new tasks go to; nil is Reminders' own default list.
    @Published var newList: String? { didSet { ud.set(newList, forKey: Self.newListKey) } }

    private init() {
        enabled = ud.object(forKey: Self.enabledKey) as? Bool ?? true
        hiddenLists = Set(ud.stringArray(forKey: Self.hiddenListsKey) ?? [])
        newList = ud.string(forKey: Self.newListKey)
    }
}

/// Reminders through EventKit: the lists, the open tasks of the shown lists, today's done count.
@MainActor
final class TasksStore: ObservableObject {
    static let shared = TasksStore()

    enum Access { case unknown, granted, denied }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var lists: [TaskList] = []
    @Published private(set) var items: [TaskItem] = []
    @Published private(set) var doneToday = 0

    private let store = EKEventStore()
    private var changeObserver: NSObjectProtocol?
    private var fetchGeneration = 0

    private init() {
        access = Self.currentAccess()
        changeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            MainActor.assumeIsolated { TasksStore.shared.reload() }
        }
        if access == .granted { reload() }
    }

    /// What macOS says, whatever the page shows (the Debug sample fakes access).
    static var reallyGranted: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return .granted
        case .notDetermined: return .unknown
        default: return .denied
        }
    }

    /// Asks for Reminders the first time; afterwards macOS answers from its own setting.
    func requestAccess() async {
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        access = granted ? .granted : Self.currentAccess()
        appendAppLog("nb.log", "[Tasks] Reminders access: \(granted ? "granted" : "refused")")
        if granted { reload() }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The lists shown in the notch, in Reminders' order.
    var shownLists: [TaskList] { lists.filter { !TasksSettings.shared.hiddenLists.contains($0.id) } }

    func list(_ id: String) -> TaskList? { lists.first { $0.id == id } }

    /// The list a new task goes to: the chosen one when it still exists, else Reminders' default.
    var newTaskList: TaskList? {
        if let id = TasksSettings.shared.newList, let l = list(id) { return l }
        if let d = store.defaultCalendarForNewReminders() { return list(d.calendarIdentifier) }
        return lists.first
    }

    // MARK: Reading

    func reload() {
        #if DEBUG
        if debugFrozen { return }
        #endif
        guard access == .granted else { return }
        let calendars = store.calendars(for: .reminder)
        lists = calendars.map { TaskList(id: $0.calendarIdentifier, title: $0.title, color: Color(nsColor: $0.color ?? .systemBlue)) }
        let shown = calendars.filter { !TasksSettings.shared.hiddenLists.contains($0.calendarIdentifier) }
        guard !shown.isEmpty else { items = []; doneToday = 0; return }
        fetchGeneration += 1
        let generation = fetchGeneration
        let open = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: shown)
        let start = Calendar.current.startOfDay(for: .now)
        let done = store.predicateForCompletedReminders(withCompletionDateStarting: start, ending: nil, calendars: shown)
        store.fetchReminders(matching: open) { reminders in
            let mapped = (reminders ?? []).map(Self.item)
            Task { @MainActor in
                guard generation == self.fetchGeneration else { return }
                self.items = Self.sorted(mapped)
            }
        }
        store.fetchReminders(matching: done) { reminders in
            let count = reminders?.count ?? 0
            Task { @MainActor in
                guard generation == self.fetchGeneration else { return }
                self.doneToday = count
            }
        }
    }

    private nonisolated static func item(_ r: EKReminder) -> TaskItem {
        let comps = r.dueDateComponents
        let due = comps.flatMap { Calendar.current.date(from: $0) }
        return TaskItem(id: r.calendarItemIdentifier, title: r.title ?? "", due: due,
                        hasTime: comps?.hour != nil, listID: r.calendar.calendarIdentifier,
                        done: r.isCompleted, completedAt: r.completionDate)
    }

    /// Overdue and today first by time, later by day, then the ones without a time by title.
    static func sorted(_ items: [TaskItem]) -> [TaskItem] {
        items.sorted { a, b in
            switch (a.due, b.due) {
            case let (x?, y?): return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }
    }

    // MARK: Writing

    private func reminder(_ id: String) -> EKReminder? { store.calendarItem(withIdentifier: id) as? EKReminder }

    /// Adds a task; returns its identifier, or nil when Reminders refused it.
    @discardableResult
    func add(title: String, due: Date?, hasTime: Bool, listID: String?) -> String? {
        guard access == .granted else { return nil }
        let r = EKReminder(eventStore: store)
        r.title = title
        r.calendar = listID.flatMap { id in store.calendars(for: .reminder).first { $0.calendarIdentifier == id } }
            ?? store.defaultCalendarForNewReminders()
        if let due { setDue(r, due, hasTime: hasTime) }
        do {
            try store.save(r, commit: true)
            appendAppLog("nb.log", "[Tasks] added to \(r.calendar.title)\(due == nil ? "" : ", due")")
            reload()
            return r.calendarItemIdentifier
        } catch {
            appendAppLog("nb.log", "[Tasks] add failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func setDue(_ r: EKReminder, _ due: Date, hasTime: Bool) {
        let units: Set<Calendar.Component> = hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
        r.dueDateComponents = Calendar.current.dateComponents(units, from: due)
        // A timed task alerts on every device at its time, as one made in Reminders does.
        r.alarms?.forEach { r.removeAlarm($0) }
        if hasTime { r.addAlarm(EKAlarm(absoluteDate: due)) }
    }

    func setDone(_ id: String, _ done: Bool) {
        guard let r = reminder(id) else { return }
        r.isCompleted = done
        commit(r, "done=\(done)")
    }

    func setDue(_ id: String, _ due: Date?, hasTime: Bool) {
        guard let r = reminder(id) else { return }
        if let due { setDue(r, due, hasTime: hasTime) } else {
            r.dueDateComponents = nil
            r.alarms?.forEach { r.removeAlarm($0) }
        }
        commit(r, "time")
    }

    func move(_ id: String, to listID: String) {
        guard let r = reminder(id), let cal = store.calendars(for: .reminder).first(where: { $0.calendarIdentifier == listID }) else { return }
        r.calendar = cal
        commit(r, "moved")
    }

    func delete(_ id: String) {
        guard let r = reminder(id) else { return }
        do {
            try store.remove(r, commit: true)
            appendAppLog("nb.log", "[Tasks] deleted")
            reload()
        } catch {
            appendAppLog("nb.log", "[Tasks] delete failed: \(error.localizedDescription)")
        }
    }

    private func commit(_ r: EKReminder, _ what: String) {
        do {
            try store.save(r, commit: true)
            appendAppLog("nb.log", "[Tasks] \(what)")
            reload()
        } catch {
            appendAppLog("nb.log", "[Tasks] \(what) failed: \(error.localizedDescription)")
        }
    }

    #if DEBUG
    /// Snapshots only: sample lists and tasks, as if Reminders had answered (never written anywhere).
    private var debugFrozen = false

    func debugFill() {
        debugFrozen = true
        let cal = Calendar.current, now = Date.now
        access = .granted
        lists = [TaskList(id: "w", title: "Work", color: Color(hex: "#0A84FF")),
                 TaskList(id: "p", title: "Personal", color: Color(hex: "#FF9F0A")),
                 TaskList(id: "g", title: "Groceries", color: Color(hex: "#30D158"))]
        let today = cal.startOfDay(for: now)
        func at(_ h: Int, _ m: Int, dayOffset: Int = 0) -> Date {
            cal.date(bySettingHour: h, minute: m, second: 0, of: cal.date(byAdding: .day, value: dayOffset, to: today)!)!
        }
        items = Self.sorted([
            TaskItem(id: "1", title: "Send the build to the testers", due: now.addingTimeInterval(-3 * 3600), hasTime: true, listID: "w", done: false),
            TaskItem(id: "2", title: "Review the Briefs preview", due: now.addingTimeInterval(10 * 60), hasTime: true, listID: "w", done: false),
            TaskItem(id: "5", title: "Stretch for a minute", due: now.addingTimeInterval(40), hasTime: true, listID: "p", done: false),
            TaskItem(id: "3", title: "Call the bank about the card", due: at(9, 0, dayOffset: 1), hasTime: true, listID: "p", done: false),
            TaskItem(id: "4", title: "Milk, eggs, coffee beans", due: nil, hasTime: false, listID: "g", done: false),
            TaskItem(id: "6", title: "Renew the passport", due: at(11, 0, dayOffset: 3), hasTime: true, listID: "p", done: false),
            TaskItem(id: "7", title: "Quarterly review deck", due: at(0, 0, dayOffset: 10), hasTime: false, listID: "w", done: false),
        ])
        doneToday = 3
        TaskDueSoon.shared.update()
        appendAppLog("nb.log", "[Tasks] sample: due soon \(TaskDueSoon.shared.next.map { "\($0.title) at \($0.due.formatted(date: .omitted, time: .shortened))" } ?? "none")")
    }
    #endif

    /// Opens the Reminders app, where every task and the done history live.
    func openReminders() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
            NSWorkspace.shared.openApplication(at: app, configuration: .init(), completionHandler: nil)
        }
    }
}
/// The next timed task due within 15 minutes, for the closed notch's right wing (in the clock's
/// place until it is due; the Time's up card takes over then).
@MainActor
final class TaskDueSoon: ObservableObject {
    static let shared = TaskDueSoon()
    static let lead: TimeInterval = 15 * 60

    struct Due: Equatable {
        let title: String
        let due: Date
        let color: Color
        /// An event's name, shown before its time ("Stand-up 10:30"); a task shows its time alone.
        var label: String? = nil
    }

    @Published private(set) var next: Due?
    private var timer: Timer?
    private var itemsWatch: AnyCancellable?
    private var eventsWatch: AnyCancellable?

    private init() {
        itemsWatch = TasksStore.shared.$items.receive(on: DispatchQueue.main).sink { _ in
            MainActor.assumeIsolated { TaskDueSoon.shared.update() }
        }
        eventsWatch = CalendarStore.shared.$events.receive(on: DispatchQueue.main).sink { _ in
            MainActor.assumeIsolated { TaskDueSoon.shared.update() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { TaskDueSoon.shared.update() }
        }
        timer?.tolerance = 5
    }

    func update() {
        let store = TasksStore.shared
        let now = Date.now
        // The next calendar event inside the minutes chosen in Settings → Agenda → Calendar.
        let cal = CalendarSettings.shared
        let event: Due? = (cal.enabled && cal.wing && CalendarStore.shared.access == .granted)
            ? CalendarStore.shared.nextEvent(now: now).flatMap { e in
                guard e.start > now, e.start.timeIntervalSince(now) <= TimeInterval(cal.wingMinutes * 60) else { return nil }
                return Due(title: e.title, due: e.start, color: CalendarStore.shared.calendar(e.calendarID)?.color ?? .blue,
                           label: Self.short(e.title))
            }
            : nil
        guard TasksSettings.shared.enabled, store.access == .granted else {
            if next != event { next = event }
            return
        }
        let shown = Set(store.shownLists.map(\.id))
        let task = store.items
            .filter { $0.hasTime && shown.contains($0.listID) }
            .compactMap { item -> Due? in
                guard let due = item.due, due > now, due.timeIntervalSince(now) <= Self.lead else { return nil }
                return Due(title: item.title, due: due, color: store.list(item.listID)?.color ?? .blue)
            }
            .min { $0.due < $1.due }
        // The sooner of the two; at the same minute the task comes first.
        let soon: Due?
        switch (task, event) {
        case let (t?, e?): soon = e.due.timeIntervalSince(t.due) < -59 ? e : t
        case let (t?, nil): soon = t
        default: soon = event
        }
        if soon != next { next = soon }
    }

    /// An event's name for the wing: its first words, at most 16 characters.
    static func short(_ title: String) -> String {
        guard title.count > 16 else { return title }
        return String(title.prefix(15)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// The right wing's due time: the list's colour and the time ("5:30").
struct TaskDueWing: View {
    let due: TaskDueSoon.Due

    /// "3:32" on a 12-hour Mac, "15:32" on a 24-hour one: the wing has no room for AM/PM.
    static let clock: DateFormatter = {
        let f = DateFormatter()
        let twelve = (DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a")
        f.dateFormat = twelve ? "h:mm" : "H:mm"
        return f
    }()

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(due.color).frame(width: 7, height: 7)
            if let label = due.label {
                Text(label).font(.system(size: 11, weight: .semibold)).foregroundColor(Color(hex: "#E1E3E6"))
            }
            Text(Self.clock.string(from: due.due))
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundColor(Color(hex: "#E1E3E6"))
        }
        .fixedSize()
        .help("\(due.title) at \(due.due.formatted(date: .omitted, time: .shortened))")
    }
}
#endif
