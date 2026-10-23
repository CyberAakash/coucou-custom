#if !APPSTORE
import AppKit
import Combine
import SwiftUI

// coucou-custom fork: the Daily brief — a banner that grows out of the notch, and the full-screen
// story of cards (greeting and weather, what you did, your routines, the Mac's day, the Claude
// plan, today ahead). It comes up by itself once a day (Settings → Daily brief) or when opened
// from the menu-bar panel.

@MainActor
final class DailyBriefController {
    static let shared = DailyBriefController()

    private var banner: NSPanel?
    private var bannerClose: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var subscription: AnyCancellable?
    private var building = false
    /// Due but you were away: asked again each minute until you are back, that day only.
    private var retry: Timer?

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DailyBriefController.shared.checkSoon() }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DailyBriefController.shared.checkSoon() }
        })
        subscription = DailyBriefSettings.shared.objectWillChange
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { DailyBriefController.shared.schedule() } }
        schedule()
        checkSoon()
    }

    /// A timer for the chosen time today (or tomorrow), so the brief comes when it is due.
    private func schedule() {
        timer?.invalidate()
        timer = nil
        let s = DailyBriefSettings.shared
        guard s.enabled, s.trigger != .manual else { return }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var due = cal.date(byAdding: .minute, value: s.minuteOfDay, to: today) ?? Date()
        if due <= Date() { due = cal.date(byAdding: .day, value: 1, to: due) ?? due }
        let t = Timer(fire: due, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated {
                DailyBriefController.shared.check()
                DailyBriefController.shared.schedule()
            }
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// After a wake or an unlock, once things have settled.
    private func checkSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { MainActor.assumeIsolated { DailyBriefController.shared.check() } }
    }

    private func check() {
        let s = DailyBriefSettings.shared
        guard s.enabled, DailyBriefSchedule.shouldShow(trigger: s.trigger, minuteOfDay: s.minuteOfDay, now: Date(), lastShownDay: s.lastShownDay) else {
            // Shown, off, or past its time: no more asking.
            retry?.invalidate()
            retry = nil
            return
        }
        // Only when you are there: something touched in the last two minutes.
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle < 120, CGDisplayIsAsleep(CGMainDisplayID()) == 0 else {
            if s.trigger == .firstUse, retry == nil {
                let t = Timer(timeInterval: 60, repeats: true) { _ in
                    MainActor.assumeIsolated { DailyBriefController.shared.check() }
                }
                t.tolerance = 15
                RunLoop.main.add(t, forMode: .common)
                retry = t
            }
            return
        }
        retry?.invalidate()
        retry = nil
        show(force: false)
    }

    /// `force`: opened by hand (the panel, Settings): full screen at once, whatever the style.
    func show(force: Bool) {
        guard !building else { return }
        building = true
        Task { @MainActor in
            let brief = await DailyBriefBuilder.build(askCalendar: force)
            building = false
            let s = DailyBriefSettings.shared
            s.lastShownDay = MacDay.dayKey(Date())
            if s.sound { SoundEngine.shared.play("greeting") }
            if force || s.style == .fullScreen { showFull(brief, takeKeyboard: force || NSApp.isActive) }
            else { showBanner(brief) }
        }
    }

    // MARK: Banner

    private func showBanner(_ brief: DailyBrief) {
        closeBanner(animated: false)
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        let size = NSSize(width: DailyBriefBanner.width + 40, height: DailyBriefBanner.height + 30)
        let p = NSPanel(contentRect: NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                                            width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        // Over the menu bar and the notch's island, as the island itself is.
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        let notchWidth = max(160, screen.frame.width - (screen.auxiliaryTopLeftArea?.width ?? 0) - (screen.auxiliaryTopRightArea?.width ?? 0))
        p.contentView = NSHostingView(rootView: DailyBriefBanner(
            brief: brief, notchWidth: min(notchWidth, 240), notchHeight: max(24, screen.safeAreaInsets.top),
            open: { [weak self] in
                self?.closeBanner(animated: true)
                self?.showFull(brief, takeKeyboard: true)
            },
            later: { [weak self] in self?.closeBanner(animated: true) }))
        p.orderFrontRegardless()
        banner = p
        // Not read: it folds back into the notch after a while.
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.closeBanner(animated: true) } }
        bannerClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    private func closeBanner(animated: Bool) {
        bannerClose?.cancel()
        bannerClose = nil
        guard let p = banner else { return }
        banner = nil
        guard animated else { p.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            p.animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { p.orderOut(nil) } })
    }

    // MARK: Full screen

    func showFull(_ brief: DailyBrief, takeKeyboard: Bool) {
        DailyBriefReads.markRead()
        var b = brief
        b.readStreak = DailyBriefReads.streak(now: Date())
        b.weekRead = DailyBriefReads.week(now: Date())
        let model = DailyBriefStory(brief: b, autoAdvance: DailyBriefSettings.shared.autoAdvance)
        FullScreenOverlay.shared.present(
            DailyBriefFullView(model: model, close: { FullScreenOverlay.shared.close(owner: "brief") }),
            owner: "brief", dim: 0.5, takeKeyboard: takeKeyboard) { event in
            switch event.keyCode {
            case 53: FullScreenOverlay.shared.close(owner: "brief"); return true                  // Esc
            case 124, 49, 36: if !model.next() { FullScreenOverlay.shared.close(owner: "brief") }; return true   // → Space Return
            case 123: model.previous(); return true                                               // ←
            default: return false
            }
        }
    }
}

