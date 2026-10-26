import SwiftUI
import AppKit

/// SwiftUI wrapper: TimelineView drives a Canvas that calls BotEngine.draw().
/// Uses a shared engine per-task; the main bot uses AppState's shared engine.
struct BotCanvasView: View {
    @ObservedObject var state: AppState
    var particleOverhang: CGFloat = 0
    /// When set, overrides island-based eye-tracking (used by desktop Mochi).
    /// CGPoint in the same coord space as state.mousePosition (DesktopSpace, y-down).
    var lookOriginOverride: CGPoint? = nil
    /// Not drawn while true (e.g. the notch copy while Mochi is on the desktop).
    var paused: Bool = false

    // One engine per view instance (main bot)
    @StateObject private var engine = BotEngine()

    var body: some View {
        // At most 60 frames a second (every frame on a 60 Hz screen, one in two on ProMotion);
        // the engine runs the steps of the frames it skips, so Mochi's speed never changes.
        let pace = MochiFrameClock.pacing(cap: MochiFrameClock.mainFPS)
        TimelineView(.animation(minimumInterval: pace.interval, paused: state.mode == .hidden || paused)) { timeline in
            // The Canvas must capture the frame's date: a closure that doesn't change from
            // one tick to the next is not redrawn, and Mochi froze.
            let frame = timeline.date
            Canvas { context, size in
                _ = frame
                let look = lookXY(state: state)
                engine.lookX = look.x
                engine.lookY = look.y
                engine.particleOverhang = particleOverhang
                // How the Mac feels (MochiMood.swift).
                engine.moodTarget = MachineVitals.shared.mood
                // Widen slot when file is hovering over the mailbox (morph > 0.5)
                // Open mouth (hover=0.20R) when file dragged over box; close when not
                if engine.morph > 0.3 {
                    engine.slotHTarget = state.fileDragOver ? 0.20 : 0
                } else {
                    engine.slotHTarget = 0
                    if engine.morph < 0.05 { engine.slotH = 0; engine.slotHVel = 0 }
                }
                // Integration pills have a fixed brand color → use it as bodyColor.
                // Claude Code tasks use state-based gradient (working=blue, thinking=purple, etc.).
                #if !APPSTORE
                if state.showingPlanDetail {
                    let hex = state.planDetailIsCodex
                        ? CodexPlanGauge.color(state.codexPlanUsage)
                        : ClaudePlanGauge.color(for: state.claudePlanUsage.flatMap { ClaudePlanGauge.dominantPct($0) })
                    engine.bodyColor = cgColorFromHex(hex)
                } else {
                    engine.bodyColor = (state.focusTask?.isIntegration == true)
                        ? cgColorFromHex(state.focusTask!.color)
                        : nil
                }
                // A new Coucou waits and Mochi has nothing else to say: he turns blue, with an arrow.
                let updateHint = MacUpdater.shared.hintActive
                    && (state.effectiveState == .idle || state.effectiveState == .sleeping)
                    && state.pendingApproval == nil && state.pendingQuestion == nil
                    && !state.showingPlanDetail
                if updateHint { engine.bodyColor = BotEngine.updateBlue }
                engine.setUpdateHint(updateHint)
                #else
                engine.bodyColor = (state.focusTask?.isIntegration == true)
                    ? cgColorFromHex(state.focusTask!.color)
                    : nil
                #endif

                // Compute shouldDance per-frame (no observer lag)
                let dancing: Bool = {
                    #if !APPSTORE
                    let active = AppState.shared.activeIntegrations
                    let music = AppState.shared.musicPlaying && active.contains("integration_music")
                    let spotify = SpotifyController.shared.isPlaying && active.contains(SpotifyController.pillId)
                    guard music || spotify else { return false }
                    let allowed: Set<BotState> = [.idle, .working, .thinking, .searching, .finished]
                    guard allowed.contains(state.effectiveState) else { return false }
                    if state.mode == .compact { return true }
                    guard state.mode == .expanded && state.view == .overview else { return false }
                    return (music && state.focusId == "integration_music")
                        || (spotify && state.focusId == SpotifyController.pillId)
                    #else
                    return false
                    #endif
                }()
                engine.setDancing(dancing)
                let isWardrobe = state.mode == .expanded && state.view == .wardrobe
                let isFocusMain = state.focusId == state.mainPillId || state.focusId == nil
                let showOutfit = isFocusMain || state.mode != .expanded || isWardrobe
                engine.setOutfit(showOutfit ? state.resolvedOutfit : .none,
                                 animated: state.view != .wardrobe)

                #if !APPSTORE
                if state.view == .listening {
                    // Expanded listening view only (no longer used by voice, kept for the
                    // view itself). Smoothed so the eyes do not follow every mic frame.
                    let target = CGFloat(VoiceEngine.shared.micLevel)
                    engine.listeningLevel += (target - engine.listeningLevel) * 0.12
                    engine.listeningHasWords = !VoiceEngine.shared.commandTranscript.isEmpty
                } else if state.voiceActive && state.mode == .compact {
                    // Compact voice: feed mic level for the listening sub-state eye pulse.
                    let target = CGFloat(VoiceEngine.shared.micLevel)
                    engine.listeningLevel += (target - engine.listeningLevel) * 0.12
                }
                // Propagate voice sub-state every frame so BotEngine gets transitions promptly.
                if state.voiceActive { engine.voiceSubState = state.voiceSubState }
                else if engine.voiceSubState != .none { engine.voiceSubState = .none }
                #endif

                MochiFrameClock.advance(engine, steps: pace.steps)
                var ctx = context
                engine.applyDance(&ctx, size: size)
                // Rigid-roll: when Mochi wears an outfit (presence > 0.05) and is rolling,
                // rotate the entire body+accessories context around the body center so the
                // whole character genuinely turns. Particles/badge (drawHandsAndExtras) are
                // drawn outside the rotated context and do not spin.
                if engine.outfit != .none && engine.outfitPresence > 0.05 && abs(engine.roll) > 0.001 {
                    let center = engine.bodyCenter(size: size)
                    var rigidCtx = ctx
                    rigidCtx.translateBy(x: center.x, y: center.y)
                    rigidCtx.rotate(by: .radians(engine.roll))
                    rigidCtx.translateBy(x: -center.x, y: -center.y)
                    engine.drawHandsBehind(context: rigidCtx, size: size)
                    engine.drawOutfitBehind(context: rigidCtx, size: size)
                    engine.draw(context: rigidCtx, size: size)
                    engine.drawOutfitFront(context: rigidCtx, size: size)
                } else {
                    engine.drawHandsBehind(context: ctx, size: size)
                    engine.drawOutfitBehind(context: ctx, size: size)
                    engine.draw(context: ctx, size: size)
                    engine.drawOutfitFront(context: ctx, size: size)
                }
                engine.drawHandsAndExtras(context: ctx, size: size)
            }
        }
        .onChange(of: state.effectiveState) { _, newState in
            engine.setState(newState)
        }
        #if !APPSTORE
        .onChange(of: state.voiceActive) { _, on in
            if on { engine.enterVoiceCompact() } else { engine.exitVoiceCompact() }
        }
        #endif
        .onChange(of: state.view) { oldView, newView in
            // Morph up when upload view is active
            if state.mode == .expanded && newView == .upload {
                engine.anim("morph", keys: [TweenKey(target: 1, duration: 550, ease: Ease.inOut)])
            } else if newView != .upload && newView != .uploading && engine.morph > 0.01 {
                // Any other view (not mid-gulp): morph back
                engine.anim("morph", keys: [TweenKey(target: 0, duration: 550, ease: Ease.inOut)])
            }
            #if !APPSTORE
            if newView == .listening {
                engine.enterListening()
            } else if oldView == .listening {
                engine.exitListening(hadCommand: !VoiceEngine.shared.commandTranscript.isEmpty)
            }
            #endif
        }
        .onChange(of: state.mode) { _, newMode in
            // Hard-reset morph when island collapses
            if newMode != .expanded {
                engine.tweens.removeValue(forKey: "morph")
                engine.locks.remove("morph")
                engine.morph = 0
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerEmote)) { notif in
            if let emote = notif.object as? BotEmote {
                engine.triggerEmote(emote)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerSlap)) { _ in
            engine.slap()
        }
        .onReceive(NotificationCenter.default.publisher(for: .botBlink)) { _ in
            engine.blink()
        }
        .onReceive(NotificationCenter.default.publisher(for: .botSetTgEs)) { notif in
            if let v = notif.object as? CGFloat {
                engine.tgEs = v
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .botGulp)) { _ in
            engine.gulp()
        }
        .onReceive(NotificationCenter.default.publisher(for: .botMorphTo)) { notif in
            if let target = notif.object as? CGFloat {
                let dur: CGFloat = target > 0.5 ? 550 : 650
                engine.anim("morph", keys: [TweenKey(target: target, duration: dur, ease: Ease.inOut)])
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .botGreet)) { _ in
            engine.greet()
        }
        .onAppear {
            engine.setState(state.effectiveState, force: true)
            let isWardrobe = state.mode == .expanded && state.view == .wardrobe
            let isFocusMain = state.focusId == state.mainPillId || state.focusId == nil
            let showOutfit = isFocusMain || state.mode != .expanded || isWardrobe
            engine.setOutfit(showOutfit ? state.resolvedOutfit : .none, animated: false)
        }
    }

