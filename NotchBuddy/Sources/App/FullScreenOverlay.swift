#if !APPSTORE
import AppKit
import Combine
import SwiftUI

// coucou-custom fork: Coucou's full-screen moments — a routine's alert (water, a reminder, a focus
// session starting or done, a timer) and the Daily brief — over a dimmed, blurred screen. While
// one shows, the desktop Buddy's companions tuck into its pouch and its card waits.

@MainActor
final class FullScreenOverlay {
    static let shared = FullScreenOverlay()

    private var window: FullScreenOverlayWindow?
    private var onKey: ((NSEvent) -> Bool)?
    private var keyMonitor: Any?
    private(set) var owner: String?
    /// Another owner's full screen, waiting for this one to close (a moment over the brief, the
    /// brief over a moment): never replaced, shown next.
    private var waiting: [(owner: String, show: () -> Void)] = []

    var isShowing: Bool { window != nil }

    /// The screen it opens on: the one under the pointer.
    static var targetScreen: NSScreen {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// `owner` names who shows it ("brief", "moment"), so one never closes the other's.
    /// The keyboard is taken only when Coucou already has it (it never steals your typing);
    /// otherwise a click on the overlay gives it.
    func present<V: View>(_ view: V, owner: String, dim: Double = 0.55,
                          takeKeyboard: Bool = NSApp.isActive, onKey: ((NSEvent) -> Bool)? = nil) {
        if window != nil, self.owner != owner {
            waiting.removeAll { $0.owner == owner }
            waiting.append((owner, { [weak self] in
                self?.present(view, owner: owner, dim: dim, takeKeyboard: takeKeyboard, onKey: onKey)
            }))
            return
        }
        close(animated: false, showNext: false)
        let screen = Self.targetScreen
        let w = FullScreenOverlayWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        // Under the Buddy's level (it stays over the dim, as for full-screen breathing).
        w.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        w.animationBehavior = .none
        w.setFrame(screen.frame, display: false)

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        let host = NSHostingView(rootView: ZStack {
            Color.black.opacity(dim).ignoresSafeArea()
            view
        }
        .environment(\.colorScheme, .dark))
        host.frame = blur.bounds
        host.autoresizingMask = [.width, .height]
        blur.addSubview(host)
        w.contentView = blur

        w.alphaValue = 0
        w.orderFrontRegardless()
        if takeKeyboard { w.makeKey() }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            w.animator().alphaValue = 1
        }
        window = w
        self.owner = owner
        self.onKey = onKey
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let w = self.window, event.window === w, let handler = self.onKey else { return false }
                return handler(event)
            }
            return handled ? nil : event
        }
        BuddyController.shared.setFullScreenShowing(true)
    }

    func close(owner: String? = nil, animated: Bool = true, showNext: Bool = true) {
        guard let w = window else {
            if let owner { waiting.removeAll { $0.owner == owner } }
            return
        }
        if let owner, owner != self.owner {
            waiting.removeAll { $0.owner == owner }
            return
        }
        window = nil
        self.owner = nil
        onKey = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        if showNext, !waiting.isEmpty {
            let next = waiting.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated { next.show() } }
        } else if showNext {
            // (Replaced by the same owner's next one, the companions stay tucked.)
            BuddyController.shared.setFullScreenShowing(false)
        }
        guard animated else { w.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            w.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                w.orderOut(nil)
                w.contentView = nil   // nothing keeps drawing once it is gone
            }
        })
    }
}

/// Takes the keyboard (Return, Esc, arrows) without making Coucou the active app.
final class FullScreenOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Routine moments

enum RoutineMomentKind: String, CaseIterable, Identifiable {
    case water, reminder, focusStart, focusDone, breakDone, timerStart, timerDone
    var id: String { rawValue }

    var title: String {
        switch self {
        case .water: "Water reminders"
        case .reminder: "Reminders"
        case .focusStart: "Focus session starts"
        case .focusDone: "Focus session done"
        case .breakDone: "Break over"
        case .timerStart: "Timer starts"
        case .timerDone: "Timer done"
        }
    }

    /// A start is a short moment that closes by itself; the others wait for you.
    var closesByItself: Bool { self == .focusStart || self == .timerStart }