// MARK: - The cards

enum DailyBriefCard: Hashable {
    case greeting, work, routines, mac, plan, ahead, closing

    static func cards(for sections: [DailyBriefSection]) -> [DailyBriefCard] {
        var out: [DailyBriefCard] = sections.map {
            switch $0 {
            case .weather: .greeting
            case .work: .work
            case .routines: .routines
            case .mac: .mac
            case .plan: .plan
            case .ahead: .ahead
            }
        }
        if out.first != .greeting { out.insert(.greeting, at: 0) }
        // The streak and "Start the day" live on Today ahead; without it, a card of their own.
        if !out.contains(.ahead) { out.append(.closing) }
        return out
    }
}

@MainActor
final class DailyBriefStory: ObservableObject {
    let brief: DailyBrief
    let cards: [DailyBriefCard]
    let autoAdvance: Int
    @Published var index = 0
    @Published var cardStart = Date()
    private var timer: Timer?

    init(brief: DailyBrief, autoAdvance: Int) {
        self.brief = brief
        self.cards = DailyBriefCard.cards(for: brief.sections)
        self.autoAdvance = autoAdvance
        arm()
    }

    /// False at the last card.
    @discardableResult
    func next() -> Bool {
        guard index + 1 < cards.count else { return false }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { index += 1 }
        cardStart = Date()
        arm()
        return true
    }

    func previous() {
        guard index > 0 else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { index -= 1 }
        cardStart = Date()
        arm()
    }

    private func arm() {
        timer?.invalidate()
        timer = nil
        guard autoAdvance > 0, index + 1 < cards.count else { return }
        let t = Timer(timeInterval: TimeInterval(autoAdvance), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

struct DailyBriefFullView: View {
    @ObservedObject var model: DailyBriefStory
    let close: () -> Void

    static let size = CGSize(width: 720, height: 560)

    var body: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                ticks
                HStack {
                    Text("Daily brief").font(.system(size: 12.5, weight: .bold))
                    Text(model.brief.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.system(size: 12.5)).foregroundColor(HubTheme.muted)
                    Spacer()
                    Text("\(model.index + 1) of \(model.cards.count)").font(.system(size: 12).monospacedDigit()).foregroundColor(HubTheme.muted)
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundColor(HubTheme.secondary)
                            .frame(width: 22, height: 22).background(Circle().fill(Color.white.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 6)
                }
                ZStack {
                    ForEach(Array(model.cards.enumerated()), id: \.offset) { i, card in
                        if i == model.index {
                            DailyBriefCardView(card: card, brief: model.brief, close: close)
                                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 30)),
                                                        removal: .opacity.combined(with: .offset(x: -30))))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
                .onTapGesture { if !model.next() { close() } }
            }
            .padding(22)
            .frame(width: Self.size.width, height: Self.size.height)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(hex: "#0E0F11").opacity(0.96)))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 20)

            HStack(spacing: 14) {
                hint("←", "→", "Move")
                hint("Esc", nil, "Close")
            }
        }
        .foregroundColor(HubTheme.text)
    }

    private var ticks: some View {
        HStack(spacing: 4) {
            ForEach(0..<model.cards.count, id: \.self) { i in
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        if i < model.index {
                            Capsule().fill(Color.white.opacity(0.85))
                        } else if i == model.index {
                            if model.autoAdvance > 0 {
                                TimelineView(.animation) { ctx in
                                    let k = min(1, ctx.date.timeIntervalSince(model.cardStart) / Double(model.autoAdvance))
                                    Capsule().fill(Color.white.opacity(0.85)).frame(width: g.size.width * k)
                                }
                            } else {
                                Capsule().fill(Color.white.opacity(0.85))
                            }
                        }
                    }
                }
                .frame(height: 3)
            }
        }
    }

    private func hint(_ a: String, _ b: String?, _ what: String) -> some View {
        HStack(spacing: 5) {
            ForEach([a] + (b.map { [$0] } ?? []), id: \.self) { k in
                Text(k).font(.system(size: 10.5, weight: .bold)).padding(.horizontal, 6).frame(height: 18)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.12)))
            }
            Text(what).font(.system(size: 11.5)).foregroundColor(HubTheme.secondary)
        }
    }
}

