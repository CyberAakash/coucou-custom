#if !APPSTORE
import AppKit
import Combine
import SwiftUI

// coucou-custom fork: the panel under Coucou's menu-bar item, in Liquid Glass — your agents, today
// and this week, the Claude plan's limits, the Mac, your routines with their quick actions, your
// Custom Metrics; Coucou's actions in one menu at the top right. Each section can be hidden or moved
// (Settings → Menu bar → Panel). A borderless panel right under the menu bar, like Control Centre's,
// gone on Esc or a click anywhere else.

enum MenuBarPanelSection: String, CaseIterable, Identifiable, Codable {
    case agents, briefs, plan, mac, routines, metrics
    var id: String { rawValue }

    var title: String {
        switch self {
        case .agents: "Agents"
        case .briefs: "Today & this week"
        case .plan: "Claude plan"
        case .mac: "This Mac"
        case .routines: "Routines"
        case .metrics: "Custom Metrics"
        }
    }

    var detail: String {
        switch self {
        case .agents: "Each running session: its project, what it does, how long, and when it needs you."
        case .briefs: "Your agents' time today and this week, with water and focus; click one for its brief."
        case .plan: "The 5-hour and weekly windows, with when they reset."
        case .mac: "CPU and memory with their last minutes, storage, battery, network."
        case .routines: "Water, the focus session, the timer and your next reminder, with their buttons."
        case .metrics: "The cards of your Custom Metrics files."
        }
    }