    static func of(_ alert: BuddyAlert.Kind) -> RoutineMomentKind? {
        switch alert {
        case .water: .water
        case .reminder: .reminder
        case .focusDone: .focusDone
        case .breakDone: .breakDone
        case .timerDone: .timerDone
        case .greeting: nil
        }
    }
}

@MainActor
final class RoutineMomentSettings: ObservableObject {
    static let shared = RoutineMomentSettings()
    private let defaults = UserDefaults.standard

    /// Each one off until chosen: a full screen is a strong interruption.
    @Published var enabled: Set<RoutineMomentKind> {
        didSet { defaults.set(enabled.map(\.rawValue).sorted(), forKey: "routineMomentsFullScreen") }
    }
    /// Seconds a start stays up.
    @Published var startSeconds: Int { didSet { defaults.set(startSeconds, forKey: "routineMomentsStartSeconds") } }
    /// How dark the screen behind goes, 0.2…0.85.
    @Published var dim: Double { didSet { defaults.set(dim, forKey: "routineMomentsDim") } }

    static let startChoices = [2, 3, 5, 8]

    private init() {
        enabled = Set((defaults.stringArray(forKey: "routineMomentsFullScreen") ?? []).compactMap(RoutineMomentKind.init(rawValue:)))
        startSeconds = defaults.object(forKey: "routineMomentsStartSeconds") as? Int ?? 3
        dim = min(0.85, max(0.2, defaults.object(forKey: "routineMomentsDim") as? Double ?? 0.55))
    }

    func wants(_ kind: RoutineMomentKind) -> Bool { enabled.contains(kind) }

    func toggle(_ kind: RoutineMomentKind, _ on: Bool) {
        if on { enabled.insert(kind) } else { enabled.remove(kind) }
    }
}

@MainActor
final class RoutineMoments {
    static let shared = RoutineMoments()

    private var shownAlert: UUID?
    /// Alerts due while another one is on screen, shown one after the other.
    private var queue: [UUID] = []
    private var autoClose: DispatchWorkItem?
    private var watch: AnyCancellable?

    private init() {
        // Acted on anywhere else (the HUD, the panel, the chat): the full screen goes too.
        watch = BuddyRoutineController.shared.$alerts.receive(on: DispatchQueue.main).sink { [weak self] alerts in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.queue.removeAll { id in !alerts.contains { $0.id == id } }
                guard let id = self.shownAlert, !alerts.contains(where: { $0.id == id }) else { return }
                self.close(acted: true)
            }
        }
    }

    /// An alert that waits for you, full screen when chosen for its kind.
    func present(_ alert: BuddyAlert) {
        guard let kind = RoutineMomentKind.of(alert.kind), RoutineMomentSettings.shared.wants(kind) else { return }
        if shownAlert != nil {
            if !queue.contains(alert.id) { queue.append(alert.id) }
            return
        }
        shownAlert = alert.id
        show(RoutineMoment(kind: kind, alert: alert))
    }

    /// A focus session or a timer starting: a short moment, gone by itself. Never over an alert.
    func started(_ kind: RoutineMomentKind, title: String, detail: String) {
        guard RoutineMomentSettings.shared.wants(kind), shownAlert == nil else { return }
        show(RoutineMoment(kind: kind, alert: nil, startTitle: title, startDetail: detail))
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.close(acted: true) } }
        autoClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(RoutineMomentSettings.shared.startSeconds), execute: work)
    }

    /// Settings' "Try it": a water moment, gone after a few seconds, whatever is chosen.
    func preview() {
        guard shownAlert == nil else { return }
        show(RoutineMoment(kind: .water, alert: nil, startTitle: "Time for some water",
                           startDetail: "This is how a moment looks. It closes by itself."))
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.close(acted: true) } }
        autoClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func show(_ moment: RoutineMoment) {
        autoClose?.cancel()
        // The Buddy walks to the middle of that screen and stands in the ring, as for breathing.
        let radius = BuddyController.shared.visitCenter(of: FullScreenOverlay.targetScreen)
        let view = RoutineMomentView(moment: moment, buddyRadius: radius, perform: { [weak self] action in self?.perform(action) })
        FullScreenOverlay.shared.present(view, owner: "moment", dim: RoutineMomentSettings.shared.dim) { [weak self] event in
            self?.key(event, moment) ?? false
        }
    }

    /// A button or a key: the screen goes first, so whatever the action starts (a snoozed timer's
    /// own "Timer starts") can show.
    func perform(_ action: RoutineMoment.Action?) {
        close(acted: true)
        action?.run()
    }

    /// Closed without an answer while the Buddy is off: no card holds the alert, so it is
    /// retired (a reminder counts as shown, as the notch's note does) instead of lingering.
    func close(acted: Bool = false) {
        autoClose?.cancel()
        autoClose = nil
        if !acted, !BuddySettings.shared.enabled, let id = shownAlert,
           let alert = BuddyRoutineController.shared.alerts.first(where: { $0.id == id }) {
            BuddyRoutineController.shared.retire(alert)
        }
        shownAlert = nil
        FullScreenOverlay.shared.close(owner: "moment")
        BuddyController.shared.leaveCenter()
        showNextQueued()
    }

    private func showNextQueued() {
        let alerts = BuddyRoutineController.shared.alerts
        while !queue.isEmpty {
            let id = queue.removeFirst()
            if let next = alerts.first(where: { $0.id == id }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    MainActor.assumeIsolated { self?.present(next) }
                }
                return
            }
        }
    }

    /// Return: the main action. Esc: the gentle one (later, snooze), or just close.
    private func key(_ event: NSEvent, _ m: RoutineMoment) -> Bool {
        switch event.keyCode {
        case 36, 76: perform(m.primary); return true
        case 53:   // Esc
            if let s = m.secondary { perform(s) } else { close() }
            return true
        default: return false
        }
    }
}