private struct DailyBriefCardView: View {
    let card: DailyBriefCard
    let brief: DailyBrief
    let close: () -> Void

    var body: some View {
        switch card {
        case .greeting: GreetingCard(brief: brief)
        case .work: WorkCard(brief: brief)
        case .routines: RoutinesCard(brief: brief)
        case .mac: MacCard(brief: brief)
        case .plan: PlanCard(brief: brief)
        case .ahead: AheadCard(brief: brief, close: close)
        case .closing: ClosingCard(brief: brief, close: close)
        }
    }
}

// MARK: Card pieces

private struct CardTitle: View {
    let label: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased()).font(.system(size: 11.5, weight: .bold)).tracking(1.3).foregroundColor(HubTheme.muted)
            Text(title).font(.system(size: 30, weight: .bold)).lineLimit(2).minimumScaleFactor(0.7)
        }
        .padding(.bottom, 6)
    }
}

private struct Tile<Content: View>: View {
    var glow: Color? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(HubTheme.card)
                    .overlay {
                        if let glow {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(RadialGradient(colors: [glow.opacity(0.2), .clear], center: .topLeading, startRadius: 0, endRadius: 300))
                        }
                    }
            )
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
    }
}

private struct Stat: View {
    let value: String
    let label: String
    var color: Color = HubTheme.text

    var body: some View {
        Tile {
            Text(value).font(.system(size: 28, weight: .bold).monospacedDigit()).foregroundColor(color).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: 12.5)).foregroundColor(HubTheme.secondary)
        }
    }
}

// MARK: Greeting

private struct GreetingCard: View {
    let brief: DailyBrief
    @State private var hop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 18) {
                HubLiveMochi(color: "#F5F6F8", size: 64, state: .idle)
                    .frame(width: 76, height: 60)
                    .offset(y: hop ? -6 : 0)
                VStack(alignment: .leading, spacing: 4) {
                    Text(brief.greeting).font(.system(size: 34, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
                    Text(brief.isToday ? "Here's your day so far." : "Here's yesterday, and what today looks like.")
                        .font(.system(size: 14)).foregroundColor(HubTheme.secondary)
                }
            }
            if let w = brief.weather {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.city).font(.system(size: 11.5)).foregroundColor(HubTheme.secondary)
                        Text("\(w.now)°").font(.system(size: 48, weight: .light).monospacedDigit())
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Label(DailyBriefWeather.describe(w.code), systemImage: DailyBriefWeather.symbol(w.code))
                            .font(.system(size: 15, weight: .semibold))
                            .symbolRenderingMode(.multicolor)
                        Text(w.line).font(.system(size: 12)).foregroundColor(HubTheme.secondary)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach(w.hours, id: \.hour) { h in
                            VStack(spacing: 5) {
                                Text(String(format: "%02d:00", h.hour)).font(.system(size: 10.5)).foregroundColor(HubTheme.muted)
                                Image(systemName: DailyBriefWeather.symbol(h.code)).symbolRenderingMode(.multicolor).font(.system(size: 12))
                                Text("\(h.temp)°").font(.system(size: 13, weight: .semibold).monospacedDigit())
                            }
                            .frame(width: 50, height: 70)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
                        }
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: "#1B2A44"), HubTheme.card], startPoint: .topLeading, endPoint: .bottomTrailing)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
            } else if brief.sections.contains(.weather) {
                Tile {
                    Label("Name your city in Settings → Voice → Your city to see the weather here.", systemImage: "cloud.sun")
                        .font(.system(size: 13)).foregroundColor(HubTheme.secondary)
                }
                .frame(height: 70)
            }
            Text(brief.headline).font(.system(size: 15)).foregroundColor(HubTheme.body).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Text("Tap to continue").font(.system(size: 11.5)).foregroundColor(HubTheme.muted)
        }
        .onAppear { withAnimation(.spring(response: 0.45, dampingFraction: 0.5).delay(0.2)) { hop = true }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.6).delay(0.55)) { hop = false } }
    }
}

