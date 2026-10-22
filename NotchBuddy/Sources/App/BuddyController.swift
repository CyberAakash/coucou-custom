#if !APPSTORE
import AppKit
import SwiftUI
import Combine

// coucou-custom fork: the Buddy — a Mochi of its own on the desktop, in its own window, like an
// OpenPets pet. It is not the notch's Mochi (DesktopMochiController moves that one out of the
// notch): it has its own engine, look and settings, and never changes the notch. Settings →
// Buddy, or right-click it.

/// Takes every mouse event inside the panel: the SwiftUI drawing under it never sees them.
private final class BuddyContainerView: NSView {
    weak var controller: BuddyController?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) { controller?.mouseDown(at: NSEvent.mouseLocation) }
    override func mouseDragged(with event: NSEvent) { controller?.mouseDragged(to: NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { controller?.mouseUp(clickCount: event.clickCount) }
    override func rightMouseDown(with event: NSEvent) { controller?.rightMouseDown(event, in: self) }
}

/// A menu item that runs a closure.
private final class BuddyMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, checked: Bool = false, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { run() }
}

/// The speech bubble's drawing.
private struct BuddyBubbleView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.black)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.black.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
            .padding(6)
            .fixedSize()
    }
}

@MainActor
final class BuddyController {
    static let shared = BuddyController()

    private let settings = BuddySettings.shared

    private var panel: NSPanel?
    private var bubble: NSPanel?
    private var bubbleHide: DispatchWorkItem?
    private var engine: BotEngine?
    private var viewState: BuddyViewState?
    /// The size the panel was built for: rebuilt only when it changes.
    private var shownSize: BuddySize?
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var started = false

    private var screenOff = false
    private var isSleeping = false
    private var lastAgentActive = Date.now
    /// The agents' state as last seen, for the speech bubble and the finish emote.
    private var lastAgentState: BotState = .idle
    /// The state the engine was last given.
    private var shownState: BotState?
    /// "Auto" outfits follow the date: checked once a minute.
    private var lastLookCheck = Date.distantPast
    private var speech = BuddySpeech()
    private var speechPick = 0

    private var dragStartMouse: NSPoint?
    /// The square's origin when the drag began.
    private var dragStartSquare: NSPoint = .zero
    private var dragging = false

    private init() {}

