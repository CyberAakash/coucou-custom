#if !APPSTORE
import AppKit
import Combine
import SwiftUI

// coucou-custom fork: the panel under Coucou's menu-bar item, in Liquid Glass — your agents, today
// and this week, the Claude plan's limits, the Mac as a bento, water, focus and the timer,
// reminders, breathing, your Custom Metrics; the settings at the top right, quick actions (water,
// focus, breathe, ask Mochi) and Quit in a bar that stays at the bottom. Each section can be hidden or moved
// (Settings → Menu bar → Panel). A borderless panel right under the menu bar, like Control Centre's,
// gone on Esc or a click anywhere else.

enum MenuBarPanelSection: String, CaseIterable, Identifiable, Codable {
    case agents, briefs, plan, mac, water, focus, remind, breathe, metrics
    var id: String { rawValue }

    /// The stored order; the earlier single "routines" section became its four.
    static func decode(_ raw: [String]) -> [MenuBarPanelSection] {
        var out: [MenuBarPanelSection] = []
        for r in raw {
            let found: [MenuBarPanelSection] = r == "routines" ? [.water, .focus, .remind, .breathe] : [MenuBarPanelSection(rawValue: r)].compactMap { $0 }
            for f in found where !out.contains(f) { out.append(f) }
        }
        return out
    }

    var title: String {
        switch self {
        case .agents: "Agents"
        case .briefs: "Today & this week"
        case .plan: "Claude plan"
        case .mac: "This Mac"
        case .water: "Water"
        case .focus: "Focus & timer"
        case .remind: "Reminders"
        case .breathe: "Breathe"
        case .metrics: "Custom Metrics"
        }
    }

    var detail: String {
        switch self {
        case .agents: "Each running session: its project, what it does, how long, and when it needs you."
        case .briefs: "Your agents' time today and this week, with water and focus; click one for its brief."
        case .plan: "The current session and each weekly limit, with when they reset."
        case .mac: "CPU and memory with their last minutes, storage, battery, network."
        case .water: "Today's water against your goal, with a glass to log in one click."
        case .focus: "The focus session and the timer side by side, started, paused or ended from here."
        case .remind: "Your next reminders, snoozed or done, and a new one in a few words."
        case .breathe: "A minute of calm in one of the breathing rhythms."
        case .metrics: "The cards of your Custom Metrics files."
        }
    }

    var symbol: String {
        switch self {
        case .agents: "terminal"
        case .briefs: "sun.horizon"
        case .plan: "staroflife"
        case .mac: "laptopcomputer"
        case .water: "drop"
        case .focus: "timer"
        case .remind: "bell"
        case .breathe: "wind"
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
    /// The content's last measured height: the panel opens at it, then follows the content.
    private var lastHeight: CGFloat = 520
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
                                                  resize: { [weak self] h in self?.fit(height: h) }))
        fit(height: lastHeight)
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
        // The window's size is set from the content's measured height (fit), not by the
        // hosting view: letting it size the window ran a layout pass of the whole panel each change.
        h.sizingOptions = []
        p.contentView = h
        host = h
        return p
    }

    /// As tall as its content, up to what the screen has under the menu bar.
    func fit(height content: CGFloat) {
        lastHeight = content
        guard let p = panel, let button = anchor, let window = button.window,
              let screen = window.screen ?? NSScreen.main else { return }
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let maxHeight = min(MenuBarPanelView.maxHeight, screen.visibleFrame.height - 16)
        let height = min(max(120, content.rounded(.up)), maxHeight)
        var x = buttonFrame.midX - MenuBarPanelView.width / 2
        x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - MenuBarPanelView.width - 8)
        let frame = NSRect(x: x, y: screen.visibleFrame.maxY - 6 - height, width: MenuBarPanelView.width, height: height)
        guard abs(p.frame.height - frame.height) >= 1 || abs(p.frame.minX - frame.minX) >= 1 || abs(p.frame.maxY - frame.maxY) >= 1 else { return }
        p.setFrame(frame, display: true)
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
    static let footerHeight: CGFloat = 54

    let close: () -> Void
    /// The panel's whole height as its content measures it, for the window.
    let resize: (CGFloat) -> Void

    // Each section watches only its own data (the routines' clock ticks every second, the Mac
    // is read every few): one watching everything here redrew the whole panel each time.
    @ObservedObject private var settings = RunnerSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                // A preference from inside the ScrollView reached the window as 0: the content's
                // own geometry, read where it is laid out, is its real height.
                content
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                        guard h > 0 else { return }
                        DispatchQueue.main.async { resize(h + Self.footerHeight) }
                    }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: .infinity)
            PanelFooter(close: close)
        }
        .frame(width: Self.width)
        .modifier(PanelGlass())
        .foregroundColor(HubTheme.text)
        .environment(\.colorScheme, .dark)
        .onAppear { if settings.panelSections.contains(.plan) { ClaudePlanLimitsFetcher.shared.refresh() } }
    }

    /// What scrolls (also drawn off screen by the debug hook, which cannot draw a ScrollView).
    var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelHeader(close: close)
            ForEach(settings.panelSections) { section in
                sectionView(section)
            }
        }
        .padding(14)
    }

    @ViewBuilder private func sectionView(_ s: MenuBarPanelSection) -> some View {
        switch s {
        case .agents: PanelAgents(close: close)
        case .briefs: PanelBriefs(close: close)
        case .plan: PanelPlan()
        case .mac: PanelMac()
        case .water: PanelWater()
        case .focus: PanelFocusTimer()
        case .remind: PanelReminders()
        case .breathe: PanelBreathe(close: close)
        case .metrics: PanelMetrics()
        }
    }
}

