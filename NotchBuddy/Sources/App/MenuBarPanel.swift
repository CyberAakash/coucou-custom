#if !APPSTORE
import AppKit
import Combine
import SwiftUI

// coucou-custom fork: the panel under Coucou's menu-bar item — your agents, the Claude plan, the
// Mac, your routines, your Custom Metrics, then Coucou's actions. Each section can be hidden or
// moved (Settings → Menu bar → Panel). A borderless panel right under the menu bar, like Control
// Centre's, gone on Esc or a click anywhere else.

enum MenuBarPanelSection: String, CaseIterable, Identifiable, Codable {
    case agents, plan, mac, routines, metrics
    var id: String { rawValue }

    var title: String {
        switch self {
        case .agents: "Agents"
        case .plan: "Claude plan"
        case .mac: "This Mac"
        case .routines: "Routines"
        case .metrics: "Custom Metrics"
        }
    }

    var detail: String {
        switch self {
        case .agents: "Each running session: its project, what it does, how long, and when it needs you."
        case .plan: "The 5-hour and weekly windows, with when they reset."
        case .mac: "CPU and memory with their last minutes, storage, battery, network."
        case .routines: "Water, the focus session, the timer and your next reminder, with their buttons."
        case .metrics: "The cards of your Custom Metrics files."
        }
    }

    var symbol: String {
        switch self {
        case .agents: "terminal"
        case .plan: "staroflife"
        case .mac: "laptopcomputer"
        case .routines: "drop"
        case .metrics: "chart.bar.horizontal.page"
        }
    }
}

// MARK: - The window

@MainActor
final class MenuBarPanelController {
    static let shared = MenuBarPanelController()

    private var panel: NSPanel?
    private var host: NSHostingView<AnyView>?
    private var monitors: [Any] = []
    /// Bumped on each show: a fade-out that ends after a new show leaves the panel alone.
    private var generation = 0
    private weak var anchor: NSStatusBarButton?
    var onClose: (() -> Void)?

    var isShown: Bool { panel?.isVisible == true }

    func toggle(from button: NSStatusBarButton) {
        if isShown { close() } else { show(from: button) }
    }

    func show(from button: NSStatusBarButton) {
        generation += 1
        anchor = button
        let p = panel ?? makePanel()
        panel = p
        host?.rootView = AnyView(MenuBarPanelView(close: { [weak self] in self?.close() },
                                                  resize: { [weak self] in self?.fit() }))
        fit()
        p.alphaValue = 0
        p.orderFrontRegardless()
        p.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            p.animator().alphaValue = 1
        }
        watchOutside()
    }

    func close() {
        guard let p = panel, p.isVisible else { return }
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        let closing = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard closing == self.generation else { return }   // shown again meanwhile
                p.orderOut(nil)
                // Nothing keeps drawing behind a closed panel.
                self.host?.rootView = AnyView(EmptyView())
                self.onClose?()
            }
        })
    }

    private func makePanel() -> NSPanel {
        let p = MenuBarPanelWindow(contentRect: NSRect(x: 0, y: 0, width: MenuBarPanelView.width, height: 200),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.appearance = NSAppearance(named: .darkAqua)
        let h = NSHostingView(rootView: AnyView(EmptyView()))
        p.contentView = h
        host = h
        return p
    }

    /// As tall as its content, up to what the screen has under the menu bar.
    func fit() {
        guard let p = panel, let host, let button = anchor, let window = button.window,
              let screen = window.screen ?? NSScreen.main else { return }
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let maxHeight = min(MenuBarPanelView.maxHeight, screen.visibleFrame.height - 16)
        let size = host.fittingSize
        let height = min(max(120, size.height), maxHeight)
        var x = buttonFrame.midX - MenuBarPanelView.width / 2
        x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - MenuBarPanelView.width - 8)
        let frame = NSRect(x: x, y: screen.visibleFrame.maxY - 6 - height, width: MenuBarPanelView.width, height: height)
        if p.frame != frame { p.setFrame(frame, display: true) }
    }

    private func watchOutside() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(m) }
        // A click in another of Coucou's windows closes it too (not one on the icon: that toggles).
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            let outside = MainActor.assumeIsolated { () -> Bool in
                guard let self, let p = self.panel else { return false }
                return event.window !== p && event.window !== self.anchor?.window
            }
            if outside { MainActor.assumeIsolated { self?.close() } }
            return event
        }) { monitors.append(m) }
        // Esc in the panel only; Coucou's other windows keep theirs.
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            let mine = MainActor.assumeIsolated { () -> Bool in
                event.keyCode == 53 && event.window === self?.panel
            }
            guard mine else { return event }
            MainActor.assumeIsolated { self?.close() }
            return nil
        }) { monitors.append(m) }
    }
}