    /// Where Mochi looks (the pointer), both axes at once: the island geometry and the
    /// screen are looked up once per frame instead of twice each.
    private func lookXY(state: AppState) -> (x: CGFloat, y: CGFloat) {
        if let origin = lookOriginOverride {
            return (tanh((state.mousePosition.x - origin.x) / 260),
                    -tanh((state.mousePosition.y - origin.y) / 200))
        }
        let (islandW, islandH) = islandSize(mode: state.mode, view: state.view,
                                             progress: state.uploadProgress,
                                             nw: state.notchWidth, nh: state.notchHeight)
        let screen = IslandWindowController.islandScreen().frame
        let desktopTop = IslandWindowController.desktopTop
        // The pointer read now, not from the island poll (which slows down far from it).
        let mouse = DesktopSpace.topDown(NSEvent.mouseLocation, desktopTop: desktopTop)
        func botPoint(islandH: CGFloat) -> CGPoint {
            let (botCx, botCy, _, _) = botPosition(mode: state.mode, view: state.view,
                                                    islandW: islandW, islandH: islandH,
                                                    uploadProgress: state.uploadProgress)
            return DesktopSpace.topDown(CGPoint(x: screen.midX - islandW / 2 + botCx,
                                                y: screen.maxY - botCy),
                                        desktopTop: desktopTop)
        }
        let botX = botPoint(islandH: islandH)
        // The chat view grows with the conversation: vertical look uses its real height.
        let actualH: CGFloat = (state.mode == .expanded && state.view == .prompt)
            ? ChatLayout.height   // coucou-custom fork: measured (ChatFit)
            : islandH
        let botY = actualH == islandH ? botX : botPoint(islandH: actualH)
        return (tanh((mouse.x - botX.x) / 260),
                -tanh((mouse.y - botY.y) / 200))
    }
}

