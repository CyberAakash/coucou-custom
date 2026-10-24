#if !APPSTORE
import SwiftUI
import AppKit
import Combine

// coucou-custom fork: the Buddy page's Wardrobe, Shadow and Clicks, in the Coucou window's style.
// The wardrobe follows OpenPets' Control Center: outfit cards (Now, Always), a status line with
// Follow schedule, and the schedule's rules — on/off, edit, reorder, delete, add, reset.

// MARK: - Shadow

struct BuddyShadowChips: View {
    @Binding var opacity: Double

    var body: some View {
        let preset = BuddyShadow.preset(opacity: opacity)
        BriefSegmented(options: BuddyShadow.allCases.map { BriefSegmentedOption(value: $0.opacity, title: $0.label) }
                       + [BriefSegmentedOption(value: -1, title: "Custom", symbol: "slider.horizontal.3")],
                       selection: Binding(get: { preset == nil ? -1 : opacity }, set: { v in
                           if v < 0 {
                               // Nudge off the preset so the slider shows, starting where the shadow is now.
                               if preset != nil { opacity = min(opacity + 0.02, BuddyShadow.customRange.upperBound) }
                           } else {
                               opacity = v
                           }
                       }), tint: HubBuddyPage.tint)
    }
}

/// A custom value under its preset row. `live: false` applies the value when the slider is
/// released (resizing the Buddy rebuilds its window, too heavy for every step of a drag).
struct BuddyCustomSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let low: String
    let high: String
    var live = false
    let readout: (Double) -> String
    @State private var draft: Double?

    var body: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Text(low).font(.system(size: 11)).foregroundColor(HubTheme.secondary)
            Slider(value: Binding(get: { draft ?? value }, set: { v in if live { value = v } else { draft = v } }),
                   in: range, step: step,
                   onEditingChanged: { editing in
                       if !editing, let d = draft { value = d; draft = nil }
                   })
                .frame(width: 240)
            Text(high).font(.system(size: 11)).foregroundColor(HubTheme.secondary)
            Text(readout(draft ?? value))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(HubTheme.text)
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.top, -4)
    }
}

// MARK: - Wardrobe

struct BuddyWardrobeCard: View {
    @ObservedObject var settings: BuddySettings
    @State private var editing: UUID?
    /// The minute the card shows ("Now" moves with the schedule).
    @State private var now = Date()
    private let minute = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var worn: BuddyOutfit { settings.resolvedOutfit(on: now) }
    private var active: Int? { settings.activeRule(on: now) }

