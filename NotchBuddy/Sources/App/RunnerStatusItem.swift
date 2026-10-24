#if !APPSTORE
import AppKit
import Combine
import QuartzCore
import ScreenCaptureKit
import SwiftUI

// coucou-custom fork: Coucou's one menu-bar item (Settings → Menu bar). Its icon is the one chosen
// there — Coucou's own, Mochi, a RunCat runner or yours — played after RunCat Neo's RunnerLayer:
// one Core Animation keyframe loop whose speed follows the Mac, so the frames play without
// waking Coucou. Its numbers sit beside it; a click opens the panel, a right-click Coucou's menu.

@MainActor
final class RunnerStatusItem: NSObject {
    static let shared = RunnerStatusItem()

    private let settings = RunnerSettings.shared
    private var item: NSStatusItem?
    private var bar: RunnerBarView?
    private var bag: Set<AnyCancellable> = []
    private var appearanceObservation: NSKeyValueObservation?
    /// What the current frames were built from, to rebuild them only when it changes.
    private var framesKey = ""

    func start() {
        #if DEBUG
        installDebugDump()
        #endif
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppDelegate.current?.statusItem?.isVisible = true }
        }
        let s = settings
        // Any setting, the runners on disk: rebuild on the next turn of the run loop.
        Publishers.MergeMany(
            s.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            RunnerLibrary.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            // The Mochi icon in the Buddy's colour follows it.
            BuddySettings.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
        .sink { [weak self] in MainActor.assumeIsolated { self?.apply() } }
        .store(in: &bag)

        RunnerSampler.shared.$sample.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshLive() } }
            .store(in: &bag)
        RunnerMetricsCenter.shared.$states.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshText() } }
            .store(in: &bag)
        AppState.shared.$tasks.map(Self.workingAgents).removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshLive() } }
            .store(in: &bag)
        AppState.shared.$claudePlanUsage.map { _ in () }.receive(on: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.refreshText() } }
            .store(in: &bag)
        ClaudePlanLimitsFetcher.shared.$limits.map { _ in () }.receive(on: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.refreshText() } }
            .store(in: &bag)
        apply()
    }

    /// macOS saves a status item's visibility: Coucou's own item is made visible again on the
    /// way out, so a Coucou without this feature (or with it off) never starts with it hidden.
    private var terminateObserver: NSObjectProtocol?

    static func workingAgents(_ tasks: [AgentTask]) -> Int {
        tasks.filter { !$0.isIntegration && [.working, .thinking, .searching].contains($0.state) }.count
    }

    // MARK: - Showing and hiding

    private func apply() {
        // Coucou's own item shows only when the two are not merged.
        AppDelegate.current?.statusItem?.isVisible = !settings.unified
        guard settings.unified || settings.enabled else {
            tearDown()
            return
        }
        if item == nil { setUp() }
        item?.button?.setAccessibilityLabel(settings.unified ? "Coucou" : "Coucou Runner")
        RunnerMetricsCenter.shared.setRunnerShowing(true)
        let key = "\(settings.runnerID)|\(settings.flipped)|\(settings.mochiStyle)|\(RunnerLibrary.shared.runner(settings.runnerID).map { "\($0.frameOrder)\($0.isTemplate)\($0.frameCount)" } ?? "")"
        if key != framesKey {
            framesKey = key
            let frames = Self.frames(for: settings.runnerID)
            animated = frames.images.count > 1
            bar?.setFrames(frames, flipped: settings.flipped)
        }
        refreshSampling()
        refreshLive()
    }

    private var sampledInterval = 0
    /// The icon has more than one frame: its speed needs the Mac's load.
    private var animated = false

    /// Reads the Mac only when something shows it: a moving icon, numbers in the bar, the panel.
    private func refreshSampling() {
        let needed = item != nil && (animated || !settings.menuBarMetrics.isEmpty || MenuBarPanelController.shared.isShown)
        if needed, !RunnerSampler.shared.running || sampledInterval != settings.interval {
            sampledInterval = settings.interval
            RunnerSampler.shared.start(interval: settings.interval)
        } else if !needed, RunnerSampler.shared.running {
            RunnerSampler.shared.stop()
        }
    }

    private func setUp() {
        let statusItem = NSStatusBar.system.statusItem(withLength: 30)
        statusItem.autosaveName = "CoucouRunner"
        statusItem.isVisible = true
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel("Coucou Runner")
        let view = RunnerBarView(frame: button.bounds)
        view.autoresizingMask = [.width, .height]
        button.addSubview(view)
        bar = view
        item = statusItem
        appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshTint() }
        }
        refreshTint()
    }

    private func tearDown() {
        guard item != nil else { return }
        MenuBarPanelController.shared.close()
        appearanceObservation = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        bar = nil
        framesKey = ""
        RunnerSampler.shared.stop()
        RunnerMetricsCenter.shared.setRunnerShowing(false)
    }

    // MARK: - Live values

    private func refreshLive() {
        refreshSpeed()
        refreshText()
    }

    private func currentLoad() -> Double {
        switch settings.speedSource {
        case .cpu: return RunnerSampler.shared.sample.cpu ?? 0
        case .memory: return RunnerSampler.shared.sample.memoryFraction ?? 0
        case .agents: return RunnerSpeed.agentLoad(working: Self.workingAgents(AppState.shared.tasks))
        }
    }

    private func refreshSpeed() {
        guard let bar else { return }
        bar.setSpeed(Float(RunnerSpeed.speed(load: currentLoad(), slowerUnderLoad: settings.slowerUnderLoad)))
    }

    private func refreshTint() {
        guard let button = item?.button else { return }
        var color = NSColor.labelColor.cgColor
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.cgColor
        }
        bar?.setTint(color)
        refreshText()
    }

    private func refreshText() {
        guard let bar, let item else { return }
        // Beside the icon, the plan is asked again every five minutes.
        if settings.coucouMetrics.contains(.claudePlan) { ClaudePlanLimitsFetcher.shared.refresh(maxAge: 300) }
        let text = Self.menuBarText(settings: settings, sample: RunnerSampler.shared.sample,
                                    states: RunnerMetricsCenter.shared.states)
        let width = bar.setText(text, appearance: item.button?.effectiveAppearance)
        if abs(item.length - width) > 0.5 { item.length = width }
    }

    /// The Mac's chosen numbers, then each file shown in the menu bar (its symbol and value).
    static func menuBarText(settings: RunnerSettings, sample: SystemSample,
                            states: [UUID: MetricsSourceState]) -> [(symbol: String?, text: String)] {
        var parts: [(String?, String)] = []
        for kind in SystemMetricKind.allCases where settings.menuBarMetrics.contains(kind) {
            if let text = sample.menuBarText(kind) { parts.append((nil, text)) }
        }
        if settings.coucouMetrics.contains(.claudePlan), let text = claudePlanText() {
            parts.append(("staroflife", text))
        }
        if settings.coucouMetrics.contains(.agents) {
            parts.append(("terminal", RunnerCoucouMetric.agentsText(working: workingAgents(AppState.shared.tasks))))
        }
        for source in settings.sources where source.showsInMenuBar {
            let state = states[source.id]
            let symbol = state?.snapshot?.symbol ?? source.symbol ?? MetricsSnapshot.defaultSymbol
            let text = (state?.failed ?? true) ? "---" : (state?.snapshot?.menuBarText ?? "---")
            parts.append((symbol, text))
        }
        return parts
    }

    /// "5h 10% · 7d 55%": the current session and the all-models week, as Claude Code reports them.
    static func claudePlanText(now: Date = Date()) -> String? {
        guard let l = ClaudePlanLimitsFetcher.shared.best else { return nil }
        let all = l.weekly.first { $0.kind == .weeklyAll }
        return RunnerCoucouMetric.planText(fiveHour: l.session.map { ($0.percent, $0.resetsAt ?? .distantFuture) },
                                           sevenDay: all.map { ($0.percent, $0.resetsAt ?? .distantFuture) }, now: now)
    }

    // MARK: - Frames

    static func frames(for id: String) -> RunnerFrames { RunnerIconFrames.frames(for: id) }

    // MARK: - Clicks

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            if settings.unified, let menu = AppDelegate.current?.statusItem?.menu {
                // Coucou's own menu, as its item had it.
                MenuBarPanelController.shared.close()
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 5), in: sender)
            } else {
                showMenu()
            }
        } else {
            togglePopover(sender)
        }
    }

    /// One of Coucou's menu actions (AppDelegate's), from the panel.
    static func perform(_ action: String) {
        guard let delegate = AppDelegate.current else { return }
        NSApp.sendAction(NSSelectorFromString(action), to: delegate, from: nil)
    }

    private func togglePopover(_ button: NSStatusBarButton) {
        let panel = MenuBarPanelController.shared
        panel.onClose = { [weak self] in self?.refreshSampling() }
        panel.toggle(from: button)
        refreshSampling()
    }

    private func showMenu() {
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Runner Settings…", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let hide = NSMenuItem(title: "Hide Runner", action: #selector(hideRunner), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        item?.menu = menu
        item?.button?.performClick(nil)
        item?.menu = nil
    }

    @objc private func openSettings() { FlowHubController.shared.show(.runner) }
    @objc private func hideRunner() { settings.enabled = false }

    #if DEBUG
    /// Debug builds: on a distributed notification, writes what the Runner shows to
    /// ~/Library/Caches/NotchBuddy/runner-debug (state.txt, bar.png, dashboard.png). Reads only.
    static let debugNotification = Notification.Name("fr.louisraille.NotchBuddy.debug.runnerDump")

    func installDebugDump() {
        DistributedNotificationCenter.default().addObserver(forName: Self.debugNotification, object: nil, queue: .main) { note in
            let what = note.object as? String ?? ""
            Task { @MainActor in
                switch what {
                case "panel": await RunnerStatusItem.shared.debugPanel()
                case "brief": await RunnerStatusItem.shared.debugBrief()
                case "liveweek":
                    WeeklyBriefController.shared.show(place: .fullScreen)
                    try? await Task.sleep(for: .seconds(3))
                    let shown = FullScreenOverlay.shared.isShowing && FullScreenOverlay.shared.owner == "weekly"
                    FullScreenOverlay.shared.close(owner: "weekly")
                    try? "weeklyShown=\(shown) after=\(FullScreenOverlay.shared.isShowing)".write(
                        to: RunnerStatusItem.shared.debugDir.appendingPathComponent("live.txt"), atomically: true, encoding: .utf8)
                case "live":
                    // The real full-screen brief for three seconds, to check it opens and closes.
                    let brief = await DailyBriefBuilder.build(askCalendar: false)
                    DailyBriefController.shared.showFull(brief, takeKeyboard: false)
                    try? await Task.sleep(for: .seconds(3))
                    let shown = FullScreenOverlay.shared.isShowing
                    FullScreenOverlay.shared.close(owner: "brief")
                    try? "fullScreenShown=\(shown) after=\(FullScreenOverlay.shared.isShowing)".write(
                        to: RunnerStatusItem.shared.debugDir.appendingPathComponent("live.txt"), atomically: true, encoding: .utf8)
                default: RunnerStatusItem.shared.debugDump()
                }
            }
        }
    }

    var debugDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchBuddy/runner-debug", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func debugWrite<V: View>(_ view: V, _ name: String) {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        if let image = renderer.cgImage, let png = RunnerImages.png(image) {
            try? png.write(to: debugDir.appendingPathComponent(name))
        }
    }

    /// Opens the panel for a moment and saves what it draws.
    private func debugPanel() async {
        guard let button = item?.button else { return }
        MenuBarPanelController.shared.show(from: button)
        try? await Task.sleep(for: .seconds(1.5))
        // Liquid Glass is drawn by the window server: only a real capture of the window shows it.
        var why = "no panel window"
        let window = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible && $0.level == .popUpMenu })
        if let window {
            why = "window \(window.windowNumber) found"
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                why += "; \(content.windows.count) shareable windows"
                if content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) == nil { why += "; not among them" }
            } catch { why += "; SCK: \(error.localizedDescription)" }
        }
        try? why.write(to: debugDir.appendingPathComponent("panel.txt"), atomically: true, encoding: .utf8)
        if let window,
           let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
           let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) {
            let config = SCStreamConfiguration()
            config.width = Int(target.frame.width * 2)
            config.height = Int(target.frame.height * 2)
            config.showsCursor = false
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target),
                                                                       configuration: config),
               let png = RunnerImages.png(image) {
                try? png.write(to: debugDir.appendingPathComponent("panel.png"))
            }
        }
        MenuBarPanelController.shared.close()
    }

    /// Renders every card of today's brief, the banner and a moment, off screen.
    private func debugBrief() async {
        let brief = await DailyBriefBuilder.build(askCalendar: false)
        let cards = DailyBriefCard.cards(for: DailyBriefSection.allCases)
        for i in cards.indices {
            let story = BriefStory(count: cards.count, autoAdvance: 0)
            story.index = i
            debugWrite(DailyBriefFullView(brief: brief, cards: cards, story: story, close: {}).padding(30).background(Color(hex: "#202226")), "brief-\(i).png")
        }
        let week = await WeeklyBriefBuilder.build()
        let wcards = WeeklyBriefCard.cards(for: WeeklyBriefSection.allCases)
        for i in wcards.indices {
            let story = BriefStory(count: wcards.count, autoAdvance: 0)
            story.index = i
            debugWrite(WeeklyBriefFullView(brief: week, cards: wcards, story: story, close: {}).padding(30).background(Color(hex: "#202226")), "week-\(i).png")
        }
        BriefNotchModel.shared.daily = brief
        BriefNotchModel.shared.weekly = week
        let h = BriefLayout.cardHeight(nh: AppState.shared.notchHeight)
        for (view, name) in [(IslandView.dailyBrief, "daily"), (.weeklyBrief, "weekly")] {
            debugWrite(BriefNotchStage(state: AppState.shared, view: view, width: BriefLayout.cardWidth, height: h, still: .card).background(Color.black), "notch-\(name).png")
            debugWrite(BriefNotchStage(state: AppState.shared, view: view, width: AppState.shared.notchWidth + BriefLayout.pillWing * 2,
                                       height: AppState.shared.notchHeight, still: .pill).background(Color.black), "notch-\(name)-pill.png")
        }
        let alert = BuddyAlert(kind: .water, title: "Time for some water", detail: "500 ml of 3 L today")
        debugWrite(RoutineMomentView(moment: RoutineMoment(kind: .water, alert: alert), perform: { _ in })
            .frame(width: 900, height: 600).background(Color.black), "moment.png")
        let lines = ["greeting=\(brief.greeting)", "headline=\(brief.headline)", "weather=\(String(describing: brief.weather))",
                     "work=\(String(describing: brief.work))", "water=\(String(describing: brief.water))", "diary=\(String(describing: brief.diary))",
                     "mac buckets=\(brief.mac?.buckets.count ?? -1)", "plan=\(brief.plan != nil)", "events=\(brief.events.count)",
                     "readStreak=\(brief.readStreak) week=\(brief.weekRead)"]
            + BuddyOutfit.allCases.map { "headroom \($0.rawValue)=\(String(format: "%.3f", BuddyHeadroom.top($0)))" }
        debugWrite(BuddyFullScreenCard().frame(width: 760).padding(20).background(Color(hex: "#0E0F11")), "fullscreen-card.png")
        debugWrite(MenuBarPanelView(close: {}, resize: { _ in }).content.frame(width: MenuBarPanelView.width).background(Color(hex: "#1C1D21"))
            .environment(\.colorScheme, .dark), "panel-render.png")
        debugWrite(PanelFooter(close: {}).frame(width: MenuBarPanelView.width).background(Color(hex: "#1C1D21"))
            .environment(\.colorScheme, .dark), "panel-footer.png")
        for kind in RoutineMomentKind.allCases {
            debugWrite(BuddyRoutineCard(moment: RoutineMoment.sample(kind), routines: .shared)
                .padding(20).background(Color(hex: "#3A3F48")), "card-\(kind.rawValue).png")
            RoutineNotchModel.shared.moment = RoutineMoment.sample(kind)
            debugWrite(RoutineNotchCard().frame(width: 640, height: 110).padding(8).background(Color.black), "notch-\(kind.rawValue).png")
        }
        RoutineNotchModel.shared.moment = nil
        debugWrite(HubDailyBriefPage().frame(width: 820, height: 1900).background(Color(hex: "#0E0F11")), "briefs-settings.png")
        debugWrite(BriefShareCard.daily(brief, hidePrivate: true), "share-daily.png")
        debugWrite(BriefTimePanel(minuteOfDay: .constant(8 * 60 + 30), tint: BriefsTab.daily.tint, done: {}).background(Color(hex: "#1C1D21")), "time-picker.png")
        debugWrite(BriefComboList(options: HubDailyBriefPage.triggers(includingManual: true), selection: .constant(DailyBriefTrigger.firstUse),
                                  tint: BriefsTab.daily.tint, custom: nil, customTitle: nil, placeholder: "Search", done: {})
            .background(Color(hex: "#1C1D21")), "combo.png")
        try? lines.joined(separator: "\n").write(to: debugDir.appendingPathComponent("brief.txt"), atomically: true, encoding: .utf8)
    }

    private func debugDump() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchBuddy/runner-debug", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var lines: [String] = []
        lines.append("enabled=\(settings.enabled) item=\(item != nil) length=\(item?.length ?? -1)")
        if let w = item?.button?.window {
            lines.append("window frame=\(w.frame) visible=\(w.isVisible) occluded=\(!w.occlusionState.contains(.visible)) screen=\(w.screen?.localizedName ?? "nil") screenFrame=\(w.screen?.frame ?? .zero)")
        }
        lines.append("itemVisible=\(item?.isVisible ?? false)")
        for s in NSScreen.screens { lines.append("screen \(s.localizedName) frame=\(s.frame) safeTop=\(s.safeAreaInsets.top) auxL=\(s.auxiliaryTopLeftArea ?? .zero) auxR=\(s.auxiliaryTopRightArea ?? .zero)") }
        if let main = AppDelegate.current?.statusItem?.button?.window { lines.append("coucou main item frame=\(main.frame) visible=\(main.isVisible)") }
        lines.append("runner=\(settings.runnerID) source=\(settings.speedSource.rawValue) slower=\(settings.slowerUnderLoad) flipped=\(settings.flipped) interval=\(settings.interval)")
        lines.append("load=\(currentLoad()) speed=\(RunnerSpeed.speed(load: currentLoad(), slowerUnderLoad: settings.slowerUnderLoad)) layerSpeed=\(bar?.debugSpeed ?? -1) frames=\(bar?.debugFrameCount ?? -1) template=\(bar?.debugTemplate ?? false)")
        lines.append("sample=\(RunnerSampler.shared.sample)")
        lines.append("text=\(Self.menuBarText(settings: settings, sample: RunnerSampler.shared.sample, states: RunnerMetricsCenter.shared.states).map { "[\($0.symbol ?? "-")] \($0.text)" })")
        for source in settings.sources {
            let s = RunnerMetricsCenter.shared.states[source.id]
            lines.append("source \(source.displayName): failed=\(s?.failed.description ?? "nil") error=\(s?.error ?? "-") title=\(s?.snapshot?.title ?? "-") bar=\(s?.snapshot?.menuBarText ?? "-")")
        }
        lines.append("library=\(RunnerLibrary.shared.runners.map { "\($0.name)(\($0.frameCount))" })")
        let plan = ClaudePlanLimitsFetcher.shared
        lines.append("planCLI=\(plan.limits.map { l in l.limits.map { "\($0.label) \(Int($0.percent))%" } } ?? []) plan=\(plan.limits?.plan ?? "-") error=\(plan.lastError ?? "-")")
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("state.txt"), atomically: true, encoding: .utf8)

        if let button = item?.button, let layer = button.layer {
            let scale: CGFloat = 4
            let size = button.bounds.size
            if let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                   bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
                // The button is flipped (y down); the bitmap is not.
                ctx.translateBy(x: 0, y: size.height * scale)
                ctx.scaleBy(x: scale, y: -scale)
                layer.render(in: ctx)
                if let image = ctx.makeImage(), let png = RunnerImages.png(image) {
                    try? png.write(to: dir.appendingPathComponent("bar.png"))
                }
            }
        }
        let renderer = ImageRenderer(content: RunnerDashboardView(onSettings: {}).environment(\.colorScheme, .dark))
        renderer.scale = 2
        if let image = renderer.cgImage, let png = RunnerImages.png(image) {
            try? png.write(to: dir.appendingPathComponent("dashboard.png"))
        }
        for (i, frame) in RunnerStatusItem.frames(for: settings.runnerID).images.enumerated() {
            if let png = RunnerImages.png(frame) { try? png.write(to: dir.appendingPathComponent("icon-\(i).png")) }
        }
    }
    #endif
}

