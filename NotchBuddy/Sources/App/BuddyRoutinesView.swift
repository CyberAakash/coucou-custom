#if !APPSTORE
import SwiftUI

// coucou-custom fork: the Buddy page's Assistant and Routines cards, in the Coucou window's style.

struct BuddyAssistantCard: View {
    @ObservedObject var settings: BuddyRoutineSettings

    var body: some View {
        HubCard {
            HubRow(title: "Let the chat act",
                   detail: "The notch chat can set reminders, start focus sessions and timers, turn on water nudges, start a breathing exercise, check your Mac and sum up your agents. Each action shows in the chat. Works with Claude (API key or Claude Code login), OpenAI and Gemini.") {
                BriefSwitch(isOn: $settings.assistantTools, tint: HubBuddyPage.tint)
            }
            HubDivider()
            HubRow(title: "Try it", detail: "\"Remind me in 10 minutes to stretch\", \"Start a 25 minute focus session\", \"Help me calm down\".") {
                Button("Open the chat") {
                    BuddyController.shared.openChat()
                }
                .buttonStyle(HubButtonStyle())
            }
        }
    }
}

struct BuddyRoutinesCard: View {
    @ObservedObject var settings: BuddyRoutineSettings
    @ObservedObject var routines = BuddyRoutineController.shared