// MARK: What you did

private struct WorkCard: View {
    let brief: DailyBrief

    var body: some View {
        let w = brief.work ?? DayWork()
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(label: "What you did", title: title(w))
            if w.isEmpty {
                Tile { Text("No agent session \(brief.isToday ? "yet today" : "yesterday"). Coucou counts them as your agents work.")
                    .font(.system(size: 13)).foregroundColor(HubTheme.secondary) }
                    .frame(height: 80)
            } else {
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        Stat(value: "\(w.sessions)", label: w.sessions == 1 ? "agent session" : "agent sessions")
                        Stat(value: DailyBriefText.duration(minutes: w.minutes), label: "with agents")
                        Stat(value: "\(w.filesChanged)", label: w.filesChanged == 1 ? "file changed" : "files changed")
                    }
                    GridRow {
                        Tile {
                            HStack(spacing: 4) {
                                Text("+\(w.linesAdded)").foregroundColor(HubTheme.green)
                                Text("/").foregroundColor(HubTheme.muted)
                                Text("−\(w.linesRemoved)").foregroundColor(HubTheme.red)
                            }
                            .font(.system(size: 28, weight: .bold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.5)
                            Text("lines added / removed").font(.system(size: 12.5)).foregroundColor(HubTheme.secondary)
                        }
                        Stat(value: "\(w.commands)", label: "commands run")
                        Stat(value: "\(w.questions)", label: w.questions == 1 ? "question answered" : "questions answered")
                    }
                }
                .frame(height: 210)
                if let project = w.topProject {
                    Tile(glow: HubTheme.accent) {
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Top project").font(.system(size: 11.5)).foregroundColor(HubTheme.secondary)
                                Text(project).font(.system(size: 20, weight: .bold)).foregroundColor(HubTheme.accent).lineLimit(1)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(agentLine(w)).font(.system(size: 12)).foregroundColor(HubTheme.secondary).lineLimit(1)
                                HourStrip(byHour: w.byHour)
                            }
                        }
                    }
                    .frame(height: 74)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func title(_ w: DayWork) -> String {
        guard !w.isEmpty else { return "A quiet day for your agents." }
        return "\(DailyBriefText.duration(minutes: w.minutes)) with your agents\(brief.isToday ? " so far" : "")."
    }

