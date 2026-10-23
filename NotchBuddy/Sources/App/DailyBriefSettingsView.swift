#if !APPSTORE
import SwiftUI

// coucou-custom fork: the Coucou window's Daily brief page — whether it comes, how (from the notch
// or full screen), when, which day it tells about, and which cards it has.

struct HubDailyBriefPage: View {
    @ObservedObject private var settings = DailyBriefSettings.shared

    var body: some View {
        HubPageScaffold(title: String(localized: "Daily brief"), subtitle: String(localized: "hub.notch.brief")) {
            hero

            HubLabel("When")
            HubCard {
                HubRow(title: "Comes up", detail: triggerDetail) {
                    RunnerChips(values: DailyBriefTrigger.allCases, label: { t in
                        switch t { case .firstUse: "First time at the Mac"; case .atTime: "At a time"; case .manual: "Only when I open it" }
                    }, selection: $settings.trigger)
                }
                if settings.trigger != .manual {
                    HubDivider()
                    HubRow(title: settings.trigger == .firstUse ? "Not before" : "At") {
                        DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute)
                            .labelsHidden().datePickerStyle(.field).frame(width: 90)
                    }
                }
                HubDivider()
                HubRow(title: "Tells about", detail: "A morning brief looks back on yesterday; an evening one sums up today.") {
                    RunnerChips(values: DailyBriefPeriod.allCases, label: { p in
                        switch p { case .auto: "Before noon yesterday, then today"; case .yesterday: "Yesterday"; case .today: "Today" }
                    }, selection: $settings.period)
                }
            }

            HubLabel("How")
            HubCard {
                HubRow(title: "Style", detail: settings.style == .banner
                       ? "A banner grows out of the notch with the day in a line and a few numbers; click it for the full brief."
                       : "The full brief over a dimmed screen, card after card.") {
                    RunnerChips(values: DailyBriefStyle.allCases, label: { $0 == .banner ? "Notch banner" : "Full screen" },
                                selection: $settings.style)
                }
                HubDivider()
                HubRow(title: "Next card by itself after", detail: "Or move with a click, the arrow keys, Space or Return.") {
                    RunnerChips(values: DailyBriefSettings.autoAdvanceChoices, label: { $0 == 0 ? "Never" : "\($0) s" },
                                selection: $settings.autoAdvance)
                }
                HubDivider()
                HubRow(title: "Sound", detail: "Coucou's greeting as it comes up.") {
                    Toggle("", isOn: $settings.sound).toggleStyle(.switch).labelsHidden()
                }
                HubDivider()
                HubRow(title: "Your name", detail: "In the greeting. Empty: your first name from macOS (\(resolveUserFirstName() ?? "none found")).") {
                    HubField(placeholder: resolveUserFirstName() ?? "Name", text: $settings.name).frame(width: 180)
                }
            }

            HubLabel("Cards")
            HubCard {
                ForEach(Array(order.enumerated()), id: \.element) { i, section in
                    if i > 0 { HubDivider() }
                    let on = settings.sections.contains(section)
                    HStack(spacing: 12) {
                        Image(systemName: section.symbol).font(.system(size: 12, weight: .semibold))
                            .foregroundColor(on ? HubTheme.accent : HubTheme.muted)
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill((on ? HubTheme.accent : HubTheme.muted).opacity(0.14)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.title).font(.system(size: 13.5, weight: .medium))
                            Text(section.detail).font(.system(size: 12)).foregroundColor(HubTheme.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        if on {
                            HubIconButton(symbol: "chevron.up", help: "Move up") { move(section, -1) }
                                .disabled(settings.sections.first == section).opacity(settings.sections.first == section ? 0.35 : 1)
                            HubIconButton(symbol: "chevron.down", help: "Move down") { move(section, 1) }
                                .disabled(settings.sections.last == section).opacity(settings.sections.last == section ? 0.35 : 1)
                        }
                        Toggle("", isOn: Binding(get: { on }, set: { settings.toggle(section, $0) }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                }
                HubNote(text: "Everything stays on this Mac. The weather is asked from Open-Meteo for your city, the calendar is read here, and the Mac's day is one reading a minute, kept 14 days, only while the brief shows it.")
            }
        }
    }

    private var hero: some View {
        HubGlowCard(color: Color(hex: "#F7B32B"), padding: 22) {
            HStack(spacing: 20) {
                HubLiveMochi(color: "#F5F6F8", size: 64, state: .idle).frame(width: 80, height: 62)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Circle().fill(settings.enabled ? HubTheme.green : HubTheme.muted).frame(width: 7, height: 7)
                        Text(settings.enabled ? "On · \(settings.style == .banner ? "from the notch" : "full screen")" : "Off")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(settings.enabled ? HubTheme.green : HubTheme.secondary)
                    }
                    Text("Your day, in a minute").font(.system(size: 21, weight: .bold))
                    Text("Once a day: the weather, what your agents did, your routines, the Mac's day, your Claude plan and what's on your calendar — then Mochi wishes you a good one.")
                        .font(.system(size: 13)).foregroundColor(HubTheme.body).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Toggle(isOn: $settings.enabled) { Text("Show the Daily brief").font(.system(size: 13, weight: .semibold)) }
                            .toggleStyle(.switch)
                        Spacer(minLength: 8)
                        Button("Show it now") { DailyBriefController.shared.show(force: true) }.buttonStyle(HubButtonStyle(primary: true))
                    }
                }
            }
        }
    }

