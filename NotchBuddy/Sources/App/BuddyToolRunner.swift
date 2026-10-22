#if !APPSTORE
import AppKit

// coucou-custom fork: runs the notch chat's Buddy tools (BuddyToolCatalog) and shows each call in
// the chat as a line with its status. A result is short text for the model; `ok` false when the
// call could not be done (bad time, nothing running…), so the model can say so.

@MainActor
enum BuddyToolRunner {
    /// Is the notch chat given the tools (Settings → Buddy → Assistant)?
    static var enabled: Bool { BuddyRoutineSettings.shared.assistantTools }

    /// Runs one call, with its line in the chat (running, then completed or failed), before the
    /// reply streaming in `before` when there is one, so the reply reads after its actions.
    static func runShown(_ name: String, _ input: [String: Any], state: AppState, before: UUID? = nil) async -> String {
        let title = BuddyToolCatalog.title(name, input)
        // The title as content too: the chat scrolls to the last message with content.
        let row = ChatMessage(role: .assistant, content: title, tool: ChatToolRun(title: title, status: .running))
        if let before, let i = state.chatHistory.firstIndex(where: { $0.id == before }) {
            state.chatHistory.insert(row, at: i)
        } else {
            state.chatHistory.append(row)
        }
        let (text, ok) = await run(name, input)
        if let i = state.chatHistory.firstIndex(where: { $0.id == row.id }) {
            state.chatHistory[i].tool?.status = ok ? .completed : .failed
        }
        appendAppLog("buddy.log", "tool \(name) \(ok ? "ok" : "failed")")
        return text
    }