/// Takes the keyboard (Esc, text fields) without making Coucou the active app.
private final class MenuBarPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - The panel

struct MenuBarPanelView: View {
    static let width: CGFloat = 360
    static let maxHeight: CGFloat = 680

    let close: () -> Void
    let resize: () -> Void

    @ObservedObject private var settings = RunnerSettings.shared
    @ObservedObject private var sampler = RunnerSampler.shared
    @ObservedObject private var center = RunnerMetricsCenter.shared
    @ObservedObject private var live = LiveSessions.shared
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var routines = BuddyRoutineController.shared
    @ObservedObject private var routineSettings = BuddyRoutineSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    ForEach(settings.panelSections) { section in
                        sectionView(section)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)
                .background(GeometryReader { g in Color.clear.preference(key: PanelHeightKey.self, value: g.size.height) })
            }
            .scrollIndicators(.never)
            .frame(maxHeight: Self.maxHeight - 110)
            .fixedSize(horizontal: false, vertical: true)
            footer
        }
        .frame(width: Self.width)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(hex: "#0E0F11").opacity(0.97))
        )
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.09)))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .foregroundColor(HubTheme.text)
        .environment(\.colorScheme, .dark)
        .onPreferenceChange(PanelHeightKey.self) { _ in DispatchQueue.main.async { resize() } }
        .onChange(of: settings.panelSections) { DispatchQueue.main.async { resize() } }
    }

    // MARK: Header

    private var busySessions: [SessionTracker.Session] { live.sessions.filter(\.isBusy) }

    private var header: some View {
        HStack(spacing: 12) {
            HubLiveMochi(color: "#F5F6F8", size: 36, state: busySessions.isEmpty ? .idle : .working)
                .frame(width: 40, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(DailyBriefText.greeting(at: Date(), name: nil))
                    .font(.system(size: 16, weight: .bold))
                Text(statusLine)
                    .font(.system(size: 12))
                    .foregroundColor(HubTheme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { close(); FlowHubController.shared.show(.runner) } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 12, weight: .semibold))
                    .foregroundColor(HubTheme.secondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("Menu bar settings")
        }
    }

    private var statusLine: String {
        let working = busySessions.filter { $0.status == .working || $0.status == .background }.count
        let waiting = busySessions.filter { $0.status == .waiting }.count
        var parts: [String] = []
        if working > 0 { parts.append(working == 1 ? "1 agent working" : "\(working) agents working") }
        if waiting > 0 { parts.append(waiting == 1 ? "1 needs you" : "\(waiting) need you") }
        return parts.isEmpty ? "No agent at work" : parts.joined(separator: " · ")
    }

    // MARK: Sections

    @ViewBuilder private func sectionView(_ s: MenuBarPanelSection) -> some View {
        switch s {
        case .agents: agentsSection
        case .plan: planSection
        case .mac: macSection
        case .routines: routinesSection
        case .metrics: metricsSection
        }
    }

    private func label(_ text: String, trailing: String? = nil) -> some View {
        HStack {
            Text(text.uppercased()).font(.system(size: 10.5, weight: .bold)).tracking(1.2).foregroundColor(HubTheme.muted)
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 11)).foregroundColor(HubTheme.muted) }
        }
    }

    // Agents

    @ViewBuilder private var agentsSection: some View {
        let shown = live.sessions.filter(\.needsAttention).sorted { $0.lastActivity > $1.lastActivity }.prefix(5)
        VStack(alignment: .leading, spacing: 8) {
            label("Agents", trailing: shown.isEmpty ? nil : (shown.count == 1 ? "1 session" : "\(shown.count) sessions"))
            if shown.isEmpty {
                PanelEmpty(symbol: "moon.zzz", text: "No session right now. Mochi is resting.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, s in
                        if i > 0 { Divider().overlay(Color.white.opacity(0.05)).padding(.leading, 50) }
                        PanelSessionRow(session: s) {
                            close()
                            LiveSessions.shared.select(s.id)
                            NotificationCenter.default.post(name: .hookExpand, object: IslandView.sessions)
                        }
                    }
                }
                .background(PanelCard())
            }
        }
    }

    // Plan

    @ViewBuilder private var planSection: some View {
        if let usage = app.claudePlanUsage, usage.fiveHour != nil || usage.sevenDay != nil {
            VStack(alignment: .leading, spacing: 8) {
                label("Claude plan", trailing: "updated \(MetricsFormat.ago(usage.updatedAt, now: Date()))")
                HStack(spacing: 0) {
                    if let w = usage.fiveHour { PanelPlanRing(title: "5-hour", window: w, tint: HubTheme.accent) }
                    if let w = usage.sevenDay { PanelPlanRing(title: "Weekly", window: w, tint: Color(hex: "#A78BFA")) }
                }
                .padding(12)
                .background(PanelCard(glow: HubTheme.accent))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                label("Claude plan")
                PanelEmpty(symbol: "staroflife", text: "Shows once Claude Code reports your plan (Agents → Plan gauge).")
            }
        }
    }

    // Mac

    private var macSection: some View {
        let s = sampler.sample
        let tiles = SystemMetricKind.allCases.filter { settings.panelMacTiles.contains($0) }
        return VStack(alignment: .leading, spacing: 8) {
            label("This Mac", trailing: Host.current().localizedName)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(tiles) { kind in
                    switch kind {
                    case .cpu:
                        PanelMacTile(title: "CPU", value: s.cpu.map(MetricsFormat.percent) ?? "—",
                                     history: sampler.cpuHistory.values, fraction: s.cpu, tint: Color(hex: "#3B9EFF"),
                                     caption: "\(ProcessInfo.processInfo.activeProcessorCount) cores")
                    case .memory:
                        PanelMacTile(title: "Memory", value: s.memoryUsed.map { MetricsFormat.bytes($0) } ?? "—",
                                     history: sampler.memoryHistory.values, fraction: s.memoryFraction, tint: Color(hex: "#A78BFA"),
                                     caption: s.memoryTotal.map { "of \(MetricsFormat.bytes($0))" })
                    case .storage:
                        PanelMacTile(title: "Storage", value: s.storageFraction.map(MetricsFormat.percent) ?? "—",
                                     history: [], fraction: s.storageFraction, tint: Color(hex: "#22D3EE"),
                                     caption: s.storageTotal.map { t in "\(MetricsFormat.diskBytes(t - min(t, s.storageUsed ?? 0))) free" })
                    case .battery:
                        if let b = s.batteryPercent {
                            PanelMacTile(title: "Battery", value: "\(b)%", history: [], fraction: Double(b) / 100,
                                         tint: b < 20 ? HubTheme.red : HubTheme.green,
                                         caption: s.batteryOnPower == true ? "on power" : "on battery")
                        }
                    case .network:
                        PanelMacTile(title: "Network", value: s.networkIn.map { "↓ " + MetricsFormat.rate($0) } ?? "—",
                                     history: [], fraction: nil, tint: HubTheme.green,
                                     caption: s.networkOut.map { "↑ " + MetricsFormat.rate($0) })
                    }
                }
            }
        }
    }

    // Routines

    @ViewBuilder private var routinesSection: some View {
        let water = routineSettings.waterEnabled
        let hasAny = water || routines.focus != nil || routines.countdown != nil || !routines.reminders.isEmpty
        VStack(alignment: .leading, spacing: 8) {
            label("Routines")
            if !hasAny {
                PanelEmpty(symbol: "sparkles", text: "Start a focus session or a timer, or turn on Water in Settings → Buddy.")
            } else {
                VStack(spacing: 8) {
                    if water { PanelWaterRow(routines: routines, settings: routineSettings) }
                    if let f = routines.focus { PanelFocusRow(focus: f, routines: routines) }
                    if let c = routines.countdown { PanelTimerRow(countdown: c, routines: routines) }
                    if let next = routines.reminders.sorted(by: { $0.due < $1.due }).first {
                        PanelReminderRow(reminder: next, more: routines.reminders.count - 1)
                    }
                }
            }
            HStack(spacing: 6) {
                if routines.focus == nil {
                    PanelChip(symbol: "brain.head.profile", text: "Focus") { routines.startFocus() }
                }
                if routines.countdown == nil {
                    PanelChip(symbol: "timer", text: "5 min") { _ = routines.startTimer(seconds: 300) }
                }
                PanelChip(symbol: "wind", text: "Breathe") { close(); routines.startBreathing(routineSettings.lastBreathing) }
            }
        }
    }

    // Custom Metrics

    @ViewBuilder private var metricsSection: some View {
        if !settings.sources.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                label("Custom Metrics")
                ForEach(settings.sources) { source in
                    RunnerMetricsCard(source: source, state: center.states[source.id])
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 8) {
            if MacUpdater.shared.hintActive {
                Button { close(); RunnerStatusItem.perform("openUpdate") } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill").foregroundColor(Color(hex: "#3B9EFF"))
                        Text("A new Coucou is ready").font(.system(size: 12.5, weight: .semibold))
                        Spacer()
                        Text("Update").font(.system(size: 12, weight: .bold)).foregroundColor(Color(hex: "#3B9EFF"))
                    }
                    .padding(.horizontal, 12).frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(hex: "#3B9EFF").opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                PanelAction(text: "Open Coucou") { close(); RunnerStatusItem.perform("openIsland") }
                PanelAction(text: "Daily brief") { close(); DailyBriefController.shared.show(force: true) }
                PanelAction(text: "Weekly recap") { close(); RunnerStatusItem.perform("openWeeklyRecap") }
                PanelAction(text: "Coucou window") { close(); RunnerStatusItem.perform("openFlowHub") }
                PanelAction(text: "Settings") { close(); RunnerStatusItem.perform("openSettings") }
                PanelAction(text: "Quit", dim: true) { close(); RunnerStatusItem.perform("quitCompletely") }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.025))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
    }
}

private struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Pieces

private struct PanelCard: View {
    var glow: Color? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(HubTheme.card)
            .overlay {
                if let glow {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(RadialGradient(colors: [glow.opacity(0.16), .clear], center: .topLeading, startRadius: 0, endRadius: 220))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
    }
}

private struct PanelEmpty: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundColor(HubTheme.muted)
            Text(text).font(.system(size: 12)).foregroundColor(HubTheme.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(PanelCard())
    }
}

private struct PanelSessionRow: View {
    let session: SessionTracker.Session
    let open: () -> Void
    @State private var hover = false

    private var pill: PillDefinition? { PillCatalog.definition(for: session.pill) }
    private var tint: Color { Color(hex: pill?.color ?? "#8E939C") }

    private var initials: String {
        let name = pill?.name ?? session.pill
        let words = name.split(separator: " ")
        let letters = words.count > 1 ? words.prefix(2).compactMap(\.first) : Array(name.prefix(2))
        return String(letters).uppercased()
    }

    private var state: (text: String, color: Color) {
        switch session.status {
        case .working: ("Working", HubTheme.green)
        case .background: ("Agents running", Color(hex: "#3B9EFF"))
        case .waiting: ("Needs you", Color(hex: "#F7B32B"))
        case .finished: ("Done", Color(hex: "#8E939C"))
        case .failed: ("Failed", HubTheme.red)
        case .idle: ("Ready", Color(hex: "#8E939C"))
        }
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Text(initials)
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundColor(tint)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.16)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.projectName.isEmpty ? (pill?.name ?? "Session") : session.projectName)
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text([pill?.name, session.currentStep].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundColor(HubTheme.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 3) {
                    HStack(spacing: 4) {
                        Circle().fill(state.color).frame(width: 6, height: 6)
                        Text(state.text).font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundColor(state.color)
                    .padding(.horizontal, 7).frame(height: 20)
                    .background(Capsule().fill(state.color.opacity(0.13)))
                    if let start = session.turnStartedAt, session.isBusy {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(BuddyTimeText.clock(ctx.date.timeIntervalSince(start)))
                                .font(.system(size: 10.5).monospacedDigit()).foregroundColor(HubTheme.muted)
                        }
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(hover ? Color.white.opacity(0.04) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct PanelPlanRing: View {
    let title: String
    let window: PlanWindow
    let tint: Color

    var body: some View {
        let pct = ClaudePlanGauge.effectivePct(window)
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.08), lineWidth: 5)
                Circle().trim(from: 0, to: CGFloat(min(1, pct / 100)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(pct.rounded()))%").font(.system(size: 11.5, weight: .bold).monospacedDigit())
            }
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text("resets \(Self.reset(window.resetsAt))").font(.system(size: 11)).foregroundColor(HubTheme.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    static func reset(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: date)
    }
}

private struct PanelMacTile: View {
    let title: String
    let value: String
    let history: [Double]
    let fraction: Double?
    let tint: Color
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 11.5)).foregroundColor(HubTheme.secondary)
                Spacer()
                Text(value).font(.system(size: 13, weight: .bold).monospacedDigit()).lineLimit(1)
            }
            if history.count > 1 {
                RunnerSparkline(values: history, color: tint).frame(height: 20)
            } else if let fraction {
                RunnerBar(fraction: fraction, color: tint)
            }
            if let caption {
                Text(caption).font(.system(size: 10.5).monospacedDigit()).foregroundColor(HubTheme.muted).lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .background(PanelCard())
    }
}

