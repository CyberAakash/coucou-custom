#if !APPSTORE
import SwiftUI

// MARK: - Settings → Routines → Tasks (coucou-custom fork, roadmap phase 2)
//
// The notch's Tasks page on or off, access to Reminders, and the lists: which ones show in the
// notch and which one new tasks go to. The tasks themselves live in Reminders.

struct HubTasksSettings: View {
    @ObservedObject private var store = TasksStore.shared
    @ObservedObject private var settings = TasksSettings.shared

    var body: some View {
        HubLabel("Tasks")
        HubCard {
            HubRow(title: "Tasks page in the notch",
                   detail: "Your Reminders: type a task with a day, a time and #list; tick them off. Timed ones bring the Time's up card and show in the closed notch 15 minutes before.") {
                Toggle("", isOn: $settings.enabled).toggleStyle(.switch).labelsHidden()
            }
            HubDivider()
            HubRow(title: "Reminders", detail: accessDetail) {
                switch store.access {
                case .granted:
                    Button("Open Reminders") { store.openReminders() }.buttonStyle(HubButtonStyle())
                case .unknown:
                    Button("Allow access") { Task { await store.requestAccess() } }.buttonStyle(HubButtonStyle(primary: true))
                case .denied:
                    Button("Open System Settings") { store.openPrivacySettings() }.buttonStyle(HubButtonStyle())
                }
            }
        }

        if store.access == .granted {
            HubLabel("Lists")
            HubCard {
                if store.lists.isEmpty {
                    Text("No lists in Reminders yet.").font(.system(size: 13)).foregroundColor(HubTheme.secondary)
                }
                ForEach(Array(store.lists.enumerated()), id: \.element.id) { i, list in
                    if i > 0 { HubDivider() }
                    listRow(list)
                }
                Text("The lists shown in the notch, with Reminders' own colours. Done tasks stay in Reminders; the notch counts today's.")
                    .font(.system(size: 12)).foregroundColor(HubTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }

    private var accessDetail: String {
        switch store.access {
        case .granted: return "Coucou reads and writes your Reminders on this Mac; they sync to your iPhone and Watch through iCloud as usual."
        case .unknown: return "Coucou asks once; nothing leaves the Mac."
        case .denied: return "Coucou is not allowed: turn it on in Privacy & Security → Reminders."
        }
    }

    private func listRow(_ list: TaskList) -> some View {
        let shown = !settings.hiddenLists.contains(list.id)
        let isNew = store.newTaskList?.id == list.id
        return HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { shown }, set: { on in
                if on { settings.hiddenLists.remove(list.id) } else { settings.hiddenLists.insert(list.id) }
                store.reload()
            }))
            .toggleStyle(.checkbox).labelsHidden()
            Circle().fill(list.color).frame(width: 10, height: 10)
            Text(list.title).font(.system(size: 13.5, weight: .medium))
                .foregroundColor(shown ? HubTheme.text : HubTheme.secondary)
            Spacer(minLength: 8)
            if isNew {
                Text("New tasks go here").font(.system(size: 12)).foregroundColor(HubTheme.secondary)
            } else {
                Button("Make new tasks go here") { settings.newList = list.id }
                    .buttonStyle(.plain).pointer()
                    .font(.system(size: 12, weight: .medium)).foregroundColor(HubTheme.accent)
            }
        }
        .padding(.vertical, 2)
    }
}
#endif