    private var order: [DailyBriefSection] {
        settings.sections + DailyBriefSection.allCases.filter { !settings.sections.contains($0) }
    }

    private func move(_ s: DailyBriefSection, _ delta: Int) {
        guard let i = settings.sections.firstIndex(of: s), settings.sections.indices.contains(i + delta) else { return }
        settings.sections.swapAt(i, i + delta)
    }

    private var triggerDetail: String {
        switch settings.trigger {
        case .firstUse: "The first time you are at the Mac after the time below: when you wake it, unlock it or start Coucou. Once a day."
        case .atTime: "At the time below, if you are at the Mac then. Once a day."
        case .manual: "From the menu-bar panel (Daily brief) or the button above."
        }
    }

    private var timeBinding: Binding<Date> {
        Binding(get: {
            Calendar.current.date(byAdding: .minute, value: settings.minuteOfDay, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        }, set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            settings.minuteOfDay = (c.hour ?? 8) * 60 + (c.minute ?? 0)
        })
    }
}

/// Settings → Buddy: which routine moments take the whole screen.
struct BuddyFullScreenCard: View {
    @ObservedObject private var settings = RoutineMomentSettings.shared

    var body: some View {
        HubCard {
            Text("A routine's moment over the whole screen, Mochi in the middle, instead of the Buddy's card. Return and Esc work on it when Coucou has the keyboard; it never takes it from what you type. The Buddy's companions wait in its pouch meanwhile.")
                .font(.system(size: 12.5)).foregroundColor(HubTheme.body).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(RoutineMomentKind.allCases.enumerated()), id: \.element) { i, kind in
                if i > 0 { HubDivider() }
                HubRow(title: kind.title, detail: kind.closesByItself ? "A short moment, gone by itself." : "Waits for you.") {
                    Toggle("", isOn: Binding(get: { settings.wants(kind) }, set: { settings.toggle(kind, $0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }
            HubDivider()
            HubRow(title: "A start stays", detail: "Focus starts and timer starts.") {
                RunnerChips(values: RoutineMomentSettings.startChoices, label: { "\($0) s" }, selection: $settings.startSeconds)
            }
            HubDivider()
            HubRow(title: "Screen behind", detail: "How dark it goes.") {
                HStack(spacing: 8) {
                    Slider(value: $settings.dim, in: 0.2...0.85).frame(width: 150)
                    Text(MetricsFormat.percent(settings.dim)).font(.system(size: 12).monospacedDigit()).foregroundColor(HubTheme.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
            HStack {
                Spacer()
                Button("Try it") {
                    RoutineMoments.shared.preview()
                }
                .buttonStyle(HubButtonStyle())
            }
        }
    }
}
#endif
