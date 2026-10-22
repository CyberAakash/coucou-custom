#if !APPSTORE
import AppKit
import SwiftUI
import Combine

// coucou-custom fork: the Buddy — a desktop pet in its own window, like OpenPets. It is not the
// notch's Mochi (DesktopMochiController moves that one out of the notch): the notch keeps its
// Mochi, and the Buddy stays on the desktop whatever the notch shows. Mochi (drawn by BotEngine)
// by default, or an OpenPets / Codex pet. Settings → Buddy, or right-click the Buddy.

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
    private let store = BuddyPetStore.shared

    private var panel: NSPanel?
    private var bubble: NSPanel?
    private var bubbleHide: DispatchWorkItem?
    private var engine: BotEngine?
    private var viewState: DesktopBotViewState?
    private var pet: BuddyLoadedPet?
    /// What the panel shows now ("petId|size"): rebuilt only when it changes.
    private var contentKey: String?
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var started = false

    private var screenOff = false
    private var isSleeping = false
    private var lastAgentActive = Date.now
    private var lastState: BotState = .idle
    private var speech = BuddySpeech()
    private var speechPick = 0

    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint = .zero
    private var dragging = false
    private var lastDragX: CGFloat = 0
    private var lastMouse: NSPoint = .zero
    private var lastMouseMove: Date?

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
        store.$pets
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.apply(force: true) } }
            .store(in: &cancellables)
        observeScreen()
        apply()
    }

    // MARK: - Show / hide / rebuild

    /// The pet chosen in Settings, or Mochi when it is gone.
    private var resolvedPetId: String {
        settings.isMochi || store.pet(id: settings.petId) == nil ? BuddySettings.mochiId : settings.petId
    }

    private var side: CGFloat { settings.size.panelSide(isMochi: pet == nil) }

    private func apply(force: Bool = false) {
        guard settings.enabled else { hide(); return }
        let key = "\(resolvedPetId)|\(settings.size.rawValue)"
        if panel == nil || key != contentKey || force { show(key: key) }
    }

    private func show(key: String) {
        let firstShow = panel == nil
        let p = panel ?? makePanel()
        let oldFoot = firstShow ? nil : BuddyPlacement.foot(origin: p.frame.origin, side: p.frame.width)

        let hosting = makeContent()   // sets pet, which decides the side
        let s = side
        let container = BuddyContainerView(frame: CGRect(x: 0, y: 0, width: s, height: s))
        container.controller = self
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)

        let screen = oldFoot.flatMap { screenAt($0) } ?? startScreen()
        let foot = oldFoot ?? savedFoot(on: screen) ?? BuddyPlacement.defaultFoot(visibleFrame: screen.visibleFrame, side: s)
        let origin = BuddyPlacement.clamp(origin: BuddyPlacement.origin(foot: foot, side: s), side: s,
                                          visibleFrame: screen.visibleFrame)
        p.setFrame(NSRect(origin: origin, size: CGSize(width: s, height: s)), display: false)
        p.contentView = container
        viewState?.lookOrigin = lookOrigin(p)
        panel = p
        contentKey = key
        p.orderFrontRegardless()
        if firstShow { engine?.triggerEmote(.happy, duration: 0.6, silent: true) }
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
        pet = nil
        contentKey = nil
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

    /// Mochi (its own BotEngine, not the notch's) or the pet's sprite.
    private func makeContent() -> NSView {
        let vs = DesktopBotViewState()
        vs.paused = screenOff
        vs.isSleeping = isSleeping
        viewState = vs
        pet = nil
        engine = nil
        if resolvedPetId != BuddySettings.mochiId, let loaded = BuddyLoadedPet.load(id: resolvedPetId) {
            pet = loaded
            syncPetOptions(loaded)
            return NSHostingView(rootView: BuddyPetView(pet: loaded, viewState: vs))
        }
        let eng = BotEngine()
        eng.setState(isSleeping ? .sleeping : AppState.shared.effectiveState, force: true)
        eng.setOutfit(AppState.shared.resolvedOutfit, animated: false)
        engine = eng
        return NSHostingView(rootView: DesktopBotView(appState: AppState.shared, engine: eng, viewState: vs))
    }

    // MARK: - Where it stands

    private func screenAt(_ point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.screens.min { distance($0.frame, point) < distance($1.frame, point) }
    }

    private func distance(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
    }

    /// The display it last stood on, if still connected; else the main one.
    private func startScreen() -> NSScreen {
        let spots = settings.spots
        if let first = spots.first,
           let s = NSScreen.screens.first(where: { BuddyPlacement.screenKey($0.frame) == first.screen }) { return s }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    private func savedFoot(on screen: NSScreen) -> CGPoint? {
        guard let spot = BuddyPlacement.spot(for: BuddyPlacement.screenKey(screen.frame), in: settings.spots) else { return nil }
        return CGPoint(x: spot.x, y: spot.y)
    }

    private func saveSpot() {
        guard let p = panel else { return }
        let foot = BuddyPlacement.foot(origin: p.frame.origin, side: p.frame.width)
        guard let screen = screenAt(foot) else { return }
        settings.spots = BuddyPlacement.remembering(
            BuddySpot(screen: BuddyPlacement.screenKey(screen.frame), x: Double(foot.x), y: Double(foot.y)),
            in: settings.spots)
    }

    /// Settings → Buddy → Reset position: bottom right of the display it is on.
    func resetPosition() {
        guard let p = panel else {
            settings.spots = []
            return
        }
        let s = p.frame.width
        let screen = screenAt(BuddyPlacement.foot(origin: p.frame.origin, side: s)) ?? startScreen()
        let foot = BuddyPlacement.defaultFoot(visibleFrame: screen.visibleFrame, side: s)
        p.setFrameOrigin(BuddyPlacement.origin(foot: foot, side: s))
        saveSpot()
        moveBubble()
    }

    /// Displays plugged, unplugged or rearranged: stay on a display, inside its usable area.
    private func reclamp() {
        guard let p = panel else { return }
        let s = p.frame.width
        let foot = BuddyPlacement.foot(origin: p.frame.origin, side: s)
        let onScreen = NSScreen.screens.contains { $0.frame.contains(foot) }
        let screen = onScreen ? (screenAt(foot) ?? startScreen()) : startScreen()
        let target = onScreen ? foot : (savedFoot(on: screen)
            ?? BuddyPlacement.defaultFoot(visibleFrame: screen.visibleFrame, side: s))
        p.setFrameOrigin(BuddyPlacement.clamp(origin: BuddyPlacement.origin(foot: target, side: s), side: s,
                                              visibleFrame: screen.visibleFrame))
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
        guard let p = panel else { return }
        let mouse = NSEvent.mouseLocation
        let pf = p.frame
        let s = pf.width
        let local = CGPoint(x: mouse.x - pf.minX, y: mouse.y - pf.minY)

        // Click-through everywhere but on what is drawn.
        let over = isOverPet(local: local, side: s)
        let wantsMouse = over || dragStartMouse != nil
        if p.ignoresMouseEvents == wantsMouse { p.ignoresMouseEvents = !wantsMouse }
        let hovering = over && !dragging
        if viewState?.isHovered != hovering { viewState?.isHovered = hovering }

        // Mochi's eyes follow the cursor (same space as the notch's Mochi).
        viewState?.lookOrigin = lookOrigin(p)
        if engine != nil {
            let pos = DesktopSpace.topDown(mouse, desktopTop: IslandWindowController.desktopTop)
            let cur = AppState.shared.mousePosition
            if abs(pos.x - cur.x) > 1 || abs(pos.y - cur.y) > 1 { AppState.shared.mousePosition = pos }
        }

        // Asleep after 2 idle minutes with the cursor away (as the desktop Mochi).
        let effective = AppState.shared.effectiveState
        if effective != .idle && effective != .sleeping { lastAgentActive = .now }
        let shouldSleep = DesktopMochiLogic.shouldSleep(
            lastAgentActiveInterval: Date.now.timeIntervalSince(lastAgentActive),
            mouseDistanceToPanelCenter: hypot(mouse.x - pf.midX, mouse.y - pf.midY))
        if shouldSleep != isSleeping {
            isSleeping = shouldSleep
            viewState?.isSleeping = shouldSleep
            engine?.setState(shouldSleep ? .sleeping : effective)
        }

        if effective != lastState {
            stateChanged(from: lastState, to: effective)
            lastState = effective
        }
        if let pet { updatePet(pet, mouse: mouse, frame: pf, side: s) }
        if bubble != nil { moveBubble() }
    }

    private func stateChanged(from old: BotState, to new: BotState) {
        if new == .finished { engine?.triggerEmote(.happy, duration: 1.2, silent: true) }
        guard settings.speechBubbles, let c = BuddySpeech.category(for: new), speech.shouldSpeak(c, now: .now) else { return }
        speechPick += 1
        say(BuddySpeech.line(c, pick: speechPick))
    }

    private func isOverPet(local: CGPoint, side s: CGFloat) -> Bool {
        if let pet {
            let c = pet.animator.cell(now: .now, gaze: pet.gaze)
            guard let px = BuddySpriteGeometry.atlasPixel(localTopDown: CGPoint(x: local.x, y: s - local.y),
                                                          panelSide: s, row: c.row, column: c.column,
                                                          flipped: pet.animator.flipped) else { return false }
            return BuddySpriteGeometry.isOpaque(alphaAt: pet.atlas.alphaAt, x: px.x, y: px.y)
        }
        return DesktopMochiLogic.isOverBody(localPoint: local, panelSize: s)
    }

    private func syncPetOptions(_ pet: BuddyLoadedPet) {
        pet.animator.flipped = settings.isFlipped(pet.entry.id)
        pet.animator.relaxedWaiting = settings.relaxedWaiting
    }

    /// The pet's reaction from Coucou's state, and the V2 gaze (idle, not dragged, the cursor
    /// moved in the last 1.2 s).
    private func updatePet(_ pet: BuddyLoadedPet, mouse: NSPoint, frame pf: NSRect, side s: CGFloat) {
        syncPetOptions(pet)
        let state = isSleeping ? BotState.sleeping : AppState.shared.effectiveState
        pet.animator.setReaction(settings.animation(for: .forState(state)))

        let now = Date.now
        if mouse != lastMouse { lastMouse = mouse; lastMouseMove = now }
        guard pet.entry.manifest.layout.hasGaze, settings.cursorGaze, !dragging,
              BuddyGaze.isActive(lastCursorMove: lastMouseMove, now: now) else { pet.gaze = nil; return }
        let a = BuddySpriteGeometry.gazeAnchor(panelSide: s, anchor: pet.entry.manifest.gazeAnchor,
                                               flipped: pet.animator.flipped)
        // Both points y-down for BuddyGaze: AppKit y negated.
        pet.gaze = BuddyGaze.direction(cursor: CGPoint(x: mouse.x, y: -mouse.y),
                                       anchor: CGPoint(x: pf.minX + a.x, y: -(pf.maxY - a.y)))
    }

    private func lookOrigin(_ p: NSPanel) -> CGPoint {
        DesktopMochiLogic.lookOrigin(panelMinX: p.frame.minX, panelMinY: p.frame.minY,
                                     desktopTop: IslandWindowController.desktopTop, panelSize: p.frame.width)
    }

    // MARK: - Mouse

    /// Screen points (AppKit, y up).
    fileprivate func mouseDown(at m: NSPoint) {
        guard let p = panel else { return }
        dragStartMouse = m
        dragStartOrigin = p.frame.origin
        lastDragX = m.x
        dragging = false
    }

    fileprivate func mouseDragged(to m: NSPoint) {
        guard let p = panel, let start = dragStartMouse else { return }
        if !dragging {
            guard hypot(m.x - start.x, m.y - start.y) > 3 else { return }
            dragging = true
            hideBubble()
        }
        let s = p.frame.width
        let screen = screenAt(m) ?? startScreen()
        let origin = BuddyPlacement.clamp(origin: CGPoint(x: dragStartOrigin.x + m.x - start.x,
                                                          y: dragStartOrigin.y + m.y - start.y),
                                          side: s, visibleFrame: screen.visibleFrame)
        p.setFrameOrigin(origin)
        viewState?.lookOrigin = lookOrigin(p)
        // A pet runs the way it is dragged (OpenPets' running-left / running-right rows).
        if let pet {
            let step = m.x - lastDragX
            if abs(step) > 0.5 { pet.animator.motion = step > 0 ? .runningRight : .runningLeft }
            lastDragX = m.x
        }
    }

    fileprivate func mouseUp(clickCount: Int) {
        defer { dragStartMouse = nil; dragging = false }
        if dragging {
            pet?.animator.motion = nil
            saveSpot()
            return
        }
        guard dragStartMouse != nil, clickCount == 1 else { return }
        // A click plays: a pet waves, Mochi is happy (no slap: that would make the notch dizzy).
        if let pet {
            pet.animator.play(settings.animation(for: .waving))
        } else {
            engine?.triggerEmote(.happy, duration: 0.8, silent: false)
        }
    }

    fileprivate func rightMouseDown(_ e: NSEvent, in view: NSView) {
        NSMenu.popUpContextMenu(contextMenu(), with: e, for: view)
    }

    /// OpenPets' pet menu (size, flip…), plus the pet choice and Coucou's settings.
    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let petMenu = NSMenu()
        petMenu.addItem(BuddyMenuItem("Mochi", checked: resolvedPetId == BuddySettings.mochiId) { [weak self] in
            self?.settings.petId = BuddySettings.mochiId
        })
        if !store.pets.isEmpty { petMenu.addItem(.separator()) }
        for p in store.pets {
            petMenu.addItem(BuddyMenuItem(p.manifest.displayName, checked: resolvedPetId == p.id) { [weak self] in
                self?.settings.petId = p.id
            })
        }
        let petItem = NSMenuItem(title: "Pet", action: nil, keyEquivalent: "")
        petItem.submenu = petMenu
        menu.addItem(petItem)

        let sizeMenu = NSMenu()
        for size in BuddySize.allCases {
            sizeMenu.addItem(BuddyMenuItem(size.label, checked: settings.size == size) { [weak self] in
                self?.settings.size = size
            })
        }
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        if let pet {
            let id = pet.entry.id
            menu.addItem(BuddyMenuItem("Flip horizontally", checked: settings.isFlipped(id)) { [weak self] in
                guard let self else { return }
                self.settings.setFlipped(id, !self.settings.isFlipped(id))
            })
            if pet.entry.manifest.layout.hasGaze {
                menu.addItem(BuddyMenuItem("Look at the cursor", checked: settings.cursorGaze) { [weak self] in
                    self?.settings.cursorGaze.toggle()
                })
            }
        }
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

    /// Centred over the pet's head, kept on its display.
    private func moveBubble() {
        guard let b = bubble, let p = panel else { return }
        let size = b.frame.size
        let screen = screenAt(CGPoint(x: p.frame.midX, y: p.frame.minY))?.visibleFrame ?? p.frame
        var origin = CGPoint(x: p.frame.midX - size.width / 2, y: p.frame.maxY - 6)
        origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
        if origin.y + size.height > screen.maxY { origin.y = p.frame.minY - size.height }
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