// MARK: - The view in the status button

/// The runner layer and the numbers. Clicks go through it to the status button.
final class RunnerBarView: NSView {
    private let holder = CALayer()
    private let anim = CALayer()
    private let label = NSTextField(labelWithString: "")
    private var runnerSize = CGSize(width: 22, height: 18)
    private var isTemplate = true
    private var speed: Float = 1

    private static let pad: CGFloat = 3
    private static let gap: CGFloat = 5

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        holder.masksToBounds = true
        anim.contentsGravity = .resizeAspect
        anim.contentsScale = 2
        layer?.addSublayer(holder)
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byClipping
        label.isHidden = true
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    #if DEBUG
    var debugSpeed: Float { anim.speed }
    var debugFrameCount: Int { (anim.animation(forKey: "running") as? CAKeyframeAnimation)?.values?.count ?? 0 }
    var debugTemplate: Bool { holder.mask != nil }
    #endif

    func setFrames(_ frames: RunnerFrames, flipped: Bool) {
        runnerSize = frames.size == .zero ? CGSize(width: 22, height: 18) : frames.size
        isTemplate = frames.isTemplate
        let keyframes = CAKeyframeAnimation(keyPath: "contents")
        keyframes.values = frames.images
        keyframes.calculationMode = .discrete
        keyframes.duration = Double(max(frames.images.count, 1)) * RunnerSpeed.frameSeconds
        keyframes.repeatCount = .infinity
        keyframes.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        anim.removeAllAnimations()
        anim.removeFromSuperlayer()
        holder.mask = nil
        anim.frame = CGRect(origin: .zero, size: runnerSize)
        anim.contents = frames.images.first
        if isTemplate {
            // The menu bar's colour shows through the frames' alpha.
            holder.mask = anim
        } else {
            holder.backgroundColor = nil
            holder.addSublayer(anim)
        }
        holder.transform = flipped ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
        anim.speed = 1
        anim.timeOffset = 0
        anim.beginTime = 0
        anim.add(keyframes, forKey: "running")
        CATransaction.commit()
        applySpeed()
        layoutContent()
    }