    var body: some View {
        HubCard {
            // Status: following the schedule, or always wearing one.
            HStack(spacing: 10) {
                Image(systemName: settings.alwaysWear == nil ? "calendar.badge.clock" : "pin.fill")
                    .foregroundColor(HubTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.alwaysWear == nil ? "Following the schedule" : "Always wearing \(worn.name)")
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(settings.alwaysWear == nil
                         ? "Now: \(worn.name)" + (active.map { " · " + BuddyWardrobe.describe(settings.schedule[$0].when) } ?? " · no rule matches")
                         : "The schedule is paused. Click the outfit again, or follow the schedule.")
                        .font(.system(size: 12))
                        .foregroundColor(HubTheme.secondary)
                }
                Spacer()
                if settings.alwaysWear != nil {
                    Button("Follow the schedule") { settings.alwaysWear = nil }
                        .buttonStyle(HubButtonStyle())
                }
            }

            // Outfit cards: Now and Always badges; a click toggles "always wear".
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 86, maximum: 110), spacing: 10)], spacing: 10) {
                ForEach(BuddyOutfit.allCases) { outfit in
                    let always = settings.alwaysWear == outfit
                    let isNow = worn == outfit
                    Button { settings.alwaysWear = always ? nil : outfit } label: {
                        VStack(spacing: 6) {
                            BuddyMochiThumb(outfit: outfit, color: settings.color)
                                .frame(width: 58, height: 62)
                            Text(outfit.name)
                                .font(.system(size: 11.5, weight: isNow ? .bold : .medium))
                                .foregroundColor(isNow ? HubTheme.text : HubTheme.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(isNow ? HubTheme.accent.opacity(0.12) : Color.white.opacity(0.03)))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(isNow ? HubTheme.accent : Color.white.opacity(0.07), lineWidth: isNow ? 1.5 : 1))
                        .overlay(alignment: .topTrailing) {
                            if always { badge("Always", system: "pin.fill") }
                            else if isNow { badge("Now", system: nil) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(always ? "Back to the schedule" : "Always wear \(outfit.name)")
                }
            }

            HubDivider()

            // The schedule
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Schedule").font(.system(size: 13.5, weight: .semibold))
                    Text(settings.userSchedule == nil
                         ? "The Buddy's own. The first rule that matches wins; none matching, no outfit."
                         : "Yours. The first rule that matches wins; none matching, no outfit.")
                        .font(.system(size: 12)).foregroundColor(HubTheme.secondary)
                }
                Spacer()
                if settings.userSchedule != nil {
                    Button("Reset to the Buddy's") { editing = nil; settings.userSchedule = nil }
                        .buttonStyle(HubButtonStyle())
                }
                Button {
                    let rule = BuddyWardrobeRule(outfit: .crown, when: BuddyWhen(days: [.sat, .sun]))
                    settings.editSchedule { $0.append(rule) }
                    editing = settings.schedule.last?.id
                } label: { Label("Add a rule", systemImage: "plus") }
                    .buttonStyle(HubButtonStyle(primary: true))
                    .disabled(settings.schedule.count >= BuddyWardrobe.maxRules)
            }

            if settings.schedule.isEmpty {
                Text("No rules: it never changes on its own.")
                    .font(.system(size: 12)).foregroundColor(HubTheme.muted)
            }
            // First match wins: drag a rule up to make it win first.
            HubReorderList(items: Binding(get: { settings.schedule }, set: { new in settings.editSchedule { $0 = new } })) { rule in
                let i = settings.schedule.firstIndex { $0.id == rule.id } ?? 0
                BuddyRuleRow(rule: rule,
                             isActive: settings.alwaysWear == nil && active == i,
                             editing: editing == rule.id, color: settings.color,
                             onEdit: { editing = editing == rule.id ? nil : rule.id },
                             change: { new in settings.editSchedule { s in if let j = s.firstIndex(where: { $0.id == rule.id }) { s[j] = new } } },
                             delete: { settings.editSchedule { $0.removeAll { $0.id == rule.id } } })
            }
        }
        .onReceive(minute) { now = $0 }
    }

    private func badge(_ text: String, system: String?) -> some View {
        HStack(spacing: 3) {
            if let system { Image(systemName: system).font(.system(size: 8, weight: .bold)) }
            Text(text).font(.system(size: 9.5, weight: .bold))
        }
        .foregroundColor(HubTheme.onAccent)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(HubTheme.accent))
        .padding(5)
    }
}

/// One rule: on/off, the outfit, when; edit it inline.
private struct BuddyRuleRow: View {
    let rule: BuddyWardrobeRule
    let isActive: Bool
    let editing: Bool
    let color: String
    let onEdit: () -> Void
    let change: (BuddyWardrobeRule) -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                BriefSwitch(isOn: Binding(get: { rule.enabled }, set: { var r = rule; r.enabled = $0; change(r) }), tint: HubBuddyPage.tint)
                    .controlSize(.small)
                BuddyMochiThumb(outfit: rule.outfit, color: color).frame(width: 30, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(rule.outfit.name).font(.system(size: 13, weight: .semibold))
                        .foregroundColor(rule.enabled ? HubTheme.text : HubTheme.muted)
                    Text(BuddyWardrobe.describe(rule.when)).font(.system(size: 11.5))
                        .foregroundColor(rule.when.isEmpty ? HubTheme.red : HubTheme.secondary)
                }
                if isActive {
                    Text("Active now").font(.system(size: 10, weight: .bold)).foregroundColor(HubTheme.green)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(HubTheme.green.opacity(0.14)))
                }
                Spacer()
                HubIconButton(symbol: editing ? "checkmark" : "pencil", help: editing ? "Done" : "Edit") { onEdit() }
                HubIconButton(symbol: "trash", help: "Delete") { delete() }
            }
            if editing { BuddyRuleEditor(rule: rule, change: change).padding(.leading, 46) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isActive ? HubTheme.green.opacity(0.05) : Color.white.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(isActive ? HubTheme.green.opacity(0.35) : Color.white.opacity(0.06)))
    }
}

/// The rule's outfit and conditions: time of day, weekdays, dates through the year.
private struct BuddyRuleEditor: View {
    let rule: BuddyWardrobeRule
    let change: (BuddyWardrobeRule) -> Void

