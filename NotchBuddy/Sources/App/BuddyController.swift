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

/// AppKit keeps windows below the menu bar (constrainFrameRect): the Buddy may go up there too,
/// like every other edge.
private final class BuddyPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
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

/// The HUD's buttons work on the first click, the Buddy's panels never being key.
private final class BuddyHUDHostingView: NSHostingView<BuddyHUDView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The breathing session's panel: it takes the keyboard when clicked (Esc closes, Space pauses).
private final class BuddyCalmPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { BuddyRoutineController.shared.stopBreathing() }
    }
}

private final class BuddyCalmHostingView: NSHostingView<BuddyCalmView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // The card's background drags the window (isMovableByWindowBackground).
    override var mouseDownCanMoveWindow: Bool { true }
}

private final class BuddyCalmFullHostingView: NSHostingView<BuddyCalmFullView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// What a routine asks of the Buddy.
enum BuddyReaction { case started, alert, done }

/// The speech bubble's drawing: a rounded bubble with a tail pointing at Mochi's head, popping
/// up from the tail (coucou-custom fork; it used to float as a plain label well above him).
private struct BuddyBubbleView: View {
    let text: String
    /// The tail points down (bubble over Mochi) or up (bubble under him, near the top of a screen).
    var tailDown = true
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let tail: CGFloat = 7
    /// Transparent room around the bubble for its shadow and the pop's overshoot.
    static let margin: CGFloat = 6

    var body: some View {
        let shape = BuddyBubbleShape(tail: Self.tail, tailDown: tailDown)
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundColor(Color(hex: "#1D1B22"))
            .lineLimit(3)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 220)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .padding(tailDown ? .bottom : .top, Self.tail)
            .background(shape.fill(Color.white))
            .overlay(shape.stroke(Color.black.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
            .scaleEffect(shown || reduceMotion ? 1 : 0.55, anchor: tailDown ? .bottom : .top)
            .opacity(shown || reduceMotion ? 1 : 0)
            .padding(Self.margin)
            .fixedSize()
            .onAppear { withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) { shown = true } }
    }
}

/// A rounded rectangle with a small rounded tail in the middle of its bottom (or top) edge, one
/// path so the outline runs round the tail too.
private struct BuddyBubbleShape: Shape {
    let tail: CGFloat
    let tailDown: Bool

    func path(in rect: CGRect) -> Path {
        let body = tailDown ? CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - tail)
                            : CGRect(x: rect.minX, y: rect.minY + tail, width: rect.width, height: rect.height - tail)
        let r = min(12, body.height / 2)
        let half: CGFloat = 7
        var p = Path(roundedRect: body, cornerRadius: r, style: .continuous)
        var t = Path()
        if tailDown {
            t.move(to: CGPoint(x: body.midX - half, y: body.maxY - 0.5))
            t.addQuadCurve(to: CGPoint(x: body.midX, y: rect.maxY), control: CGPoint(x: body.midX - 2, y: body.maxY + tail * 0.4))
            t.addQuadCurve(to: CGPoint(x: body.midX + half, y: body.maxY - 0.5), control: CGPoint(x: body.midX + 2, y: body.maxY + tail * 0.4))
        } else {
            t.move(to: CGPoint(x: body.midX - half, y: body.minY + 0.5))
            t.addQuadCurve(to: CGPoint(x: body.midX, y: rect.minY), control: CGPoint(x: body.midX - 2, y: body.minY - tail * 0.4))
            t.addQuadCurve(to: CGPoint(x: body.midX + half, y: body.minY + 0.5), control: CGPoint(x: body.midX + 2, y: body.minY - tail * 0.4))
        }
        t.closeSubpath()
        p.addPath(t)
        return p.normalized()
    }
}

@MainActor
final class BuddyController {
    static let shared = BuddyController()

    private let settings = BuddySettings.shared

    private var panel: NSPanel?
    private var bubble: NSPanel?
    private var bubbleHide: DispatchWorkItem?
    private var hud: NSPanel?
    private let hudLook = BuddyHUDLook()
    /// Its companions are tucked in its pouch while a full-screen view shows.
    private var companionsTucked = false
    private var calm: NSPanel?
    private var calmFull: NSPanel?
    private let routines = BuddyRoutineController.shared
    private var engine: BotEngine?
    private var viewState: BuddyViewState?
    /// The size and companion count the panel was built for: rebuilt only when they change.
    private var shownScale: Double?
    private var shownCompanionCount: Int?
    private var shownCompanionSide: BuddyCompanionSide?
    private var companions: BuddyCompanions?
    /// The companion a click started on, if any.
    private var pressedCompanion: BuddyCompanions.Mini?
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

    /// Clicks: the gesture waiting for more clicks, the bonks of the last 1.7 s (the notch's slap
    /// rule), and until when it is dizzy or dancing.
    private var pendingGesture: DispatchWorkItem?
    private var bonkTimes: [Double] = []
    private var dizzyUntil = Date.distantPast
    private var danceUntil = Date.distantPast

    private var dragStartMouse: NSPoint?
    /// The cursor's last point and time while dragging, its speed (points a second), and the
    /// swing it makes (a damped spring: it sways on, then settles, after it is put down).
    private var lastDrag: (p: NSPoint, t: Double)?
    private var dragVelocity: CGPoint = .zero
    private var swingVelocity: CGFloat = 0
    private var stretchVelocity: CGFloat = 0
    /// When the drag turned back fast: enough of them in a moment is a shake.
    private var shakes: [Double] = []
    /// The square's origin when the drag began.
    private var dragStartSquare: NSPoint = .zero
    private var dragging = false

    private init() {}

    /// Every input event type (kCGAnyInputEventType), for the system's idle time.
    private static let anyInput = CGEventType(rawValue: ~0)!

    /// The notch, for "Open the notch" and "Ask Mochi…" (NSApp.delegate is SwiftUI's adaptor, not
    /// AppDelegate, so it can't be found from there).
    private weak var island: IslandWindowController?