    func setTint(_ color: CGColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        holder.backgroundColor = isTemplate ? color : nil
        tint = color
        CATransaction.commit()
    }

    private var tint: CGColor = NSColor.labelColor.cgColor

    /// Retimes the loop where it is, so a new speed never makes it jump (RunCat's way).
    func setSpeed(_ value: Float) {
        guard abs(value - speed) > 0.01 else { return }
        speed = value
        applySpeed()
    }

    private func applySpeed() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let now = CACurrentMediaTime()
        anim.timeOffset = anim.convertTime(now, from: nil)
        anim.beginTime = now
        anim.speed = speed
        CATransaction.commit()
    }

    /// Lays the numbers out after the runner; returns the item's width.
    func setText(_ parts: [(symbol: String?, text: String)], appearance: NSAppearance?) -> CGFloat {
        if isTemplate { holder.backgroundColor = tint }
        guard !parts.isEmpty else {
            label.isHidden = true
            layoutContent()
            return Self.pad * 2 + runnerSize.width
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let text = NSMutableAttributedString()
        for (i, part) in parts.enumerated() {
            if i > 0 { text.append(NSAttributedString(string: "  ", attributes: [.font: font])) }
            if let symbol = part.symbol,
               let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: MetricsSnapshot.defaultSymbol, accessibilityDescription: nil) {
                var color = NSColor.labelColor
                appearance?.performAsCurrentDrawingAppearance { color = NSColor(cgColor: NSColor.labelColor.cgColor) ?? .labelColor }
                let configured = image.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 11, weight: .medium).applying(.init(paletteColors: [color]))) ?? image
                let attachment = NSTextAttachment()
                attachment.image = configured
                attachment.bounds = CGRect(x: 0, y: -2, width: configured.size.width, height: configured.size.height)
                text.append(NSAttributedString(attachment: attachment))
                text.append(NSAttributedString(string: " ", attributes: [.font: font]))
            }
            text.append(NSAttributedString(string: part.text, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        }
        label.attributedStringValue = text
        label.isHidden = false
        // NSTextField's intrinsic width leaves out part of the symbol attachments; the string's
        // own measure counts them (+ the cell's 2 pt of inset on each side).
        textSize = CGSize(width: ceil(text.size().width) + 4, height: ceil(max(text.size().height, label.intrinsicContentSize.height)))
        layoutContent()
        return Self.pad * 2 + runnerSize.width + Self.gap + textSize.width
    }

    override func layout() {
        super.layout()
        layoutContent()
    }

    private func layoutContent() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        holder.frame = CGRect(x: Self.pad, y: ((bounds.height - runnerSize.height) / 2).rounded(),
                              width: runnerSize.width, height: runnerSize.height)
        anim.frame = CGRect(origin: .zero, size: runnerSize)
        CATransaction.commit()
        label.frame = CGRect(x: Self.pad + runnerSize.width + Self.gap, y: ((bounds.height - textSize.height) / 2).rounded(),
                             width: textSize.width, height: textSize.height)
    }

    private var textSize = CGSize.zero
}

