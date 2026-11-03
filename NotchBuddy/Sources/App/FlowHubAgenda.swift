#if !APPSTORE
import SwiftUI

// MARK: - Settings → Agenda (coucou-custom fork)
//
// The notch's Agenda shows tasks and events together, so their settings are one page with a tab
// each: Tasks (Reminders, the lists, where reminders show), Calendar (the calendars, alerts, the
// wing, the Join card) and Composer (what a new line starts as, your templates). Tasks and Calendar
// keep their own switch: the Agenda shows when either is on.

/// What a swipe across an Agenda row does (Settings → Agenda → Composer → Swipes).
enum AgendaSwipe: String, CaseIterable, Identifiable {
    case done, hour, tomorrow, nextWeek, delete, open, copyLink, none
    var id: String { rawValue }

    static let taskChoices: [AgendaSwipe] = [.done, .hour, .tomorrow, .nextWeek, .delete, .none]
    static let eventChoices: [AgendaSwipe] = [.open, .copyLink, .none]

    var title: String {
        switch self {
        case .done: "Done"
        case .hour: "In an hour"
        case .tomorrow: "Tomorrow"
        case .nextWeek: "Next week"
        case .delete: "Delete"
        case .open: "Join or open"
        case .copyLink: "Copy link"
        case .none: "Nothing"
        }
    }

    var symbol: String {
        switch self {
        case .done: "checkmark"
        case .hour, .tomorrow, .nextWeek: "clock"
        case .delete: "trash"
        case .open: "arrow.up.right.square"
        case .copyLink: "link"
        case .none: ""
        }
    }

    /// The colour behind the row as it slides.
    var color: Color {
        switch self {
        case .done: Color(hex: "#1F7A3D")
        case .hour, .tomorrow, .nextWeek: Color(hex: "#8A5A12")
        case .delete: Color(hex: "#9F1D2A")
        case .open, .copyLink: Color(hex: "#0A5FC2")
        case .none: .clear
        }
    }
}

/// Settings → Agenda → Composer: what a new line starts as, and your templates.
@MainActor
final class AgendaComposerSettings: ObservableObject {
    static let shared = AgendaComposerSettings()
    private let ud = UserDefaults.standard

    /// A new line is an event rather than a task (/task, /event and Tab still choose).
    @Published var eventsFirst: Bool { didSet { ud.set(eventsFirst, forKey: "agendaEventsFirst") } }
    /// An event's length when none is typed.
    @Published var eventMinutes: Int { didSet { ud.set(eventMinutes, forKey: "agendaEventMinutes") } }
    /// An alert saved on a new event when none is typed, minutes before; -1 none.
    @Published var newEventAlert: Int { didSet { ud.set(newEventAlert, forKey: "agendaNewEventAlert") } }
    @Published var eventHint: Bool { didSet { ud.set(eventHint, forKey: "agendaEventHint") } }
    @Published var suggestions: Bool { didSet { ud.set(suggestions, forKey: "agendaSuggestions") } }
    /// Swipes across a row: right and left, for a task and for an event.
    @Published var taskRight: AgendaSwipe { didSet { ud.set(taskRight.rawValue, forKey: "agendaSwipeTaskRight") } }
    @Published var taskLeft: AgendaSwipe { didSet { ud.set(taskLeft.rawValue, forKey: "agendaSwipeTaskLeft") } }
    @Published var eventRight: AgendaSwipe { didSet { ud.set(eventRight.rawValue, forKey: "agendaSwipeEventRight") } }
    @Published var eventLeft: AgendaSwipe { didSet { ud.set(eventLeft.rawValue, forKey: "agendaSwipeEventLeft") } }
    @Published var templates: [AgendaTemplate] {
        didSet { ud.set(try? JSONEncoder().encode(templates), forKey: "agendaTemplates") }
    }