    private func agentLine(_ w: DayWork) -> String {
        let agent = w.topAgentPill.flatMap { PillCatalog.definition(for: $0)?.name }
        return [w.approvals > 0 ? "\(w.approvals) approvals" : nil, agent.map { "mostly \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Sessions per hour, as a little strip.
private struct HourStrip: View {
    let byHour: [Int]

    var body: some View {
        let top = max(1, byHour.max() ?? 1)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<24, id: \.self) { h in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(byHour[h] > 0 ? HubTheme.accent : Color.white.opacity(0.08))
                    .frame(height: 3 + 15 * CGFloat(byHour[h]) / CGFloat(top))
            }
        }
        .frame(height: 18)
    }
}

// MARK: Routines

private struct RoutinesCard: View {
    let brief: DailyBrief

    var body: some View {
        let d = brief.diary ?? BuddyDiary.Day()
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(label: "Your routines", title: title(d))
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Tile(glow: Color(hex: "#22D3EE")) {
                        if let water = brief.water {
                            let k = Double(water.ml) / Double(max(1, water.goal))
                            HStack(spacing: 14) {
                                ZStack {
                                    Circle().stroke(Color.white.opacity(0.08), lineWidth: 6)
                                    Circle().trim(from: 0, to: CGFloat(min(1, k)))
                                        .stroke(Color(hex: "#22D3EE"), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                                        .rotationEffect(.degrees(-90))
                                    Text(MetricsFormat.percent(k)).font(.system(size: 14, weight: .bold).monospacedDigit())
                                }
                                .frame(width: 72, height: 72)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(DailyBriefText.water(water.ml)) / \(DailyBriefText.water(water.goal))")
                                        .font(.system(size: 22, weight: .bold).monospacedDigit())
                                    Text(water.ml >= water.goal ? "water · goal reached" : "water · \(DailyBriefText.water(water.goal - water.ml)) short")
                                        .font(.system(size: 12)).foregroundColor(HubTheme.secondary)
                                }
                            }
                        } else {
                            Text("Water").font(.system(size: 16, weight: .semibold))
                            Text("Turn on Water in Settings → Buddy to keep a daily goal.").font(.system(size: 12)).foregroundColor(HubTheme.secondary)
                        }
                    }
                    Tile(glow: Color(hex: "#818CF8")) {
                        countLine(d.focusSessions, d.focusSessions == 1 ? "focus session" : "focus sessions")
                        Segments(count: d.focusSessions, of: max(4, d.focusSessions), color: Color(hex: "#818CF8"))
                        Text(d.focusMinutes > 0 ? "\(DailyBriefText.duration(minutes: d.focusMinutes)) focused" : "None yet")
                            .font(.system(size: 12)).foregroundColor(HubTheme.secondary)
                    }
                }
                GridRow {
                    Tile(glow: HubTheme.green) {
                        countLine(d.remindersDone, "reminders done" + (brief.remindersLeft > 0 ? " · \(brief.remindersLeft) left" : ""))
                        Segments(count: d.remindersDone, of: d.remindersDone + brief.remindersLeft, color: HubTheme.green,
                                 rest: brief.remindersLeft > 0 ? Color(hex: "#F7B32B") : Color.white.opacity(0.1))
                        Text("\(d.timersDone) timer\(d.timersDone == 1 ? "" : "s") done").font(.system(size: 12)).foregroundColor(HubTheme.secondary)
                    }
                    Tile(glow: Color(hex: "#F472B6")) {
                        countLine(d.breathingSessions, d.breathingSessions == 1 ? "breathing session" : "breathing sessions")
                        Text(d.breathingSessions > 0 ? "A calmer day." : "One minute of calm, any time: right-click the Buddy → Breathe.")
                            .font(.system(size: 12)).foregroundColor(HubTheme.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func countLine(_ n: Int, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(n)").font(.system(size: 26, weight: .bold).monospacedDigit())
            Text(label).font(.system(size: 14)).foregroundColor(HubTheme.secondary)
        }
    }

    private func title(_ d: BuddyDiary.Day) -> String {
        var parts: [String] = []
        if let w = brief.water {
            let k = Double(w.ml) / Double(max(1, w.goal))
            parts.append(k >= 1 ? "Water goal reached." : k >= 0.75 ? "So close on water." : "Water at \(MetricsFormat.percent(k)).")
        }
        if d.focusSessions >= 4 { parts.append("Focus was strong.") }
        else if d.focusSessions > 0 { parts.append("\(d.focusSessions) focus session\(d.focusSessions == 1 ? "" : "s").") }
        return parts.isEmpty ? "A day to start a routine." : parts.joined(separator: " ")
    }
}

private struct Segments: View {
    let count: Int
    let of: Int
    let color: Color
    var rest: Color = Color.white.opacity(0.1)

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<max(1, min(12, of)), id: \.self) { i in
                Capsule().fill(i < count ? color : rest).frame(height: 6)
            }
        }
    }
}

// MARK: The Mac's day

private struct MacCard: View {
    let brief: DailyBrief

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(label: "The Mac's day", title: title)
            if let mac = brief.mac, !mac.buckets.isEmpty {
                Tile {
                    HStack {
                        Text("CPU").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("avg \(MetricsFormat.percent(mac.averageCPU ?? 0)) · peak \(MetricsFormat.percent(mac.buckets.map(\.cpuMax).max() ?? 0))")
                            .font(.system(size: 12).monospacedDigit()).foregroundColor(HubTheme.secondary)
                    }
                    DayChart(values: mac.buckets.map { ($0.minute, $0.cpu) }, peaks: mac.peaks(), color: Color(hex: "#3B9EFF"))
                        .frame(height: 150)
                    HStack {
                        ForEach(["00:00", "06:00", "12:00", "18:00", "24:00"], id: \.self) { t in
                            Text(t).font(.system(size: 10.5)).foregroundColor(HubTheme.muted)
                            if t != "24:00" { Spacer() }
                        }
                    }
                }
                .frame(height: 220)
                Tile {
                    HStack {
                        Text("Memory").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("avg \(MetricsFormat.percent(mac.averageMemory ?? 0)) · peak \(MetricsFormat.percent(mac.buckets.map(\.memory).max() ?? 0))")
                            .font(.system(size: 12).monospacedDigit()).foregroundColor(HubTheme.secondary)
                    }
                    DayChart(values: mac.buckets.map { ($0.minute, $0.memory) }, peaks: [], color: Color(hex: "#A78BFA"))
                        .frame(height: 70)
                }
                .frame(height: 120)
            } else {
                Tile {
                    Text("Coucou keeps a light record of the Mac's day while the Daily brief shows it: one reading a minute, kept 14 days, never sent anywhere. Tomorrow's brief will have it.")
                        .font(.system(size: 13)).foregroundColor(HubTheme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(height: 100)
            }
            Spacer(minLength: 0)
        }
    }