// MARK: - Dashboard

/// The popover under the Runner: the Mac's numbers with their last minutes, then every file.
struct RunnerDashboardView: View {
    let onSettings: () -> Void
    @ObservedObject private var sampler = RunnerSampler.shared
    @ObservedObject private var center = RunnerMetricsCenter.shared
    @ObservedObject private var settings = RunnerSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("This Mac").font(.system(size: 13, weight: .bold))
                Spacer()
                Button(action: onSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(.plain)
                    .foregroundColor(HubTheme.secondary)
                    .help("Runner Settings…")
            }
            let s = sampler.sample
            RunnerGaugeRow(symbol: "cpu", title: "CPU", value: s.cpu.map(MetricsFormat.percent) ?? "—",
                           fraction: s.cpu, history: sampler.cpuHistory.values, color: HubTheme.accent)
            RunnerGaugeRow(symbol: "memorychip", title: "Memory",
                           value: s.memoryUsed.map { "\(MetricsFormat.bytes($0)) of \(MetricsFormat.bytes(s.memoryTotal ?? 0))" } ?? "—",
                           fraction: s.memoryFraction, history: sampler.memoryHistory.values, color: Color(hex: "#A78BFA"))
            RunnerGaugeRow(symbol: "internaldrive", title: "Storage",
                           value: s.storageUsed.map { "\(MetricsFormat.diskBytes($0)) of \(MetricsFormat.diskBytes(s.storageTotal ?? 0))" } ?? "—",
                           fraction: s.storageFraction, history: [], color: Color(hex: "#3B9EFF"))
            if let battery = s.batteryPercent {
                RunnerGaugeRow(symbol: s.batteryOnPower == true ? "battery.100percent.bolt" : "battery.75percent",
                               title: "Battery", value: "\(battery)%" + (s.batteryOnPower == true ? " · on power" : ""),
                               fraction: Double(battery) / 100, history: [], color: HubTheme.green)
            }
            RunnerGaugeRow(symbol: "network", title: "Network",
                           value: s.networkIn.map { "↓ \(MetricsFormat.rate($0))   ↑ \(MetricsFormat.rate(s.networkOut ?? 0))" } ?? "—",
                           fraction: nil, history: [], color: HubTheme.green)

