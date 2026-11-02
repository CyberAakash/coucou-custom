#if !APPSTORE
import SwiftUI

// MARK: - Settings → Calendar (coucou-custom fork, roadmap phase 3)
//
// Events in the notch's Agenda on or off, access and Internet Accounts, the calendars by account
// (shown or not, where new events go), and the meetings: the next one in the closed wing, the
// Join card when one starts.

struct HubCalendarPage: View {
    @ObservedObject private var store = CalendarStore.shared
    @ObservedObject private var settings = CalendarSettings.shared

    static let tint = Color(hex: "#0A84FF")

    var body: some View {
        HubPageScaffold(title: "Calendar",
                        subtitle: "Your events in the notch's Agenda beside your tasks, the next meeting in the closed wing, and a Join button when it starts.",
                        trailing: { HubBannerSwitch(title: "In the Agenda", tint: Self.tint, isOn: $settings.enabled) }) {
            HubLabel("Calendar")
            HubCard {
                HubRow(title: "Calendars on this Mac", detail: accessDetail) {
                    switch store.access {
                    case .granted:
                        Button("Open Internet Accounts") { store.openInternetAccounts() }.buttonStyle(HubButtonStyle())
                    case .unknown:
                        Button("Allow access") { Task { await store.requestAccess() } }.buttonStyle(HubButtonStyle(primary: true))
                    case .denied:
                        Button("Open System Settings") { store.openPrivacySettings() }.buttonStyle(HubButtonStyle())
                    }
                }
            }

            if store.access == .granted {
                HubLabel("Calendars")
                HubCard {
                    if store.calendars.isEmpty {
                        Text("No calendars on this Mac yet.").font(.system(size: 13)).foregroundColor(HubTheme.secondary)
                    }
                    ForEach(accounts, id: \.self) { account in
                        Text(account.uppercased())
                            .font(.system(size: 10.5, weight: .heavy)).tracking(1).foregroundColor(HubTheme.muted)
                            .padding(.top, account == accounts.first ? 0 : 10)
                        ForEach(store.calendars.filter { $0.account == account }) { calendarRow($0) }
                    }
                }
            }

            HubLabel("Meetings")
            HubCard {
                HubRow(title: "Next event in the closed notch", detail: "Its name and time in the right wing, this long before it starts; a task due at the same time comes first.") {
                    HStack(spacing: 10) {
                        Picker("", selection: $settings.wingMinutes) {
                            ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) min").tag($0) }
                        }
                        .labelsHidden().fixedSize().disabled(!settings.wing)
                        Toggle("", isOn: $settings.wing).toggleStyle(.switch).labelsHidden()
                    }
                }
                HubDivider()
                HubRow(title: "Join card", detail: "Below the notch when a meeting with a Zoom, Meet, Teams or Webex link starts; Join opens it in its app.") {
                    HStack(spacing: 10) {
                        Picker("", selection: $settings.joinLead) {
                            Text("At the start").tag(0)
                            Text("1 min before").tag(1)
                            Text("5 min before").tag(5)
                        }
                        .labelsHidden().fixedSize().disabled(!settings.join)
                        Toggle("", isOn: $settings.join).toggleStyle(.switch).labelsHidden()
                    }
                }
            }
        }
        .onAppear { store.reload() }
    }

    private var accounts: [String] {
        var seen: [String] = []
        for c in store.calendars where !seen.contains(c.account) { seen.append(c.account) }
        return seen
    }

    private var accessDetail: String {
        switch store.access {
        case .granted: return "iCloud, Google and Exchange calendars added in System Settings → Internet Accounts show here; Coucou reads them on this Mac, nothing leaves it."
        case .unknown: return "Coucou asks once; nothing leaves the Mac."
        case .denied: return "Coucou is not allowed: turn it on in Privacy & Security → Calendars."
        }
    }

    private func calendarRow(_ c: CalCalendar) -> some View {
        let shown = !settings.hidden.contains(c.id)
        let isNew = store.newEventCalendar?.id == c.id
        return HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { shown }, set: { on in
                if on { settings.hidden.remove(c.id) } else { settings.hidden.insert(c.id) }
                store.reload()
            }))
            .toggleStyle(.checkbox).labelsHidden()
            Circle().fill(c.color).frame(width: 10, height: 10)
            Text(c.title).font(.system(size: 13.5, weight: .medium))
                .foregroundColor(shown ? HubTheme.text : HubTheme.secondary)
            Spacer(minLength: 8)
            if !c.writable {
                Text("Read only").font(.system(size: 12)).foregroundColor(HubTheme.muted)
            } else if isNew {
                Text("New events go here").font(.system(size: 12)).foregroundColor(HubTheme.secondary)
            } else {
                Button("Make new events go here") { settings.newCalendar = c.id }
                    .buttonStyle(.plain).pointer()
                    .font(.system(size: 12, weight: .medium)).foregroundColor(HubTheme.accent)
            }
        }
        .padding(.vertical, 2)
    }
}
#endif
