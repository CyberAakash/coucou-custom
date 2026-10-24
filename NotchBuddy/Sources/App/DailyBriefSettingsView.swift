#if !APPSTORE
import SwiftUI

// coucou-custom fork: the Coucou window's Briefs page — one banner to turn the Daily brief and the
// Weekly recap on, then each one's When, How and Cards (in your order: drag them, or Shuffle), and
// a live preview of what it will look like, in the notch or full screen.

enum BriefsTab: String, CaseIterable, Identifiable {
    case daily, weekly
    var id: String { rawValue }
    var title: String { self == .daily ? "Daily brief" : "Weekly recap" }
    var tint: Color { self == .daily ? Color(hex: "#FB923C") : Color(hex: "#818CF8") }
}

struct HubDailyBriefPage: View {
    @ObservedObject private var settings = DailyBriefSettings.shared
    @ObservedObject private var weekly = WeeklyBriefSettings.shared
    @AppStorage("briefsSettingsTab") private var tabRaw = BriefsTab.daily.rawValue

    private var tab: BriefsTab { BriefsTab(rawValue: tabRaw) ?? .daily }

    var body: some View {
        // The page's one banner: its title, and the two switches beside it.
        HubPageScaffold(title: String(localized: "Briefs"), subtitle: String(localized: "hub.notch.briefs"),
                        trailing: { BriefsBanner() }) {
            BriefSegmented(options: BriefsTab.allCases.map {
                BriefSegmentedOption(value: $0, title: $0.title, symbol: $0 == .daily ? "sun.max.fill" : "calendar")
            }, selection: Binding(get: { tab }, set: { tabRaw = $0.rawValue }), tint: tab.tint, height: 38)
            Group {
                VStack(alignment: .leading, spacing: 12) {
                    HubLabel("Preview")
                    BriefSettingsPreview(tab: tab)
                }
                VStack(alignment: .leading, spacing: 12) {
                    switch tab {
                    case .daily: dailyTab
                    case .weekly: weeklyTab
                    }
                }
            }
            .id(tab)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity))
        }
    }

    // MARK: Daily

    @ViewBuilder private var dailyTab: some View {
        let tint = BriefsTab.daily.tint
        HubLabel("When")
        HubCard {
            HubRow(title: "Comes up", detail: "Once a day, never over a permission or a question waiting in the notch.") {
                BriefComboBox(options: Self.triggers(includingManual: true), selection: $settings.trigger, tint: tint)
            }
            if settings.trigger != .manual {
                HubDivider()
                HubRow(title: settings.trigger == .firstUse ? "Not before" : "At",
                       detail: settings.trigger == .firstUse ? "The first time you are at the Mac after this time." : "If you are at the Mac then.") {
                    BriefTimePicker(minuteOfDay: $settings.minuteOfDay, tint: tint)
                }
            }
            HubDivider()
            BriefSettingRow(title: "Tells about", detail: "A morning brief looks back on yesterday; an evening one sums up today.") {
                BriefSegmented(options: [
                    BriefSegmentedOption(value: DailyBriefPeriod.auto, title: "Yesterday, then today", symbol: "sunrise"),
                    BriefSegmentedOption(value: .yesterday, title: "Yesterday", symbol: "arrow.uturn.backward"),
                    BriefSegmentedOption(value: .today, title: "Today", symbol: "sun.max"),
                ], selection: $settings.period, tint: tint)
            }
        }

        HubLabel("How")
        HubCard {
            BriefSettingRow(title: "Shows", detail: settings.place == .notch
                   ? "In the notch: a pill, then a card with the day in a line and its numbers; Open for the whole story."
                   : "Full screen: the whole brief over the blurred screen, card after card.") {
                BriefSegmented(options: Self.places, selection: $settings.place, tint: tint)
            }
            HubDivider()
            HubRow(title: "Next card by itself after", detail: "Or move with a click, the arrow keys, Space or Return.") {
                autoAdvance($settings.autoAdvance, tint: tint)
            }
            HubDivider()
            HubRow(title: "Sound", detail: "A hello as it comes up; full screen, a soft sound with each card and a cheer at the end.") {
                BriefSwitch(isOn: $settings.sound, tint: tint)
            }
            HubDivider()
            HubRow(title: "Your name", detail: "In the greeting. Empty: your first name from macOS (\(resolveUserFirstName() ?? "none found")).") {
                HubField(placeholder: resolveUserFirstName() ?? "Name", text: $settings.name).frame(width: 220)
            }
        }

        cardsHeader(tint: tint) { withAnimation(BriefLayout.spring) { settings.sections = BriefOrder.rotate(settings.sections) } }
        HubCard {
            BriefCardOrder(all: DailyBriefSection.allCases, order: $settings.sections, tint: tint,
                           toggle: { settings.toggle($0, $1) })
            HubNote(text: "Everything stays on this Mac. The weather is asked from Open-Meteo for your city, the calendar is read here, and the Mac's day is one reading a minute, kept 14 days, only while the brief shows it.")
        }
    }

    // MARK: Weekly

    @ViewBuilder private var weeklyTab: some View {
        let tint = BriefsTab.weekly.tint
        HubLabel("When")
        HubCard {
            if !weekly.autoShow {
                HubNote(text: "It is off: turn it on in the banner above. You can still open it from the menu-bar panel or the preview.")
            }
            Group {
                BriefSettingRow(title: "Day", detail: "Once a week, on \(WeeklyBriefSchedule.weekdayNames[weekly.weekday - 1]), when your agents did some work.") {
                    BriefWeekdayPicker(weekday: $weekly.weekday, tint: tint)
                }
                HubDivider()
                HubRow(title: "Comes up") {
                    BriefComboBox(options: Self.triggers(includingManual: false), selection: $weekly.trigger, tint: tint)
                }
                HubDivider()
                HubRow(title: weekly.trigger == .firstUse ? "Not before" : "At",
                       detail: weekly.trigger == .firstUse ? "The first time you are at the Mac that day, after this time." : "If you are at the Mac then.") {
                    BriefTimePicker(minuteOfDay: $weekly.minuteOfDay, tint: tint)
                }
            }
            .opacity(weekly.autoShow ? 1 : 0.5)
            HubDivider()
            BriefSettingRow(title: "Tells about", detail: "Last week suits an early-week recap; this week so far suits a Friday one.") {
                BriefSegmented(options: [
                    BriefSegmentedOption(value: WeeklyBriefPeriod.lastWeek, title: "Last week", symbol: "arrow.uturn.backward"),
                    BriefSegmentedOption(value: .thisWeek, title: "This week so far", symbol: "calendar.badge.clock"),
                ], selection: $weekly.period, tint: tint)
            }
        }

        HubLabel("How")
        HubCard {
            BriefSettingRow(title: "Shows", detail: weekly.place == .notch
                   ? "In the notch: a pill, then the week in a line and its numbers; Open for the whole story."
                   : "Full screen: the whole week, card after card, then share it as an image.") {
                BriefSegmented(options: Self.places, selection: $weekly.place, tint: tint)
            }
            HubDivider()
            HubRow(title: "Next card by itself after") {
                autoAdvance($weekly.autoAdvance, tint: tint)
            }
            HubDivider()
            HubRow(title: "Sound", detail: "A hello as it opens full screen, a soft sound with each card, a cheer at the end.") {
                BriefSwitch(isOn: $weekly.sound, tint: tint)
            }
        }

        cardsHeader(tint: tint) { withAnimation(BriefLayout.spring) { weekly.sections = BriefOrder.rotate(weekly.sections) } }
        HubCard {
            BriefCardOrder(all: WeeklyBriefSection.allCases, order: $weekly.sections, tint: tint,
                           toggle: { weekly.toggle($0, $1) })
        }
    }

    // MARK: Pieces

    static let places = [
        BriefSegmentedOption(value: BriefPlace.notch, title: "In the notch", symbol: "rectangle.topthird.inset.filled"),
        BriefSegmentedOption(value: BriefPlace.fullScreen, title: "Full screen", symbol: "rectangle.inset.filled"),
    ]

    static func triggers(includingManual: Bool) -> [BriefComboOption<DailyBriefTrigger>] {
        var list = [
            BriefComboOption(value: DailyBriefTrigger.firstUse, title: "First time at the Mac",
                             detail: "When you wake it, unlock it or start Coucou, after the time.", symbol: "person.crop.circle.badge.checkmark"),
            BriefComboOption(value: .atTime, title: "At a time", detail: "At the time, if you are at the Mac then.", symbol: "alarm"),
        ]
        if includingManual {
            list.append(BriefComboOption(value: .manual, title: "Only by hand", detail: "From the menu-bar panel or the preview.", symbol: "hand.tap"))
        }
        return list
    }

    private func autoAdvance(_ value: Binding<Int>, tint: Color) -> some View {
        BriefComboBox(options: [BriefComboOption(value: 0, title: "Never", detail: "Only when you click or press a key.", symbol: "hand.tap")]
                      + [5, 6, 8, 10, 15, 20, 30, 45, 60].map { BriefComboOption(value: $0, title: "\($0) s", symbol: "timer") },
                      selection: value, tint: tint, symbol: "timer",
                      custom: BriefInput.seconds(from:), customTitle: { "\($0) s" }, placeholder: "Search, or type seconds")
    }

    private func cardsHeader(tint: Color, shuffle: @escaping () -> Void) -> some View {
        HStack {
            HubLabel("Cards")
            Spacer()
            BriefShuffleButton(tint: tint, action: shuffle)
        }
    }
}