/// Mini bot canvas (for agent pills/column)
struct MiniBotCanvasView: View {
    let task: AgentTask
    var isDancing: Bool = false
    @StateObject private var engine: BotEngine

    init(task: AgentTask, isDancing: Bool = false) {
        self.task = task
        self.isDancing = isDancing
        _engine = StateObject(wrappedValue: {
            let e = BotEngine()
            e.isMini = true
            e.bodyColor = cgColorFromHex(task.color)
            return e
        }())
    }

    @Environment(\.islandViewActive) private var viewActive


    var body: some View {
        // Paused in island views that are not shown. A mini Mochi is a few points wide: 30
        // frames a second, 60 while it dances.
        let pace = MochiFrameClock.pacing(cap: isDancing ? MochiFrameClock.mainFPS : MochiFrameClock.miniFPS)
        TimelineView(.animation(minimumInterval: pace.interval, paused: !viewActive)) { timeline in
            let frame = timeline.date   // see BotCanvasView: redraw on every tick
            Canvas { context, size in
                _ = frame
                engine.setDancing(isDancing)
                MochiFrameClock.advance(engine, steps: pace.steps)
                var ctx = context
                engine.applyDance(&ctx, size: size)
                engine.draw(context: ctx, size: size)
            }
        }
        .onChange(of: task.state) { _, newState in
            engine.setState(newState)
        }
        // The colour is set once, when the engine is made: a colour picked in
        // Settings has to reach a mini Mochi that is already on screen.
        .onChange(of: task.color) { _, newColor in
            engine.bodyColor = cgColorFromHex(newColor)
        }
        .onAppear {
            engine.setState(task.state, force: true)
            if let emote = task.emote {
                engine.setPermanentEmote(emote)
            }
            // Direct eye override takes priority (e.g. .wide eyes for Research)
            if let eye = task.miniEye {
                engine.permanentEye = eye
                engine.eyeOverride = eye
                engine.eyeOverrideUntil = .greatestFiniteMagnitude
            }
        }
    }
}

// MARK: - Frame clock

/// Mochi's engine has always moved one `update(dt: 0.05)` per display frame (its look,
/// colour, springs and particles are tuned to that). Drawing slower than the display must
/// not slow Mochi down: each drawn frame runs the steps of the display frames it skipped.
@MainActor
enum MochiFrameClock {
    /// The island screen's refresh rate, looked up at most every 2 s.
    private static var fpsCache: (value: Double, at: CFTimeInterval) = (60, -10)
    static var displayFPS: Double {
        let now = CACurrentMediaTime()
        if now - fpsCache.at > 2 {
            let fps = IslandWindowController.islandScreen().maximumFramesPerSecond
            fpsCache = (Double(min(120, max(30, fps))), now)
        }
        return fpsCache.value
    }

    /// What a canvas draws per second at most. The engine's steps per second stay what the
    /// display's rate makes them (`pacing`), so Mochi moves as fast as ever: only the drawing
    /// is spread out. A drawn frame costs ~50 times a step (measured), and drawing every
    /// display frame, 120 a second on ProMotion, per Mochi was most of Coucou's CPU.
    static let mainFPS = 60.0
    static let miniFPS = 30.0

    static func pacing(cap: Double, display: Double = displayFPS) -> MochiPacing {
        MochiPacing(cap: cap, display: display)
    }

    /// One engine step per display frame, exactly as before the frame clock (9 October): a
    /// perfectly regular rhythm. The step-debt version measured the time between renders,
    /// and its jitter made frames with 0 steps (Mochi froze) and frames with 2 or more
    /// (Mochi jumped), several times a second: the stutter when the island opens and when
    /// Mochi follows the pointer. A canvas drawn every display frame runs one step; one
    /// capped below the display rate runs the same whole number every time.
    static func advance(_ engine: BotEngine, steps: Int = 1) {
        for _ in 0..<steps { engine.update(dt: 0.05) }
    }
}