    private var title: String {
        guard let mac = brief.mac, !mac.buckets.isEmpty else { return "The Mac's day starts now." }
        guard let peak = mac.peaks(count: 1).first else { return "A calm day for the Mac." }
        let when = MacDay.clock(peak.minute)
        return peak.peakApp.map { "Busiest at \(when), during \($0)." } ?? "Busiest at \(when)."
    }
}

/// A day, 00:00 to 24:00, as an area; the peaks dotted and named.
private struct DayChart: View {
    let values: [(minute: Int, value: Double)]
    let peaks: [MacDayBucket]
    let color: Color

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let point = { (m: Int, v: Double) in CGPoint(x: w * CGFloat(m + 2) / 1440, y: h * (1 - CGFloat(max(0, min(1, v))) * 0.92)) }
            ZStack(alignment: .topLeading) {
                Path { p in
                    guard let first = values.first else { return }
                    p.move(to: CGPoint(x: point(first.minute, 0).x, y: h))
                    for v in values { p.addLine(to: point(v.minute, v.value)) }
                    p.addLine(to: CGPoint(x: point(values.last!.minute, 0).x, y: h))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.04)], startPoint: .top, endPoint: .bottom))
                Path { p in
                    for (i, v) in values.enumerated() {
                        if i == 0 { p.move(to: point(v.minute, v.value)) } else { p.addLine(to: point(v.minute, v.value)) }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                ForEach(peaks, id: \.minute) { peak in
                    let p = point(peak.minute, peak.cpuMax)
                    Circle().fill(.white).frame(width: 9, height: 9)
                        .overlay(Circle().stroke(color, lineWidth: 3))
                        .position(p)
                    Text([peak.peakApp, MacDay.clock(peak.minute)].compactMap { $0 }.joined(separator: " "))
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 7).frame(height: 20)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .fixedSize()
                        .position(x: min(max(p.x + 50, 60), w - 60), y: max(10, p.y))
                }
            }
        }
    }
}

// MARK: Claude plan