struct RoutineMoment {
    let kind: RoutineMomentKind
    let alert: BuddyAlert?
    var startTitle = ""
    var startDetail = ""

    struct Action {
        let title: String
        let run: () -> Void
    }

    @MainActor var title: String { alert?.title ?? startTitle }
    @MainActor var detail: String { alert?.detail ?? startDetail }

    var tint: Color {
        switch kind {
        case .water: Color(hex: "#22D3EE")
        case .reminder: Color(hex: "#F472B6")
        case .focusStart: Color(hex: "#818CF8")
        case .focusDone, .breakDone: Color(hex: "#34D399")
        case .timerStart, .timerDone: Color(hex: "#F7B32B")
        }
    }

    var mochiState: BotState {
        switch kind {
        case .focusDone, .timerDone: .finished
        case .reminder: .question
        case .focusStart, .timerStart: .working
        case .water, .breakDone: .idle
        }
    }

    /// The ring around Mochi: water drunk today, or full for a done moment.
    @MainActor var progress: Double? {
        switch kind {
        case .water:
            let s = BuddyRoutineSettings.shared
            return Double(s.waterLog.total(on: Date())) / Double(max(1, s.waterPlan.goal))
        case .focusDone, .timerDone, .breakDone: return 1
        default: return nil
        }
    }

    /// The buttons, in order; the last is the main one (Return).
    @MainActor var actions: [Action] {
        let r = BuddyRoutineController.shared
        guard let a = alert else { return [Action(title: "OK") {}] }
        switch a.kind {
        case .water:
            return [Action(title: "Skip") { r.dismiss(a) }, Action(title: "Later") { r.snoozeWater() },
                    Action(title: "+\(BuddyWater.amount(BuddyRoutineSettings.shared.waterPlan.glass))") { r.act(on: a) }]
        case .reminder:
            return [Action(title: "Snooze 5 min") { r.act(on: a) }, Action(title: "Done") { r.dismiss(a) }]
        case .timerDone:
            return [Action(title: "Snooze 5 min") { r.act(on: a) }, Action(title: "Dismiss") { r.dismiss(a) }]
        case .breakDone:
            return [Action(title: "End") { r.endFocus() }, Action(title: "Start focus") { r.act(on: a) }]
        case .focusDone, .greeting:
            return [Action(title: "OK") { r.dismiss(a) }]
        }
    }

    @MainActor var primary: Action? { actions.last }
    /// Esc: the gentle choice — later, snooze, OK. Never "End" (a break over closes the screen
    /// only, the alert stays on the Buddy's card).
    @MainActor var secondary: Action? {
        switch alert?.kind {
        case .water: return actions.count > 1 ? actions[1] : nil   // Later
        case .reminder, .timerDone: return actions.first            // Snooze 5 min
        case .breakDone: return nil
        default: return actions.last
        }
    }
}