            if let plan = RunnerStatusItem.claudePlanText() {
                RunnerGaugeRow(symbol: "staroflife", title: "Claude plan", value: plan,
                               fraction: AppState.shared.claudePlanUsage.flatMap { ClaudePlanGauge.dominantPct($0) }.map { $0 / 100 },
                               history: [], color: Color(hex: "#E07950"))
            }

            if !settings.sources.isEmpty {
                Divider().overlay(Color.white.opacity(0.08))
                ForEach(settings.sources) { source in
                    RunnerMetricsCard(source: source, state: center.states[source.id])
                }
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(HubTheme.panel)
        .foregroundColor(HubTheme.text)
    }
}

struct RunnerGaugeRow: View {
    let symbol: String
    let title: String
    let value: String
    let fraction: Double?
    let history: [Double]
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.opacity(0.14)))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(value).font(.system(size: 11.5).monospacedDigit()).foregroundColor(HubTheme.secondary)
                }
                if history.count > 1 {
                    RunnerSparkline(values: history, color: color).frame(height: 18)
                } else if let fraction {
                    RunnerBar(fraction: fraction, color: color)
                }
            }
        }
    }
}

struct RunnerBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(color).frame(width: max(3, geo.size.width * max(0, min(1, fraction))))
            }
        }
        .frame(height: 5)
    }
}