    private init() {
        eventsFirst = ud.bool(forKey: "agendaEventsFirst")
        eventMinutes = ud.object(forKey: "agendaEventMinutes") as? Int ?? 60
        newEventAlert = ud.object(forKey: "agendaNewEventAlert") as? Int ?? -1
        eventHint = ud.object(forKey: "agendaEventHint") as? Bool ?? true
        suggestions = ud.object(forKey: "agendaSuggestions") as? Bool ?? true
        taskRight = Self.swipe("agendaSwipeTaskRight", .done)
        taskLeft = Self.swipe("agendaSwipeTaskLeft", .tomorrow)
        eventRight = Self.swipe("agendaSwipeEventRight", .open)
        eventLeft = Self.swipe("agendaSwipeEventLeft", .none)
        templates = (ud.data(forKey: "agendaTemplates")).flatMap { try? JSONDecoder().decode([AgendaTemplate].self, from: $0) } ?? []
    }
}

extension AgendaComposerSettings {
    fileprivate static func swipe(_ key: String, _ fallback: AgendaSwipe) -> AgendaSwipe {
        UserDefaults.standard.string(forKey: key).flatMap(AgendaSwipe.init(rawValue:)) ?? fallback
    }
}

struct HubAgendaPage: View {
    enum Tab: String, CaseIterable { case tasks, calendar, composer }

    @AppStorage("agendaSettingsTab") private var tabRaw = Tab.tasks.rawValue

    private var tab: Tab { Tab(rawValue: tabRaw) ?? .tasks }

    var body: some View {
        HubPageScaffold(title: "Agenda",
                        subtitle: "Your tasks from Reminders and your events from the Mac's calendars, together in the notch's Agenda.",
                        trailing: { EmptyView() },
                        pinned: {
            BriefSegmented(options: [BriefSegmentedOption(value: Tab.tasks, title: "Tasks", symbol: "checklist"),
                                     BriefSegmentedOption(value: Tab.calendar, title: "Calendar", symbol: "calendar"),
                                     BriefSegmentedOption(value: Tab.composer, title: "Composer", symbol: "text.cursor")],
                           selection: Binding(get: { tab }, set: { tabRaw = $0.rawValue }),
                           tint: HubCalendarSettings.tint, height: 38)
        }, aside: { EmptyView() }, showsAside: false) {
            switch tab {
            case .tasks:
                HubTasksSettings()
                HubLabel("Where reminders show")
                BuddyAlertPlaces(kinds: [.reminder], trial: true)
            case .calendar:
                HubCalendarSettings()
            case .composer:
                HubComposerSettings()
            }
        }
    }
}

/// What a new line starts as, and your templates: your own slash commands.
struct HubComposerSettings: View {
    @ObservedObject private var settings = AgendaComposerSettings.shared
    @State private var editing: String?      // a template's name, or "" for a new one
    @State private var name = ""
    @State private var line = ""

    var body: some View {
        Group { content }
        #if DEBUG
        .onAppear {
            guard let e = KeepDebug.composerEditing else { return }
            if e == "help" { name = "help"; line = "x"; editing = "" }
            else if let t = settings.templates.first(where: { $0.name == e }) { name = t.name; line = t.line; editing = e }
            else { editing = "" }
        }
        #endif
    }