private struct PanelHeader: View {
    let close: () -> Void
    @ObservedObject private var live = LiveSessions.shared

    var body: some View { header }

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
            PanelGearButton { close(); FlowHubController.shared.show(.runner) }
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

}

private struct PanelAgents: View {
    let close: () -> Void
    @ObservedObject private var live = LiveSessions.shared

    var body: some View { agentsSection }

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

}

/// Today & this week, counted once when the panel opens: it reads the recap's weeks and the
/// diary, too much to redo on every redraw.
private struct PanelBriefs: View {
    let close: () -> Void
    @State private var lines: (today: String, week: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelLabel(text: "Today & this week")
            VStack(spacing: 0) {
                PanelBriefRow(symbol: "sun.max.fill", tint: Color(hex: "#F7B32B"), title: "Today", line: lines?.today ?? " ") {
                    close(); DailyBriefController.shared.show()
                }
                Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 50)
                PanelBriefRow(symbol: "calendar", tint: Color(hex: "#818CF8"), title: "This week", line: lines?.week ?? " ") {
                    close(); WeeklyBriefController.shared.show(period: .thisWeek)
                }
            }
            .background(PanelCard())
        }
        .onAppear { if lines == nil { lines = Self.count() } }
    }

    static func count() -> (today: String, week: String) {
        let records = RecapStore.shared.records()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let day = DayWork.from(turns: records.turns, decisions: records.decisions, start: today,
                               end: cal.date(byAdding: .day, value: 1, to: today) ?? Date(), calendar: cal)
        let week = WeekWork.from(turns: records.turns, decisions: records.decisions, weekStart: WeekWork.monday(of: Date()), calendar: cal)
        let rs = BuddyRoutineSettings.shared
        let water = rs.waterEnabled ? rs.waterLog.total(on: Date()) : nil
        let focus = BuddyDiaryStore.diary.day(Date())?.focusSessions ?? 0
        let todayLine = [day.isEmpty ? "No agent work yet" : "\(DailyBriefText.duration(minutes: day.minutes)) with agents · \(day.sessions) sessions",
                         water.map { "\(DailyBriefText.water($0)) water" }, focus > 0 ? "\(focus) focus" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        let weekLine = week.total.isEmpty ? "No agent work yet"
            : "\(DailyBriefText.duration(minutes: week.total.minutes)) over \(week.activeDays) day\(week.activeDays == 1 ? "" : "s")" + (week.projects.first.map { " · \($0.name)" } ?? "")
        return (todayLine, weekLine)
    }
}

/// The plan as claude.ai's usage page lists it.
private struct PanelPlan: View {
    @ObservedObject private var plan = ClaudePlanLimitsFetcher.shared

    var body: some View { planSection }

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

}

/// The Mac as a bento, whatever the number of tiles.
private struct PanelMac: View {
    @ObservedObject private var settings = RunnerSettings.shared
    @ObservedObject private var sampler = RunnerSampler.shared

    var body: some View { macSection }