// MARK: - The banner: just the two switches

private struct BriefsBanner: View {
    @ObservedObject private var settings = DailyBriefSettings.shared
    @ObservedObject private var weekly = WeeklyBriefSettings.shared

    var body: some View {
        HStack(spacing: 8) {
            HubBannerSwitch(title: "Daily brief", tint: BriefsTab.daily.tint, isOn: $settings.enabled)
            HubBannerSwitch(title: "Weekly recap on \(WeeklyBriefSchedule.weekdayNames[weekly.weekday - 1])s", tint: BriefsTab.weekly.tint, isOn: $weekly.autoShow)
        }
    }
}

/// A switch in the brief's colour that glows while on.
struct BriefSwitch: View {
    @Binding var isOn: Bool
    let tint: Color

    var body: some View {
        Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().tint(tint)
            .shadow(color: isOn ? tint.opacity(0.55) : .clear, radius: isOn ? 7 : 0)
            .animation(.easeOut(duration: 0.3), value: isOn)
    }
}

/// A setting with its words on top and its choices under them.
struct BriefSettingRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundColor(HubTheme.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            control()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Shuffle

private struct BriefShuffleButton: View {
    let tint: Color
    let action: () -> Void
    @State private var turns = 0.0

    var body: some View {
        Button {
            withAnimation(BriefLayout.pop) { turns += 1 }
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "shuffle").font(.system(size: 11, weight: .bold))
                    .rotationEffect(.degrees(turns * 180))
                Text("Shuffle").font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(HubTheme.text)
            .padding(.horizontal, 11).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.07)))
            .contentShape(Capsule())
        }
        .buttonStyle(BriefPress())
        .help("Turn the cards' order round by one")
    }
}