    var body: some View {
        HubCard {
            HubRow(title: "Focus session", detail: "Focus Buddy: a Pomodoro timer on the Buddy. Breaks start on their own; the next session waits for you.") {
                BuddyMinuteChips(values: [15, 25, 45, 50], selection: $settings.focusPlan.focus, custom: BuddyFocusPlan.focusRange, step: 5)
            }
            HubDivider()
            HubRow(title: "Breaks", detail: "Short, and long after every \(settings.focusPlan.roundsBeforeLong) sessions.") {
                HStack(spacing: 8) {
                    BuddyMinuteChips(values: [5, 10], selection: $settings.focusPlan.shortBreak, custom: BuddyFocusPlan.breakRange)
                    BuddyMinuteChips(values: [15, 20, 30], selection: $settings.focusPlan.longBreak, custom: BuddyFocusPlan.longBreakRange, step: 5)
                }
            }
            HubDivider()
            HubRow(title: "Breathing full screen", detail: "The Buddy walks to the middle of the screen, which dims, and breathes with you in an orb; it walks back after. Drag it away to go on in a card by it. Off: the card only.") {
                BriefSwitch(isOn: $settings.breathingFullScreen, tint: HubBuddyPage.tint)
            }
            HubDivider()
            HubRow(title: "Launch greeting", detail: "Launch Buddy: it says hello when Coucou starts.") {
                HStack(spacing: 10) {
                    Toggle("Sound", isOn: $settings.launchGreetingSound).toggleStyle(.checkbox)
                        .disabled(!settings.launchGreeting)
                    BriefSwitch(isOn: $settings.launchGreeting, tint: HubBuddyPage.tint)
                }
            }
            HubDivider()
            HubRow(title: "Alert sound", detail: "When a reminder or a timer is due, and when a focus session or a break ends.") {
                BriefSwitch(isOn: $settings.alertSound, tint: HubBuddyPage.tint)
            }
            HubDivider()
            HubRow(title: "Start now", detail: "Also in the Buddy's right-click menu.") {
                HStack(spacing: 8) {
                    Button("Focus") { routines.startFocus() }.buttonStyle(HubButtonStyle())
                        .disabled(routines.focus != nil)
                    Button("Breathe") { routines.startBreathing(settings.lastBreathing, autoStart: false) }.buttonStyle(HubButtonStyle())
                        .disabled(routines.breathing != nil)
                    Button("Test reminder") {
                        routines.addReminder("Test reminder", due: .now.addingTimeInterval(5))
                    }
                    .buttonStyle(HubButtonStyle())
                }
            }
            if !routines.reminders.isEmpty {
                HubDivider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reminders").font(.system(size: 13, weight: .semibold)).foregroundColor(HubTheme.text)
                    ForEach(routines.reminders) { r in
                        HStack(spacing: 10) {
                            Image(systemName: "bell").font(.system(size: 11)).foregroundColor(HubTheme.secondary)
                            Text(r.due.formatted(date: Calendar.current.isDateInToday(r.due) ? .omitted : .abbreviated, time: .shortened))
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(HubTheme.body)
                            Text(r.text).font(.system(size: 13)).foregroundColor(HubTheme.text).lineLimit(1)
                            Spacer(minLength: 8)
                            Button { routines.removeReminder(r.id) } label: {
                                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(HubTheme.secondary)
                            .help("Remove")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Water

struct BuddyWaterCard: View {
    @ObservedObject var settings: BuddyRoutineSettings
    @ObservedObject var routines = BuddyRoutineController.shared

    var body: some View {
        let plan = settings.waterPlan
        HubCard {
            HStack(alignment: .center, spacing: 22) {
                BuddyWaterToday(ml: routines.waterToday, goal: plan.goal)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Today").font(.system(size: 13, weight: .semibold)).foregroundColor(HubTheme.text)
                    HStack(spacing: 8) {
                        Button("+ \(BuddyWater.amount(plan.glass))") { routines.logWater() }
                            .buttonStyle(HubButtonStyle(primary: true))
                        Button("Undo") { routines.logWater(-plan.glass) }
                            .buttonStyle(HubButtonStyle())
                            .disabled(routines.waterToday == 0)
                    }
                    Text(routines.waterToday >= plan.goal ? "Goal reached. Nice!"
                         : "\(BuddyWater.amount(plan.goal - routines.waterToday)) to go, about \(Int(ceil(Double(plan.goal - routines.waterToday) / Double(max(1, plan.glass))))) glasses.")
                        .font(.system(size: 12)).foregroundColor(HubTheme.secondary)
                }
                Spacer(minLength: 8)
                BuddyWaterWeek(days: settings.waterLog.history(7, upTo: .now), goal: plan.goal)
            }
            HubDivider()
            HubRow(title: "Water reminder", detail: settings.waterEnabled
                   ? "A gentle nudge, only while you are at the Mac\(plan.stopAtGoal ? ", until the goal" : "")\(routines.nextWaterNudge.map { ". Next at \($0.formatted(date: .omitted, time: .shortened))" } ?? "")."
                   : "A gentle nudge to take a water break, and a glass logged in one click.") {
                BriefSwitch(isOn: $settings.waterEnabled, tint: HubBuddyPage.tint)
            }
            HubDivider()
            // coucou-custom fork: the same choice as Routines → Alerts, with its Try.
            BriefSettingRow(title: "The nudge shows as", detail: "On the Buddy with its +glass button, a line in the notch, or full screen.") {
                BuddyAlertStylePicker(kind: .water)
            }
            HubDivider()
            HubRow(title: "Daily goal") {
                BuddyAmountChips(values: BuddyWaterPlan.goals, selection: $settings.waterPlan.goal, custom: BuddyWaterPlan.goalRange, step: 250)
            }
            HubDivider()
            HubRow(title: "A glass", detail: "What a nudge's button and each click log.") {
                BuddyAmountChips(values: BuddyWaterPlan.glasses, selection: $settings.waterPlan.glass, custom: BuddyWaterPlan.glassRange, step: 10)
            }
            HubDivider()
            HubRow(title: "Every") {
                BuddyMinuteChips(values: BuddyWaterPlan.intervals, selection: $settings.waterPlan.every, custom: BuddyWaterPlan.everyRange, step: 5)
            }
            HubDivider()
            HubRow(title: "Between", detail: "Outside these hours it stays quiet.") {
                HStack(spacing: 6) {
                    BuddyClockField(minutes: $settings.waterPlan.from)
                    Text("–").foregroundColor(HubTheme.secondary)
                    BuddyClockField(minutes: $settings.waterPlan.to)
                }
            }
            HubDivider()
            HubRow(title: "On") {
                BuddyWeekdayChips(selection: $settings.waterPlan.days)
            }
            HubDivider()
            HubRow(title: "Stop once the goal is reached", detail: "No more nudges that day.") {
                BriefSwitch(isOn: $settings.waterPlan.stopAtGoal, tint: HubBuddyPage.tint)
            }
        }
    }
}

/// Today's water: a ring filling up toward the goal.
struct BuddyWaterToday: View {
    let ml: Int
    let goal: Int

    var body: some View {
        let p = goal > 0 ? Double(ml) / Double(goal) : 0
        ZStack {
            Circle().stroke(Color.white.opacity(0.07), lineWidth: 9)
            Circle()
                .trim(from: 0, to: min(p, 1))
                .stroke(AngularGradient(colors: [Color(hex: "#3B9EFF"), Color(hex: "#22D3EE"), Color(hex: "#3B9EFF")], center: .center),
                        style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.6, dampingFraction: 0.8), value: p)
            VStack(spacing: 1) {
                Image(systemName: "drop.fill").font(.system(size: 13)).foregroundColor(Color(hex: "#22D3EE"))
                Text(BuddyWater.amount(ml)).font(.system(size: 16, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundColor(HubTheme.text)
                Text("of \(BuddyWater.amount(goal))").font(.system(size: 10.5)).foregroundColor(HubTheme.secondary)
            }
        }
        .frame(width: 96, height: 96)
    }
}

/// The last seven days, a bar each, the goal as a line.
struct BuddyWaterWeek: View {
    let days: [(day: Date, ml: Int)]
    let goal: Int

    var body: some View {
        let top = Double(max(goal, days.map(\.ml).max() ?? 0, 1))
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                VStack(spacing: 4) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.05)).frame(width: 14, height: 70)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(d.ml >= goal ? Color(hex: "#22D3EE") : Color(hex: "#3B9EFF").opacity(0.7))
                            .frame(width: 14, height: max(d.ml > 0 ? 3 : 0, 70 * Double(d.ml) / top))
                    }
                    Text(d.day.formatted(.dateTime.weekday(.narrow)))
                        .font(.system(size: 10, weight: i == days.count - 1 ? .bold : .medium))
                        .foregroundColor(i == days.count - 1 ? HubTheme.text : HubTheme.secondary)
                }
                .help("\(d.day.formatted(.dateTime.weekday(.wide))): \(BuddyWater.amount(d.ml))")
            }
        }
        .overlay(alignment: .top) {
            // The goal's height on the bars.
            Rectangle().fill(Color(hex: "#22D3EE").opacity(0.35)).frame(height: 1)
                .offset(y: 70 * (1 - Double(goal) / top))
        }
    }
}

/// Millilitres, as the page's other chips.
struct BuddyAmountChips: View {
    let values: [Int]
    @Binding var selection: Int
    var custom: ClosedRange<Int>? = nil
    var step = 1

