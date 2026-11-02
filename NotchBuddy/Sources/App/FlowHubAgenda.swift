#if !APPSTORE
import SwiftUI

// MARK: - Settings → Agenda (coucou-custom fork)
//
// The notch's Agenda shows tasks and events together, so their settings are one page with a tab
// each: Tasks (Reminders, the lists, where reminders show) and Calendar (the calendars, the wing,
// the Join card). Each tab keeps its own switch: the Agenda shows when either is on.

struct HubAgendaPage: View {
    enum Tab: String, CaseIterable { case tasks, calendar }

    @AppStorage("agendaSettingsTab") private var tabRaw = Tab.tasks.rawValue

    private var tab: Tab { Tab(rawValue: tabRaw) ?? .tasks }

    var body: some View {
        HubPageScaffold(title: "Agenda",
                        subtitle: "Your tasks from Reminders and your events from the Mac's calendars, together in the notch's Agenda.",
                        trailing: { EmptyView() },
                        pinned: {
            BriefSegmented(options: [BriefSegmentedOption(value: Tab.tasks, title: "Tasks", symbol: "checklist"),
                                     BriefSegmentedOption(value: Tab.calendar, title: "Calendar", symbol: "calendar")],
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
            }
        }
    }
}
#endif