// MARK: - Cards in your order: drag a row, or Shuffle

protocol BriefCardKind: Hashable {
    var rawValue: String { get }
    var title: String { get }
    var detail: String { get }
    var symbol: String { get }
    var dot: Color { get }
}

extension DailyBriefSection: BriefCardKind {
    var dot: Color {
        switch self {
        case .weather: Color(hex: "#3B9EFF")
        case .work: Color(hex: "#FB923C")
        case .routines: Color(hex: "#22D3EE")
        case .mac: Color(hex: "#A78BFA")
        case .plan: Color(hex: "#F7B32B")
        case .ahead: Color(hex: "#F472B6")
        }
    }
}

extension WeeklyBriefSection: BriefCardKind {
    var dot: Color {
        switch self {
        case .summary: Color(hex: "#818CF8")
        case .days: Color(hex: "#3B9EFF")
        case .projects: Color(hex: "#FB923C")
        case .routines: Color(hex: "#22D3EE")
        case .mac: Color(hex: "#A78BFA")
        case .plan: Color(hex: "#F7B32B")
        }
    }
}

private struct BriefCardOrder<Section: BriefCardKind & Identifiable>: View {
    let all: [Section]
    @Binding var order: [Section]
    let tint: Color
    let toggle: (Section, Bool) -> Void

    var body: some View {
        HubReorderList(items: $order, fixed: all.filter { !order.contains($0) }, tint: tint) { section in
            row(section, on: order.contains(section), position: order.firstIndex(of: section))
        }
    }

    private func row(_ section: Section, on: Bool, position: Int?) -> some View {
        HStack(spacing: 12) {
            Circle().fill(on ? section.dot : HubTheme.muted).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(section.title).font(.system(size: 13.5, weight: .semibold))
                Text(section.detail).font(.system(size: 12)).foregroundColor(HubTheme.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let position {
                Text("\(position + 1)").font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundColor(HubTheme.muted)
            }
            BriefSwitch(isOn: Binding(get: { on }, set: { v in withAnimation(BriefLayout.spring) { toggle(section, v) } }), tint: tint)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.03)))
        .opacity(on ? 1 : 0.6)
    }
}

// MARK: - The preview: what it will look like, played here