    static func run(_ name: String, _ input: [String: Any]) async -> (String, Bool) {
        let r = BuddyRoutineController.shared
        let now = Date.now
        let action = input["action"] as? String ?? ""
        func time(_ d: Date) -> String { d.formatted(date: Calendar.current.isDateInToday(d) ? .omitted : .abbreviated, time: .shortened) }

        switch name {
        case "create_reminder":
            let text = (input["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return ("No reminder text given.", false) }
            guard let due = BuddyReminders.due(inMinutes: BuddyToolCatalog.number(input["in_minutes"]),
                                               at: input["at"] as? String, now: now) else {
                return ("Could not read a future time. Give in_minutes, or at like \"15:30\".", false)
            }
            guard let rem = r.addReminder(text, due: due) else { return ("Too many reminders already.", false) }
            return ("Reminder \(rem.id) set for \(time(due)): \(rem.text).", true)

        case "list_reminders":
            guard !r.reminders.isEmpty else { return ("No pending reminders.", true) }
            return (r.reminders.map { "\($0.id): \($0.text) at \(time($0.due))" }.joined(separator: "\n"), true)

        case "update_reminder":
            let id = input["id"] as? String ?? ""
            guard let rem = r.reminder(id) else { return ("No reminder with id \(id). Call list_reminders.", false) }
            if action == "snooze" {
                let mins = Int(BuddyToolCatalog.number(input["minutes"]) ?? Double(BuddyReminders.snoozeMinutes))
                guard let s = r.snoozeReminder(id, minutes: mins) else { return ("Could not snooze it.", false) }
                return ("Snoozed \(s.text) until \(time(s.due)).", true)
            }
            r.removeReminder(id)
            return ("Done: \(rem.text).", true)

        case "focus_session":
            switch action {
            case "start":
                r.startFocus(minutes: BuddyToolCatalog.number(input["minutes"]).map { Int($0) },
                             breakMinutes: BuddyToolCatalog.number(input["break_minutes"]).map { Int($0) })
                let f = r.focus!
                return ("Focus session started: \(BuddyTimeText.duration(TimeInterval(f.plan.focus * 60))), then a break of \(BuddyTimeText.duration(TimeInterval(f.plan.shortBreak * 60))).", true)
            case "status":
                return (focusStatus(r, now: now), true)
            default:
                guard r.focus != nil else { return ("No focus session is running.", false) }
                switch action {
                case "pause": r.pauseFocus()
                case "resume": r.resumeFocus()
                case "skip": r.skipFocus()
                case "end": r.endFocus(); return ("Focus session ended.", true)
                default: return ("Unknown action \(action).", false)
                }
                return (focusStatus(r, now: now), true)
            }

        case "timer":
            let secs = (BuddyToolCatalog.number(input["minutes"]) ?? 0) * 60 + (BuddyToolCatalog.number(input["seconds"]) ?? 0)
            switch action {
            case "start":
                guard r.startTimer(seconds: secs, label: input["label"] as? String ?? "") else {
                    return ("Give a duration between 1 second and 24 hours.", false)
                }
                return ("Timer started for \(BuddyTimeText.duration(secs)).", true)
            case "status":
                return (timerStatus(r, now: now), true)
            default:
                guard r.countdown != nil else { return ("No timer is running.", false) }
                switch action {
                case "pause": r.pauseTimer()
                case "resume": r.resumeTimer()
                case "add":
                    guard secs > 0 else { return ("Give minutes or seconds to add.", false) }
                    r.addToTimer(secs)
                case "cancel": r.cancelTimer(); return ("Timer cancelled.", true)
                default: return ("Unknown action \(action).", false)
                }
                return (timerStatus(r, now: now), true)
            }

        case "water_reminder":
            var plan = r.settings.waterPlan
            if let m = BuddyToolCatalog.number(input["every_minutes"]) { plan.every = Int(m) }
            if let l = BuddyToolCatalog.number(input["goal_litres"]) { plan.goal = Int((l * 1000).rounded()) }
            if let g = BuddyToolCatalog.number(input["glass_ml"]) { plan.glass = Int(g) }
            if let f = (input["from"] as? String).flatMap(BuddyReminders.clock) { plan.from = f.0 * 60 + f.1 }
            if let t = (input["to"] as? String).flatMap(BuddyReminders.clock) { plan.to = t.0 * 60 + t.1 }
            r.settings.waterPlan = plan
            if let on = input["enabled"] as? Bool { r.settings.waterEnabled = on }
            return (waterStatus(r), true)

        case "log_water":
            let ml = BuddyToolCatalog.number(input["ml"]).map { Int($0) }
                ?? BuddyToolCatalog.number(input["glasses"]).map { Int($0 * Double(r.settings.waterPlan.glass)) }
            guard ml.map({ $0 != 0 && abs($0) <= 3000 }) ?? true else { return ("Give between 1 and 3000 ml.", false) }
            r.logWater(ml)
            return (waterStatus(r), true)

        case "water_status":
            return (waterStatus(r), true)

        case "breathing_exercise":
            let p = input["pattern"] as? String ?? "calm"
            if p == "stop" {
                guard r.breathing != nil else { return ("No breathing exercise is running.", false) }
                r.stopBreathing()
                return ("Stopped.", true)
            }
            let pattern = BuddyBreathing(rawValue: p == "quick_reset" ? "quickReset" : p) ?? .calm
            r.startBreathing(pattern)
            return ("\(pattern.name) (\(pattern.detail)) started: \(pattern.cycles) breaths, about \(BuddyTimeText.duration(TimeInterval(pattern.totalSeconds))). A breathing panel opened over the Buddy, with Mochi breathing in an orb.", true)

        case "buddy_action":
            guard BuddySettings.shared.enabled else { return ("The Buddy is hidden (Settings → Buddy).", false) }
            let b = BuddyController.shared
            switch action {
            case "greet": r.greet()
            case "wave": b.perform(BuddyClickBinding(action: .hello))
            case "jump": b.perform(BuddyClickBinding(action: .jump))
            case "dance": b.perform(BuddyClickBinding(action: .dance))
            case "spin": b.perform(BuddyClickBinding(action: .spin))
            case "hearts": b.perform(BuddyClickBinding(action: .hearts))
            case "party": b.perform(BuddyClickBinding(action: .party))
            default: return ("Unknown action \(action).", false)
            }
            return ("Done.", true)

        case "system_status":
            return (await BuddySystemStatus.read(), true)

        case "activity_summary":
            return (activity(r, now: now), true)

        default:
            return ("Unknown tool \(name).", false)
        }
    }

    private static func waterStatus(_ r: BuddyRoutineController) -> String {
        let p = r.settings.waterPlan
        func clock(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
        let week = r.settings.waterLog.history(7, upTo: .now).map { BuddyWater.amount($0.ml) }.joined(separator: ", ")
        var s = "Water today: \(BuddyWater.amount(r.waterToday)) of \(BuddyWater.amount(p.goal)) (glass \(BuddyWater.amount(p.glass))). Last 7 days, oldest first: \(week)."
        s += r.settings.waterEnabled
            ? " Nudges every \(p.every) minutes, \(clock(p.from))–\(clock(p.to))\(p.days.count < 7 ? " on \(p.days.count) days a week" : ""), next at \(r.nextWaterNudge?.formatted(date: .omitted, time: .shortened) ?? "–")."
            : " Nudges off."
        return s
    }

    private static func focusStatus(_ r: BuddyRoutineController, now: Date) -> String {
        guard let f = r.focus else { return "No focus session is running." }
        return "\(f.phase.label), round \(f.round), \(BuddyTimeText.left(f.remaining(at: now)))\(f.isPaused ? " (paused)" : ""). \(f.completed) focus session\(f.completed == 1 ? "" : "s") done."
    }

    private static func timerStatus(_ r: BuddyRoutineController, now: Date) -> String {
        guard let c = r.countdown else { return "No timer is running." }
        return "\(c.label.isEmpty ? "Timer" : c.label): \(BuddyTimeText.left(c.remaining(at: now)))\(c.isPaused ? " (paused)" : "")."
    }

    private static func activity(_ r: BuddyRoutineController, now: Date) -> String {
        let app = AppState.shared
        var lines: [String] = []
        // Claude Code in VS Code and the like report through their integration pill: a busy one
        // counts as a session; an idle one is only listed.
        let agents = app.tasks.filter { !$0.isIntegration || $0.state != .idle }
        let idle = app.tasks.filter { $0.isIntegration && $0.state == .idle }.map(\.name)
        if agents.isEmpty {
            lines.append("No agent is working in the notch right now.")
        } else {
            lines.append("Agent sessions:")
            for t in agents {
                var line = "- \(t.name): \(t.state.rawValue)"
                if t.steps.indices.contains(t.stepIndex) { line += " — \(t.steps[t.stepIndex])" }
                if let f = t.finalLine, !f.isEmpty { line += " — last: \(f.prefix(160))" }
                if let cwd = t.sessionCwd { line += " (in \((cwd as NSString).lastPathComponent))" }
                lines.append(line)
            }
        }
        if !idle.isEmpty { lines.append("Connected, idle: \(idle.joined(separator: ", ")).") }
        if app.pendingApproval != nil { lines.append("A permission request is waiting in the notch.") }
        if app.pendingQuestion != nil { lines.append("An agent's question is waiting in the notch.") }
        lines.append(focusStatus(r, now: now))
        lines.append(timerStatus(r, now: now))
        lines.append(r.reminders.isEmpty ? "No reminders." : "\(r.reminders.count) reminder\(r.reminders.count == 1 ? "" : "s"), next: \(r.reminders[0].text) at \(r.reminders[0].due.formatted(date: .omitted, time: .shortened)).")
        lines.append(waterStatus(r))
        return lines.joined(separator: "\n")
    }
}

/// The Mac's vitals for system_status.
enum BuddySystemStatus {
    @MainActor
    static func read() async -> String {
        var lines: [String] = []
        if let a = MachineVitals.cpuTicks() {
            try? await Task.sleep(for: .milliseconds(400))
            if let b = MachineVitals.cpuTicks(), b.total > a.total {
                let load = Double(b.busy - a.busy) / Double(b.total - a.total) * 100
                lines.append("Processor: \(Int(load.rounded()))% busy over \(ProcessInfo.processInfo.activeProcessorCount) cores.")
            }
        }
        if let mem = memory() {
            let gb = { (v: UInt64) in String(format: "%.1f GB", Double(v) / 1_073_741_824) }
            lines.append("Memory: \(gb(mem.used)) used of \(gb(mem.total)).")
        }
        if let bat = MachineVitals.readBattery() {
            lines.append("Battery: \(bat.percent)%\(bat.onPower ? ", plugged in" : ", on battery").")
        }
        if let free = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                                              .volumeTotalCapacityKey]),
           let avail = free.volumeAvailableCapacityForImportantUsage, let total = free.volumeTotalCapacity {
            lines.append(String(format: "Disk: %.0f GB free of %.0f GB.", Double(avail) / 1e9, Double(total) / 1e9))
        }
        let thermal: String = switch ProcessInfo.processInfo.thermalState {
        case .nominal: "normal"
        case .fair: "warm"
        case .serious: "hot"
        case .critical: "critical"
        @unknown default: "unknown"
        }
        lines.append("Thermal state: \(thermal).")
        lines.append("Up for \(BuddyTimeText.duration((ProcessInfo.processInfo.systemUptime / 60).rounded(.down) * 60)).")
        return lines.joined(separator: "\n")
    }

    /// Used (active + wired + compressed, as Activity Monitor's "Memory Used" roughly) and total.
    private static func memory() -> (used: UInt64, total: UInt64)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(getpagesize())
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return (used, ProcessInfo.processInfo.physicalMemory)
    }
}
#endif
