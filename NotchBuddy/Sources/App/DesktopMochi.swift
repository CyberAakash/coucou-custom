import AppKit
import SwiftUI
import Combine

// MARK: - Desktop bot view state

/// Observable bridge so DesktopMochiController can update view-level state without
/// coupling to SwiftUI @State.
@MainActor
final class DesktopBotViewState: ObservableObject {
    /// Drop to 10 fps when sleeping (saves energy).
    @Published var isSleeping: Bool = false
    /// Pause entirely (screen sleep / lock).
    @Published var paused: Bool = false
    /// Mouse is over Mochi's body — drives hover scale animation.
    @Published var isHovered: Bool = false
    /// Bot center in the same coord space as AppState.mousePosition (DesktopSpace, y-down).
    /// Updated every poll frame; Canvas reads it inside TimelineView — @Published not needed.
    var lookOrigin: CGPoint = .zero
}

// MARK: - Desktop bot view

/// Full Mochi character rendered inside the desktop floating panel.
struct DesktopBotView: View {
    @ObservedObject var appState: AppState
    /// Engine owned by DesktopMochiController; controller calls methods on it directly.
    let engine: BotEngine
    @ObservedObject var viewState: DesktopBotViewState

    var body: some View {
        TimelineView(.animation(paused: viewState.paused)) { timeline in
            Canvas { ctx, size in
                _ = timeline.date   // force redraw every tick (see BotCanvasView)

                // Eye tracking based on the panel's own screen position
                engine.lookX = tanh((appState.mousePosition.x - viewState.lookOrigin.x) / 260)
                engine.lookY = -tanh((appState.mousePosition.y - viewState.lookOrigin.y) / 200)
                engine.moodTarget = MachineVitals.shared.mood

                // Desktop Mochi is always the "main" Mochi — always dressed
                engine.setOutfit(appState.resolvedOutfit, animated: true)

                // Dance when music plays (same rules as compact mode)
                let dancing: Bool = {
                    #if !APPSTORE
                    let music = appState.musicPlaying && appState.activeIntegrations.contains("integration_music")
                    let spotify = SpotifyController.shared.isPlaying
                        && appState.activeIntegrations.contains(SpotifyController.pillId)
                    guard music || spotify else { return false }
                    let allowed: Set<BotState> = [.idle, .working, .thinking, .searching, .finished]
                    return allowed.contains(appState.effectiveState)
                    #else
                    return false
                    #endif
                }()
                engine.setDancing(dancing)
                MochiFrameClock.advance(engine)

                var c = ctx
                engine.applyDance(&c, size: size)

                // Rigid roll when outfit is present (matches BotCanvasView)
                if engine.outfit != .none && engine.outfitPresence > 0.05 && abs(engine.roll) > 0.001 {
                    let center = engine.bodyCenter(size: size)
                    var rigidCtx = c
                    rigidCtx.translateBy(x: center.x, y: center.y)
                    rigidCtx.rotate(by: .radians(engine.roll))
                    rigidCtx.translateBy(x: -center.x, y: -center.y)
                    engine.drawHandsBehind(context: rigidCtx, size: size)
                    engine.drawOutfitBehind(context: rigidCtx, size: size)
                    engine.draw(context: rigidCtx, size: size)
                    engine.drawOutfitFront(context: rigidCtx, size: size)
                } else {
                    engine.drawHandsBehind(context: c, size: size)
                    engine.drawOutfitBehind(context: c, size: size)
                    engine.draw(context: c, size: size)
                    engine.drawOutfitFront(context: c, size: size)
                }
                engine.drawHandsAndExtras(context: c, size: size)
            }
        }
        .scaleEffect(viewState.isHovered ? 1.07 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: viewState.isHovered)
        .onChange(of: appState.effectiveState) { _, newState in
            engine.setState(newState)
        }
        .onAppear {
            engine.setState(appState.effectiveState, force: true)
            engine.setOutfit(appState.resolvedOutfit, animated: false)
        }
    }
}

// MARK: - Desktop Mochi controller