    private var macSection: some View {
        let tiles = macTiles
        return VStack(alignment: .leading, spacing: 8) {
            PanelLabel(text: "This Mac", trailing: Host.current().localizedName)
            VStack(spacing: 8) {
                ForEach(Array(PanelBento.rows(tiles.map(\.kind), preferWide: .network).enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(row) { kind in
                            if let t = tiles.first(where: { $0.kind == kind }) {
                                PanelMacTile(tile: t, wide: row.count == 1).frame(maxHeight: .infinity)
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The tiles there is something to show for (no battery on a desktop Mac).
    private var macTiles: [PanelMacTileModel] {
        let s = sampler.sample
        return SystemMetricKind.allCases.filter { settings.panelMacTiles.contains($0) }.compactMap { kind in
            switch kind {
            case .cpu:
                PanelMacTileModel(kind: kind, title: "CPU", value: s.cpu.map(MetricsFormat.percent) ?? "—",
                                  history: sampler.cpuHistory.values, fraction: s.cpu, tint: Color(hex: "#3B9EFF"),
                                  caption: "\(ProcessInfo.processInfo.activeProcessorCount) cores")
            case .memory:
                PanelMacTileModel(kind: kind, title: "Memory", value: s.memoryUsed.map { MetricsFormat.bytes($0) } ?? "—",
                                  history: sampler.memoryHistory.values, fraction: s.memoryFraction, tint: Color(hex: "#A78BFA"),
                                  caption: s.memoryTotal.map { "of \(MetricsFormat.bytes($0))" })
            case .storage:
                PanelMacTileModel(kind: kind, title: "Storage", value: s.storageFraction.map(MetricsFormat.percent) ?? "—",
                                  history: [], fraction: s.storageFraction, tint: Color(hex: "#22D3EE"),
                                  caption: s.storageTotal.map { t in "\(MetricsFormat.diskBytes(t - min(t, s.storageUsed ?? 0))) free" })
            case .battery:
                s.batteryPercent.map { b in
                    PanelMacTileModel(kind: kind, title: "Battery", value: "\(b)%", history: [], fraction: Double(b) / 100,
                                      tint: b < 20 ? HubTheme.red : HubTheme.green,
                                      caption: s.batteryOnPower == true ? "on power" : "on battery")
                }
            case .network:
                PanelMacTileModel(kind: kind, title: "Network", value: s.networkIn.map { "↓ " + MetricsFormat.rate($0) } ?? "—",
                                  history: [], fraction: nil, tint: HubTheme.green,
                                  caption: s.networkOut.map { "↑ " + MetricsFormat.rate($0) })
            }
        }
    }

}

private struct PanelMetrics: View {
    @ObservedObject private var settings = RunnerSettings.shared
    @ObservedObject private var center = RunnerMetricsCenter.shared

    var body: some View { metricsSection }

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

struct PanelMacTileModel {
    let kind: SystemMetricKind
    let title: String
    let value: String
    let history: [Double]
    let fraction: Double?
    let tint: Color
    var caption: String? = nil
}

/// Half a row, or the whole row as a strip when the bento has an odd tile.
private struct PanelMacTile: View {
    let tile: PanelMacTileModel
    let wide: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(tile.title).font(.system(size: 11.5)).foregroundColor(HubTheme.secondary)
                if wide, let caption = tile.caption, tile.kind != .network {
                    Text(caption).font(.system(size: 10.5).monospacedDigit()).foregroundColor(HubTheme.muted).lineLimit(1)
                }
                Spacer()
                Text(tile.value).font(.system(size: 13, weight: .bold).monospacedDigit()).lineLimit(1)
                if wide, tile.kind == .network, let caption = tile.caption {
                    Text(caption).font(.system(size: 13, weight: .bold).monospacedDigit()).foregroundColor(Color(hex: "#3B9EFF")).lineLimit(1)
                }
            }
            if tile.history.count > 1 {
                RunnerSparkline(values: tile.history, color: tile.tint).frame(height: wide ? 24 : 20)
            } else if let fraction = tile.fraction {
                RunnerBar(fraction: fraction, color: tile.tint)
            }
            if !wide, let caption = tile.caption {
                Spacer(minLength: 0)
                Text(caption).font(.system(size: 10.5).monospacedDigit()).foregroundColor(HubTheme.muted).lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: wide ? 0 : 72, alignment: .topLeading)
        .background(PanelCard())
    }
}

// MARK: - Routines: one section each, with their quick actions

enum PanelRoutine {
    case water, focus, timer, remind, breathe

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

private struct PanelRing: View {
    let progress: Double
    let routine: PanelRoutine
    var size: CGFloat = 42

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 4)
            Circle().trim(from: 0, to: CGFloat(max(0.001, min(1, progress))))
                .stroke(routine.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: progress)
            Image(systemName: routine.symbol).font(.system(size: size * 0.31, weight: .semibold)).foregroundColor(routine.tint)
        }
        .frame(width: size, height: size)
    }
}

private struct PanelWater: View {
    @ObservedObject private var routines = BuddyRoutineController.shared
    @ObservedObject private var settings = BuddyRoutineSettings.shared
    @State private var lastWater: Int?

    var body: some View {
        let today = settings.waterLog.total(on: Date())
        let goal = max(1, settings.waterPlan.goal)
        let glass = settings.waterPlan.glass
        VStack(alignment: .leading, spacing: 8) {
            PanelLabel(text: "Water", trailing: nudge)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    PanelRing(progress: Double(today) / Double(goal), routine: .water)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(DailyBriefText.water(today)) of \(DailyBriefText.water(goal))").font(.system(size: 15, weight: .bold).monospacedDigit())
                        Text(today >= goal ? "Goal reached today" : "\(DailyBriefText.water(goal - today)) to go")
                            .font(.system(size: 11)).foregroundColor(HubTheme.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    PanelChip(symbol: "plus", text: BuddyWater.amount(glass), tint: PanelRoutine.water.tint) { log(glass) }
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
            .padding(12)
            .background(PanelCard(glow: PanelRoutine.water.tint))
        }
    }

    private var nudge: String? {
        guard settings.waterEnabled, let next = routines.nextWaterNudge else { return nil }
        return "next nudge \(next.formatted(.dateTime.hour().minute()))"
    }

    private func log(_ ml: Int) {
        routines.logWater(ml)
        lastWater = ml
    }
}

/// The focus session and the timer, two cards side by side.
private struct PanelFocusTimer: View {
    @ObservedObject private var routines = BuddyRoutineController.shared
    @ObservedObject private var settings = BuddyRoutineSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelLabel(text: "Focus & timer")
            HStack(alignment: .top, spacing: 8) {
                focus.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(12).background(PanelCard(glow: PanelRoutine.focus.tint))
                timer.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(12).background(PanelCard(glow: PanelRoutine.timer.tint))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private let grid = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    @ViewBuilder private var focus: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let f = routines.focus {
                let left = f.remaining(at: routines.now)
                let total = TimeInterval(max(1, f.plan.minutes(f.phase) * 60))
                HStack(spacing: 10) {
                    PanelRing(progress: 1 - left / total, routine: .focus, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(BuddyTimeText.clock(left)).font(.system(size: 17, weight: .bold).monospacedDigit())
                        Text("\(f.phase.label) · \(f.round)\(f.isPaused ? " · paused" : "")")
                            .font(.system(size: 10.5)).foregroundColor(HubTheme.secondary).lineLimit(1)
                    }
                }
                HStack(spacing: 6) {
                    PanelIconChip(symbol: f.isPaused ? "play.fill" : "pause.fill", help: f.isPaused ? "Resume" : "Pause", tint: PanelRoutine.focus.tint) {
                        f.isPaused ? routines.resumeFocus() : routines.pauseFocus()
                    }
                    PanelIconChip(symbol: "forward.fill", help: f.phase.isBreak ? "Focus now" : "Break") { routines.skipFocus() }
                    PanelIconChip(symbol: "stop.fill", help: "End") { routines.endFocus() }
                }
            } else {
                title("Focus", .focus, "Breaks follow")
                LazyVGrid(columns: grid, spacing: 6) {
                    ForEach([15, 25, 45, 50], id: \.self) { m in
                        PanelChip(symbol: "play.fill", text: "\(m)m", tint: m == settings.focusPlan.focus ? PanelRoutine.focus.tint : HubTheme.body, fill: true) {
                            routines.startFocus(minutes: m)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var timer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let c = routines.countdown {
                let left = c.remaining(at: routines.now)
                HStack(spacing: 10) {
                    PanelRing(progress: 1 - left / max(1, c.total), routine: .timer, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(BuddyTimeText.clock(left)).font(.system(size: 17, weight: .bold).monospacedDigit())
                        Text((c.label.isEmpty ? "Timer" : c.label) + (c.isPaused ? " · paused" : ""))
                            .font(.system(size: 10.5)).foregroundColor(HubTheme.secondary).lineLimit(1)
                    }
                }
                HStack(spacing: 6) {
                    PanelIconChip(symbol: c.isPaused ? "play.fill" : "pause.fill", help: c.isPaused ? "Resume" : "Pause", tint: PanelRoutine.timer.tint) {
                        c.isPaused ? routines.resumeTimer() : routines.pauseTimer()
                    }
                    PanelIconChip(symbol: "goforward.plus", help: "1 more minute") { routines.addToTimer(60) }
                    PanelIconChip(symbol: "xmark", help: "Cancel") { routines.cancelTimer() }
                }
            } else {
                title("Timer", .timer, "Tells you when done")
                LazyVGrid(columns: grid, spacing: 6) {
                    ForEach([1, 5, 15, 30], id: \.self) { m in
                        PanelChip(symbol: "timer", text: "\(m)m", tint: PanelRoutine.timer.tint, fill: true) {
                            _ = routines.startTimer(seconds: TimeInterval(m * 60))
                        }
                    }
                }
            }
        }
    }

    private func title(_ text: String, _ r: PanelRoutine, _ sub: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: r.symbol).font(.system(size: 11, weight: .semibold)).foregroundColor(r.tint)
                .frame(width: 26, height: 26).background(Circle().fill(r.tint.opacity(0.16)))
            VStack(alignment: .leading, spacing: 0) {
                Text(text).font(.system(size: 13, weight: .semibold))
                Text(sub).font(.system(size: 10.5)).foregroundColor(HubTheme.secondary).lineLimit(1)
            }
        }
    }
}

private struct PanelReminders: View {
    @ObservedObject private var routines = BuddyRoutineController.shared
    @State private var text = ""

    var body: some View {
        let upcoming = routines.reminders.sorted { $0.due < $1.due }.prefix(3)
        let empty = text.trimmingCharacters(in: .whitespaces).isEmpty
        VStack(alignment: .leading, spacing: 8) {
            PanelLabel(text: "Reminders", trailing: routines.reminders.isEmpty ? nil : "\(routines.reminders.count) set")
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(upcoming)) { r in
                    HStack(spacing: 8) {
                        Circle().fill(PanelRoutine.remind.tint).frame(width: 7, height: 7)
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
                TextField(upcoming.isEmpty ? "Remind me to…" : "Another one…", text: $text)
                    .textFieldStyle(.plain).font(.system(size: 12.5))
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.25)))
                    .onSubmit { add(minutes: 30) }
                HStack(spacing: 6) {
                    ForEach([(15, "15m"), (60, "1h"), (120, "2h"), (24 * 60, "Tomorrow")], id: \.0) { m, label in
                        PanelChip(symbol: "plus", text: label, tint: PanelRoutine.remind.tint, fill: true) { add(minutes: m) }
                            .disabled(empty).opacity(empty ? 0.45 : 1)
                    }
                }
            }
            .padding(12)
            .background(PanelCard(glow: PanelRoutine.remind.tint))
        }
    }

    private func add(minutes: Int) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        let due: Date
        if minutes == 24 * 60 {
            // Tomorrow at 9:00.
            let cal = Calendar.current
            due = cal.date(bySettingHour: 9, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()) ?? Date()
        } else {
            due = Date().addingTimeInterval(TimeInterval(minutes * 60))
        }
        if routines.addReminder(t, due: due) != nil { text = "" }
    }
}

private struct PanelBreathe: View {
    let close: () -> Void
    @ObservedObject private var routines = BuddyRoutineController.shared
    @ObservedObject private var settings = BuddyRoutineSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelLabel(text: "Breathe", trailing: routines.breathing != nil ? "on now" : nil)
            VStack(alignment: .leading, spacing: 8) {
                VStack(spacing: 6) {
                    ForEach(Array(PanelBento.rows(BuddyBreathing.allCases).enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 6) {
                            ForEach(row, id: \.self) { b in rhythm(b) }
                        }
                    }
                }
                if routines.breathing != nil {
                    PanelChip(symbol: "stop.fill", text: "Stop") { routines.stopBreathing() }
                }
            }
            .padding(10)
            .background(PanelCard(glow: PanelRoutine.breathe.tint))
        }
    }