    var symbol: String {
        switch self {
        case .agents: "terminal"
        case .briefs: "sun.horizon"
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
    static let width: CGFloat = 368
    static let maxHeight: CGFloat = 720

    let close: () -> Void
    let resize: () -> Void

    @ObservedObject private var settings = RunnerSettings.shared
    @ObservedObject private var sampler = RunnerSampler.shared
    @ObservedObject private var center = RunnerMetricsCenter.shared
    @ObservedObject private var live = LiveSessions.shared
    @ObservedObject private var plan = ClaudePlanLimitsFetcher.shared
    @ObservedObject private var routines = BuddyRoutineController.shared
    @ObservedObject private var routineSettings = BuddyRoutineSettings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                ForEach(settings.panelSections) { section in
                    sectionView(section)
                }
            }
            .padding(14)
            .background(GeometryReader { g in Color.clear.preference(key: PanelHeightKey.self, value: g.size.height) })
        }
        .scrollIndicators(.never)
        .frame(maxHeight: Self.maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: Self.width)
        .modifier(PanelGlass())
        .foregroundColor(HubTheme.text)
        .environment(\.colorScheme, .dark)
        .onPreferenceChange(PanelHeightKey.self) { _ in DispatchQueue.main.async { resize() } }
        .onChange(of: settings.panelSections) { DispatchQueue.main.async { resize() } }
        .onAppear { if settings.panelSections.contains(.plan) { plan.refresh() } }
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
            // Coucou's one way in from here; the rest of its menu is a right-click on the icon.
            Menu {
                Menu("Daily brief") {
                    Button("In the notch") { close(); DailyBriefController.shared.show(place: .notch) }
                    Button("Full screen") { close(); DailyBriefController.shared.show(place: .fullScreen) }
                }
                Menu("Weekly recap") {
                    Button("In the notch") { close(); WeeklyBriefController.shared.show(place: .notch) }
                    Button("Full screen") { close(); WeeklyBriefController.shared.show(place: .fullScreen) }
                }
                Divider()
                Button("Open the Coucou window") { close(); RunnerStatusItem.perform("openFlowHub") }
                Button("Menu bar settings…") { close(); FlowHubController.shared.show(.runner) }
                Divider()
                Button("Quit Coucou") { close(); RunnerStatusItem.perform("quitCompletely") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold))
                    .foregroundColor(HubTheme.body)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Coucou")
        }
    }

    private var statusLine: String {
        let working = busySessions.filter { $0.status == .working || $0.status == .background }.count
        let waiting = busySessions.filter { $0.status == .waiting }.count
        var parts: [String] = []
        if working > 0 { parts.append(working == 1 ? "1 agent working" : "\(working) agents working") }
        if waiting > 0 { parts.append(waiting == 1 ? "1 needs you" : "\(waiting) need you") }
        if MacUpdater.shared.hintActive { parts.append("an update is ready") }
        return parts.isEmpty ? "No agent at work" : parts.joined(separator: " · ")
    }

    // MARK: Sections

    @ViewBuilder private func sectionView(_ s: MenuBarPanelSection) -> some View {
        switch s {
        case .agents: agentsSection
        case .briefs: briefsSection
        case .plan: planSection
        case .mac: macSection
        case .routines: PanelRoutines(close: close)
        case .metrics: metricsSection
        }
    }

    // Agents

    @ViewBuilder private var agentsSection: some View {
        let shown = live.sessions.filter(\.needsAttention).sorted { $0.lastActivity > $1.lastActivity }.prefix(5)
        VStack(alignment: .leading, spacing: 8) {
            PanelLabel(text: "Agents", trailing: shown.isEmpty ? nil : (shown.count == 1 ? "1 session" : "\(shown.count) sessions"))
            if shown.isEmpty {
                PanelEmpty(symbol: "moon.zzz", text: "No session right now. Mochi is resting.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, s in
                        if i > 0 { Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 50) }
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

    // Today & this week

    private var briefsSection: some View {
        let records = RecapStore.shared.records()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let day = DayWork.from(turns: records.turns, decisions: records.decisions, start: today,
                               end: cal.date(byAdding: .day, value: 1, to: today) ?? Date(), calendar: cal)
        let week = WeekWork.from(turns: records.turns, decisions: records.decisions, weekStart: WeekWork.monday(of: Date()), calendar: cal)
        let water = routineSettings.waterEnabled ? routineSettings.waterLog.total(on: Date()) : nil
        let focus = BuddyDiaryStore.diary.day(Date())?.focusSessions ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            PanelLabel(text: "Today & this week")
            VStack(spacing: 0) {
                PanelBriefRow(symbol: "sun.max.fill", tint: Color(hex: "#F7B32B"), title: "Today",
                              line: [day.isEmpty ? "No agent work yet" : "\(DailyBriefText.duration(minutes: day.minutes)) with agents · \(day.sessions) sessions",
                                     water.map { "\(DailyBriefText.water($0)) water" }, focus > 0 ? "\(focus) focus" : nil]
                                .compactMap { $0 }.joined(separator: " · ")) {
                    close(); DailyBriefController.shared.show()
                }
                Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 50)
                PanelBriefRow(symbol: "calendar", tint: Color(hex: "#818CF8"), title: "This week",
                              line: week.total.isEmpty ? "No agent work yet"
                                : "\(DailyBriefText.duration(minutes: week.total.minutes)) over \(week.activeDays) day\(week.activeDays == 1 ? "" : "s")" + (week.projects.first.map { " · \($0.name)" } ?? "")) {
                    close(); WeeklyBriefController.shared.show(period: .thisWeek)
                }
            }
            .background(PanelCard())
        }
    }

    // Plan: as claude.ai's usage page lists it.

    @ViewBuilder private var planSection: some View {
        if let limits = plan.best {
            VStack(alignment: .leading, spacing: 8) {
                PanelLabel(text: "Claude plan" + (limits.plan.map { " · \($0.capitalized)" } ?? ""),
                           trailing: "updated \(MetricsFormat.ago(limits.updatedAt, now: Date()))")
                VStack(alignment: .leading, spacing: 10) {
                    if let s = limits.session { PanelLimitRow(limit: s, tint: HubTheme.accent) }
                    if !limits.weekly.isEmpty {
                        Text("Weekly limits").font(.system(size: 11, weight: .semibold)).foregroundColor(HubTheme.muted)
                            .padding(.top, 2)
                        ForEach(limits.weekly) { w in
                            PanelLimitRow(limit: w, tint: w.kind == .weeklyAll ? Color(hex: "#3B9EFF") : Color(hex: "#A78BFA"))
                        }
                    }
                }
                .padding(12)
                .background(PanelCard(glow: HubTheme.accent))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                PanelLabel(text: "Claude plan")
                HStack(spacing: 10) {
                    Image(systemName: "staroflife").font(.system(size: 13)).foregroundColor(HubTheme.muted)
                    Text(plan.lastError ?? "Reading your plan from Claude Code…")
                        .font(.system(size: 12)).foregroundColor(HubTheme.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(PanelCard())
            }
        }
    }

    // Mac

    private var macSection: some View {
        let s = sampler.sample
        let tiles = SystemMetricKind.allCases.filter { settings.panelMacTiles.contains($0) }
        return VStack(alignment: .leading, spacing: 8) {
            PanelLabel(text: "This Mac", trailing: Host.current().localizedName)
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

    // Custom Metrics

    @ViewBuilder private var metricsSection: some View {
        if !settings.sources.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                PanelLabel(text: "Custom Metrics")
                ForEach(settings.sources) { source in
                    RunnerMetricsCard(source: source, state: center.states[source.id])
                }
            }
        }
    }
}

/// macOS 26's Liquid Glass, as Control Centre has it; a dark blur before it.
private struct PanelGlass: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.tint(Color.black.opacity(0.18)), in: shape)
                .clipShape(shape)
        } else {
            content
                .background(PanelBlur().clipShape(shape))
                .background(shape.fill(Color(hex: "#0E0F11").opacity(0.55)))
                .overlay(shape.strokeBorder(Color.white.opacity(0.1)))
                .clipShape(shape)
        }
    }
}