/// Manages the "Mochi on the desktop" floating panel.
///
/// Life cycle:
/// - **Install from drag**: `IslandWindowController.finishDrag` calls `install(ghostPanel:at:)`.
/// - **Launch restore**: `AppDelegate` observes `.greetComplete` → `launchFlyIfNeeded()`.
/// - **Alert**: `pendingApproval`/`pendingQuestion` goes non-nil → surprised emote →
///   `retractForAlert()` (panel gone, flag stays true) → both nil → `launchFlyIfNeeded()`.
/// - **User flies home**: double-click → `flyHome()` → full teardown.
@MainActor
final class DesktopMochiController {
    static let shared = DesktopMochiController()
    private init() {
        observeScreenSleep()
        observeScreenLock()
        observeAlerts()   // permanent — lives for the lifetime of the singleton
        observeBuddySettings()   // coucou-custom fork: Settings → Buddy
    }

    private var panel: NSPanel?
    private var engine: BotEngine?
    private var viewState: DesktopBotViewState?
    private var frameTimer: Timer?

    // Alert state machine
    private var phase: DesktopPhase = .home

    // Desktop drag repositioning
    private var isDragging = false
    private var dragMouseStart: NSPoint = .zero
    private var dragOriginAtStart: NSPoint = .zero

    // Deferred single-click slap
    private var pendingSlapWorkItem: DispatchWorkItem?

    // Sleep detection
    private var lastAgentActive: Date = .distantPast
    private var isSleeping = false

    // Screen sleep / lock
    private var screenSleeping = false

    // Lifecycle subscriptions (cleared on retractForAlert + fullTearDown)
    private var cancellables: Set<AnyCancellable> = []
    // Alert subscription — permanent, only released with the singleton
    private var alertSubscription: AnyCancellable?
    private var buddySubscription: AnyCancellable?

    #if !APPSTORE
    /// coucou-custom fork: the Buddy pet drawn instead of Mochi (Settings → Buddy); nil shows Mochi.
    private var pet: BuddyLoadedPet?
    private var lastMouse: NSPoint = .zero
    private var lastMouseMove: Date?
    private var lastDragX: CGFloat = 0
    #endif

    // Event monitors
    private var mouseDownMonitor:    Any?
    private var mouseDraggedMonitor: Any?
    private var mouseUpMonitor:      Any?
    private var globalMouseUpMonitor: Any?
    private var rightClickMonitor:   Any?

    // UserDefaults keys
    private static let posXKey    = "desktopMochiX"
    private static let posYKey    = "desktopMochiY"
    static let enabledKey = "mochiOnDesktop"

    /// Side of the panel: Settings → Buddy's size, for Mochi or the pet shown (Mochi at Medium
    /// is the original 120 pt).
    private var panelSize: CGFloat {
        #if !APPSTORE
        BuddySettings.shared.size.panelSide(isMochi: pet == nil)
        #else
        BuddySettings.shared.size.panelSide(isMochi: true)
        #endif
    }

    // MARK: - Keyboard shortcut toggle (⌃⌥D)

    /// Fly Mochi to the desktop if not there, or bring him back if he is.
    func flyOutOrHome() {
        if phase == .home {
            UserDefaults.standard.set(true, forKey: DesktopMochiController.enabledKey)
            launchFlyIfNeeded()
        } else if phase == .onDesktop {
            flyHome()
        }
    }

    // MARK: - Install (from drag-drop)