private struct BriefSettingsPreview: View {
    let tab: BriefsTab
    /// The card's inside width, measured: the preview uses the page's whole width.
    @State private var inner: CGFloat = 700
    @ObservedObject private var daily = DailyBriefSettings.shared
    @ObservedObject private var weekly = WeeklyBriefSettings.shared
    @State private var place: BriefPlace?
    @State private var dailyBrief: DailyBrief?
    @State private var weeklyBrief: WeeklyBrief?
    @State private var story: BriefStory?
    @State private var phase: BriefPhase = .card

    private var shown: BriefPlace { place ?? (tab == .daily ? daily.place : weekly.place) }
    private var view: IslandView { tab == .daily ? .dailyBrief : .weeklyBrief }

    /// What the preview depends on: it is made again when one changes.
    private var key: String {
        tab == .daily
            ? "\(daily.sections.map(\.rawValue))\(daily.period.rawValue)\(daily.name)\(daily.autoAdvance)"
            : "\(weekly.sections.map(\.rawValue))\(weekly.period.rawValue)\(weekly.autoAdvance)"
    }

    var body: some View {
        HubCard {
            HStack(spacing: 8) {
                BriefSegmented(options: HubDailyBriefPage.places, selection: Binding(get: { shown }, set: { place = $0 }), tint: tab.tint)
                    .frame(width: 300)
                if shown == .notch {
                    Button { replay() } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(HubButtonStyle()).help("Play it again")
                }
                Spacer()
                Button("Try in the notch") { open(.notch) }.buttonStyle(HubButtonStyle(primary: shown == .notch))
                Button("Try full screen") { open(.fullScreen) }.buttonStyle(HubButtonStyle(primary: shown == .fullScreen))
            }
            ZStack {
                if shown == .notch { notch.transition(.opacity) } else { fullScreen.transition(.opacity) }
            }
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: "#1B2536"), Color(hex: "#1A1424"), Color(hex: "#110F16")], startPoint: .top, endPoint: .bottom)))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .background(GeometryReader { g in Color.clear.onAppear { inner = g.size.width }.onChange(of: g.size.width) { inner = g.size.width } })
            .animation(.easeInOut(duration: 0.3), value: shown)
            .animation(.easeInOut(duration: 0.3), value: key)
            Text(shown == .notch ? "As it opens under the notch: ‹ › step through the numbers, which turn every 2.4 s." : "Click through it as on the full screen: the left third goes back.")
                .font(.system(size: 11.5)).foregroundColor(HubTheme.muted)
        }
        .task(id: key) { await build() }
    }

    private func open(_ p: BriefPlace) {
        if tab == .daily { DailyBriefController.shared.show(place: p) } else { WeeklyBriefController.shared.show(place: p) }
    }

    private var notch: some View {
        let nw = AppState.shared.notchWidth, nh = AppState.shared.notchHeight
        let w = phase == .pill ? nw + BriefLayout.pillWing * 2 : BriefLayout.cardWidth
        let h = phase == .pill ? nh : BriefLayout.cardHeight(nh: nh)
        let r: CGFloat = phase == .pill ? 16 : 30
        return ZStack(alignment: .top) {
            UnevenRoundedRectangle(bottomLeadingRadius: r, bottomTrailingRadius: r, style: .continuous).fill(Color.black)
            BriefNotchStage(state: AppState.shared, view: view, width: w, height: h, still: phase)
        }
        .frame(width: w, height: h)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: r, bottomTrailingRadius: r, style: .continuous))
        .shadow(color: .black.opacity(phase == .card ? 0.5 : 0), radius: 24, y: 12)
        .frame(width: BriefLayout.cardWidth, height: BriefLayout.cardHeight(nh: nh), alignment: .top)
        .scaleEffect(min(1, inner / BriefLayout.cardWidth), anchor: .top)
        .frame(maxWidth: .infinity)
        .frame(height: BriefLayout.cardHeight(nh: nh) * min(1, inner / BriefLayout.cardWidth) + 40, alignment: .top)
    }

    @ViewBuilder private var fullScreen: some View {
        let s: CGFloat = min(0.9, (inner - 32) / BriefStoryFrame<EmptyView>.size.width)
        if let story {
            Group {
                if tab == .daily, let b = dailyBrief {
                    DailyBriefFullView(brief: b, cards: DailyBriefCard.cards(for: b.sections), story: story, close: {})
                } else if tab == .weekly, let b = weeklyBrief {
                    WeeklyBriefFullView(brief: b, cards: WeeklyBriefCard.cards(for: b.sections), story: story, close: {})
                }
            }
            .frame(width: BriefStoryFrame<EmptyView>.size.width, height: BriefStoryFrame<EmptyView>.size.height + 44)
            .scaleEffect(s)
            .frame(width: BriefStoryFrame<EmptyView>.size.width * s, height: (BriefStoryFrame<EmptyView>.size.height + 44) * s)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .id(key)
        } else {
            ProgressView().frame(height: 200)
        }
    }

    private func replay() {
        phase = .pill
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { withAnimation(BriefLayout.spring) { phase = .card } }
    }

    private func build() async {
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        if tab == .daily {
            let b = await DailyBriefBuilder.build(askCalendar: false)
            BriefNotchModel.shared.daily = b
            dailyBrief = b
            story = BriefStory(count: DailyBriefCard.cards(for: b.sections).count, autoAdvance: daily.autoAdvance)
        } else {
            let b = await WeeklyBriefBuilder.build()
            BriefNotchModel.shared.weekly = b
            weeklyBrief = b
            story = BriefStory(count: WeeklyBriefCard.cards(for: b.sections).count, autoAdvance: weekly.autoAdvance)
        }
    }
}