    /// Called once at launch: shows the Buddy if it is on, and follows Settings from then on.
    func start() {
        guard !started else { return }
        started = true
        // objectWillChange fires before the value is set: apply on the next turn of the loop.
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.apply() } }
            .store(in: &cancellables)
        observeScreen()
        apply()
    }

    /// The Buddy waves (Settings → Buddy → Say hi).
    func wave() {
        engine?.triggerEmote(.happy, duration: 1.2, silent: false)
    }

    // MARK: - Show / hide / rebuild

    private var side: CGFloat { (shownSize ?? settings.size).side }
    private let insets = BuddyInsets.mochi

    private func apply() {
        guard settings.enabled else { hide(); return }
        if panel == nil || shownSize != settings.size { show() }
        applyLook()
    }

    /// Outfit and colour from the Buddy's own settings (never the notch's wardrobe).
    private func applyLook() {
        guard let engine else { return }
        engine.setOutfit(settings.resolvedOutfit(), animated: true)
        engine.bodyColor = settings.color.isEmpty ? nil : cgColorFromHex(settings.color)
    }

    private func show() {
        let firstShow = panel == nil
        let p = panel ?? makePanel()
        let oldFoot = firstShow ? nil : foot(p)

        shownSize = settings.size
        let s = side
        let size = insets.panelSize(side: s)
        let vs = BuddyViewState()
        vs.paused = screenOff
        viewState = vs
        let eng = BotEngine()
        shownState = nil
        engine = eng
        eng.setOutfit(settings.resolvedOutfit(), animated: false)
        applyLook()
        updateEngineState()

        let hosting = NSHostingView(rootView: BuddyMochiView(engine: eng, viewState: vs,
                                                             inner: insets.innerRectTopDown(side: s), canvas: size))
        let container = BuddyContainerView(frame: CGRect(origin: .zero, size: size))
        container.controller = self
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)

        let screen = oldFoot.flatMap { screenAt($0) } ?? startScreen()
        let target = oldFoot ?? savedFoot(on: screen) ?? BuddyPlacement.defaultFoot(visibleFrame: screen.visibleFrame, side: s)
        p.setFrame(NSRect(origin: p.frame.origin, size: size), display: false)
        place(p, foot: target, on: screen)
        p.contentView = container
        panel = p
        p.orderFrontRegardless()
        if firstShow { eng.triggerEmote(.happy, duration: 0.6, silent: true) }
        startTimer()
    }

    private func hide() {
        stopTimer()
        hideBubble()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        engine = nil
        viewState = nil
        shownSize = nil
        shownState = nil
        dragging = false
        dragStartMouse = nil
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        return p
    }

    // MARK: - Where it stands

    /// Mochi's square on screen (AppKit, y up). Placement, hit testing, the eyes and the bubble
    /// go by the square; the room around it (BuddyInsets) is transparent and never takes clicks.
    private func inner(_ p: NSPanel) -> NSRect {
        let o = insets.innerOrigin(side: side)
        return NSRect(x: p.frame.minX + o.x, y: p.frame.minY + o.y, width: side, height: side)
    }

    /// The window origin that puts the square's bottom-left at `squareOrigin`.
    private func panelOrigin(square squareOrigin: CGPoint) -> CGPoint {
        let o = insets.innerOrigin(side: side)
        return CGPoint(x: squareOrigin.x - o.x, y: squareOrigin.y - o.y)
    }

    /// The square's foot (bottom centre) on screen.
    private func foot(_ p: NSPanel) -> CGPoint {
        let r = inner(p)
        return CGPoint(x: r.midX, y: r.minY)
    }

    /// Puts the square's foot at `target`, kept inside the display's usable area.
    private func place(_ p: NSPanel, foot target: CGPoint, on screen: NSScreen) {
        let square = BuddyPlacement.clamp(origin: BuddyPlacement.origin(foot: target, side: side),
                                          side: side, visibleFrame: screen.visibleFrame)
        p.setFrameOrigin(panelOrigin(square: square))
    }

    private func screenAt(_ point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.screens.min { distance($0.frame, point) < distance($1.frame, point) }
    }

    private func distance(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
    }

    /// The display it last stood on, if still connected; else the main one.
    private func startScreen() -> NSScreen {
        if let first = settings.spots.first,
           let s = NSScreen.screens.first(where: { BuddyPlacement.screenKey($0.frame) == first.screen }) { return s }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    private func savedFoot(on screen: NSScreen) -> CGPoint? {
        guard let spot = BuddyPlacement.spot(for: BuddyPlacement.screenKey(screen.frame), in: settings.spots) else { return nil }
        return CGPoint(x: spot.x, y: spot.y)
    }

    private func saveSpot() {
        guard let p = panel else { return }
        let f = foot(p)
        guard let screen = screenAt(f) else { return }
        settings.spots = BuddyPlacement.remembering(
            BuddySpot(screen: BuddyPlacement.screenKey(screen.frame), x: Double(f.x), y: Double(f.y)),
            in: settings.spots)
    }

    /// Settings → Buddy → Reset position: bottom right of the display it is on.
    func resetPosition() {
        guard let p = panel else {
            settings.spots = []
            return
        }
        let screen = screenAt(foot(p)) ?? startScreen()
        place(p, foot: BuddyPlacement.defaultFoot(visibleFrame: screen.visibleFrame, side: side), on: screen)
        saveSpot()
        moveBubble()
    }

    /// Displays plugged, unplugged or rearranged: stay on a display, inside its usable area.
    private func reclamp() {
        guard let p = panel else { return }
        let f = foot(p)
        let onScreen = NSScreen.screens.contains { $0.frame.contains(f) }
        let screen = onScreen ? (screenAt(f) ?? startScreen()) : startScreen()
        let target = onScreen ? f : (savedFoot(on: screen)
            ?? BuddyPlacement.defaultFoot(visibleFrame: screen.visibleFrame, side: side))
        place(p, foot: target, on: screen)
    }

    // MARK: - Per frame

    private func startTimer() {
        guard timer == nil, !screenOff, panel != nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.005
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let p = panel, let engine else { return }
        let mouse = NSEvent.mouseLocation
        let sq = inner(p)
        let local = CGPoint(x: mouse.x - sq.minX, y: mouse.y - sq.minY)   // in the square, y up

        // Click-through everywhere but on Mochi's body.
        let over = local.x >= 0 && local.y >= 0 && local.x < side && local.y < side
            && DesktopMochiLogic.isOverBody(localPoint: local, panelSize: side)
        let wantsMouse = over || dragStartMouse != nil
        if p.ignoresMouseEvents == wantsMouse { p.ignoresMouseEvents = !wantsMouse }
        let hovering = over && !dragging
        if viewState?.isHovered != hovering { viewState?.isHovered = hovering }

        // Its own eyes: from its own square to the cursor (the notch's Mochi keeps its own).
        if settings.followCursor {
            let eye = DesktopSpace.topDown(CGPoint(x: sq.midX, y: sq.midY), desktopTop: IslandWindowController.desktopTop)
            let m = DesktopSpace.topDown(mouse, desktopTop: IslandWindowController.desktopTop)
            engine.lookX = tanh((m.x - eye.x) / 260)
            engine.lookY = -tanh((m.y - eye.y) / 200)
        } else {
            engine.lookX = 0
            engine.lookY = 0
        }
        engine.moodTarget = MachineVitals.shared.mood
        engine.setDancing(musicPlaying && [.idle, .working, .thinking, .searching, .finished].contains(agentState))

        // Naps after 2 quiet minutes with the cursor away (as the desktop Mochi).
        let agents = agentState
        if agents != .idle && agents != .sleeping { lastAgentActive = .now }
        let nap = settings.napWhenIdle && DesktopMochiLogic.shouldSleep(
            lastAgentActiveInterval: Date.now.timeIntervalSince(lastAgentActive),
            mouseDistanceToPanelCenter: hypot(mouse.x - sq.midX, mouse.y - sq.midY))
        if nap != isSleeping { isSleeping = nap }

        if agents != lastAgentState {
            agentsChanged(to: agents)
            lastAgentState = agents
        }
        updateEngineState()
        if bubble != nil { moveBubble() }
        if Date.now.timeIntervalSince(lastLookCheck) > 60 {
            lastLookCheck = .now
            applyLook()
        }
    }

    /// What the agents do, or idle when the Buddy does not follow them.
    private var agentState: BotState {
        settings.reactToAgents ? AppState.shared.effectiveState : .idle
    }

    private var musicPlaying: Bool {
        let app = AppState.shared
        let music = app.musicPlaying && app.activeIntegrations.contains("integration_music")
        let spotify = SpotifyController.shared.isPlaying && app.activeIntegrations.contains(SpotifyController.pillId)
        return music || spotify
    }

    private func updateEngineState() {
        let want: BotState = isSleeping ? .sleeping : agentState
        guard want != shownState, let engine else { return }
        engine.setState(want, force: shownState == nil)
        shownState = want
    }

    private func agentsChanged(to new: BotState) {
        if new == .finished { engine?.triggerEmote(.happy, duration: 1.2, silent: true) }
        guard settings.speechBubbles, let c = BuddySpeech.category(for: new), speech.shouldSpeak(c, now: .now) else { return }
        speechPick += 1
        say(BuddySpeech.line(c, pick: speechPick))
    }

    // MARK: - Mouse

    /// Screen points (AppKit, y up).
    fileprivate func mouseDown(at m: NSPoint) {
        guard let p = panel else { return }
        dragStartMouse = m
        dragStartSquare = inner(p).origin
        dragging = false
    }

    fileprivate func mouseDragged(to m: NSPoint) {
        guard let p = panel, let start = dragStartMouse else { return }
        if !dragging {
            guard hypot(m.x - start.x, m.y - start.y) > 3 else { return }
            dragging = true
            hideBubble()
        }
        let screen = screenAt(m) ?? startScreen()
        let square = BuddyPlacement.clamp(origin: CGPoint(x: dragStartSquare.x + m.x - start.x,
                                                          y: dragStartSquare.y + m.y - start.y),
                                          side: side, visibleFrame: screen.visibleFrame)
        p.setFrameOrigin(panelOrigin(square: square))
    }

    fileprivate func mouseUp(clickCount: Int) {
        defer { dragStartMouse = nil; dragging = false }
        if dragging {
            saveSpot()
            return
        }
        // A click says hi (no slap: that is the notch Mochi's, and makes the notch dizzy).
        guard dragStartMouse != nil, clickCount == 1 else { return }
        wave()
    }

    fileprivate func rightMouseDown(_ e: NSEvent, in view: NSView) {
        NSMenu.popUpContextMenu(contextMenu(), with: e, for: view)
    }

    /// OpenPets' pet menu (size…), with the Buddy's own outfit and Coucou's settings.
    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let sizeMenu = NSMenu()
        for size in BuddySize.allCases {
            sizeMenu.addItem(BuddyMenuItem(size.label, checked: settings.size == size) { [weak self] in
                self?.settings.size = size
            })
        }
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let outfitMenu = NSMenu()
        for outfit in Outfit.allCases {
            outfitMenu.addItem(BuddyMenuItem(outfit.displayName, checked: settings.outfit == outfit) { [weak self] in
                self?.settings.outfit = outfit
            })
            if outfit == .none { outfitMenu.addItem(.separator()) }
        }
        let outfitItem = NSMenuItem(title: "Outfit", action: nil, keyEquivalent: "")
        outfitItem.submenu = outfitMenu
        menu.addItem(outfitItem)

        menu.addItem(.separator())
        menu.addItem(BuddyMenuItem("React to my agents", checked: settings.reactToAgents) { [weak self] in
            self?.settings.reactToAgents.toggle()
        })
        menu.addItem(BuddyMenuItem("Speech bubbles", checked: settings.speechBubbles) { [weak self] in
            self?.settings.speechBubbles.toggle()
        })
        menu.addItem(.separator())
        menu.addItem(BuddyMenuItem("Buddy Settings…") {
            NotificationCenter.default.post(name: .openFullSettings, object: "buddy")
        })
        menu.addItem(BuddyMenuItem("Hide Buddy") { [weak self] in
            self?.settings.enabled = false
        })
        return menu
    }

    // MARK: - Speech bubble

    private func say(_ text: String) {
        guard !text.isEmpty, panel != nil else { return }
        let b = bubble ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            p.ignoresMouseEvents = true
            p.isReleasedWhenClosed = false
            return p
        }()
        let host = NSHostingView(rootView: BuddyBubbleView(text: text))
        let size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)
        b.contentView = host
        b.setContentSize(size)
        bubble = b
        moveBubble()
        b.orderFrontRegardless()
        bubbleHide?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hideBubble() } }
        bubbleHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + BuddySpeech.displayDuration, execute: work)
    }

    /// Centred over Mochi's head, kept on its display.
    private func moveBubble() {
        guard let b = bubble, let p = panel else { return }
        let size = b.frame.size
        let sq = inner(p)
        let screen = screenAt(CGPoint(x: sq.midX, y: sq.minY))?.visibleFrame ?? sq
        var origin = CGPoint(x: sq.midX - size.width / 2, y: sq.maxY - 6)
        origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
        if origin.y + size.height > screen.maxY { origin.y = sq.minY - size.height }
        if b.frame.origin != origin { b.setFrameOrigin(origin) }
    }

    private func hideBubble() {
        bubbleHide?.cancel()
        bubbleHide = nil
        bubble?.orderOut(nil)
        bubble = nil
    }

    // MARK: - Screen sleep, lock, displays

    private func observeScreen() {
        let ws = NSWorkspace.shared.notificationCenter
        let dc = DistributedNotificationCenter.default()
        for (center, name, off) in [
            (ws as NotificationCenter, NSWorkspace.screensDidSleepNotification, true),
            (ws, NSWorkspace.screensDidWakeNotification, false),
            (dc, NSNotification.Name("com.apple.screenIsLocked"), true),
            (dc, NSNotification.Name("com.apple.screenIsUnlocked"), false),
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setScreenOff(off) }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reclamp() }
        }
    }

    /// Nothing runs while the screen is off or locked.
    private func setScreenOff(_ off: Bool) {
        screenOff = off
        viewState?.paused = off
        if off { stopTimer() } else { startTimer() }
    }
}
#endif
