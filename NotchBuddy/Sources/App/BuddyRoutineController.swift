#if !APPSTORE
import AppKit
import Combine

// coucou-custom fork: runs the Buddy's routines (BuddyRoutines) — reminders, the focus timer, the
// simple timer, water nudges, breathing, the launch greeting — for its menu, its HUD and the notch
// chat's tools. A 1 Hz tick only while a focus session or a timer runs (4 Hz while breathing, for its
// cues); reminders and
// water wait on one timer set for the next one due. Nothing runs otherwise.
//
// Alerts show on the Buddy's HUD until you act on them; with the Buddy hidden, in the notch.

/// Something that wants your attention: shown on the HUD with its buttons.
struct BuddyAlert: Identifiable, Equatable {
    enum Kind: Equatable {
        case reminder(id: String)
        case timerDone
        case focusDone
        case breakDone
        case water
        case greeting
    }

    let id = UUID()
    let kind: Kind
    let title: String
    var detail: String = ""
    /// Gone on its own after this long; nil stays until dismissed.
    var autoDismiss: TimeInterval?
    /// Settings' Try (coucou-custom fork): shown as the real one, its buttons do nothing.
    var isPreview = false
}

@MainActor
final class BuddyRoutineController: ObservableObject {
    static let shared = BuddyRoutineController()

    let settings = BuddyRoutineSettings.shared

    @Published private(set) var reminders: [BuddyReminder] = []
    @Published private(set) var focus: BuddyFocusSession?
    @Published private(set) var countdown: BuddyCountdown?
    /// The breathing session, shown in its own panel (BuddyCalmView) until closed.
    @Published private(set) var breathing: BuddyBreathSession? {
        didSet { if breathing == nil { BuddyController.shared.setBreath(1) } }
    }
    @Published private(set) var alerts: [BuddyAlert] = []
    /// The tick's clock, for the HUD's text.
    @Published private(set) var now = Date.now

    private var tickTimer: Timer?
    private var dueTimer: Timer?
    private var nextWater: Date?
    private var started = false
    private var cancellables: Set<AnyCancellable> = []