    /// Called once at launch: shows the Buddy if it is on, and follows Settings from then on.
    func start(island: IslandWindowController?) {
        guard !started else { return }
        started = true
        self.island = island
        // objectWillChange fires before the value is set: apply on the next turn of the loop.
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.apply() } }
            .store(in: &cancellables)
        routines.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateHUD(); self?.updateCalm() } }
            .store(in: &cancellables)
        observeScreen()
        apply()
        routines.start()
    }

    /// The notch chat, as its keyboard shortcut opens it (the island takes the keyboard, so it
    /// stays open).
    func openChat() {
        island?.handleHotKey(.openChat)
        // Once the chat is on screen, its text field takes the cursor.
        for delay in [0.05, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NotificationCenter.default.post(name: .buddyFocusChat, object: nil)
            }
        }
    }

    /// A routine started, needs you, or ended.
    func react(_ r: BuddyReaction) {
        guard let engine else { return }
        switch r {
        case .started: engine.triggerEmote(.happy, duration: 1, silent: true)
        case .alert:
            jump()
            engine.triggerEmote(.surprised, duration: 1.4, silent: true)
            companions?.react(to: .question)
        case .done: engine.triggerEmote(.love, duration: 1.4, silent: true)
        }
    }

    /// Breathing with you: its size, 1 for its own.
    func setBreath(_ k: CGFloat) { viewState?.breath = k }

    /// A goal reached: a party and a line.
    func celebrate(_ line: String) {
        perform(BuddyClickBinding(action: .party))
        say(line)
    }

    /// Launch Buddy: a wave and a line.
    func greet(_ line: String) {
        wave()
        say(line)
    }

    /// The Buddy says hi (Settings → Buddy → Say hi, a click): a hop, happy eyes and a blush, a
    /// "Hi!" in its bubble, and its companions wave back. The happy emote alone was too faint to see.
    func wave() {
        guard let engine else { return }
        jump()
        engine.triggerEmote(.happy, duration: 1.4, silent: false)
        say(["Hi!", "Hello!", "Coucou!"].randomElement() ?? "Hi!")
        companions?.greet()
    }

    // MARK: - Show / hide / rebuild

    private var side: CGFloat { BuddySize.side(scale: shownScale ?? settings.sizeScale) }
    private let insets = BuddyInsets.mochi
    /// The companions' roaming room on each side of the window.
    private var strip: CGFloat { companions?.layout.roam ?? 0 }

    private func apply() {
        guard settings.enabled else { hide(); return }
        if panel == nil || shownScale != settings.sizeScale || shownCompanionCount != settings.companions
            || shownCompanionSide != settings.companionSide { show() }
        applyLook()
    }

    /// Its wardrobe (always wear, or the schedule now), colour and shadow, from its own settings
    /// (never the notch's wardrobe).
    private func applyLook(animated: Bool = true) {
        guard let engine else { return }
        let worn = settings.resolvedOutfit()
        engine.setOutfit(worn.engineOutfit ?? .none, animated: animated)
        viewState?.nightcap = worn == .nightcap
        viewState?.shadow = settings.shadowOpacity
        engine.bodyColor = settings.color.isEmpty ? nil : cgColorFromHex(settings.color)
        companions?.recolor { [settings] in settings.companionColor($0) }
    }

    private func show() {
        let firstShow = panel == nil
        let p = panel ?? makePanel()
        let oldFoot = firstShow ? nil : foot(p)

        shownScale = settings.sizeScale
        shownCompanionCount = settings.companions
        shownCompanionSide = settings.companionSide
        let s = side
        let layout = BuddyCompanionLayout(count: settings.companions, side: s, placement: settings.companionSide)
        let size = insets.panelSize(side: s, strip: layout.roam)
        let squareMidX = insets.innerRectTopDown(side: s, strip: layout.roam).midX
        companions = layout.count > 0
            ? BuddyCompanions(layout: layout, stageWidth: size.width, buddyMidX: squareMidX,
                              colors: { [settings] in settings.companionColor($0) })
            : nil
        companions?.setNapping(isSleeping)
        companions?.popped = { [weak self] in self?.engine?.squash() }   // a joey out of the pouch
        // Rebuilt during a full screen (a new count, side or size): the new ones are tucked too.
        if companionsTucked { companions?.pickUp() }
        pressedCompanion = nil
        let vs = BuddyViewState()
        vs.paused = screenOff
        viewState = vs
        let eng = BotEngine()
        shownState = nil
        engine = eng
        applyLook(animated: false)
        updateEngineState()

        let hosting = NSHostingView(rootView: BuddyMochiView(engine: eng, viewState: vs,
                                                             inner: insets.innerRectTopDown(side: s, strip: strip),
                                                             canvas: size, companions: companions))
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
        updateHUD()
    }

    private func hide() {
        stopTimer()
        hideBubble()
        hideHUD()
        centered = false   // its saved spot was never changed: it shows there again
        breathHome = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        engine = nil
        viewState = nil
        companions = nil
        pressedCompanion = nil
        shownScale = nil
        shownCompanionCount = nil
        shownCompanionSide = nil
        shownState = nil
        dragging = false
        dragStartMouse = nil
    }

    private func makePanel() -> NSPanel {
        let p = BuddyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        // Above the menu bar (as OpenPets' native panels): up there it stays visible and grabbable.
        p.level = .statusBar
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
        let o = insets.innerOrigin(side: side, strip: strip)
        return NSRect(x: p.frame.minX + o.x, y: p.frame.minY + o.y, width: side, height: side)
    }

    /// The window origin that puts the square's bottom-left at `squareOrigin`.
    private func panelOrigin(square squareOrigin: CGPoint) -> CGPoint {
        let o = insets.innerOrigin(side: side, strip: strip)
        return CGPoint(x: squareOrigin.x - o.x, y: squareOrigin.y - o.y)
    }

    /// The square's foot (bottom centre) on screen.
    private func foot(_ p: NSPanel) -> CGPoint {
        let r = inner(p)
        return CGPoint(x: r.midX, y: r.minY)
    }

    /// Puts the square's foot at `target`: anywhere its centre stays on the display (up to half off
    /// an edge), else back inside the display's usable area.
    private func place(_ p: NSPanel, foot target: CGPoint, on screen: NSScreen) {
        let origin = BuddyPlacement.origin(foot: target, side: side)
        let square = BuddyPlacement.isOnScreen(origin: origin, side: side, frames: NSScreen.screens.map(\.frame))
            ? BuddyPlacement.clampLoose(origin: origin, side: side, frame: screen.frame)
            : BuddyPlacement.clamp(origin: origin, side: side, visibleFrame: screen.visibleFrame)
        p.setFrameOrigin(panelOrigin(square: square))
    }

    /// The display the square's centre is on, or the nearest.
    private func screenOfSquare(_ p: NSPanel) -> NSScreen? {
        let r = inner(p)
        return screenAt(CGPoint(x: r.midX, y: r.midY))
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
        guard let screen = screenOfSquare(p) else { return }
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
        let screen = screenOfSquare(p) ?? startScreen()
        place(p, foot: BuddyPlacement.defaultFoot(visibleFrame: screen.visibleFrame, side: side), on: screen)
        saveSpot()
        moveBubble()
    }

    /// Displays plugged, unplugged or rearranged: stay on a display, inside its usable area.
    private func reclamp() {
        guard let p = panel else { return }
        let f = foot(p)
        let onScreen = BuddyPlacement.isOnScreen(origin: inner(p).origin, side: side, frames: NSScreen.screens.map(\.frame))
        let screen = onScreen ? (screenOfSquare(p) ?? startScreen()) : startScreen()
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
        stepHop(p)
        stepSwing()
        let mouse = NSEvent.mouseLocation
        let sq = inner(p)
        let local = CGPoint(x: mouse.x - sq.minX, y: mouse.y - sq.minY)   // in the square, y up

        // Click-through everywhere but on Mochi's body and its companions.
        let over = local.x >= 0 && local.y >= 0 && local.x < side && local.y < side
            && DesktopMochiLogic.isOverBody(localPoint: local, panelSize: side)
        let overCompanion = !over && companion(at: mouse, in: p) != nil
        if let companions, let screen = screenOfSquare(p)?.frame {
            let v = (screen.minX - p.frame.minX)...(screen.maxX - p.frame.minX)
            if companions.visible != v { companions.visible = v }
        }
        let wantsMouse = over || overCompanion || dragStartMouse != nil
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
        engine.setDancing(Date.now < danceUntil
            || (musicPlaying && [.idle, .working, .thinking, .searching, .finished].contains(agentState)))

        // Naps only when you are idle (BuddyNap): any keyboard, mouse or trackpad input wakes it.
        let agents = agentState
        if (agents != .idle && agents != .sleeping) || routines.breathing != nil { lastAgentActive = .now }   // no nap mid-breath
        let nap = BuddyNap.shouldNap(enabled: settings.napWhenIdle,
                                     userIdle: CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: Self.anyInput),
                                     agentsQuiet: Date.now.timeIntervalSince(lastAgentActive))
        if nap != isSleeping { isSleeping = nap }
        companions?.setNapping(isSleeping)

        if agents != lastAgentState {
            agentsChanged(to: agents)
            lastAgentState = agents
        }
        updateEngineState()
        if let b = routines.breathing, case .breathing(let pos) = b.phase(at: .now) {
            viewState?.breath = BuddyBreathing.scale(step: pos.step, progress: pos.progress)
        }
        if hud != nil { moveHUD() }
        if calm != nil && !dragging { moveCalm() }
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
        let want: BotState = Date.now < dizzyUntil ? .dizzy : (isSleeping ? .sleeping : agentState)
        guard want != shownState, let engine else { return }
        engine.setState(want, force: shownState == nil)
        shownState = want
    }

    private func agentsChanged(to new: BotState) {
        if new == .finished { engine?.triggerEmote(.happy, duration: 1.2, silent: true) }
        companions?.react(to: new)
        guard settings.speechBubbles, let c = BuddySpeech.category(for: new), speech.shouldSpeak(c, now: .now) else { return }
        speechPick += 1
        say(BuddySpeech.line(c, pick: speechPick))
    }

    // MARK: - Mouse

    /// Each frame: held, it swings away from where it goes and stretches with speed; let go, it
    /// sways back and settles.
    private func stepSwing() {
        guard let vs = viewState else { return }
        if !dragging { dragVelocity = CGPoint(x: dragVelocity.x * 0.7, y: dragVelocity.y * 0.7) }
        // Held still: its speed fades, so the swing settles while still held.
        if dragging, let l = lastDrag, CACurrentMediaTime() - l.t > 0.06 {
            dragVelocity = CGPoint(x: dragVelocity.x * 0.8, y: dragVelocity.y * 0.8)
        }
        let targetSwing = dragging ? max(-0.55, min(0.55, -dragVelocity.x / 2600)) : 0
        let speed = hypot(dragVelocity.x, dragVelocity.y)
        let targetStretch = dragging ? min(0.16, speed / 9000) : 0
        swingVelocity = (swingVelocity + (targetSwing - vs.swing) * 0.16) * 0.84
        stretchVelocity = (stretchVelocity + (targetStretch - vs.stretch) * 0.2) * 0.75
        vs.swing += swingVelocity
        vs.stretch += stretchVelocity
        if !dragging, abs(vs.swing) < 0.002, abs(swingVelocity) < 0.002, abs(vs.stretch) < 0.002 {
            vs.swing = 0
            vs.stretch = 0
        }
    }

    /// The companion under a screen point (AppKit, y up), if any.
    private func companion(at m: NSPoint, in p: NSPanel) -> BuddyCompanions.Mini? {
        guard let companions else { return nil }
        let topDown = CGPoint(x: m.x - p.frame.minX, y: p.frame.maxY - m.y)
        return companions.hit(topDown, square: insets.innerRectTopDown(side: side, strip: strip))
    }

    /// Screen points (AppKit, y up).
    fileprivate func mouseDown(at m: NSPoint) {
        guard let p = panel else { return }
        dragStartMouse = m
        dragStartSquare = inner(p).origin
        dragging = false
        pressedCompanion = companion(at: m, in: p)
    }

    fileprivate func mouseDragged(to m: NSPoint) {
        guard let p = panel, let start = dragStartMouse else { return }
        if !dragging {
            guard hypot(m.x - start.x, m.y - start.y) > 3 else { return }
            dragging = true
            hideBubble()
            leaveFullByDrag()
            engine?.triggerEmote(.surprised, duration: 0.8, silent: true)   // whee
            // Tucked for a full screen, they are in the pouch already.
            if !companionsTucked { companions?.pickUp() }
            setHUDCarried(true)
            shakes = []
            lastDrag = (m, CACurrentMediaTime())
        }
        // Its speed, for the swing.
        let now = CACurrentMediaTime()
        if let l = lastDrag, now > l.t {
            let dt = CGFloat(now - l.t)
            let vx = (m.x - l.p.x) / dt
            // A shake: the way it goes turns back, fast, again and again.
            if abs(vx) > 700, dragVelocity.x != 0, (vx > 0) != (dragVelocity.x > 0) { shakes.append(now) }
            dragVelocity = CGPoint(x: dragVelocity.x * 0.5 + vx * 0.5, y: dragVelocity.y * 0.5 + (m.y - l.p.y) / dt * 0.5)
        }
        lastDrag = (m, now)
        // Up to half off any edge of the display under the cursor (OpenPets lets a roaming pet go
        // anywhere while its anchor is on a display).
        let screen = screenAt(m) ?? startScreen()
        let square = BuddyPlacement.clampLoose(origin: CGPoint(x: dragStartSquare.x + m.x - start.x,
                                                               y: dragStartSquare.y + m.y - start.y),
                                               side: side, frame: screen.frame)
        p.setFrameOrigin(panelOrigin(square: square))
        // With it at once, not a frame behind.
        if hud != nil { moveHUD() }
    }

    fileprivate func mouseUp(clickCount: Int) {
        defer { dragStartMouse = nil; dragging = false; pressedCompanion = nil }
        if dragging {
            reclamp()   // fully off every display: back on one
            saveSpot()
            // Put down: a squash and a smile, its companions land and run in; shaken, all dizzy.
            let now = CACurrentMediaTime()
            let shaken = shakes.filter { now - $0 < 1.5 }.count >= 4
            engine?.squash()
            if shaken { dizzy() } else { engine?.triggerEmote(.happy, duration: 1, silent: true) }
            // A full screen still up keeps them in the pouch.
            if !companionsTucked { companions?.putDown(shaken: shaken) }
            setHUDCarried(false)
            shakes = []
            lastDrag = nil
            return
        }
        guard dragStartMouse != nil else { return }
        // A click on a companion: it blushes.
        if let m = pressedCompanion { companions?.poke(m); return }
        clicked(count: clickCount)
    }

    // MARK: - Clicks and their actions

    /// Every click squashes it at once (the notch Mochi's slap feel); the gesture's action waits
    /// for more clicks only when a longer gesture does something (BuddyClicks.shouldWait).
    private func clicked(count: Int) {
        engine?.squash()
        pendingGesture?.cancel()
        let gesture = BuddyGesture.from(count: count)
        guard BuddyClicks.shouldWait(after: count, bindings: settings.clicks) else {
            perform(settings.binding(gesture))
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingGesture = nil
                self.perform(self.settings.binding(gesture))
            }
        }
        pendingGesture = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    /// Runs a gesture's action (also from Settings' Try buttons).
    func perform(_ b: BuddyClickBinding) {
        guard let engine, b.isRunnable else { return }
        switch b.action {
        case .none: break
        case .hello: wave()
        case .hearts: engine.triggerEmote(.love, duration: 1.8, silent: false)
        case .wink: engine.triggerEmote(.wink, duration: 1.2, silent: false)
        case .surprise: engine.triggerEmote(.surprised, duration: 1.2, silent: false)
        case .jump: jump()
        case .spin: engine.doRoll(duration: 900, turns: 1)
        case .dance: danceUntil = Date.now.addingTimeInterval(5)
        case .bonk: bonk()
        case .dizzy: dizzy()
        case .party:
            jump()
            engine.triggerEmote(.love, duration: 1.8, silent: false)
            companions?.party()
        case .nextOutfit:
            let all = BuddyOutfit.allCases
            let now = settings.resolvedOutfit()
            settings.alwaysWear = all[((all.firstIndex(of: now) ?? 0) + 1) % all.count]
        case .openNotch:
            island?.fsm.openedExternally()
            island?.expand(to: .overview)
        case .openCoucou: FlowHubController.shared.show(.dictation)
        case .openSettings: NotificationCenter.default.post(name: .openFullSettings, object: "buddy")
        case .shortcut: BuddyShortcuts.run(b.parameter)
        case .open: BuddyShortcuts.open(b.parameter)
        case .hide: settings.enabled = false
        }
    }

    /// A little hop: up 0.35 R and back, then a squash.
    private func jump() {
        engine?.anim("oy", keys: [TweenKey(target: -0.35, duration: 190, ease: Ease.out),
                                  TweenKey(target: 0, duration: 260, ease: Ease.inOut)]) { [weak self] in
            self?.engine?.squash()
        }
    }

    /// The notch Mochi's slap, for the Buddy alone: a squash, line eyes, the slap sound; three
    /// within 1.7 s make it dizzy (BotEngine.slap posts .botDizzy, which would make the notch
    /// dizzy too, so it is not called).
    private func bonk() {
        guard let engine, Date.now >= dizzyUntil else { return }
        let now = CACurrentMediaTime()
        bonkTimes = bonkTimes.filter { now - $0 < 1.7 } + [now]
        SoundEngine.shared.play("slap")
        engine.squash()
        if bonkTimes.count >= 3 {
            bonkTimes = []
            dizzy()
        } else {
            engine.eyeOverride = .line
            engine.eyeOverrideUntil = now + 0.8
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { SoundEngine.shared.play("annoyed") }
        }
    }

    /// Dizzy (spiral eyes, two turns) for 3.3 s, then happy again: the notch's timing.
    private func dizzy() {
        dizzyUntil = Date.now.addingTimeInterval(3.3)
        updateEngineState()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.35) { [weak self] in
            MainActor.assumeIsolated {
                self?.updateEngineState()
                self?.engine?.triggerEmote(.happy, silent: true)
            }
        }
    }

    fileprivate func rightMouseDown(_ e: NSEvent, in view: NSView) {
        NSMenu.popUpContextMenu(contextMenu(), with: e, for: view)
    }

    /// OpenPets' pet menu (size…), with the Buddy's own outfit and Coucou's settings.
    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        addRoutineItems(to: menu)
        menu.addItem(.separator())

        let sizeMenu = NSMenu()
        for size in BuddySize.allCases {
            sizeMenu.addItem(BuddyMenuItem(size.label, checked: BuddySize.preset(scale: settings.sizeScale) == size) { [weak self] in
                self?.settings.sizeScale = size.rawValue
            })
        }
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        // OpenPets' outfit menu: Automatic · what the schedule says now, each outfit, Edit Wardrobe…
        let outfitMenu = NSMenu()
        let scheduled = BuddyWardrobe.resolve(always: nil, schedule: settings.schedule, at: .now, calendar: .current)
        outfitMenu.addItem(BuddyMenuItem("Automatic · \(scheduled.name)", checked: settings.alwaysWear == nil) { [weak self] in
            self?.settings.alwaysWear = nil
        })
        outfitMenu.addItem(.separator())
        for outfit in BuddyOutfit.allCases {
            outfitMenu.addItem(BuddyMenuItem(outfit.name, checked: settings.alwaysWear == outfit) { [weak self] in
                self?.settings.alwaysWear = outfit
            })
            if outfit == .nightcap { outfitMenu.addItem(.separator()) }
        }
        outfitMenu.addItem(.separator())
        outfitMenu.addItem(BuddyMenuItem("Edit Wardrobe…") {
            NotificationCenter.default.post(name: .openFullSettings, object: "buddy")
        })
        let outfitItem = NSMenuItem(title: "Outfit", action: nil, keyEquivalent: "")
        outfitItem.submenu = outfitMenu
        menu.addItem(outfitItem)

        let companionMenu = NSMenu()
        companionMenu.autoenablesItems = false
        for n in 0...BuddyCompanionLayout.maxCount {
            companionMenu.addItem(BuddyMenuItem(n == 0 ? "None" : "\(n)", checked: settings.companions == n) { [weak self] in
                self?.settings.companions = n
            })
        }
        companionMenu.addItem(.separator())
        for s in BuddyCompanionSide.allCases {
            let title = s == .both ? "On both sides" : "On the \(s.rawValue)"
            let item = BuddyMenuItem(title, checked: settings.companionSide == s) { [weak self] in
                self?.settings.companionSide = s
            }
            item.isEnabled = settings.companions > 0
            companionMenu.addItem(item)
        }
        let companionItem = NSMenuItem(title: "Companions", action: nil, keyEquivalent: "")
        companionItem.submenu = companionMenu
        menu.addItem(companionItem)

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

    // MARK: - Routines in the menu (OpenPets' plugin menus)

    private func submenu(_ title: String, in menu: NSMenu, _ build: (NSMenu) -> Void) {
        let sub = NSMenu()
        sub.autoenablesItems = false
        build(sub)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = sub
        menu.addItem(item)
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func addRoutineItems(to menu: NSMenu) {
        let r = routines
        menu.addItem(BuddyMenuItem("Ask Mochi…") { [weak self] in self?.openChat() })

        submenu(r.focus.map { "Focus · \(BuddyTimeText.left($0.remaining(at: .now)))" } ?? "Focus", in: menu) { m in
            if let f = r.focus {
                m.addItem(info("\(f.phase.label) · round \(f.round)\(f.isPaused ? " · paused" : "")"))
                m.addItem(BuddyMenuItem(f.isPaused ? "Resume" : "Pause") { f.isPaused ? r.resumeFocus() : r.pauseFocus() })
                m.addItem(BuddyMenuItem(f.phase.isBreak ? "End break, focus now" : "Skip to break") { r.skipFocus() })
                m.addItem(BuddyMenuItem("End focus session") { r.endFocus() })
            } else {
                let plan = r.settings.focusPlan
                m.addItem(BuddyMenuItem("Start focus session (\(plan.focus) min)") { r.startFocus() })
                for mins in [15, 25, 45, 50, 60] where mins != plan.focus {
                    m.addItem(BuddyMenuItem("Focus \(mins) min") { r.startFocus(minutes: mins) })
                }
            }
        }

        submenu(r.countdown.map { "Timer · \(BuddyTimeText.clock($0.remaining(at: .now)))" } ?? "Timer", in: menu) { m in
            if let c = r.countdown {
                m.addItem(BuddyMenuItem(c.isPaused ? "Resume timer" : "Pause timer") { c.isPaused ? r.resumeTimer() : r.pauseTimer() })
                m.addItem(BuddyMenuItem("Add 5 minutes") { r.addToTimer(300) })
                m.addItem(BuddyMenuItem("Cancel timer") { r.cancelTimer() })
            } else {
                for mins in BuddyCountdown.presets {
                    m.addItem(BuddyMenuItem(BuddyTimeText.duration(TimeInterval(mins * 60))) { r.startTimer(seconds: TimeInterval(mins * 60)) })
                }
                m.addItem(.separator())
                m.addItem(BuddyMenuItem("Start timer…") { [weak self] in self?.askTimer() })
            }
        }

        submenu(r.reminders.isEmpty ? "Reminders" : "Reminders · \(r.reminders.count)", in: menu) { m in
            m.addItem(BuddyMenuItem("Set reminder…") { [weak self] in self?.askReminder(minutes: 10) })
            for mins in [5, 15, 30, 60] {
                m.addItem(BuddyMenuItem("Remind me in \(BuddyTimeText.duration(TimeInterval(mins * 60)))…") { [weak self] in
                    self?.askReminder(minutes: mins)
                })
            }
            if !r.reminders.isEmpty {
                m.addItem(.separator())
                for rem in r.reminders.prefix(10) {
                    submenu("\(rem.due.formatted(date: .omitted, time: .shortened)) · \(rem.text)", in: m) { s in
                        s.addItem(BuddyMenuItem("Snooze 5 minutes") { r.snoozeReminder(rem.id) })
                        s.addItem(BuddyMenuItem("Remove") { r.removeReminder(rem.id) })
                    }
                }
                m.addItem(BuddyMenuItem("Clear reminders") { r.clearReminders() })
            }
        }

        submenu("Breathe", in: menu) { m in
            if r.breathing != nil {
                m.addItem(BuddyMenuItem(r.breathingFull ? "Leave full screen" : "Full screen") { r.setBreathingFull(!r.breathingFull) })
                m.addItem(BuddyMenuItem("Stop") { r.stopBreathing() })
            } else {
                for p in BuddyBreathing.allCases {
                    m.addItem(BuddyMenuItem("\(p.name) (\(p.detail))", checked: p == r.settings.lastBreathing) { r.startBreathing(p) })
                }
                m.addItem(.separator())
                m.addItem(BuddyMenuItem("Open full screen", checked: r.settings.breathingFullScreen) {
                    r.settings.breathingFullScreen.toggle()
                })
            }
        }

        let plan = r.settings.waterPlan
        submenu("Water · \(BuddyWater.amount(r.waterToday)) of \(BuddyWater.amount(plan.goal))", in: menu) { m in
            m.addItem(BuddyMenuItem("Log a glass (\(BuddyWater.amount(plan.glass)))") { r.logWater() })
            for ml in BuddyWaterPlan.glasses where ml != plan.glass {
                m.addItem(BuddyMenuItem("Log \(BuddyWater.amount(ml))") { r.logWater(ml) })
            }
            if r.waterToday > 0 {
                m.addItem(BuddyMenuItem("Undo last glass") { r.logWater(-plan.glass) })
            }
            m.addItem(.separator())
            m.addItem(BuddyMenuItem("Reminders every \(plan.every) min", checked: r.settings.waterEnabled) {
                r.settings.waterEnabled.toggle()
            })
            m.addItem(BuddyMenuItem("Water settings…") {
                NotificationCenter.default.post(name: .openFullSettings, object: "buddy")
            })
        }
    }

    /// The Buddy's panels never take the keyboard: a small dialog asks.
    private func ask(_ title: String, fields: [(placeholder: String, value: String)]) -> [String]? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 6
        let inputs = fields.map { f -> NSTextField in
            let t = NSTextField(string: f.value)
            t.placeholderString = f.placeholder
            t.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
            t.widthAnchor.constraint(equalToConstant: 240).isActive = true
            stack.addArrangedSubview(t)
            return t
        }
        stack.frame = NSRect(x: 0, y: 0, width: 240, height: CGFloat(fields.count) * 28)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = inputs.first
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return inputs.map { $0.stringValue }
    }

    private func askReminder(minutes: Int) {
        guard let v = ask("Remind me", fields: [("What?", ""), ("In how many minutes, or at what time (15:30)", "\(minutes)")]),
              !v[0].trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let when = v[1].trimmingCharacters(in: .whitespaces)
        guard let due = BuddyReminders.due(inMinutes: Double(when), at: Double(when) == nil ? when : nil, now: .now) else {
            say("I couldn't read that time")
            return
        }
        routines.addReminder(v[0], due: due)
        say("OK! At \(due.formatted(date: .omitted, time: .shortened))")
    }

    private func askTimer() {
        guard let v = ask("Start timer", fields: [("Minutes", "10"), ("Label (optional)", "")]),
              let mins = Double(v[0].replacingOccurrences(of: ",", with: ".")), mins > 0 else { return }
        routines.startTimer(seconds: mins * 60, label: v[1])
    }

    // MARK: - Speech bubble

    private func say(_ text: String) {
        // Quiet while you breathe.
        guard !text.isEmpty, panel != nil, calm == nil, calmFull == nil else { return }
        let b = bubble ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            p.ignoresMouseEvents = true
            p.isReleasedWhenClosed = false
            return p
        }()
        bubbleText = text
        bubble = b
        layoutBubble(tailDown: bubbleFitsAbove(b))
        b.orderFrontRegardless()
        bubbleHide?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hideBubble() } }
        bubbleHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + BuddySpeech.displayDuration, execute: work)
    }

    private var bubbleText = ""
    private var bubbleTailDown = true

    /// Renders the bubble with its tail up or down and sizes its window to it.
    private func layoutBubble(tailDown: Bool) {
        guard let b = bubble else { return }
        bubbleTailDown = tailDown
        let host = NSHostingView(rootView: BuddyBubbleView(text: bubbleText, tailDown: tailDown))
        let size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)
        b.contentView = host
        b.setContentSize(size)
        moveBubble()
    }

    /// The top of Mochi's head or hat on screen, as measured for what he wears (the square has
    /// room above it for hats and hops, which left the bubble floating far above him).
    private func headTop(_ sq: NSRect) -> CGFloat {
        sq.minY + BuddyHeadroom.top(settings.resolvedOutfit()) * side
    }

    private func bubbleFitsAbove(_ b: NSPanel) -> Bool {
        guard let p = panel else { return true }
        let sq = inner(p)
        let screen = screenAt(CGPoint(x: sq.midX, y: sq.minY))?.visibleFrame ?? sq
        return headTop(sq) + b.frame.height <= screen.maxY
    }

    /// Its tail just over Mochi's head (or over the routine card when that sits over him), centred,
    /// kept on its display; under him when there is no room above.
    private func moveBubble() {
        guard let b = bubble, let p = panel else { return }
        let sq = inner(p)
        let screen = screenAt(CGPoint(x: sq.midX, y: sq.minY))?.visibleFrame ?? sq
        let above = bubbleFitsAbove(b)
        if above != bubbleTailDown { layoutBubble(tailDown: above); return }
        let size = b.frame.size
        let m = BuddyBubbleView.margin
        // The bubble's own transparent margin is outside its tail: subtract it so the tail tip
        // lands 3 pt above the head.
        let head = hud.map { $0.frame.minY >= sq.midY ? $0.frame.maxY - 12 : headTop(sq) } ?? headTop(sq)
        var origin = CGPoint(x: sq.midX - size.width / 2,
                             y: above ? head + 3 - m : sq.minY + 6 - size.height + m)
        origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
        if b.frame.origin != origin { b.setFrameOrigin(origin) }
    }

    private func hideBubble() {
        bubbleHide?.cancel()
        bubbleHide = nil
        bubble?.orderOut(nil)
        bubble = nil
    }

    // MARK: - HUD (routines)

    /// Shown while a routine runs or an alert waits, rebuilt when they change.
    private func updateHUD() {
        guard panel != nil, routines.hasHUD, calmFull == nil, !routines.breathingFull, !externalFullScreen else { hideHUD(); return }
        let h = hud ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = true
            let host = BuddyHUDHostingView(rootView: BuddyHUDView(routines: routines, look: hudLook))
            p.contentView = host
            return p
        }()
        hud = h
        hudLook.resized = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let h = self.hud, let host = h.contentView else { return }
                    let size = host.fittingSize
                    guard h.frame.size != size else { return }
                    h.setContentSize(size)
                    self.moveHUD()
                }
            }
        }
        // objectWillChange fires before the change lands: size on the next turn.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let h = self.hud, let host = h.contentView else { return }
                guard self.routines.hasHUD, self.calmFull == nil else { self.hideHUD(); return }
                let size = host.fittingSize
                if h.frame.size != size { h.setContentSize(size) }
                self.moveHUD()
                if !h.isVisible { h.orderFrontRegardless() }
            }
        }
    }

    /// Picked up or put down: the card comes along, shrinks to its rings, or waits (Settings).
    private func setHUDCarried(_ carried: Bool) {
        let mode = settings.hudWhileDragging
        hudLook.compact = carried && mode == .shrink
        hud?.alphaValue = carried && mode == .hide ? 0 : 1
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let h = self.hud, let host = h.contentView else { return }
                let size = host.fittingSize
                if h.frame.size != size { h.setContentSize(size) }
                self.moveHUD()
            }
        }
    }

    /// Under Mochi's feet, or over its head when there is no room below.
    private func moveHUD() {
        guard let h = hud, let p = panel else { return }
        let size = h.frame.size
        let sq = inner(p)
        let screen = screenAt(CGPoint(x: sq.midX, y: sq.minY))?.visibleFrame ?? sq
        var origin = CGPoint(x: sq.midX - size.width / 2, y: sq.minY - size.height + 4)
        // Over its head: just above the top of its head or hat, as measured for what it wears
        // (the card's own 12 pt of padding is transparent).
        if origin.y < screen.minY {
            origin.y = sq.minY + BuddyHeadroom.top(settings.resolvedOutfit()) * side + settings.hudGap - 12
        }
        origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
        if h.frame.origin != origin { h.setFrameOrigin(origin) }
    }

    private func hideHUD() {
        hud?.orderOut(nil)
        hud = nil
    }

    // MARK: - Breathing: full screen, or the card by the Buddy

    /// Where the Buddy stood before walking to the middle for a full-screen session.
    private var breathHome: CGPoint?
    /// The Buddy stands in the middle of its display for the session.
    private var centered = false
    /// The card was dragged: it stays where it was put.
    private var calmPinned = false
    /// Our own moves of the card, not the user's drags.
    private var movingCalm = false

    private func updateCalm() {
        // objectWillChange fires before the change lands.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.routines.breathing == nil { self.endCalm() }
                else if self.routines.breathingFull { self.showCalmFull() }
                else { self.showCalmCard() }
            }
        }
    }

    private func endCalm() {
        calm?.orderOut(nil)
        calm = nil
        calmPinned = false
        hideCalmFull()
        walkHome()
    }

    // Full screen

    private func showCalmFull() {
        calm?.orderOut(nil)
        calm = nil
        guard calmFull == nil, hop == nil || !centered else { return }
        let screen = panel.flatMap { screenOfSquare($0) } ?? NSScreen.main ?? NSScreen.screens[0]
        hideBubble()
        hideHUD()
        tuckCompanions()
        guard let p = panel, !centered else { return openCalmFull(on: screen) }
        // Mochi cheers, shrinks away, and pops up in the middle; the dim and the guide come with it.
        centered = true
        breathHome = foot(p)
        teleport(p, foot: CGPoint(x: screen.frame.midX, y: screen.frame.midY - side / 2)) { [weak self] in
            guard let self, self.routines.breathingFull, self.routines.breathing != nil else { return }
            self.openCalmFull(on: screen)
        }
    }

    private func openCalmFull(on screen: NSScreen) {
        guard calmFull == nil else { return }
        let f = BuddyCalmPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        f.backgroundColor = .clear
        f.isOpaque = false
        f.hasShadow = false
        // A level under the Buddy's: a click on the dim brings it forward, never over Mochi.
        f.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        f.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        f.isReleasedWhenClosed = false
        f.hidesOnDeactivate = false
        f.animationBehavior = .none
        f.setFrame(screen.frame, display: false)
        let radius = max(110, side * 0.95)
        let center = CGPoint(x: screen.frame.width / 2, y: screen.frame.height / 2)
        f.contentView = BuddyCalmFullHostingView(rootView: BuddyCalmFullView(routines: routines, radius: radius, center: center))
        calmFull = f
        f.orderFrontRegardless()
        // Esc closes, Space pauses — but only take the keyboard when Coucou already has it (the
        // session came from its menu, Settings or chat): never from what you are typing in.
        // Otherwise a click on the dim gives it the keyboard.
        if NSApp.isActive { f.makeKey() }
        panel?.orderFrontRegardless()   // the Buddy over the dim
    }

    private func hideCalmFull() {
        guard let f = calmFull else { return }
        calmFull = nil
        if !externalFullScreen { untuckCompanions() }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            f.animator().alphaValue = 0
        }, completionHandler: { f.orderOut(nil) })
    }

    /// Back where it stood, after a session (unless it was dragged away meanwhile): it shrinks
    /// away in the middle and pops up at home.
    private func walkHome() {
        // Also when the session ended before the full screen opened.
        if !externalFullScreen { untuckCompanions() }
        guard centered else { return }
        centered = false
        if let p = panel, let home = breathHome { teleport(p, foot: home) }
        breathHome = nil
    }

    /// A trip in progress: shrinking where it is, then growing where it goes (tick moves it).
    private var hop: (growing: Bool, start: Double, to: CGPoint, arrive: (() -> Void)?)?
    private static let vanishSeconds = 0.6
    private static let growSeconds = 0.95

    private func teleport(_ p: NSPanel, foot target: CGPoint, arrive: (() -> Void)? = nil) {
        engine?.triggerEmote(.happy, duration: 0.8, silent: true)
        hideBubble()
        hop = (false, CACurrentMediaTime(), panelOrigin(square: BuddyPlacement.origin(foot: target, side: side)), arrive)
    }

    private func stepHop(_ p: NSPanel) {
        guard let h = hop, let vs = viewState else { return }
        let t = CACurrentMediaTime() - h.start
        if !h.growing {
            let k = min(1, t / Self.vanishSeconds)
            // A little swell first (it gathers itself), then down to nothing.
            vs.appear = k < 0.25 ? 1 + 0.12 * CGFloat(sin(k / 0.25 * .pi / 2))
                                 : 1.12 * CGFloat(1 - pow((k - 0.25) / 0.75, 2))
            guard k >= 1 else { return }
            vs.appear = 0
            p.setFrameOrigin(h.to)
            hop = (true, CACurrentMediaTime(), h.to, nil)
            h.arrive?()
        } else {
            let k = min(1, t / Self.growSeconds)
            // Slowly in, then a pop past its size and back: the boom.
            let c1 = 1.9, c3 = c1 + 1
            vs.appear = CGFloat(max(0, 1 + c3 * pow(k - 1, 3) + c1 * pow(k - 1, 2)))
            guard k >= 1 else { return }
            vs.appear = 1
            hop = nil
            engine?.squash()
            engine?.triggerEmote(.love, duration: 1, silent: true)
            if !companionsTucked { companions?.party() }
        }
    }

    /// A full-screen view of Coucou's own (a routine moment, the Daily brief) is up: the Buddy's
    /// companions tuck into its pouch and its card waits, as for full-screen breathing.
    private var externalFullScreen = false

    func setFullScreenShowing(_ on: Bool) {
        guard on != externalFullScreen else { return }
        externalFullScreen = on
        if on {
            tuckCompanions()
            hideBubble()
            hud?.alphaValue = 0
        } else {
            // Breathing full screen may be on its way (it tucks before its 0.6 s walk to the middle).
            if calmFull == nil, !routines.breathingFull { untuckCompanions() }
            hud?.alphaValue = 1
            updateHUD()
        }
    }

    /// No companions in a full-screen view: they hop into its pouch, and out again after.
    private func tuckCompanions() {
        guard !companionsTucked else { return }
        companionsTucked = true
        companions?.pickUp()
    }

    private func untuckCompanions() {
        guard companionsTucked else { return }
        companionsTucked = false
        // Carried: they come out when it is put down (mouseUp).
        if !dragging { companions?.putDown(shaken: false) }
    }

    /// Dragged out of the middle: the session goes on in the card, the Buddy stays where it is put.
    private func leaveFullByDrag() {
        guard routines.breathingFull else { return }
        if let h = hop, !h.growing, let p = panel { p.setFrameOrigin(h.to) }   // caught mid-trip: it is where it went
        hop = nil
        viewState?.appear = 1
        centered = false
        breathHome = nil
        routines.setBreathingFull(false)
    }

    // The card

    private func showCalmCard() {
        hideCalmFull()
        walkHome()
        let c = calm ?? {
            let p = BuddyCalmPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false
            p.isMovableByWindowBackground = true
            p.contentView = BuddyCalmHostingView(rootView: BuddyCalmView(routines: routines) { [weak self] size in
                MainActor.assumeIsolated { self?.resizeCalm(to: size) }
            })
            NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.movingCalm else { return }
                    self.calmPinned = true
                }
            }
            hideBubble()
            return p
        }()
        let first = calm == nil
        calm = c
        if let host = c.contentView {
            let size = host.fittingSize
            if c.frame.size != size { movingCalm = true; c.setContentSize(size); movingCalm = false }
        }
        moveCalm()
        if first { c.orderFrontRegardless() }
    }

    private func resizeCalm(to size: CGSize) {
        guard let c = calm, size.width > 0, size.height > 0, c.frame.size != size else { return }
        let top = c.frame.maxY
        movingCalm = true
        c.setContentSize(size)
        if calmPinned { c.setFrameOrigin(CGPoint(x: c.frame.minX, y: top - size.height)) }   // grows down from where it was put
        movingCalm = false
        moveCalm()
    }

    /// By the Buddy where there is room — over it, under it, to its right or its left — kept on its
    /// display; mid-screen when the Buddy is hidden. Not once it was dragged.
    private func moveCalm() {
        guard let c = calm, !calmPinned else { return }
        let size = c.frame.size
        var origin: CGPoint
        if let p = panel {
            let sq = inner(p)
            let screen = screenAt(CGPoint(x: sq.midX, y: sq.midY))?.visibleFrame ?? sq
            let gap: CGFloat = 8
            let candidates = [
                CGPoint(x: sq.midX - size.width / 2, y: sq.maxY + side * 0.3),                 // over its head
                CGPoint(x: sq.midX - size.width / 2, y: sq.minY - size.height - gap),          // under its feet
                CGPoint(x: sq.maxX + side * 0.1 + gap, y: sq.midY - size.height / 2),          // right
                CGPoint(x: sq.minX - side * 0.1 - gap - size.width, y: sq.midY - size.height / 2), // left
            ]
            origin = candidates.first { screen.contains(CGRect(origin: $0, size: size)) } ?? candidates[0]
            origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
            origin.y = min(max(origin.y, screen.minY), screen.maxY - size.height)
        } else {
            let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            origin = CGPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2)
        }
        guard c.frame.origin != origin else { return }
        movingCalm = true
        c.setFrameOrigin(origin)
        movingCalm = false
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
