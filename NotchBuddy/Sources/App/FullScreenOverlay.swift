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

    /// What Settings' Try shows for it.
    @MainActor var sample: (title: String, detail: String) {
        switch self {
        case .water:
            let s = BuddyRoutineSettings.shared
            return ("Time for some water", "\(BuddyWater.amount(s.waterLog.total(on: Date()))) of \(BuddyWater.amount(s.waterPlan.goal)) today")
        case .reminder: return ("Call Sam", "Reminder")
        case .focusStart: return ("Focus starts now", "\(BuddyRoutineSettings.shared.focusPlan.focus) min")
        case .focusDone: return ("Focus session done", "Time for a break")
        case .breakDone: return ("Break over", "Ready for the next session?")
        case .timerStart: return ("Timer started", "5 min")
        case .timerDone: return ("Timer done", "5 min")
        }
    }

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

    /// Where each kind shows; the Buddy's card until chosen (a full screen is a strong interruption).
    @Published private(set) var styles: [RoutineMomentKind: RoutineAlertStyle] {
        didSet { defaults.set(Dictionary(uniqueKeysWithValues: styles.map { ($0.key.rawValue, $0.value.rawValue) }), forKey: Self.stylesKey) }
    }
    private static let stylesKey = "routineAlertStyles"
    /// Seconds a start stays up.
    @Published var startSeconds: Int { didSet { defaults.set(startSeconds, forKey: "routineMomentsStartSeconds") } }
    /// How dark the screen behind goes, 0.2…0.85.
    @Published var dim: Double { didSet { defaults.set(dim, forKey: "routineMomentsDim") } }

    static let startChoices = [2, 3, 5, 8]

    private init() {
        if let stored = defaults.dictionary(forKey: Self.stylesKey) as? [String: String] {
            styles = Dictionary(uniqueKeysWithValues: stored.compactMap { k, v in
                guard let kind = RoutineMomentKind(rawValue: k), let style = RoutineAlertStyle(rawValue: v) else { return nil }
                return (kind, style)
            })
        } else {
            // The first build kept only which kinds go full screen.
            let full = (defaults.stringArray(forKey: "routineMomentsFullScreen") ?? []).compactMap(RoutineMomentKind.init(rawValue:))
            styles = Dictionary(uniqueKeysWithValues: full.map { ($0, .fullScreen) })
        }
        startSeconds = defaults.object(forKey: "routineMomentsStartSeconds") as? Int ?? 3
        dim = min(0.85, max(0.2, defaults.object(forKey: "routineMomentsDim") as? Double ?? 0.55))
    }

    func style(_ kind: RoutineMomentKind) -> RoutineAlertStyle { styles[kind] ?? .buddy }

    /// Where it shows now: the Buddy's card goes to the notch while the Buddy is hidden.
    func shownStyle(_ kind: RoutineMomentKind) -> RoutineAlertStyle {
        style(kind).resolved(buddyShown: BuddySettings.shared.enabled)
    }

    func wants(_ kind: RoutineMomentKind) -> Bool { style(kind) == .fullScreen }

    func set(_ kind: RoutineMomentKind, _ style: RoutineAlertStyle) { styles[kind] = style }
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
        // A shown id whose alert is gone (coucou-custom fork): nothing is on screen for it, and
        // every later moment would queue behind it for good.
        if let id = shownAlert, !BuddyRoutineController.shared.alerts.contains(where: { $0.id == id }) {
            appendAppLog("buddy.log", "moment: stale shown alert cleared")
            shownAlert = nil
        }
        if shownAlert != nil {
            if !queue.contains(alert.id) { queue.append(alert.id) }
            appendAppLog("buddy.log", "moment: \(kind) queued behind the one on screen")
            return
        }
        shownAlert = alert.id
        show(RoutineMoment(kind: kind, alert: alert))
    }

    /// A focus session or a timer starting: a short moment, gone by itself. Never over an alert.
    /// Set to the notch, the notch says it; on the Buddy, its card already shows it running.
    func started(_ kind: RoutineMomentKind, title: String, detail: String) {
        if RoutineMomentSettings.shared.shownStyle(kind) == .notch {
            RoutineNotchModel.shared.show(RoutineMoment(kind: kind, alert: nil, startTitle: title, startDetail: detail))
            return
        }
        guard RoutineMomentSettings.shared.wants(kind), shownAlert == nil else { return }
        show(RoutineMoment(kind: kind, alert: nil, startTitle: title, startDetail: detail))
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.close(acted: true) } }
        autoClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(RoutineMomentSettings.shared.startSeconds), execute: work)
    }

    /// Settings' Try: a moment, gone after a few seconds, whatever is chosen; it does nothing.
    func preview(_ kind: RoutineMomentKind = .water) {
        guard shownAlert == nil else { return }
        show(RoutineMoment.sample(kind))
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.close(acted: true) } }
        autoClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func show(_ moment: RoutineMoment) {
        autoClose?.cancel()
        let view = RoutineMomentView(moment: moment, perform: { [weak self] action in self?.perform(action) })
        FullScreenOverlay.shared.present(view, owner: "moment", dim: RoutineMomentSettings.shared.dim) { [weak self] event in
            self?.key(event, moment) ?? false
        }
    }

    /// A button or a key: the screen goes first, so whatever the action starts (a snoozed timer's
    /// own "Timer starts") can show.
    func perform(_ action: RoutineMoment.Action?) {
        guard let action else { close(acted: true); return }
        if action.keepsOpen { action.run(); return }
        close(acted: true)
        action.run()
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

/// One routine alert, as all three places draw it — the Buddy's card, the notch's card, the full
/// screen: its colour and icon, its words, its ring, its quick actions (some keep it up: water's
/// glasses), and the buttons that close it.
struct RoutineMoment {
    let kind: RoutineMomentKind
    let alert: BuddyAlert?
    var startTitle = ""
    var startDetail = ""
    /// Settings' Try with no alert behind it (a start): its buttons do nothing.
    var preview = false

    struct Action {
        let title: String
        /// Acts and stays: the moment is closed by another button (water's glasses).
        var keepsOpen = false
        var symbol: String? = nil
        let run: () -> Void
    }

    var isPreview: Bool { preview || alert?.isPreview == true }

    @MainActor var title: String { alert?.title ?? startTitle }

    /// Water's total follows each glass logged; the others say what their alert said.
    @MainActor var detail: String {
        guard kind == .water else { return alert?.detail ?? startDetail }
        let s = BuddyRoutineSettings.shared
        return "\(BuddyWater.amount(s.waterLog.total(on: Date()))) of \(BuddyWater.amount(s.waterPlan.goal)) today"
    }

    var tint: Color {
        switch kind {
        case .water: Color(hex: "#22D3EE")
        case .reminder: Color(hex: "#F472B6")
        case .focusStart: Color(hex: "#818CF8")
        case .focusDone, .breakDone: Color(hex: "#34D399")
        case .timerStart, .timerDone: Color(hex: "#F7B32B")
        }
    }

    var symbol: String {
        switch kind {
        case .water: "drop.fill"
        case .reminder: "bell.fill"
        case .focusStart: "brain.head.profile"
        case .focusDone: "cup.and.saucer.fill"
        case .breakDone: "brain.head.profile"
        case .timerStart, .timerDone: "timer"
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

    /// The ring: water drunk today, full for a done moment, none for a reminder or a start.
    @MainActor var progress: Double? {
        switch kind {
        case .water:
            let s = BuddyRoutineSettings.shared
            return Double(s.waterLog.total(on: Date())) / Double(max(1, s.waterPlan.goal))
        case .focusDone, .timerDone, .breakDone: return 1
        default: return nil
        }
    }

    /// An action that does nothing in a preview.
    private func action(_ title: String, keepsOpen: Bool = false, symbol: String? = nil, _ run: @escaping () -> Void) -> Action {
        let preview = isPreview
        return Action(title: title, keepsOpen: keepsOpen, symbol: symbol) { if !preview { run() } }
    }

    /// The quick actions, a row of their own: water's glasses (it stays up for another), a
    /// reminder's snoozes, a timer's again, a focus session's next step.
    @MainActor var quick: [Action] {
        let r = BuddyRoutineController.shared
        switch kind {
        case .water:
            let glass = BuddyRoutineSettings.shared.waterPlan.glass
            return [glass, glass * 2, 1000].map { ml in
                action("+\(BuddyWater.amount(ml))", keepsOpen: true, symbol: "drop.fill") { r.logWater(ml, keepOpen: true) }
            }
        case .reminder:
            guard case .reminder(let id)? = alert?.kind else { return [] }
            return [(5, "5 min"), (15, "15 min"), (60, "1 hour")].map { m, label in
                action(label, symbol: "zzz") { _ = r.snoozeReminder(id, minutes: m) }
            }
        case .timerDone:
            return [action("+1 min", symbol: "goforward") { r.rerunTimer(minutes: 1) },
                    action("+5 min", symbol: "goforward.5") { r.rerunTimer(minutes: 5) },
                    action("Again", symbol: "arrow.counterclockwise") { r.rerunTimer(minutes: nil) }]
        case .focusDone:
            return [action("Skip the break", symbol: "forward.fill") { r.skipFocus() },
                    action("End the session", symbol: "stop.fill") { r.endFocus() }]
        case .breakDone:
            return []
        case .focusStart:
            return [action("Pause", symbol: "pause.fill") { r.pauseFocus() },
                    action("End", symbol: "stop.fill") { r.endFocus() }]
        case .timerStart:
            return [action("+1 min", keepsOpen: true, symbol: "goforward") { r.addToTimer(60) },
                    action("Cancel", symbol: "xmark") { r.cancelTimer() }]
        }
    }

    /// The buttons that close it, in order; the last is the main one.
    @MainActor var actions: [Action] {
        let r = BuddyRoutineController.shared
        guard let a = alert else { return [action("OK") {}] }
        switch a.kind {
        case .water: return [action("Later") { r.snoozeWater() }, action("Done") { r.dismiss(a) }]
        case .reminder: return [action("Done") { r.dismiss(a) }]
        case .timerDone: return [action("Done") { r.dismiss(a) }]
        case .breakDone: return [action("End") { r.endFocus() }, action("Start focus") { r.act(on: a) }]
        case .focusDone, .greeting: return [action("OK") { r.dismiss(a) }]
        }
    }

    /// Return: water logs a glass (and stays); the others, their main button.
    @MainActor var primary: Action? { kind == .water ? quick.first : actions.last }
    /// Esc: the gentle choice — done, a snooze, OK. Never "End" (a break over closes the screen
    /// only, the alert stays on the Buddy's card).
    @MainActor var secondary: Action? {
        switch kind {
        case .reminder: return quick.first   // Snooze 5 min
        case .breakDone: return nil
        default: return actions.last
        }
    }

    /// Settings' Try: a sample of the kind, its buttons idle.
    @MainActor static func sample(_ kind: RoutineMomentKind) -> RoutineMoment {
        let s = kind.sample
        let alertKind: BuddyAlert.Kind? = switch kind {
        case .water: .water
        case .reminder: .reminder(id: "preview")
        case .focusDone: .focusDone
        case .breakDone: .breakDone
        case .timerDone: .timerDone
        case .focusStart, .timerStart: nil
        }
        if let alertKind {
            return RoutineMoment(kind: kind, alert: BuddyAlert(kind: alertKind, title: s.title, detail: s.detail, isPreview: true))
        }
        return RoutineMoment(kind: kind, alert: nil, startTitle: s.title, startDetail: s.detail, preview: true)
    }
}

/// As Claude Design drew the routine alerts: a glow in the moment's colour, a ring (water drunk
/// today, or full for a done moment) with the design's Mochi in it, the title, its line, the
/// buttons and their keys. The desktop Buddy stays where it is: a moment is short, unlike
/// full-screen breathing, which it walks to the middle for.
struct RoutineMomentView: View {
    let moment: RoutineMoment
    let perform: (RoutineMoment.Action) -> Void
    @State private var appeared = false
    /// Water's total and ring follow each glass logged here.
    @ObservedObject private var water = BuddyRoutineSettings.shared
    /// Today's water when the moment came: what was poured since shows beside the total.
    @State private var startTotal: Int?

    private let radius: CGFloat = 116

    private var detail: String {
        guard moment.kind == .water else { return moment.detail }
        let today = water.waterLog.total(on: Date())
        let poured = today - (startTotal ?? today)
        return moment.detail + (poured > 0 ? " · +\(BuddyWater.amount(poured)) just now" : "")
    }

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
            startTotal = water.waterLog.total(on: Date())
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
            DesignMochi(size: 132, mode: mochiMode).padding(.top, 16)
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
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 17).monospacedDigit()).foregroundColor(Color(hex: "#8E939C"))
                        .multilineTextAlignment(.center)
                        .contentTransition(.numericText())
                        .animation(BriefLayout.spring, value: detail)
                }
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 14)
            .animation(BriefLayout.spring.delay(0.12), value: appeared)

            if !moment.quick.isEmpty {
                HStack(spacing: 12) {
                    ForEach(Array(moment.quick.enumerated()), id: \.offset) { i, log in
                        Button { perform(log) } label: {
                            Label(log.title, systemImage: log.symbol ?? moment.symbol)
                                .font(.system(size: 17, weight: .bold))
                                .foregroundColor(i == 0 && moment.kind == .water ? Color(hex: "#06131A") : moment.tint)
                                .padding(.horizontal, 26).frame(height: 52)
                                .background(Capsule().fill(i == 0 && moment.kind == .water ? moment.tint : moment.tint.opacity(0.14)))
                                .overlay(Capsule().strokeBorder(moment.tint.opacity(i == 0 && moment.kind == .water ? 0 : 0.45)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(BriefPress())
                    }
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 20)
                .animation(BriefLayout.spring.delay(0.16), value: appeared)
            }

            if moment.alert != nil || !moment.quick.isEmpty {
                HStack(spacing: 12) {
                    ForEach(Array(moment.actions.enumerated()), id: \.offset) { i, action in
                        // With water's glasses first, Done is a quiet button.
                        let main = moment.kind != .water && i == moment.actions.count - 1
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