/// Settings → Buddy: where each routine's alert shows — the Buddy's card, the notch, or full screen.
struct BuddyFullScreenCard: View {
    @ObservedObject private var settings = RoutineMomentSettings.shared
    @ObservedObject private var buddy = BuddySettings.shared

    var body: some View {
        HubCard {
            Text("Buddy card: on the Buddy, with its buttons. Notch: a line in the notch, gone after a moment, no buttons. Full screen: over the whole screen, Mochi in the middle; Return and Esc work on it when Coucou has the keyboard, never taking it from what you type.")
                .font(.system(size: 12.5)).foregroundColor(HubTheme.body).fixedSize(horizontal: false, vertical: true)
            if !buddy.enabled {
                HubNote(text: "The Buddy is hidden: what is set to its card shows in the notch until you show it again.")
            }
            ForEach(Array(RoutineMomentKind.allCases.enumerated()), id: \.element) { i, kind in
                if i > 0 { HubDivider() }
                BriefSettingRow(title: kind.title, detail: detail(kind)) {
                    BuddyAlertStylePicker(kind: kind)
                }
            }
            HubDivider()
            HubRow(title: "A start stays", detail: "Focus starts and timer starts.") {
                BriefComboBox(options: RoutineMomentSettings.startChoices.map { BriefComboOption(value: $0, title: "\($0) s", symbol: "timer") },
                              selection: $settings.startSeconds, tint: HubBuddyPage.tint, symbol: "timer", width: 200,
                              custom: { BriefInput.seconds(from: $0).flatMap { $0 <= 30 ? $0 : nil } }, customTitle: { "\($0) s" },
                              placeholder: "Search, or type seconds")
            }
            HubDivider()
            HubRow(title: "Screen behind", detail: "How dark it goes.") {
                HStack(spacing: 8) {
                    Slider(value: $settings.dim, in: 0.2...0.85).frame(width: 150)
                    Text(MetricsFormat.percent(settings.dim)).font(.system(size: 12).monospacedDigit()).foregroundColor(HubTheme.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
    }

    private func detail(_ kind: RoutineMomentKind) -> String {
        switch kind {
        case .focusStart, .timerStart: "A short moment, gone by itself; on the Buddy, its card shows it running."
        case .breakDone: "Waits for you. In the notch, start the next session yourself: there is no button."
        default: "Waits for you."
        }
    }

    static func symbol(_ s: RoutineAlertStyle) -> String {
        switch s {
        case .buddy: "face.smiling"
        case .notch: "rectangle.topthird.inset.filled"
        case .fullScreen: "rectangle.inset.filled"
        }
    }
}
/// Where one kind of alert shows, and a Try that shows a sample there (Settings → Buddy).
struct BuddyAlertStylePicker: View {
    let kind: RoutineMomentKind
    @ObservedObject private var settings = RoutineMomentSettings.shared

    var body: some View {
        HStack(spacing: 8) {
            BriefSegmented(options: RoutineAlertStyle.allCases.map {
                BriefSegmentedOption(value: $0, title: $0.label, symbol: BuddyFullScreenCard.symbol($0))
            }, selection: Binding(get: { settings.style(kind) }, set: { settings.set(kind, $0) }), tint: HubBuddyPage.tint)
            Button { BuddyRoutineController.shared.previewAlert(kind) } label: {
                Label("Try", systemImage: "play.fill").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(HubButtonStyle())
            .help("Show a sample, where it is set to show; it does nothing")
        }
    }
}
#endif