private struct PanelBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Pieces

private struct PanelLabel: View {
    let text: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            Text(text.uppercased()).font(.system(size: 10.5, weight: .bold)).tracking(1.2).foregroundColor(HubTheme.secondary)
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 11)).foregroundColor(HubTheme.muted).lineLimit(1) }
        }
    }
}

/// A card on the glass: lighter, not another pane of glass.
private struct PanelCard: View {
    var glow: Color? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.white.opacity(0.07))
            .overlay {
                if let glow {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(RadialGradient(colors: [glow.opacity(0.16), .clear], center: .topLeading, startRadius: 0, endRadius: 240))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
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

/// One limit as claude.ai's usage page shows it: its name and reset, a bar, the share used.
private struct PanelLimitRow: View {
    let limit: ClaudePlanLimits.Limit
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.label).font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text("\(Int(limit.percent.rounded()))% used").font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundColor(limit.percent >= 90 ? HubTheme.red : limit.percent >= 75 ? Color(hex: "#F7B32B") : HubTheme.body)
            }
            RunnerBar(fraction: limit.percent / 100, color: limit.percent >= 90 ? HubTheme.red : tint)
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                Text(ClaudePlanLimits.resetText(limit.resetsAt, now: ctx.date))
                    .font(.system(size: 10.5)).foregroundColor(HubTheme.muted)
            }
        }
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
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.18)))
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
                    .background(Capsule().fill(state.color.opacity(0.14)))
                    if let start = session.turnStartedAt, session.isBusy {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(BuddyTimeText.clock(ctx.date.timeIntervalSince(start)))
                                .font(.system(size: 10.5).monospacedDigit()).foregroundColor(HubTheme.muted)
                        }
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(hover ? Color.white.opacity(0.05) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct PanelBriefRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let line: String
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundColor(tint)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.18)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(line).font(.system(size: 11)).foregroundColor(HubTheme.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundColor(HubTheme.muted)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(hover ? Color.white.opacity(0.05) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
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

// MARK: - Routines: one card, a tab per routine, its quick actions

enum PanelRoutineTab: String, CaseIterable, Identifiable {
    case water, focus, timer, remind, breathe
    var id: String { rawValue }

    var title: String {
        switch self {
        case .water: "Water"
        case .focus: "Focus"
        case .timer: "Timer"
        case .remind: "Remind"
        case .breathe: "Breathe"
        }
    }

    var symbol: String {
        switch self {
        case .water: "drop.fill"
        case .focus: "brain.head.profile"
        case .timer: "timer"
        case .remind: "bell.fill"
        case .breathe: "wind"
        }
    }

    var tint: Color {
        switch self {
        case .water: Color(hex: "#22D3EE")
        case .focus: Color(hex: "#818CF8")
        case .timer: Color(hex: "#F7B32B")
        case .remind: Color(hex: "#F472B6")
        case .breathe: Color(hex: "#34D399")
        }
    }
}

private struct PanelRoutines: View {
    let close: () -> Void
    @ObservedObject private var routines = BuddyRoutineController.shared
    @ObservedObject private var settings = BuddyRoutineSettings.shared
    @AppStorage("menuBarRoutineTab") private var tabRaw = PanelRoutineTab.water.rawValue
    @State private var lastWater: Int?
    @State private var reminderText = ""

    private var tab: PanelRoutineTab { PanelRoutineTab(rawValue: tabRaw) ?? .water }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelLabel(text: "Routines", trailing: running)
            VStack(alignment: .leading, spacing: 12) {
                tabs
                switch tab {
                case .water: water
                case .focus: focus
                case .timer: timer
                case .remind: remind
                case .breathe: breathe
                }
            }
            .padding(12)
            .background(PanelCard(glow: tab.tint))
        }
    }

    /// What runs now, so another tab still says so.
    private var running: String? {
        var parts: [String] = []
        if let f = routines.focus { parts.append("focus \(BuddyTimeText.clock(f.remaining(at: routines.now)))") }
        if let c = routines.countdown { parts.append("timer \(BuddyTimeText.clock(c.remaining(at: routines.now)))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(PanelRoutineTab.allCases) { t in
                let on = t == tab
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { tabRaw = t.rawValue } } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.symbol).font(.system(size: 12, weight: .semibold))
                        Text(t.title).font(.system(size: 9.5, weight: .semibold))
                    }
                    .foregroundColor(on ? t.tint : HubTheme.secondary)
                    .frame(maxWidth: .infinity).frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? t.tint.opacity(0.16) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.18)))
    }

    // Water

    @ViewBuilder private var water: some View {
        let today = settings.waterLog.total(on: Date())
        let goal = max(1, settings.waterPlan.goal)
        let glass = settings.waterPlan.glass
        HStack(spacing: 12) {
            ring(Double(today) / Double(goal), PanelRoutineTab.water)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(DailyBriefText.water(today)) of \(DailyBriefText.water(goal))").font(.system(size: 15, weight: .bold).monospacedDigit())
                Text(waterLine(today: today, goal: goal)).font(.system(size: 11)).foregroundColor(HubTheme.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        HStack(spacing: 6) {
            PanelChip(symbol: "plus", text: BuddyWater.amount(glass), tint: PanelRoutineTab.water.tint) { log(glass) }
            PanelChip(symbol: "plus", text: BuddyWater.amount(glass * 2)) { log(glass * 2) }
            PanelChip(symbol: "plus", text: "1 L") { log(1000) }
            if let last = lastWater {
                PanelChip(symbol: "arrow.uturn.backward", text: "Undo") { routines.logWater(-last); lastWater = nil }
            }
        }
        if !settings.waterEnabled {
            PanelChip(symbol: "bell", text: "Turn on water nudges") { settings.waterEnabled = true }
        }
    }

    private func log(_ ml: Int) {
        routines.logWater(ml)
        lastWater = ml
    }

    private func waterLine(today: Int, goal: Int) -> String {
        if today >= goal { return "Goal reached today" }
        let left = "\(DailyBriefText.water(goal - today)) to go"
        guard settings.waterEnabled, let next = routines.nextWaterNudge else { return left }
        return left + " · next nudge \(next.formatted(.dateTime.hour().minute()))"
    }

    // Focus

    @ViewBuilder private var focus: some View {
        if let f = routines.focus {
            let left = f.remaining(at: routines.now)
            let total = TimeInterval(max(1, f.plan.minutes(f.phase) * 60))
            HStack(spacing: 12) {
                ring(1 - left / total, PanelRoutineTab.focus)
                VStack(alignment: .leading, spacing: 2) {
                    Text(BuddyTimeText.clock(left)).font(.system(size: 20, weight: .bold).monospacedDigit())
                    Text("\(f.phase.label) · round \(f.round)\(f.isPaused ? " · paused" : "")")
                        .font(.system(size: 11)).foregroundColor(HubTheme.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                PanelChip(symbol: f.isPaused ? "play.fill" : "pause.fill", text: f.isPaused ? "Resume" : "Pause", tint: PanelRoutineTab.focus.tint) {
                    f.isPaused ? routines.resumeFocus() : routines.pauseFocus()
                }
                PanelChip(symbol: "forward.fill", text: f.phase.isBreak ? "Focus now" : "Break") { routines.skipFocus() }
                PanelChip(symbol: "stop.fill", text: "End") { routines.endFocus() }
            }
        } else {
            Text("Start a focus session; breaks follow on their own.").font(.system(size: 11.5)).foregroundColor(HubTheme.secondary)
            HStack(spacing: 6) {
                ForEach([15, 25, 45, 50], id: \.self) { m in
                    PanelChip(symbol: "play.fill", text: "\(m) min", tint: m == settings.focusPlan.focus ? PanelRoutineTab.focus.tint : HubTheme.body) {
                        routines.startFocus(minutes: m)
                    }
                }
            }
        }
    }

    // Timer

    @ViewBuilder private var timer: some View {
        if let c = routines.countdown {
            let left = c.remaining(at: routines.now)
            HStack(spacing: 12) {
                ring(1 - left / max(1, c.total), PanelRoutineTab.timer)
                VStack(alignment: .leading, spacing: 2) {
                    Text(BuddyTimeText.clock(left)).font(.system(size: 20, weight: .bold).monospacedDigit())
                    Text((c.label.isEmpty ? "Timer" : c.label) + " · \(BuddyTimeText.duration(c.total))\(c.isPaused ? " · paused" : "")")
                        .font(.system(size: 11)).foregroundColor(HubTheme.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                PanelChip(symbol: c.isPaused ? "play.fill" : "pause.fill", text: c.isPaused ? "Resume" : "Pause", tint: PanelRoutineTab.timer.tint) {
                    c.isPaused ? routines.resumeTimer() : routines.pauseTimer()
                }
                PanelChip(symbol: "plus", text: "1 min") { routines.addToTimer(60) }
                PanelChip(symbol: "plus", text: "5 min") { routines.addToTimer(300) }
                PanelChip(symbol: "xmark", text: "Cancel") { routines.cancelTimer() }
            }
        } else {
            Text("A timer on the Buddy; it tells you when it's done.").font(.system(size: 11.5)).foregroundColor(HubTheme.secondary)
            HStack(spacing: 6) {
                ForEach([1, 5, 10, 15, 30], id: \.self) { m in
                    PanelChip(symbol: "timer", text: "\(m)m", tint: PanelRoutineTab.timer.tint) { _ = routines.startTimer(seconds: TimeInterval(m * 60)) }
                }
            }
        }
    }

    // Reminders

    @ViewBuilder private var remind: some View {
        let upcoming = routines.reminders.sorted { $0.due < $1.due }.prefix(3)
        ForEach(Array(upcoming)) { r in
            HStack(spacing: 8) {
                Image(systemName: "bell.fill").font(.system(size: 10)).foregroundColor(PanelRoutineTab.remind.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.text).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Text(r.due.formatted(Calendar.current.isDateInToday(r.due) ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).hour().minute()))
                        .font(.system(size: 10.5)).foregroundColor(HubTheme.muted)
                }
                Spacer()
                PanelIconChip(symbol: "zzz", help: "Snooze 5 min") { _ = routines.snoozeReminder(r.id) }
                PanelIconChip(symbol: "checkmark", help: "Done") { _ = routines.removeReminder(r.id) }
            }
        }
        if upcoming.isEmpty {
            Text("No reminder yet.").font(.system(size: 11.5)).foregroundColor(HubTheme.secondary)
        }
        HStack(spacing: 6) {
            TextField("Remind me to…", text: $reminderText)
                .textFieldStyle(.plain).font(.system(size: 12.5))
                .padding(.horizontal, 10).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.25)))
        }
        HStack(spacing: 6) {
            ForEach([(15, "15m"), (30, "30m"), (60, "1h"), (120, "2h"), (24 * 60, "Tomorrow")], id: \.0) { m, label in
                PanelChip(symbol: "plus", text: label, tint: PanelRoutineTab.remind.tint) { addReminder(minutes: m) }
                    .disabled(reminderText.trimmingCharacters(in: .whitespaces).isEmpty)
                    .opacity(reminderText.trimmingCharacters(in: .whitespaces).isEmpty ? 0.45 : 1)
            }
        }
    }

    private func addReminder(minutes: Int) {
        let text = reminderText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let due: Date
        if minutes == 24 * 60 {
            // Tomorrow at 9:00.
            let cal = Calendar.current
            due = cal.date(bySettingHour: 9, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()) ?? Date()
        } else {
            due = Date().addingTimeInterval(TimeInterval(minutes * 60))
        }
        if routines.addReminder(text, due: due) != nil { reminderText = "" }
    }

    // Breathing

    @ViewBuilder private var breathe: some View {
        Text(routines.breathing != nil ? "A session is on." : "A minute of calm. Pick a rhythm.")
            .font(.system(size: 11.5)).foregroundColor(HubTheme.secondary)
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            ForEach(BuddyBreathing.allCases, id: \.self) { b in
                Button {
                    close()
                    routines.startBreathing(b)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(b.name).font(.system(size: 12, weight: .semibold))
                        Text(b.hint).font(.system(size: 10)).foregroundColor(HubTheme.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(b == settings.lastBreathing ? PanelRoutineTab.breathe.tint.opacity(0.18) : Color.white.opacity(0.06)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        if routines.breathing != nil {
            PanelChip(symbol: "stop.fill", text: "Stop") { routines.stopBreathing() }
        }
    }

    private func ring(_ progress: Double, _ t: PanelRoutineTab) -> some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 4)
            Circle().trim(from: 0, to: CGFloat(max(0.001, min(1, progress))))
                .stroke(t.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
            Image(systemName: t.symbol).font(.system(size: 13, weight: .semibold)).foregroundColor(t.tint)
        }
        .frame(width: 42, height: 42)
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
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9.5, weight: .bold))
                Text(text).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
            }
            .foregroundColor(tint)
            .padding(.horizontal, 9).frame(height: 26)
            .background(Capsule().fill(Color.white.opacity(hover ? 0.14 : 0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct PanelIconChip: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .bold)).foregroundColor(HubTheme.body)
                .frame(width: 26, height: 26).background(Circle().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
#endif