private struct PanelWaterRow: View {
    @ObservedObject var routines: BuddyRoutineController
    @ObservedObject var settings: BuddyRoutineSettings

    var body: some View {
        let today = settings.waterLog.total(on: Date())
        let goal = max(1, settings.waterPlan.goal)
        PanelRoutineRow(tint: Color(hex: "#22D3EE"), symbol: "drop.fill", progress: Double(today) / Double(goal),
                        title: "Water", subtitle: "\(DailyBriefText.water(today)) of \(DailyBriefText.water(goal)) today") {
            PanelChip(symbol: "plus", text: BuddyWater.amount(settings.waterPlan.glass), tint: Color(hex: "#22D3EE")) {
                routines.logWater()
            }
        }
    }
}

private struct PanelFocusRow: View {
    let focus: BuddyFocusSession
    @ObservedObject var routines: BuddyRoutineController

    var body: some View {
        let left = focus.remaining(at: routines.now)
        let total = TimeInterval(max(1, focus.plan.minutes(focus.phase) * 60))
        PanelRoutineRow(tint: focus.phase.isBreak ? HubTheme.green : Color(hex: "#818CF8"),
                        symbol: focus.phase.isBreak ? "cup.and.saucer.fill" : "brain.head.profile",
                        progress: 1 - left / total, title: focus.phase.label,
                        subtitle: "\(BuddyTimeText.clock(left)) left\(focus.isPaused ? " · paused" : "")") {
            PanelChip(symbol: focus.isPaused ? "play.fill" : "pause.fill", text: focus.isPaused ? "Resume" : "Pause") {
                focus.isPaused ? routines.resumeFocus() : routines.pauseFocus()
            }
        }
    }
}