private struct PlanCard: View {
    let brief: DailyBrief

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(label: "Claude plan", title: title)
            if let plan = brief.plan, plan.fiveHour != nil || plan.sevenDay != nil {
                HStack(spacing: 12) {
                    if let w = plan.fiveHour { ring(w, "5-hour window", HubTheme.accent) }
                    if let w = plan.sevenDay { ring(w, "Weekly", Color(hex: "#A78BFA")) }
                }
            } else {
                Tile {
                    Text("Your plan shows here once Claude Code reports it through Coucou's status-line relay (Settings → Agents → Plan gauge).")
                        .font(.system(size: 13)).foregroundColor(HubTheme.secondary)
                }
                .frame(height: 90)
            }
            Spacer(minLength: 0)
        }
    }

    private var title: String {
        guard let plan = brief.plan else { return "Your Claude plan." }
        let used = [plan.fiveHour, plan.sevenDay].compactMap { $0 }.map(ClaudePlanGauge.effectivePct).max() ?? 0
        return used < 50 ? "Plenty of Claude left for today." : used < 80 ? "Keep an eye on your plan." : "Your plan is nearly used up."
    }

    private func ring(_ w: PlanWindow, _ name: String, _ tint: Color) -> some View {
        let left = max(0, 100 - ClaudePlanGauge.effectivePct(w))
        return Tile(glow: tint) {
            VStack(spacing: 14) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.07), lineWidth: 14)
                    Circle().trim(from: 0, to: CGFloat(left / 100))
                        .stroke(tint, style: StrokeStyle(lineWidth: 14, lineCap: .round)).rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(Int(left.rounded()))%").font(.system(size: 34, weight: .bold).monospacedDigit())
                        Text("left").font(.system(size: 12)).foregroundColor(HubTheme.secondary)
                    }
                }
                .frame(width: 150, height: 150)
                VStack(spacing: 2) {
                    Text(name).font(.system(size: 15, weight: .semibold))
                    Text("resets \(w.resetsAt.formatted(Calendar.current.isDateInToday(w.resetsAt) ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).hour().minute()))")
                        .font(.system(size: 12)).foregroundColor(HubTheme.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: Today ahead

private struct AheadCard: View {
    let brief: DailyBrief
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(label: "Today ahead", title: title)
                if DailyBriefCalendar.status != .fullAccess {
                    Tile {
                        Text("Allow Calendar access to see today's events (System Settings → Privacy & Security → Calendars → Coucou).")
                            .font(.system(size: 13)).foregroundColor(HubTheme.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(height: 90)
                } else {
                    ForEach(brief.events.prefix(6)) { e in
                        HStack(spacing: 12) {
                            Text(e.allDay ? "All day" : e.start.formatted(.dateTime.hour().minute()))
                                .font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundColor(HubTheme.secondary)
                                .frame(width: 56, alignment: .leading)
                            RoundedRectangle(cornerRadius: 1.5).fill(Color(hex: e.color ?? "#3B9EFF")).frame(width: 3, height: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                                if !e.allDay {
                                    Text(DailyBriefText.duration(minutes: Int(e.end.timeIntervalSince(e.start) / 60)))
                                        .font(.system(size: 11.5)).foregroundColor(HubTheme.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(HubTheme.card))
                        .opacity(e.end < Date() ? 0.45 : 1)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            StreakPanel(brief: brief, close: close).frame(width: 250)
        }
    }

    private var title: String {
        guard DailyBriefCalendar.status == .fullAccess else { return "Your day." }
        let upcoming = brief.events.filter { $0.end > Date() }
        guard let first = upcoming.first(where: { !$0.allDay }) ?? upcoming.first else { return "Nothing on your calendar." }
        let n = upcoming.count
        return "\(n) event\(n == 1 ? "" : "s"). First one at \(first.allDay ? "any time" : first.start.formatted(.dateTime.hour().minute()))."
    }
}

private struct ClosingCard: View {
    let brief: DailyBrief
    let close: () -> Void

    var body: some View {
        VStack {
            Spacer()
            StreakPanel(brief: brief, close: close).frame(width: 300, height: 380)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// The streak and the end of the brief: Mochi cheers.
private struct StreakPanel: View {
    let brief: DailyBrief
    let close: () -> Void
    @State private var cheer = false

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            HubLiveMochi(color: "#F5F6F8", size: 96, state: .finished)
                .frame(width: 120, height: 96)
                .scaleEffect(cheer ? 1.06 : 0.94)
            VStack(spacing: 4) {
                Text(brief.readStreak > 1 ? "\(brief.readStreak)-day streak" : "Have a good one")
                    .font(.system(size: 24, weight: .bold))
                Text(brief.readStreak > 1 ? "Brief read every day" : "See you tomorrow morning")
                    .font(.system(size: 12.5)).foregroundColor(HubTheme.secondary)
            }
            HStack(spacing: 6) {
                ForEach(Array(["M", "T", "W", "T", "F", "S", "S"].enumerated()), id: \.offset) { i, d in
                    VStack(spacing: 4) {
                        Circle().fill(brief.weekRead.indices.contains(i) && brief.weekRead[i] ? HubTheme.accent : Color.white.opacity(0.1))
                            .frame(width: 20, height: 20)
                        Text(d).font(.system(size: 10)).foregroundColor(HubTheme.muted)
                    }
                }
            }
            Button(action: close) {
                Text("Start the day").font(.system(size: 14, weight: .bold)).foregroundColor(HubTheme.onAccent)
                    .padding(.horizontal, 24).frame(height: 40)
                    .background(Capsule().fill(HubTheme.accent))
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(RadialGradient(colors: [HubTheme.accent.opacity(0.18), HubTheme.card], center: .top, startRadius: 0, endRadius: 260)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
        .onAppear { withAnimation(.easeInOut(duration: 0.6).repeatCount(5, autoreverses: true)) { cheer = true } }
    }
}

// MARK: - The notch banner

struct DailyBriefBanner: View {
    static let width: CGFloat = 560
    static let height: CGFloat = 118

    let brief: DailyBrief
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let open: () -> Void
    let later: () -> Void

    @State private var expanded = false
    @State private var chip = 0

    private var chips: [(color: Color, value: String, label: String)] {
        var out: [(Color, String, String)] = []
        if let w = brief.work, !w.isEmpty {
            out.append((HubTheme.accent, DailyBriefText.duration(minutes: w.minutes), "with your agents"))
            if w.filesChanged > 0 { out.append((HubTheme.green, "\(w.filesChanged)", "files changed")) }
        }
        if let d = brief.diary, d.focusSessions > 0 { out.append((Color(hex: "#818CF8"), "\(d.focusSessions)", "focus sessions")) }
        if let water = brief.water { out.append((Color(hex: "#22D3EE"), DailyBriefText.water(water.ml), "of water")) }
        if let weather = brief.weather { out.append((Color(hex: "#F7B32B"), "\(weather.now)°", DailyBriefWeather.describe(weather.code).lowercased())) }
        return out
    }

    var body: some View {
        let w = expanded ? Self.width : notchWidth
        let h = expanded ? Self.height : notchHeight
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                UnevenRoundedRectangle(bottomLeadingRadius: expanded ? 26 : 12, bottomTrailingRadius: expanded ? 26 : 12, style: .continuous)
                    .fill(Color.black)
                if expanded {
                    content.transition(.opacity)
                }
            }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .onTapGesture { open() }
            Spacer(minLength: 0)
        }
        .frame(width: Self.width + 40, height: Self.height + 30, alignment: .top)
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78).delay(0.1)) { expanded = true }
        }
        .task {
            // The chips take turns.
            while !Task.isCancelled, chips.count > 1 {
                try? await Task.sleep(for: .seconds(2.6))
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { chip = (chip + 1) % chips.count }
            }
        }
    }

    private var content: some View {
        HStack(alignment: .bottom, spacing: 14) {
            HubLiveMochi(color: "#F5F6F8", size: 58, state: .idle)
                .frame(width: 70, height: 52)
                .offset(y: 8)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(brief.greeting + ".").font(.system(size: 15, weight: .bold)).lineLimit(1)
                    Text(brief.headline).font(.system(size: 12.5)).foregroundColor(HubTheme.body).lineLimit(1)
                }
                HStack(spacing: 10) {
                    if !chips.isEmpty {
                        let c = chips[chip % chips.count]
                        HStack(spacing: 7) {
                            Circle().fill(c.color).frame(width: 6, height: 6)
                            Text(c.value).font(.system(size: 12.5, weight: .bold).monospacedDigit())
                            Text(c.label).font(.system(size: 12)).foregroundColor(HubTheme.secondary)
                        }
                        .padding(.horizontal, 10).frame(width: 190, height: 28, alignment: .leading)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                        .id(chip)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                        HStack(spacing: 3) {
                            ForEach(0..<chips.count, id: \.self) { i in
                                Capsule().fill(Color.white.opacity(i == chip % chips.count ? 0.9 : 0.25))
                                    .frame(width: i == chip % chips.count ? 12 : 4, height: 4)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    Button("Later", action: later).buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .semibold)).foregroundColor(HubTheme.secondary)
                    Button(action: open) {
                        Text("Open").font(.system(size: 12.5, weight: .bold)).foregroundColor(HubTheme.onAccent)
                            .padding(.horizontal, 14).frame(height: 28).background(Capsule().fill(HubTheme.accent))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.leading, 14).padding(.trailing, 16).padding(.bottom, 12).padding(.top, notchHeight + 4)
        .foregroundColor(HubTheme.text)
    }
}
#endif