    private static let months = DateFormatter().shortMonthSymbols ?? []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Wear").frame(width: 70, alignment: .leading)
                BriefComboBox(options: BuddyOutfit.allCases.map { BriefComboOption(value: $0, title: $0.name, symbol: "tshirt") },
                              selection: Binding(get: { rule.outfit }, set: { var r = rule; r.outfit = $0; change(r) }),
                              tint: HubBuddyPage.tint, symbol: "tshirt", width: 240, placeholder: "Search outfits")
            }

            // Time of day
            HStack(spacing: 8) {
                Toggle("Time", isOn: Binding(get: { rule.when.time != nil }, set: { on in
                    var r = rule
                    r.when.time = on ? BuddyTimeRange(from: BuddyClock(hour: 22, minute: 0), to: BuddyClock(hour: 7, minute: 0)) : nil
                    change(r)
                }))
                .frame(width: 70, alignment: .leading)
                if let t = rule.when.time {
                    clockPicker(t.from) { var r = rule; r.when.time?.from = $0; change(r) }
                    Text("to").foregroundColor(HubTheme.secondary)
                    clockPicker(t.to) { var r = rule; r.when.time?.to = $0; change(r) }
                    Text(t.to < t.from ? "past midnight" : "").font(.system(size: 11)).foregroundColor(HubTheme.muted)
                }
            }

            // Weekdays
            HStack(spacing: 8) {
                Toggle("Days", isOn: Binding(get: { rule.when.days != nil }, set: { on in
                    var r = rule; r.when.days = on ? [.sat, .sun] : nil; change(r)
                }))
                .frame(width: 70, alignment: .leading)
                if let days = rule.when.days {
                    HStack(spacing: 4) {
                        ForEach(BuddyWeekday.allCases) { d in
                            let on = days.contains(d)
                            Button {
                                var r = rule
                                var set = r.when.days ?? []
                                if on { set.removeAll { $0 == d } } else { set.append(d) }
                                r.when.days = BuddyWeekday.allCases.filter(set.contains)
                                change(r)
                            } label: {
                                Text(d.short)
                                    .font(.system(size: 11.5, weight: .bold))
                                    .foregroundColor(on ? HubTheme.onAccent : HubTheme.body)
                                    .frame(width: 40, height: 30)
                                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(on ? HubBuddyPage.tint : Color.white.opacity(0.05)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // Dates through the year
            HStack(spacing: 8) {
                Toggle("Dates", isOn: Binding(get: { rule.when.dates != nil }, set: { on in
                    var r = rule
                    r.when.dates = on ? BuddyDateRange(from: BuddyDay(month: 12, day: 1)!, to: BuddyDay(month: 12, day: 26)!) : nil
                    change(r)
                }))
                .frame(width: 70, alignment: .leading)
                if let d = rule.when.dates {
                    dayPicker(d.from) { var r = rule; r.when.dates?.from = $0; change(r) }
                    Text("to").foregroundColor(HubTheme.secondary)
                    dayPicker(d.to) { var r = rule; r.when.dates?.to = $0; change(r) }
                    Text(d.to.ordinal < d.from.ordinal ? "over the new year" : "every year")
                        .font(.system(size: 11)).foregroundColor(HubTheme.muted)
                }
            }

            if rule.when.isEmpty || rule.when.days == [] {
                Label("Give it at least one condition, or it never matches.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11.5)).foregroundColor(HubTheme.red)
            }
        }
        .font(.system(size: 12.5))
    }

    private func clockPicker(_ c: BuddyClock, set: @escaping (BuddyClock) -> Void) -> some View {
        BriefTimePicker(minuteOfDay: Binding(get: { c.minutes }, set: { set(BuddyClock(hour: $0 / 60, minute: $0 % 60)) }),
                        tint: HubBuddyPage.tint, width: 170)
    }

    private func dayPicker(_ d: BuddyDay, set: @escaping (BuddyDay) -> Void) -> some View {
        let lengths = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return HStack(spacing: 6) {
            BriefComboBox(options: (1...12).map { m in BriefComboOption(value: m, title: Self.months.indices.contains(m - 1) ? Self.months[m - 1] : "\(m)") },
                          selection: Binding(get: { d.month }, set: { m in if let n = BuddyDay(month: m, day: min(d.day, lengths[m - 1])) { set(n) } }),
                          tint: HubBuddyPage.tint, symbol: "calendar", width: 130, placeholder: "Month")
            BriefComboBox(options: (1...lengths[d.month - 1]).map { BriefComboOption(value: $0, title: "\($0)") },
                          selection: Binding(get: { d.day }, set: { if let n = BuddyDay(month: d.month, day: $0) { set(n) } }),
                          tint: HubBuddyPage.tint, symbol: "number", width: 100, placeholder: "Day")
        }
    }

}

// MARK: - Clicks

struct BuddyClicksCard: View {
    @ObservedObject var settings: BuddySettings
    @State private var shortcuts: [String] = []

    var body: some View {
        HubCard {
            ForEach(Array(BuddyGesture.allCases.enumerated()), id: \.element) { i, g in
                if i > 0 { HubDivider() }
                row(g)
            }
            Text("Each click squashes it at once. A single click waits a moment only when a double, triple or many-click action is set, so it can tell them apart.")
                .font(.system(size: 11.5)).foregroundColor(HubTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { shortcuts = await BuddyShortcuts.list() }
    }

    @ViewBuilder private func row(_ g: BuddyGesture) -> some View {
        let b = settings.binding(g)
        VStack(alignment: .leading, spacing: 8) {
            HubRow(title: g.label, detail: g.detail) {
                HStack(spacing: 8) {
                    BriefComboBox(options: [BriefComboOption(value: BuddyAction.none, title: BuddyAction.none.label, symbol: "circle.slash")]
                                  + BuddyAction.animations.map { BriefComboOption(value: $0, title: $0.label, detail: "Animation", symbol: "sparkles") }
                                  + BuddyAction.coucou.map { BriefComboOption(value: $0, title: $0.label, detail: "Coucou", symbol: "macwindow") }
                                  + BuddyAction.yours.map { BriefComboOption(value: $0, title: $0.label, detail: "Your own", symbol: "wand.and.stars") },
                                  selection: Binding(get: { b.action }, set: { a in
                                      settings.setBinding(.init(action: a, parameter: a == b.action ? b.parameter : ""), for: g)
                                  }), tint: HubBuddyPage.tint, symbol: "cursorarrow.click", width: 240, placeholder: "Search actions")
                    Button("Try") { BuddyController.shared.perform(b) }
                        .buttonStyle(HubButtonStyle())
                        .disabled(!b.isRunnable || !settings.enabled)
                }
            }
            if b.action == .shortcut { shortcutField(g, b) }
            if b.action == .open { openField(g, b) }
        }
    }

    private func shortcutField(_ g: BuddyGesture, _ b: BuddyClickBinding) -> some View {
        HStack(spacing: 8) {
            Spacer()
            if !shortcuts.isEmpty {
                BriefComboBox(options: [BriefComboOption(value: "", title: "Pick a Shortcut", symbol: "square.stack.3d.up")]
                              + shortcuts.map { BriefComboOption(value: $0, title: $0, symbol: "square.stack.3d.up.fill") },
                              selection: Binding(get: { shortcuts.contains(b.parameter) ? b.parameter : "" },
                                                 set: { if !$0.isEmpty { settings.setBinding(.init(action: .shortcut, parameter: $0), for: g) } }),
                              tint: HubBuddyPage.tint, symbol: "square.stack.3d.up", width: 220, placeholder: "Search your Shortcuts")
            }
            HubField(placeholder: shortcuts.isEmpty ? "Shortcut name (none found in Shortcuts)" : "or its name",
                     text: Binding(get: { b.parameter }, set: { settings.setBinding(.init(action: .shortcut, parameter: $0), for: g) }))
                .frame(width: 260)
        }
    }

    private func openField(_ g: BuddyGesture, _ b: BuddyClickBinding) -> some View {
        HStack(spacing: 8) {
            Spacer()
            HubField(placeholder: "https://… or /Applications/….app",
                     text: Binding(get: { b.parameter }, set: { settings.setBinding(.init(action: .open, parameter: $0), for: g) }))
                .frame(width: 300)
            Button("Choose an app…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.application]
                panel.directoryURL = URL(fileURLWithPath: "/Applications")
                panel.prompt = "Choose"
                if panel.runModal() == .OK, let url = panel.url {
                    settings.setBinding(.init(action: .open, parameter: url.path), for: g)
                }
            }
            .buttonStyle(HubButtonStyle())
            if !b.parameter.isEmpty && BuddyShortcuts.target(b.parameter) == nil {
                Image(systemName: "exclamationmark.triangle").foregroundColor(HubTheme.red).help("Not a link or an existing app or file")
            }
        }
    }
}
#endif