    @ViewBuilder private var content: some View {
        HubLabel("Defaults")
        HubCard {
            HubRow(title: "A new line is", detail: "/task, /event or Tab still choose for each line.") {
                HubDropdown($settings.eventsFirst, [(false, "A task"), (true, "An event")])
            }
            HubDivider()
            HubRow(title: "Event length", detail: "When none is typed (\"for 45m\").") {
                HubDropdown($settings.eventMinutes, [15, 30, 45, 60, 90, 120].map { m in
                    (m, m % 60 == 0 ? (m == 60 ? "1 hour" : "\(m / 60) hours") : (m > 60 ? "1 h 30 min" : "\(m) min"))
                })
            }
            HubDivider()
            HubRow(title: "Alert saved on new events", detail: "Kept on the event when none is typed, so the iPhone and the Watch ring too.") {
                HubDropdown($settings.newEventAlert, [(-1, "None"), (0, "At the start")]
                    + [5, 10, 15, 30, 60].map { ($0, $0 == 60 ? "1 hour before" : "\($0) min before") })
            }
            HubDivider()
            HubRow(title: "\"Looks like an event\" hint", detail: "On a task line with a length or a range.") {
                Toggle("", isOn: $settings.eventHint).toggleStyle(.switch).labelsHidden().disabled(settings.eventsFirst)
            }
            HubDivider()
            HubRow(title: "Suggestions while typing", detail: "The menus for / and #. The chips and the help (?) stay.") {
                Toggle("", isOn: $settings.suggestions).toggleStyle(.switch).labelsHidden()
            }
        }

        HubLabel("Swipes")
        HubCard {
            Text("Two fingers across a row, as in Gmail; with a mouse, drag the row. Past a third it acts, then offers Undo.")
                .font(.system(size: 12.5)).foregroundColor(HubTheme.secondary).fixedSize(horizontal: false, vertical: true)
            HubDivider()
            swipeRow("Task, swipe right", $settings.taskRight, AgendaSwipe.taskChoices)
            HubDivider()
            swipeRow("Task, swipe left", $settings.taskLeft, AgendaSwipe.taskChoices)
            HubDivider()
            swipeRow("Event, swipe right", $settings.eventRight, AgendaSwipe.eventChoices)
            HubDivider()
            swipeRow("Event, swipe left", $settings.eventLeft, AgendaSwipe.eventChoices)
        }

        HubLabel("Templates")
        HubCard {
            Text("Your own slash commands: type /name and a space, or pick it from the / menu, and its line fills the composer, ready to change.")
                .font(.system(size: 12.5)).foregroundColor(HubTheme.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(settings.templates) { t in
                HubDivider()
                if editing == t.name { editor(original: t) } else { row(t) }
            }
            HubDivider()
            if editing == "" {
                editor(original: nil)
            } else {
                Button("+ New template") { name = ""; line = ""; editing = "" }
                    .buttonStyle(.plain).pointer()
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(HubTheme.accent)
                    .padding(.vertical, 4)
            }
        }
    }

    private func swipeRow(_ title: String, _ value: Binding<AgendaSwipe>, _ choices: [AgendaSwipe]) -> some View {
        HubRow(title: title, detail: "") {
            HubDropdown(value, choices.map { ($0, $0.title) })
        }
    }

    private func row(_ t: AgendaTemplate) -> some View {
        HStack(spacing: 14) {
            Text("/" + t.name).font(.system(size: 13, design: .monospaced)).foregroundColor(Color(hex: "#67E8F9"))
                .frame(width: 120, alignment: .leading)
            Text(t.line).font(.system(size: 13)).foregroundColor(HubTheme.text).lineLimit(1)
            Spacer(minLength: 8)
            Button("Edit") { name = t.name; line = t.line; editing = t.name }
                .buttonStyle(.plain).pointer().font(.system(size: 12.5, weight: .medium)).foregroundColor(HubTheme.accent)
        }
        .padding(.vertical, 3)
    }

    private func editor(original: AgendaTemplate?) -> some View {
        let others = settings.templates.filter { $0.name != original?.name }
        let problem = AgendaTemplate.problem(name, others: others)
            ?? (line.trimmingCharacters(in: .whitespaces).isEmpty ? "Give it a line, as you would type it." : nil)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("/").font(.system(size: 13, design: .monospaced)).foregroundColor(Color(hex: "#67E8F9"))
                TextField("name", text: $name).textFieldStyle(.roundedBorder).frame(width: 140)
                TextField("The line, e.g. /e Standup 9:30 for 15m every weekday #work", text: $line).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 10) {
                if let problem, !(name.isEmpty && line.isEmpty) {
                    Text(problem).font(.system(size: 12)).foregroundColor(HubTheme.secondary)
                }
                Spacer(minLength: 0)
                if let original {
                    Button("Delete", role: .destructive) {
                        settings.templates.removeAll { $0.name == original.name }
                        editing = nil
                    }
                    .buttonStyle(HubButtonStyle())
                }
                Button("Cancel") { editing = nil }.buttonStyle(HubButtonStyle())
                Button("Save") {
                    let t = AgendaTemplate(name: name.lowercased(), line: line.trimmingCharacters(in: .whitespaces))
                    if let original, let i = settings.templates.firstIndex(where: { $0.name == original.name }) {
                        settings.templates[i] = t
                    } else {
                        settings.templates.append(t)
                    }
                    editing = nil
                }
                .buttonStyle(HubButtonStyle(primary: true)).disabled(problem != nil)
            }
        }
        .padding(.vertical, 4)
    }
}
#endif