    private func rhythm(_ b: BuddyBreathing) -> some View {
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
                .fill(b == settings.lastBreathing ? PanelRoutine.breathe.tint.opacity(0.18) : Color.white.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - The bottom bar and the settings button

/// Always there under the scroll: quick actions — a glass of water, focus, a breath, Mochi's
/// chat — and Quit. The briefs open from Today & this week.
struct PanelFooter: View {
    let close: () -> Void
    @ObservedObject private var routines = BuddyRoutineController.shared
    @ObservedObject private var settings = BuddyRoutineSettings.shared
    @State private var logged = false

    var body: some View {
        let glass = settings.waterPlan.glass
        HStack(spacing: 6) {
            PanelQuickAction(symbol: logged ? "checkmark" : "drop.fill",
                             title: logged ? "Logged" : "+\(BuddyWater.amount(glass))", tint: PanelRoutine.water.tint) {
                routines.logWater(glass)
                withAnimation(BriefLayout.pop) { logged = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation(.easeOut(duration: 0.2)) { logged = false } }
            }
            .help("Log a glass of water")
            focusAction
            PanelQuickAction(symbol: "wind", title: "Breathe", tint: PanelRoutine.breathe.tint) {
                close()
                routines.startBreathing(settings.lastBreathing)
            }
            .help("A minute of calm: \(settings.lastBreathing.name)")
            PanelQuickAction(symbol: "bubble.left.and.text.bubble.right.fill", title: "Ask Mochi", tint: HubTheme.accent) {
                close()
                BuddyController.shared.openChat()
            }
            .help("Mochi's chat in the notch")
            PanelQuitButton { close(); RunnerStatusItem.perform("quitCompletely") }
        }
        .padding(.horizontal, 12)
        .frame(height: MenuBarPanelView.footerHeight)
        .background(Color.black.opacity(0.14))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
    }

    @ViewBuilder private var focusAction: some View {
        if let f = routines.focus {
            PanelQuickAction(symbol: f.isPaused ? "play.fill" : "pause.fill", title: f.isPaused ? "Resume" : "Pause",
                             tint: PanelRoutine.focus.tint) {
                f.isPaused ? routines.resumeFocus() : routines.pauseFocus()
            }
            .help("The focus session")
        } else {
            PanelQuickAction(symbol: "brain.head.profile", title: "Focus \(settings.focusPlan.focus)m", tint: PanelRoutine.focus.tint) {
                routines.startFocus(minutes: settings.focusPlan.focus)
            }
            .help("Start a focus session")
        }
    }
}

/// One quick action: its icon over a word, lit in its colour on hover.
private struct PanelQuickAction: View {
    let symbol: String
    let title: String
    let tint: Color
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundColor(tint)
                    .scaleEffect(hover ? 1.12 : 1)
                    .contentTransition(.symbolEffect(.replace))
                Text(title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundColor(HubTheme.text)
            .frame(maxWidth: .infinity).frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(hover ? 0.24 : 0.12), Color.white.opacity(hover ? 0.08 : 0.04)],
                                         startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(tint.opacity(hover ? 0.4 : 0.14)))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(PanelPressStyle())
        .onHover { h in withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) { hover = h } }
    }
}