private struct PanelTimerRow: View {
    let countdown: BuddyCountdown
    @ObservedObject var routines: BuddyRoutineController

    var body: some View {
        let left = countdown.remaining(at: routines.now)
        PanelRoutineRow(tint: Color(hex: "#F7B32B"), symbol: "timer", progress: 1 - left / max(1, countdown.total),
                        title: countdown.label.isEmpty ? "Timer" : countdown.label,
                        subtitle: "\(BuddyTimeText.clock(left)) left\(countdown.isPaused ? " · paused" : "")") {
            PanelChip(symbol: countdown.isPaused ? "play.fill" : "pause.fill", text: countdown.isPaused ? "Resume" : "Pause") {
                countdown.isPaused ? routines.resumeTimer() : routines.pauseTimer()
            }
        }
    }
}

private struct PanelReminderRow: View {
    let reminder: BuddyReminder
    let more: Int

    var body: some View {
        PanelRoutineRow(tint: Color(hex: "#F472B6"), symbol: "bell.fill", progress: nil, title: reminder.text,
                        subtitle: "\(PanelPlanRing.reset(reminder.due))\(more > 0 ? " · \(more) more" : "")") { EmptyView() }
    }
}

private struct PanelRoutineRow<Trailing: View>: View {
    let tint: Color
    let symbol: String
    let progress: Double?
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.14))
                if let progress {
                    Circle().trim(from: 0, to: CGFloat(max(0, min(1, progress))))
                        .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                        .padding(1.5)
                }
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundColor(tint)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 11).monospacedDigit()).foregroundColor(HubTheme.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            trailing()
        }
        .padding(10)
        .background(PanelCard())
    }
}

private struct PanelChip: View {
    let symbol: String
    let text: String
    var tint: Color = HubTheme.body
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .bold))
                Text(text).font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundColor(tint)
            .padding(.horizontal, 10).frame(height: 26)
            .background(Capsule().fill(Color.white.opacity(hover ? 0.12 : 0.07)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct PanelAction: View {
    let text: String
    var dim = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(dim ? HubTheme.secondary : HubTheme.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(hover ? 0.1 : 0.055)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
#endif