/// As Claude Design drew the routine alerts: a glow in the moment's colour, a ring (water drunk
/// today, or full for a done moment) with Mochi in it, the title, its line, the buttons and their
/// keys. The ring sits in the screen's middle: the desktop Buddy comes to stand in it, as it does
/// for full-screen breathing (`buddyRadius`); without the Buddy, the design's Mochi is drawn there.
struct RoutineMomentView: View {
    let moment: RoutineMoment
    /// The ring's radius around the Buddy standing in the middle; nil: the ring holds its own Mochi.
    var buddyRadius: CGFloat? = nil
    let perform: (RoutineMoment.Action) -> Void
    @State private var appeared = false

    private var radius: CGFloat { buddyRadius ?? 116 }

    private var mochiMode: DesignMochi.Mode {
        switch moment.kind {
        case .water, .timerDone: .hop
        case .focusDone: .joy
        case .focusStart, .timerStart: .calm
        case .reminder, .breakDone: .idle
        }
    }

    var body: some View {
        GeometryReader { g in
            let center = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            ZStack {
                RadialGradient(colors: [moment.tint.opacity(0.18), .clear], center: .center, startRadius: 0, endRadius: 450)
                    .frame(width: 900, height: 900)
                    .position(center)
                    .allowsHitTesting(false)
                ring.position(center)
                info.frame(width: min(760, g.size.width - 80))
                    .padding(.top, center.y + radius + 28)
                    .frame(width: g.size.width, height: g.size.height, alignment: .top)
            }
        }
        .ignoresSafeArea()
        .foregroundColor(HubTheme.text)
        .onAppear {
            withAnimation(BriefLayout.spring) { appeared = true }
        }
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 8)
            Circle().trim(from: 0, to: appeared ? CGFloat(max(0.02, min(1, moment.progress ?? 0))) : 0)
                .stroke(moment.tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(moment.progress == nil ? 0 : 1)
                .animation(BriefLayout.spring.delay(0.3), value: appeared)
            if buddyRadius == nil {
                DesignMochi(size: 132, mode: mochiMode).padding(.top, 16)
            }
        }
        .frame(width: radius * 2, height: radius * 2)
        .scaleEffect(appeared ? 1 : 0.92)
        .opacity(appeared ? 1 : 0)
    }

    private var info: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Text(moment.title)
                    .font(.system(size: 38, weight: .bold)).tracking(-0.76)
                    .multilineTextAlignment(.center)
                if !moment.detail.isEmpty {
                    Text(moment.detail).font(.system(size: 17).monospacedDigit()).foregroundColor(Color(hex: "#8E939C"))
                        .multilineTextAlignment(.center)
                }
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 14)
            .animation(BriefLayout.spring.delay(0.12), value: appeared)

            if moment.alert != nil {
                HStack(spacing: 12) {
                    ForEach(Array(moment.actions.enumerated()), id: \.offset) { i, action in
                        let main = i == moment.actions.count - 1
                        Button { perform(action) } label: {
                            Text(action.title)
                                .font(.system(size: 17, weight: .bold))
                                .foregroundColor(main ? Color(hex: "#06131A") : Color(hex: "#F5F6F8"))
                                .padding(.horizontal, 30).frame(height: 52)
                                .background(Capsule().fill(main ? moment.tint : Color.white.opacity(0.1)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(BriefPress())
                    }
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 20)
                .animation(BriefLayout.spring.delay(0.2), value: appeared)
                HStack(spacing: 24) {
                    if let p = moment.primary { keyHint("Return", p.title) }
                    if let s = moment.secondary, moment.actions.count > 1 { keyHint("Esc", s.title) }
                    else if moment.secondary == nil { keyHint("Esc", "Close") }
                }
                .opacity(appeared ? 1 : 0)
                .animation(.easeOut(duration: 0.4).delay(0.3), value: appeared)
            }
        }
    }

    private func keyHint(_ key: String, _ what: String) -> some View {
        HStack(spacing: 8) {
            Text(key).font(.system(size: 13, weight: .semibold)).foregroundColor(Color(hex: "#E1E3E6"))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1)))
            Text(what).font(.system(size: 13)).foregroundColor(Color(hex: "#8E939C"))
        }
    }
}
#endif