private struct PanelQuitButton: View {
    let quit: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: quit) {
            Image(systemName: "power").font(.system(size: 12, weight: .bold))
                .foregroundColor(hover ? HubTheme.red : HubTheme.body)
                .frame(width: 34, height: 38)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(hover ? HubTheme.red.opacity(0.16) : Color.white.opacity(0.06)))
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(PanelPressStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .help("Quit Coucou")
    }
}

private struct PanelGearButton: View {
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            Image(systemName: "gearshape.fill").font(.system(size: 13, weight: .semibold))
                .foregroundColor(HubTheme.body)
                .rotationEffect(.degrees(hover ? 60 : 0))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(hover ? 0.14 : 0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(PanelPressStyle())
        .onHover { h in withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { hover = h } }
        .help("Menu bar settings")
    }
}

/// A small give under the finger.
private struct PanelPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

private struct PanelChip: View {
    let symbol: String
    let text: String
    var tint: Color = HubTheme.body
    var fill = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9.5, weight: .bold))
                Text(text).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
            }
            .foregroundColor(tint)
            .padding(.horizontal, 9).frame(maxWidth: fill ? .infinity : nil).frame(height: 26)
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
    var tint: Color = HubTheme.body
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .bold)).foregroundColor(tint)
                .frame(width: 26, height: 26).background(Circle().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
#endif