    /// Promote `ghostPanel` (the drag ghost) or create a fresh panel as the desktop Mochi,
    /// centered on `screenPoint`. Called by `IslandWindowController.finishDrag`.
    func install(ghostPanel: NSPanel?, at screenPoint: NSPoint) {
        guard panel == nil, phase == .home else { ghostPanel?.close(); return }
        let content = makeContent()   // loads the Buddy pet, which decides the size
        let s = panelSize

        let p: NSPanel
        if let ghost = ghostPanel {
            p = ghost
        } else {
            p = makeBlankPanel()
            p.setFrame(NSRect(x: screenPoint.x - s/2, y: screenPoint.y - s/2, width: s, height: s),
                       display: false)
        }

        // Hosting view (autoresizingMask lets it grow with the panel animation)
        content.frame = CGRect(origin: .zero, size: p.frame.size)
        content.autoresizingMask = [.width, .height]
        p.contentView = content
        viewState?.lookOrigin = lookOriginFor(panel: p)
        let eng = engine

        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.ignoresMouseEvents = true
        if !p.isVisible { p.orderFront(nil) }

        // Squash emote + sound on landing
        eng?.triggerEmote(.happy, duration: 0.6, silent: true)
        SoundEngine.shared.play("pop")

        // Animate from current (ghost) size to 120 × 120, centered on drop point
        let targetOrigin = clampToVisibleFrame(NSPoint(x: screenPoint.x - s/2, y: screenPoint.y - s/2))
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.17, 0.67, 0.38, 1.3)
            p.animator().setFrame(NSRect(origin: targetOrigin, size: CGSize(width: s, height: s)),
                                  display: true)
        }, completionHandler: {
            Task { @MainActor in
                self.panel = p
                self.phase = .onDesktop
                AppState.shared.mochiOnDesktop = true
                UserDefaults.standard.set(true, forKey: DesktopMochiController.enabledKey)
                self.persistPosition()
                // Alert may have fired during the animation (observeAlerts skipped: phase wasn't .onDesktop)
                let alertNow = AppState.shared.pendingApproval != nil || AppState.shared.pendingQuestion != nil
                if DesktopMochiLogic.shouldRetractOnLanding(alertActive: alertNow) {
                    self.engine?.triggerEmote(.surprised)
                    self.phase = .retracting
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                        guard let self else { return }
                        switch self.phase {
                        case .retracting:              self.retractForAlert()
                        case .alertResolvedDuringRetract: self.phase = .home; self.launchFlyIfNeeded()
                        default: break
                        }
                    }
                } else {
                    self.startPolling()
                    self.addEventMonitors()
                    self.observeLifecycle()
                }
            }
        })
    }

    // MARK: - Launch fly (app-start restore or alert return)

    /// Fly a new panel from the notch to the saved desktop position.
    /// Called by AppDelegate after `.greetComplete`, and by the alert-return path.
    func launchFlyIfNeeded() {
        guard UserDefaults.standard.bool(forKey: DesktopMochiController.enabledKey) else { return }
        guard phase == .home else { return }
        guard panel == nil else { return }
        // Alert active: don't fly yet — park in .atNotchForAlert so observeAlerts restores us when it clears
        if AppState.shared.pendingApproval != nil || AppState.shared.pendingQuestion != nil {
            phase = .atNotchForAlert
            return
        }

        phase = .flyingOut
        let content = makeContent()   // loads the Buddy pet, which decides the size
        let s = panelSize
        let screen = IslandWindowController.islandScreen()
        let startOrigin = NSPoint(x: screen.frame.midX - s/2, y: screen.frame.maxY - s)
        let target = loadSavedPosition()

        let p = makeBlankPanel()
        p.setFrame(NSRect(origin: startOrigin, size: CGSize(width: s, height: s)), display: false)

        content.frame = CGRect(x: 0, y: 0, width: s, height: s)
        content.autoresizingMask = [.width, .height]
        p.contentView = content
        viewState?.lookOrigin = lookOriginFor(panel: p)
        p.alphaValue = 0
        p.orderFront(nil)

        AppState.shared.mochiOnDesktop = true

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            p.animator().alphaValue = 1
            p.animator().setFrame(NSRect(origin: target, size: CGSize(width: s, height: s)), display: true)
        }, completionHandler: {
            Task { @MainActor in
                self.panel = p
                self.phase = .onDesktop
                UserDefaults.standard.set(true, forKey: DesktopMochiController.enabledKey)
                self.persistPosition()
                // Alert may have fired during the flight (observeAlerts skipped: phase was .flyingOut)
                let alertNow = AppState.shared.pendingApproval != nil || AppState.shared.pendingQuestion != nil
                if DesktopMochiLogic.shouldRetractOnLanding(alertActive: alertNow) {
                    self.engine?.triggerEmote(.surprised)
                    self.phase = .retracting
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                        guard let self else { return }
                        switch self.phase {
                        case .retracting:              self.retractForAlert()
                        case .alertResolvedDuringRetract: self.phase = .home; self.launchFlyIfNeeded()
                        default: break
                        }
                    }
                } else {
                    self.startPolling()
                    self.addEventMonitors()
                    self.observeLifecycle()
                }
            }
        })
    }

    // MARK: - Fly home (user-initiated: double-click)

    /// Animate panel to notch then fully tear down.
    func flyHome() {
        guard let p = panel else { return }
        phase = .home
        pendingSlapWorkItem?.cancel()
        stopPolling()
        removeEventMonitors()
        cancellables.removeAll()
        isSleeping = false
        let s = panelSize
        let screen = IslandWindowController.islandScreen()
        let targetOrigin = NSPoint(x: screen.frame.midX - s/2, y: screen.frame.maxY - s)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            p.animator().setFrame(NSRect(origin: targetOrigin, size: CGSize(width: s, height: s)),
                                  display: true)
        }, completionHandler: {
            Task { @MainActor in
                SoundEngine.shared.play("peek")
                self.fullTearDown()
            }
        })
    }

    // MARK: - Retract for alert (panel flies home; comes back after alert resolves)

    /// Close panel and show notch Mochi for the alert. UserDefaults flag stays true so
    /// `launchFlyIfNeeded` restores Mochi once the alert is dismissed.
    private func retractForAlert() {
        guard let p = panel else { return }
        stopPolling()
        removeEventMonitors()
        cancellables.removeAll()
        pendingSlapWorkItem?.cancel()
        isSleeping = false

        let s = panelSize
        let screen = IslandWindowController.islandScreen()
        let targetOrigin = NSPoint(x: screen.frame.midX - s/2, y: screen.frame.maxY - s)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            p.animator().setFrame(NSRect(origin: targetOrigin, size: CGSize(width: s, height: s)),
                                  display: true)
        }, completionHandler: {
            Task { @MainActor in
                p.close()
                self.panel = nil
                self.engine = nil
                self.viewState = nil
                #if !APPSTORE
                self.pet = nil
                #endif
                self.isDragging = false
                AppState.shared.mochiOnDesktop = false
                // UserDefaults flag stays TRUE so launchFlyIfNeeded works
                if self.phase == .alertResolvedDuringRetract {
                    self.phase = .home
                    self.launchFlyIfNeeded()
                } else {
                    self.phase = .atNotchForAlert
                }
            }
        })
    }

    // MARK: - Uninstall (immediate, no animation)

    func uninstall() {
        stopPolling()
        removeEventMonitors()
        fullTearDown()
    }

    private func fullTearDown() {
        phase = .home
        cancellables.removeAll()
        pendingSlapWorkItem?.cancel()
        panel?.close()
        panel = nil
        engine = nil
        viewState = nil
        #if !APPSTORE
        pet = nil
        #endif
        isDragging = false
        isSleeping = false
        AppState.shared.mochiOnDesktop = false
        UserDefaults.standard.set(false, forKey: DesktopMochiController.enabledKey)
    }

    // MARK: - Panel factory

    private func makeBlankPanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        return p
    }

    /// The panel's content: the Buddy pet chosen in Settings, or Mochi. Sets `engine`,
    /// `viewState` and `pet`; Mochi's engine is kept for a pet too, as the alert and landing
    /// emotes go through it.
    private func makeContent() -> NSView {
        let eng = BotEngine()
        eng.setState(isSleeping ? .sleeping : AppState.shared.effectiveState, force: true)
        eng.setOutfit(AppState.shared.resolvedOutfit, animated: false)
        self.engine = eng

        let vs = DesktopBotViewState()
        vs.paused = screenSleeping
        vs.isSleeping = isSleeping
        self.viewState = vs

        #if !APPSTORE
        pet = BuddyLoadedPet.load(id: BuddySettings.shared.petId)
        if let pet {
            return NSHostingView(rootView: BuddyPetView(pet: pet, viewState: vs))
        }
        #endif
        return NSHostingView(rootView: DesktopBotView(appState: AppState.shared, engine: eng, viewState: vs))
    }

    // MARK: - Buddy (coucou-custom fork: Settings → Buddy)

    /// Settings → Buddy → "Show on the desktop".
    func setOnDesktop(_ on: Bool) {
        if on {
            UserDefaults.standard.set(true, forKey: DesktopMochiController.enabledKey)
            launchFlyIfNeeded()
        } else {
            switch phase {
            case .onDesktop:
                flyHome()
            case .home, .atNotchForAlert:
                // Parked for an alert: forget it, so the alert's end does not fly it back out.
                phase = .home
                UserDefaults.standard.set(false, forKey: DesktopMochiController.enabledKey)
            case .flyingOut, .retracting, .alertResolvedDuringRetract:
                break   // mid-animation; the toggle reads the stored flag and stays as it is
            }
        }
    }

    /// Back to the default corner (bottom right of the main screen).
    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: DesktopMochiController.posXKey)
        UserDefaults.standard.removeObject(forKey: DesktopMochiController.posYKey)
        guard phase == .onDesktop, let p = panel else { return }
        p.setFrameOrigin(defaultPosition())
        viewState?.lookOrigin = lookOriginFor(panel: p)
        persistPosition()
    }

    /// The pet or the size changed in Settings: redraw in place, standing where it stood.
    private func observeBuddySettings() {
        buddySubscription = Publishers.CombineLatest(BuddySettings.shared.$petId, BuddySettings.shared.$size)
            .dropFirst()
            // @Published sends before the property is set: read it on the next turn of the loop.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                MainActor.assumeIsolated { self?.reloadBuddy() }
            }
    }

    private func reloadBuddy() {
        guard phase == .onDesktop, let p = panel else { return }
        let old = p.frame
        let content = makeContent()
        let s = panelSize
        let origin = clampToVisibleFrame(NSPoint(x: old.midX - s/2, y: old.minY))
        p.setFrame(NSRect(origin: origin, size: CGSize(width: s, height: s)), display: false)
        content.frame = CGRect(x: 0, y: 0, width: s, height: s)
        content.autoresizingMask = [.width, .height]
        p.contentView = content
        viewState?.lookOrigin = lookOriginFor(panel: p)
        persistPosition()
    }

    /// Whether the cursor is over what is drawn: Mochi's round body, or an opaque pixel of the
    /// pet's current frame (OpenPets' alpha hit test), so the rest of the panel clicks through.
    private func isOverPet(local: CGPoint, side s: CGFloat) -> Bool {
        #if !APPSTORE
        if let pet {
            let c = pet.animator.cell(now: .now, gaze: pet.gaze)
            guard let px = BuddySpriteGeometry.atlasPixel(localTopDown: CGPoint(x: local.x, y: s - local.y),
                                                          panelSide: s, row: c.row, column: c.column,
                                                          flipped: pet.animator.flipped) else { return false }
            return BuddySpriteGeometry.isOpaque(alphaAt: pet.atlas.alphaAt, x: px.x, y: px.y)
        }
        #endif
        return DesktopMochiLogic.isOverBody(localPoint: local, panelSize: s)
    }

    #if !APPSTORE
    /// Per poll: the pet's reaction from Coucou's state, its flip and waiting speed, and the V2
    /// cursor gaze (only while idle, not dragged, and the cursor moved in the last 1.2 s).
    private func updatePet(_ pet: BuddyLoadedPet, mouse: NSPoint, frame pf: NSRect, side s: CGFloat) {
        let settings = BuddySettings.shared
        pet.animator.flipped = settings.isFlipped(pet.entry.id)
        pet.animator.relaxedWaiting = settings.relaxedWaiting
        let state = isSleeping ? BotState.sleeping : AppState.shared.effectiveState
        pet.animator.setReaction(settings.animation(for: .forState(state)))

        let now = Date.now
        if mouse != lastMouse { lastMouse = mouse; lastMouseMove = now }
        guard pet.entry.manifest.layout.hasGaze, settings.cursorGaze, !isDragging,
              BuddyGaze.isActive(lastCursorMove: lastMouseMove, now: now) else { pet.gaze = nil; return }
        let a = BuddySpriteGeometry.gazeAnchor(panelSide: s, anchor: pet.entry.manifest.gazeAnchor,
                                               flipped: pet.animator.flipped)
        // Both points y-down for BuddyGaze: AppKit y negated.
        let anchor = CGPoint(x: pf.minX + a.x, y: -(pf.maxY - a.y))
        pet.gaze = BuddyGaze.direction(cursor: CGPoint(x: mouse.x, y: -mouse.y), anchor: anchor)
    }
    #endif

    private func singleClick() {
        #if !APPSTORE
        if let pet {
            pet.animator.play(BuddySettings.shared.animation(for: .waving))
            return
        }
        #endif
        engine?.slap()
    }

    // MARK: - Lifecycle observation (active while panel is live on desktop)

    private func observeLifecycle() {
        cancellables.removeAll()

        // effectiveState → .finished: joy jump (only when on desktop, not retracting)
        Publishers.CombineLatest(AppState.shared.$stateOverride, AppState.shared.$tasks)
            .map { _, _ in AppState.shared.effectiveState }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                guard let self, self.phase == .onDesktop else { return }
                if newState == .finished {
                    self.engine?.triggerEmote(.happy, duration: 1.2, silent: true)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Alert observation (permanent — installed once at init)

    private func observeAlerts() {
        alertSubscription = Publishers.CombineLatest(
            AppState.shared.$pendingApproval,
            AppState.shared.$pendingQuestion
        )
        .map { a, q in a != nil || q != nil }
        .removeDuplicates()
        .dropFirst()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] alertActive in
            guard let self else { return }

            if alertActive {
                guard self.phase == .onDesktop else { return }
                self.engine?.triggerEmote(.surprised)
                self.phase = .retracting
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    guard let self else { return }
                    switch self.phase {
                    case .retracting:
                        self.retractForAlert()
                    case .alertResolvedDuringRetract:
                        // Alert cleared before animation started — no need to retract
                        self.phase = .home
                        self.launchFlyIfNeeded()
                    default:
                        break
                    }
                }
            } else {
                switch self.phase {
                case .atNotchForAlert:
                    self.phase = .home
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        self?.launchFlyIfNeeded()
                    }
                case .retracting:
                    // Alert resolved while waiting to retract — mark it
                    self.phase = .alertResolvedDuringRetract
                default:
                    break
                }
            }
        }
    }

    // MARK: - 30 Hz polling (only while panel is live and the screen is on)
    // Mochi is drawn at 30 fps (10 asleep): polling faster bought nothing. It also feeds
    // the eye tracking (AppState.mousePosition), so the island poll can idle meanwhile.

    /// True between startPolling and stopPolling, whatever the screen does meanwhile.
    private var pollingWanted = false

    private func startPolling() {
        frameTimer?.invalidate()
        frameTimer = nil
        pollingWanted = true
        guard !screenSleeping else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            // On the main run loop: already on the main actor, no Task per tick.
            MainActor.assumeIsolated { self?.pollFrame() }
        }
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func stopPolling() {
        pollingWanted = false
        frameTimer?.invalidate()
        frameTimer = nil
    }

    private func pausePollingForScreen() {
        frameTimer?.invalidate()
        frameTimer = nil
    }

    /// Only when it was polling before the screen went off.
    private func resumePollingForScreen() {
        guard pollingWanted, panel != nil, frameTimer == nil else { return }
        startPolling()
    }

    private func pollFrame() {
        guard let p = panel else { return }
        let mouse = NSEvent.mouseLocation
        let pf    = p.frame
        let local = CGPoint(x: mouse.x - pf.minX, y: mouse.y - pf.minY)
        let s     = panelSize

        // Toggle click-through
        let overBody   = isOverPet(local: local, side: s)
        let needsMouse = overBody || isDragging
        if p.ignoresMouseEvents == needsMouse {
            p.ignoresMouseEvents = !needsMouse
        }

        // Hover scale animation
        let hovering = overBody && !isDragging
        if viewState?.isHovered != hovering { viewState?.isHovered = hovering }

        // Update eye-tracking origin every frame
        viewState?.lookOrigin = lookOriginFor(panel: p)
        let pos = DesktopSpace.topDown(mouse, desktopTop: IslandWindowController.desktopTop)
        let cur = AppState.shared.mousePosition
        if abs(pos.x - cur.x) > 1 || abs(pos.y - cur.y) > 1 { AppState.shared.mousePosition = pos }

        // Sleep detection
        let agentActive = AppState.shared.effectiveState != .idle &&
                          AppState.shared.effectiveState != .sleeping
        if agentActive { lastAgentActive = .now }
        let dist     = hypot(mouse.x - pf.midX, mouse.y - pf.midY)
        let interval = Date.now.timeIntervalSince(lastAgentActive)
        let shouldSleep = DesktopMochiLogic.shouldSleep(lastAgentActiveInterval: interval,
                                                         mouseDistanceToPanelCenter: dist)
        if shouldSleep != isSleeping {
            isSleeping = shouldSleep
            viewState?.isSleeping = shouldSleep
            engine?.setState(isSleeping ? .sleeping : AppState.shared.effectiveState)
        }
        #if !APPSTORE
        if let pet { updatePet(pet, mouse: mouse, frame: pf, side: s) }
        #endif
    }

    // MARK: - Event monitors

    private func addEventMonitors() {
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                guard event.window === self.panel else { return }
                self.dragMouseStart    = NSEvent.mouseLocation
                self.dragOriginAtStart = self.panel?.frame.origin ?? .zero
            }
            return event
        }

        mouseDraggedMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                let m = NSEvent.mouseLocation
                if !self.isDragging {
                    let dist = hypot(m.x - self.dragMouseStart.x, m.y - self.dragMouseStart.y)
                    guard self.dragMouseStart != .zero, dist > 3 else { return }
                    self.isDragging = true
                    #if !APPSTORE
                    self.lastDragX = self.dragMouseStart.x
                    #endif
                }
                #if !APPSTORE
                // A pet runs the way it is dragged (OpenPets' running-left / running-right rows).
                if let pet = self.pet {
                    let step = m.x - self.lastDragX
                    if abs(step) > 0.5 { pet.animator.motion = step > 0 ? .runningRight : .runningLeft }
                    self.lastDragX = m.x
                }
                #endif
                guard let p = self.panel else { return }
                let dx = m.x - self.dragMouseStart.x
                let dy = m.y - self.dragMouseStart.y
                let newOrigin = self.clampToVisibleFrame(
                    NSPoint(x: self.dragOriginAtStart.x + dx, y: self.dragOriginAtStart.y + dy))
                p.setFrameOrigin(newOrigin)
                self.viewState?.lookOrigin = self.lookOriginFor(panel: p)
            }
            return event
        }

        // Local mouseUp (cursor still within panel)
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                let wasDragging = self.isDragging
                self.isDragging = false
                self.dragMouseStart = .zero
                if wasDragging {
                    self.handleDragRelease(at: NSEvent.mouseLocation)
                } else if event.window === self.panel {
                    self.handleClick(clickCount: event.clickCount)
                }
            }
            return event
        }

        // Global mouseUp (cursor moved outside panel during drag)
        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isDragging else { return }
                self.isDragging = false
                self.dragMouseStart = .zero
                self.handleDragRelease(at: NSEvent.mouseLocation)
            }
        }

        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                guard event.window === self.panel else { return }
                #if !APPSTORE
                // A Buddy pet has no wardrobe: its settings instead.
                if self.pet != nil {
                    NotificationCenter.default.post(name: .openFullSettings, object: "buddy")
                    return
                }
                #endif
                NotificationCenter.default.post(name: .openWardrobeFromDesktop, object: nil)
            }
            return event
        }
    }

    // MARK: - Click / drag helpers

    private func handleClick(clickCount: Int) {
        if clickCount >= 2 {
            pendingSlapWorkItem?.cancel()
            flyHome()
        } else {
            pendingSlapWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.singleClick() } }
            pendingSlapWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: item)
        }
    }

    private func handleDragRelease(at mouse: NSPoint) {
        #if !APPSTORE
        pet?.animator.motion = nil
        #endif
        let islandController = (NSApp.delegate as? AppDelegate)?.islandController
        let inNotchZone = islandController?.window?.frame.contains(mouse) == true

        if inNotchZone {
            flyHome()
            return
        }

        #if !APPSTORE
        if let ctx = islandController?.windowContextAtPoint(mouse) {
            // Attach window context; Mochi returns to pre-drag position
            AppState.shared.promptContext = ctx
            SoundEngine.shared.play("approve")
            engine?.triggerEmote(.happy, duration: 0.6, silent: true)
            let origin = clampToVisibleFrame(dragOriginAtStart)
            panel?.setFrameOrigin(origin)
            persistPosition()
            islandController?.expand(to: .prompt)
            return
        }
        #endif
        // Elsewhere: keep new position
        persistPosition()
    }

    private func removeEventMonitors() {
        if let m = mouseDownMonitor     { NSEvent.removeMonitor(m); mouseDownMonitor     = nil }
        if let m = mouseDraggedMonitor  { NSEvent.removeMonitor(m); mouseDraggedMonitor  = nil }
        if let m = mouseUpMonitor       { NSEvent.removeMonitor(m); mouseUpMonitor       = nil }
        if let m = globalMouseUpMonitor { NSEvent.removeMonitor(m); globalMouseUpMonitor = nil }
        if let m = rightClickMonitor    { NSEvent.removeMonitor(m); rightClickMonitor    = nil }
    }

    // MARK: - Screen sleep / wake

    private func observeScreenSleep() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.screenSleeping = true
                self?.viewState?.paused = true
                self?.pausePollingForScreen()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.screenSleeping = false
                self?.viewState?.paused = false
                self?.resumePollingForScreen()
            }
        }
    }

    // MARK: - Screen lock / unlock

    private func observeScreenLock() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.screenSleeping = true
                self?.viewState?.paused = true
                self?.pausePollingForScreen()
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.screenSleeping = false
                self?.viewState?.paused = false
                self?.resumePollingForScreen()
            }
        }
    }

    // MARK: - Position helpers

    private func lookOriginFor(panel: NSPanel) -> CGPoint {
        DesktopMochiLogic.lookOrigin(
            panelMinX:  panel.frame.minX,
            panelMinY:  panel.frame.minY,
            desktopTop: IslandWindowController.desktopTop,
            panelSize:  panelSize)
    }

    private func clampToVisibleFrame(_ origin: NSPoint) -> NSPoint {
        let screen = NSScreen.screens.min(by: {
            let da = hypot(origin.x - $0.visibleFrame.midX, origin.y - $0.visibleFrame.midY)
            let db = hypot(origin.x - $1.visibleFrame.midX, origin.y - $1.visibleFrame.midY)
            return da < db
        }) ?? NSScreen.main!
        let pt = DesktopMochiLogic.clampOrigin(
            CGPoint(x: origin.x, y: origin.y),
            panelSize:    panelSize,
            visibleFrame: screen.visibleFrame,
            margin:       DesktopMochiLogic.clampMargin)
        return NSPoint(x: pt.x, y: pt.y)
    }

    private func loadSavedPosition() -> NSPoint {
        let ud = UserDefaults.standard
        guard ud.object(forKey: DesktopMochiController.posXKey) != nil else {
            return defaultPosition()
        }
        let x = CGFloat(ud.double(forKey: DesktopMochiController.posXKey))
        let y = CGFloat(ud.double(forKey: DesktopMochiController.posYKey))
        return clampToVisibleFrame(NSPoint(x: x, y: y))
    }

    private func defaultPosition() -> NSPoint {
        let s      = panelSize
        let margin = DesktopMochiLogic.clampMargin
        let vf     = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: vf.maxX - s - margin, y: vf.minY + margin)
    }

    private func persistPosition() {
        guard let p = panel else { return }
        let o = p.frame.origin
        UserDefaults.standard.set(Double(o.x), forKey: DesktopMochiController.posXKey)
        UserDefaults.standard.set(Double(o.y), forKey: DesktopMochiController.posYKey)
    }
}