    var body: some View {
        BuddyChipRow(values: values, label: { BuddyWater.amount($0) }, selection: $selection,
                     custom: custom, step: step, unit: "ml")
    }
}

/// A time of day, minutes after midnight: the Briefs page's time picker.
struct BuddyClockField: View {
    @Binding var minutes: Int

    var body: some View {
        BriefTimePicker(minuteOfDay: $minutes, tint: HubBuddyPage.tint, width: 170)
    }
}

/// The days of the week, in the user's order, each on or off, as the Briefs page's day picker.
struct BuddyWeekdayChips: View {
    @Binding var selection: Set<Int>

    var body: some View {
        let cal = Calendar.current
        let order = (0..<7).map { (cal.firstWeekday - 1 + $0) % 7 + 1 }
        HStack(spacing: 6) {
            ForEach(order, id: \.self) { d in
                let on = selection.contains(d)
                Button {
                    withAnimation(BriefLayout.pop) { if on { selection.remove(d) } else { selection.insert(d) } }
                } label: {
                    Text(cal.shortWeekdaySymbols[d - 1])
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(on ? HubTheme.onAccent : HubTheme.body)
                        .frame(width: 44, height: 34)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(on ? HubBuddyPage.tint : Color.white.opacity(0.05)))
                        .shadow(color: on ? HubBuddyPage.tint.opacity(0.45) : .clear, radius: 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(BriefPress())
                .help(cal.weekdaySymbols[d - 1])
            }
        }
    }
}

/// A few values to pick, or one of your own typed in: the Briefs page's combobox.
struct BuddyChipRow: View {
    let values: [Int]
    let label: (Int) -> String
    @Binding var selection: Int
    /// With a range, a value of your own can be typed in.
    var custom: ClosedRange<Int>? = nil
    var step = 1
    var unit = ""

    var body: some View {
        BriefComboBox(options: values.map { BriefComboOption(value: $0, title: label($0)) },
                      selection: $selection, tint: HubBuddyPage.tint, symbol: unit == "ml" ? "drop" : "timer", width: 220,
                      custom: custom.map { range in { text in
                          let digits = text.filter(\.isNumber)
                          guard let n = Int(digits), range.contains(n) else { return nil }
                          return n
                      } },
                      customTitle: { "\($0) \(unit)" },
                      placeholder: custom == nil ? "Search" : "Search, or type \(unit.isEmpty ? "a number" : unit)")
    }
}

/// A number of your own: type it, or step it with − and +; always kept in `range`.
struct BuddyNumberField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    var unit = ""

    var body: some View {
        HStack(spacing: 2) {
            stepButton("minus", -step)
            TextField("", value: Binding(get: { value }, set: { value = clamp($0) }), format: .number)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .frame(width: 46, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.3)))
            stepButton("plus", step)
            if !unit.isEmpty {
                Text(unit).font(.system(size: 11, weight: .semibold)).foregroundColor(HubTheme.secondary).padding(.leading, 2)
            }
        }
        .padding(.horizontal, 4)
        .help("\(range.lowerBound)–\(range.upperBound) \(unit)")
    }

    private func clamp(_ v: Int) -> Int { min(max(v, range.lowerBound), range.upperBound) }

    private func stepButton(_ symbol: String, _ delta: Int) -> some View {
        Button { value = clamp(value + delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(HubTheme.body)
                .frame(width: 20, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Minutes, as the page's other chips.
struct BuddyMinuteChips: View {
    let values: [Int]
    @Binding var selection: Int
    var custom: ClosedRange<Int>? = nil
    var step = 1

    var body: some View {
        BuddyChipRow(values: values, label: { "\($0)m" }, selection: $selection, custom: custom, step: step, unit: "min")
    }
}
#endif