    private static let anyInput = CGEventType(rawValue: ~0)!

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        reminders = BuddyReminders.sorted(settings.reminders)
        // Water and the plan follow Settings at once.
        settings.$waterEnabled.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.resetWater() } }
            .store(in: &cancellables)
        settings.$waterPlan.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.resetWater() } }
            .store(in: &cancellables)
        resetWater()
        // Reminders that came due while Coucou was closed: missed, shown now.
        fireDue()
        if settings.launchGreeting {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                MainActor.assumeIsolated { self?.greet(sound: self?.settings.launchGreetingSound ?? false) }
            }
        }
    }

    /// Something is running or waiting: the HUD has something to show.
    var hasHUD: Bool { focus != nil || countdown != nil || !alerts.isEmpty }

    // MARK: - Reminders

    @discardableResult
    func addReminder(_ text: String, due: Date) -> BuddyReminder? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, reminders.count < BuddyReminders.maxCount else { return nil }
        let r = BuddyReminder(text: String(t.prefix(200)), due: due)
        reminders = BuddyReminders.sorted(reminders + [r])
        saveReminders()
        return r
    }

    func reminder(_ id: String) -> BuddyReminder? {
        reminders.first { $0.id == id.lowercased() }
    }

    @discardableResult
    func removeReminder(_ id: String) -> Bool {
        let before = reminders.count
        reminders.removeAll { $0.id == id.lowercased() }
        inNotch.remove(id.lowercased())
        dropAlerts { $0 == .reminder(id: id.lowercased()) }
        saveReminders()
        return reminders.count != before
    }

    @discardableResult
    func snoozeReminder(_ id: String, minutes: Int = BuddyReminders.snoozeMinutes) -> BuddyReminder? {
        guard let i = reminders.firstIndex(where: { $0.id == id.lowercased() }) else { return nil }
        reminders[i].due = Date.now.addingTimeInterval(TimeInterval(max(1, minutes) * 60))
        reminders[i].snoozes += 1
        let r = reminders[i]
        inNotch.remove(r.id)
        reminders = BuddyReminders.sorted(reminders)
        dropAlerts { $0 == .reminder(id: r.id) }
        saveReminders()
        return r
    }

    /// Reminders due and showing in the notch's card (coucou-custom fork): not raised again until
    /// you snooze or end them, or Coucou restarts.
    private var inNotch: Set<String> = []

    func clearReminders() {
        reminders = []
        dropAlerts { if case .reminder = $0 { true } else { false } }
        saveReminders()
    }

    private func saveReminders() {
        settings.reminders = reminders
        scheduleDue()
    }

    // MARK: - Focus Buddy

    func startFocus(minutes: Int? = nil, breakMinutes: Int? = nil) {
        var plan = settings.focusPlan
        if let minutes { plan.focus = min(max(minutes, BuddyFocusPlan.focusRange.lowerBound), BuddyFocusPlan.focusRange.upperBound) }
        if let breakMinutes { plan.shortBreak = min(max(breakMinutes, BuddyFocusPlan.breakRange.lowerBound), BuddyFocusPlan.breakRange.upperBound) }
        focus = .start(plan, at: .now)
        dropAlerts { $0 == .focusDone || $0 == .breakDone }
        BuddyController.shared.react(.started)
        updateTick()
        RoutineMoments.shared.started(.focusStart, title: "Focus starts now",   // coucou-custom fork: full screen
                                      detail: "\(plan.focus) minutes, then a \(plan.shortBreak) min break")
    }

    func pauseFocus() { focus?.pause(at: .now); updateTick() }
    func resumeFocus() {
        focus?.resume(at: .now)
        dropAlerts { $0 == .breakDone }
        updateTick()
    }

    /// To the break, or from the break to the next focus session.
    func skipFocus() {
        focus?.advance(at: .now)
        dropAlerts { $0 == .focusDone || $0 == .breakDone }
        updateTick()
    }

    func endFocus() {
        focus = nil
        dropAlerts { $0 == .focusDone || $0 == .breakDone }
        updateTick()
    }

    // MARK: - Simple Timer

    @discardableResult
    func startTimer(seconds: TimeInterval, label: String = "") -> Bool {
        guard let c = BuddyCountdown.start(seconds: seconds, label: label.trimmingCharacters(in: .whitespaces), at: .now)
        else { return false }
        countdown = c
        dropAlerts { $0 == .timerDone }
        BuddyController.shared.react(.started)
        updateTick()
        RoutineMoments.shared.started(.timerStart, title: c.label.isEmpty ? "Timer started" : c.label,   // coucou-custom fork
                                      detail: BuddyTimeText.duration(c.total))
        return true
    }

    func pauseTimer() { countdown?.pause(at: .now); updateTick() }
    func resumeTimer() { countdown?.resume(at: .now); updateTick() }
    func addToTimer(_ seconds: TimeInterval) { countdown?.add(seconds, at: .now); updateTick() }

    func cancelTimer() {
        countdown = nil
        dropAlerts { $0 == .timerDone }
        updateTick()
    }

    /// A finished timer again (coucou-custom fork's quick actions): for `minutes`, or as long as it
    /// was (nil), with its label.
    func rerunTimer(minutes: Int?) {
        dropAlerts { $0 == .timerDone }
        startTimer(seconds: minutes.map { TimeInterval($0 * 60) } ?? lastTimerTotal, label: lastTimerLabel)
    }

    private var lastTimerTotal: TimeInterval = 300

    /// "Snooze 5 minutes" on a finished timer: it runs again.
    func snoozeTimer() {
        let label = lastTimerLabel
        dropAlerts { $0 == .timerDone }
        startTimer(seconds: 300, label: label)
    }

    private var lastTimerLabel = ""

    // MARK: - Water

    private func resetWater() {
        nextWater = settings.waterEnabled ? BuddyWater.next(after: .now, plan: settings.waterPlan) : nil
        if !settings.waterEnabled { dropAlerts { $0 == .water } }
        scheduleDue()
    }

    var nextWaterNudge: Date? { nextWater }

    /// Drunk today, in millilitres.
    var waterToday: Int { settings.waterLog.total(on: .now) }

    /// A glass (or `ml`) drunk: logged for today; reaching the goal is celebrated.
    /// `keepOpen` (coucou-custom fork): the water reminder stays up, for another glass; its Done
    /// closes it. Otherwise logging answers the reminder, as before.
    func logWater(_ ml: Int? = nil, keepOpen: Bool = false) {
        let amount = ml ?? settings.waterPlan.glass
        let before = waterToday
        var log = settings.waterLog
        log.add(amount, on: .now)
        settings.waterLog = log
        if keepOpen { waterLoggedAt = .now } else { dropAlerts { $0 == .water } }
        let goal = settings.waterPlan.goal
        if amount > 0, before < goal, waterToday >= goal {
            BuddyController.shared.celebrate("Water goal reached! \(BuddyWater.amount(goal)) 💧")
        } else if amount > 0 {
            BuddyController.shared.react(.done)
        }
        objectWillChange.send()
        updateTick()
    }

    /// The nudge again in a while.
    /// The last glass logged from an open reminder: it is not closed by itself while you log.
    private var waterLoggedAt: Date?

    func snoozeWater() {
        dropAlerts { $0 == .water }
        nextWater = Date.now.addingTimeInterval(TimeInterval(BuddyWater.snoozeMinutes * 60))
        scheduleDue()
        updateTick()
    }

    // MARK: - Breathing

    /// Full screen (the Buddy in the middle, the screen dimmed) or the card by the Buddy.
    @Published private(set) var breathingFull = false

    func setBreathingFull(_ on: Bool) {
        guard breathing != nil, on != breathingFull else { return }
        breathingFull = on
    }

    /// Opens the breathing session on `pattern`; `autoStart` false waits for Start.
    func startBreathing(_ pattern: BuddyBreathing, autoStart: Bool = true) {
        if breathing == nil { breathingFull = settings.breathingFullScreen }
        var s = BuddyBreathSession(pattern: pattern, at: .now)
        if !autoStart { s.pause(at: .now) }
        breathing = s
        breathCue = nil
        breathDone = false
        settings.lastBreathing = pattern
        updateBreathTick()
    }

    func pauseBreathing() { breathing?.pause(at: .now); updateBreathTick() }
    func resumeBreathing() { breathing?.resume(at: .now); updateBreathTick() }

    func restartBreathing(_ pattern: BuddyBreathing? = nil) {
        let paused = breathing?.isPaused ?? false
        breathing?.restart(pattern, at: .now)
        if paused { breathing?.pause(at: .now) }
        if let pattern { settings.lastBreathing = pattern }
        breathCue = nil
        breathDone = false
        updateBreathTick()
    }

    /// Closes the session.
    func stopBreathing() {
        breathingFull = false
        breathing = nil
        updateBreathTick()
    }

    private var breathTimer: Timer?
    /// The step last cued (cycle, step index), so each step sounds once.
    private var breathCue: (Int, Int)?
    private var breathDone = false

    private func updateBreathTick() {
        let running = breathing.map { !$0.isPaused } ?? false
        if running, breathTimer == nil {
            let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.breathTick() }
            }
            t.tolerance = 0.05
            RunLoop.main.add(t, forMode: .common)
            breathTimer = t
        } else if !running {
            breathTimer?.invalidate()
            breathTimer = nil
        }
    }

    private func breathTick() {
        guard let s = breathing else { return updateBreathTick() }
        switch s.phase(at: .now) {
        case .settling: break
        case .breathing(let pos):
            if breathCue.map({ $0 != (pos.cycle, pos.index) }) ?? true {
                breathCue = (pos.cycle, pos.index)
                if settings.breathingCues, pos.step == .inhale || pos.step == .exhale {
                    SoundEngine.shared.play(pos.step == .inhale ? "peek" : "pop")
                }
            }
        case .done:
            if !breathDone {
                breathDone = true
                BuddyDiaryStore.record { $0.breathingSessions += 1 }   // coucou-custom fork: the Daily brief
                BuddyController.shared.react(.done)
                if settings.breathingCues { SoundEngine.shared.play("proud") }
                BuddyController.shared.setBreath(1)
            }
            breathTimer?.invalidate()
            breathTimer = nil
        }
    }

    // MARK: - Launch Buddy

    func greet(sound: Bool = true) {
        let line = BuddyGreeting.line(hour: Calendar.current.component(.hour, from: .now), name: resolveUserFirstName())
        if sound { SoundEngine.shared.play("greeting") }
        if BuddySettings.shared.enabled {
            BuddyController.shared.greet(line)
        }
    }

    // MARK: - Alerts

    /// Settings' Try (coucou-custom fork): a sample of the kind's alert where it is set to show —
    /// the Buddy's card, the notch or full screen — that logs, snoozes and starts nothing.
    func previewAlert(_ kind: RoutineMomentKind) {
        let sample = RoutineMoment.sample(kind)
        switch RoutineMomentSettings.shared.shownStyle(kind) {
        case .fullScreen:
            RoutineMoments.shared.preview(kind)
        case .notch:
            RoutineNotchModel.shared.show(sample)
        case .buddy:
            // Its own card, its buttons idle; a start, which has none on the Buddy, as a plain one.
            let alert = sample.alert ?? BuddyAlert(kind: .greeting, title: sample.title, detail: sample.detail + " · a preview")
            alerts.append(alert)
            BuddyController.shared.react(.alert)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let a = self.alerts.first(where: { $0.id == alert.id }) else { return }
                    self.dismiss(a)
                }
            }
        }
    }

    /// A preview's card closed: no reminder done, nothing recorded.
    func withdraw(_ alert: BuddyAlert) {
        alerts.removeAll { $0.id == alert.id }
    }

    func dismiss(_ alert: BuddyAlert) {
        alerts.removeAll { $0.id == alert.id }
        if case .reminder(let id) = alert.kind {
            inNotch.remove(id)
            BuddyDiaryStore.record { $0.remindersDone += 1 }
            reminders.removeAll { $0.id == id }
            saveReminders()
        }
        updateTick()
    }

    /// coucou-custom fork: an alert shown full screen and closed unanswered while there is no
    /// Buddy to keep it: gone, as the notch's one-time note is (a reminder leaves the list, not
    /// counted as done).
    func retire(_ alert: BuddyAlert) {
        alerts.removeAll { $0.id == alert.id }
        if case .reminder(let id) = alert.kind {
            reminders.removeAll { $0.id == id }
            saveReminders()
        }
        updateTick()
    }

    /// The HUD's second button on an alert: snooze, or start the next focus session.
    func act(on alert: BuddyAlert) {
        switch alert.kind {
        case .reminder(let id): snoozeReminder(id)
        case .timerDone: snoozeTimer()
        case .breakDone: resumeFocus()
        case .water: logWater()
        case .focusDone, .greeting: dismiss(alert)
        }
    }

    private func dropAlerts(_ matching: (BuddyAlert.Kind) -> Bool) {
        let left = alerts.filter { !matching($0.kind) }
        if left.count != alerts.count { alerts = left }
    }

    private func raise(_ alert: BuddyAlert, sound: String) {
        if settings.alertSound { SoundEngine.shared.play(sound) }
        // coucou-custom fork: where its kind shows (Settings → Buddy → Alerts) — the Buddy's card,
        // the notch, or full screen (the alert is kept here even without the Buddy, and the full
        // screen shows it). The card goes to the notch while the Buddy is hidden.
        let style = RoutineMomentKind.of(alert.kind).map(RoutineMomentSettings.shared.shownStyle)
            ?? RoutineAlertStyle.buddy.resolved(buddyShown: BuddySettings.shared.enabled)
        let fullScreen = style == .fullScreen
        if style == .notch, let kind = RoutineMomentKind.of(alert.kind) {
            // coucou-custom fork: the routine's own notch card, with its quick actions.
            if case .reminder(let id) = alert.kind { inNotch.insert(id) }
            RoutineNotchModel.shared.show(RoutineMoment(kind: kind, alert: alert))
            return
        }
        guard style != .notch else {
            // The notch says it once.
            let app = AppState.shared
            app.noteMessage = alert.detail.isEmpty ? alert.title : "\(alert.title) — \(alert.detail)"
            NotificationCenter.default.post(name: .hookExpand, object: IslandView.note)
            if case .reminder(let id) = alert.kind {
                reminders.removeAll { $0.id == id }
                saveReminders()
            }
            return
        }
        alerts.append(alert)
        if alerts.count > 5 { alerts.removeFirst(alerts.count - 5) }
        if fullScreen { RoutineMoments.shared.present(alert) }
        BuddyController.shared.react(.alert)
        if let after = alert.autoDismiss {
            let id = alert.id
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let a = self.alerts.first(where: { $0.id == id }) else { return }
                    // coucou-custom fork: still logging glasses from it: it waits for its Done.
                    if a.kind == .water, let at = self.waterLoggedAt, Date.now.timeIntervalSince(at) < after { return }
                    self.dismiss(a)
                }
            }
        }
        updateTick()
    }

    // MARK: - Due reminders and water

    private func scheduleDue() {
        dueTimer?.invalidate()
        dueTimer = nil
        let alerted = Set(alerts.compactMap { a -> String? in
            if case .reminder(let id) = a.kind { id } else { nil }
        }).union(inNotch)
        let next = ([nextWater] + reminders.filter { !alerted.contains($0.id) }.map(\.due)).compactMap { $0 }.min()
        guard let next else { return }
        let t = Timer(fire: max(next, Date.now.addingTimeInterval(0.2)), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fireDue() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        dueTimer = t
    }

    private func fireDue() {
        let now = Date.now
        let alerted = Set(alerts.compactMap { a -> String? in
            if case .reminder(let id) = a.kind { id } else { nil }
        }).union(inNotch)
        for r in reminders where r.due <= now && !alerted.contains(r.id) {
            let late = now.timeIntervalSince(r.due) > 120
            raise(BuddyAlert(kind: .reminder(id: r.id), title: r.text,
                             detail: late ? "Missed at \(r.due.formatted(date: .omitted, time: .shortened))" : "Reminder"),
                  sound: "question")
        }
        if let due = nextWater, now >= due {
            let plan = settings.waterPlan
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: Self.anyInput)
            if !BuddyWater.isActive(plan, at: now) || (plan.stopAtGoal && waterToday >= plan.goal) {
                nextWater = BuddyWater.next(after: now, plan: plan)
            } else if BuddyWater.shouldNudge(due: due, now: now, userIdle: idle) {
                raise(BuddyAlert(kind: .water, title: "Time for some water",
                                 detail: "\(BuddyWater.amount(waterToday)) of \(BuddyWater.amount(plan.goal)) today",
                                 autoDismiss: 120),
                      sound: "gulp")
                nextWater = BuddyWater.next(after: now, plan: plan)
            } else {
                nextWater = now.addingTimeInterval(60)   // away: ask again when you are back
            }
        }
        scheduleDue()
    }

    // MARK: - Tick (only while something runs)

    private var needsTick: Bool {
        (focus.map { !$0.isPaused } ?? false) || (countdown.map { !$0.isPaused } ?? false)
    }

    private func updateTick() {
        now = .now
        if needsTick, tickTimer == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            t.tolerance = 0.1
            RunLoop.main.add(t, forMode: .common)
            tickTimer = t
        } else if !needsTick {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    private func tick() {
        let t = Date.now
        now = t
        if var f = focus, f.isOver(at: t) {
            let wasFocus = f.phase == .focus
            f.advance(at: t)
            if wasFocus {
                BuddyDiaryStore.record { $0.focusSessions += 1; $0.focusMinutes += f.plan.focus }
                let mins = f.plan.minutes(f.phase)
                raise(BuddyAlert(kind: .focusDone, title: "Focus session done",
                                 detail: "Time for a \(mins) min \(f.phase == .longBreak ? "long " : "")break", autoDismiss: 30),
                      sound: "finish")
            } else {
                // The next session waits for you.
                f.pause(at: t)
                raise(BuddyAlert(kind: .breakDone, title: "Break's over", detail: "Ready for focus session \(f.round)?"),
                      sound: "blip")
            }
            focus = f
        }
        if let c = countdown, c.isOver(at: t) {
            lastTimerLabel = c.label
            lastTimerTotal = c.total
            countdown = nil
            BuddyDiaryStore.record { $0.timersDone += 1 }
            raise(BuddyAlert(kind: .timerDone, title: c.label.isEmpty ? "Time's up" : c.label,
                             detail: "\(BuddyTimeText.duration(c.total)) timer"), sound: "finish")
        }
        updateTick()
    }
}
#endif