/// The last readings, oldest on the left, 0…1 bottom to top.
struct RunnerSparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(values.count - 1)
            var line = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: CGFloat(i) * step, y: size.height * (1 - CGFloat(max(0, min(1, v)))))
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.35), color.opacity(0.02)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(color), lineWidth: 1.4)
        }
    }
}

/// One Custom Metrics file, drawn as RunCat's card: title and symbol, the rows, when it was written.
struct RunnerMetricsCard: View {
    let source: MetricsSourceConfig
    let state: MetricsSourceState?

    var body: some View {
        let snapshot = state?.snapshot
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: snapshot?.symbol ?? source.symbol ?? MetricsSnapshot.defaultSymbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(HubTheme.accent)
                Text(snapshot?.title ?? source.displayName).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
            }
            ForEach(Array((snapshot?.metrics ?? []).enumerated()), id: \.offset) { _, metric in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(metric.title): \(metric.formattedValue)")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundColor(HubTheme.body)
                        .lineLimit(2)
                    if let bar = metric.bar { RunnerBar(fraction: bar, color: HubTheme.accent) }
                }
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                if state?.failed ?? true {
                    Text("Last updated: Failed").font(.system(size: 10.5, weight: .medium)).foregroundColor(HubTheme.red)
                } else if let date = snapshot?.lastUpdatedDate {
                    Text("Last updated: \(MetricsFormat.ago(date, now: context.date))")
                        .font(.system(size: 10.5)).foregroundColor(HubTheme.muted)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(HubTheme.card))
    }
}
#endif
