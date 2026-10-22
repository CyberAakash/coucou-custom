import Foundation

// coucou-custom fork: the tools the notch chat can call to act through the Buddy (OpenPets v4's
// "real actions": it sets reminders and starts focus sessions, not just answers). Their
// definitions, in Anthropic's shape (also served over MCP to Claude Code) and OpenAI's, and the
// line each call shows in the chat. BuddyToolRunner runs them.

enum BuddyToolCatalog {
    /// Computed: dictionaries of Any can't be a shared static under Swift 6.
    static var tools: [[String: Any]] { [
        tool("create_reminder",
             "Set a reminder: the Buddy alerts the user with a sound and a sticky bubble at that time. Give either in_minutes, or at (a local time like \"15:30\" or \"3pm\", or a local date-time \"2026-10-24T09:00\").",
             ["text": str("What to remind the user of, short (\"Stretch\", \"Call Sam\")."),
              "in_minutes": num("Minutes from now."),
              "at": str("A local clock time or date-time.")],
             required: ["text"]),
        tool("list_reminders", "List the pending reminders, soonest first, with their ids.", [:]),
        tool("update_reminder", "Complete (remove) or snooze a pending reminder by its id from list_reminders.",
             ["id": str("The reminder's id."),
              "action": enumStr(["done", "snooze"], "done removes it; snooze pushes it back."),
              "minutes": num("For snooze: minutes from now (default 5).")],
             required: ["id", "action"]),
        tool("focus_session",
             "Focus Buddy, a Pomodoro timer on the Buddy: start a focus session (followed by a break), or pause, resume, skip to the break or the next session, end it, or read its status.",
             ["action": enumStr(["start", "pause", "resume", "skip", "end", "status"], ""),
              "minutes": num("For start: focus minutes (default from Settings, usually 25)."),
              "break_minutes": num("For start: short break minutes (default 5).")],
             required: ["action"]),
        tool("timer",
             "A one-shot countdown on the Buddy with an alert when it ends: start, pause, resume, add time, cancel, or read its status.",
             ["action": enumStr(["start", "pause", "resume", "add", "cancel", "status"], ""),
              "minutes": num("For start or add."),
              "seconds": num("For start or add, added to minutes."),
              "label": str("For start: what it is for (\"Tea\").")],
             required: ["action"]),
        tool("water_reminder", "Set up the water-break nudges: on or off, how often, between which hours, the daily goal and the glass size. Give only what changes.",
             ["enabled": ["type": "boolean"],
              "every_minutes": num("Minutes between nudges (10 to 240)."),
              "from": str("Nudges start at this local time, \"09:00\"."),
              "to": str("Nudges end at this local time, \"21:00\"."),
              "goal_litres": num("Daily goal in litres (2)."),
              "glass_ml": num("One glass in millilitres (250).")]),
        tool("log_water", "Log water the user drank today (a glass by default). Negative to undo.",
             ["ml": num("Millilitres."), "glasses": num("Or a number of glasses.")]),
        tool("water_status", "Water drunk today against the goal, the last 7 days, and the nudge schedule.", [:]),
        tool("breathing_exercise",
             "A calm corner for stressful moments: a guided breathing session in a panel over the Buddy (an orb with Mochi breathing in it, each step shown). Or stop the one running.",
             ["pattern": enumStr(["calm", "box", "calming", "energizing", "quick_reset", "stop"],
                                 "calm 4-6 (a longer exhale, the default for stress), box 4-4-4-4 (focus), calming 4-7-8 (to wind down or sleep), energizing 4-4-6, quick_reset 3-3-3 (a minute).")],
             required: ["pattern"]),
        tool("buddy_action", "Make the Buddy (the user's desktop Mochi) do something: greet, wave, jump, dance, spin, hearts or a party.",
             ["action": enumStr(["greet", "wave", "jump", "dance", "spin", "hearts", "party"], "")],
             required: ["action"]),
        tool("system_status", "The Mac right now: processor load, memory, battery, free disk space, thermal state, uptime.", [:]),
        tool("activity_summary",
             "What is going on: the user's AI coding agents in the notch (Claude Code and others: working, waiting for approval or an answer, done), plus the Buddy's focus session, timer, reminders and water nudges.",
             [:]),
    ] }

    static var names: [String] { tools.compactMap { $0["name"] as? String } }

    /// OpenAI's (and Gemini's, DeepSeek's…) `tools`: the same, as functions.
    static var openAI: [[String: Any]] {
        tools.map { t in
            ["type": "function",
             "function": ["name": t["name"] ?? "", "description": t["description"] ?? "",
                          "parameters": t["input_schema"] ?? ["type": "object", "properties": [:]]]]
        }
    }

    /// Told to the model with the tools: the time (for "at 3pm") and when to use them.
    static func systemLine(now: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "EEEE yyyy-MM-dd HH:mm"
        return """
        You can act on the user's Mac through the Buddy, their desktop Mochi: reminders, focus (Pomodoro) sessions, \
        timers, water nudges, breathing exercises, the Buddy's moves, the Mac's status and a summary of their agents. \
        When the user asks for one of these, call the tool instead of only answering, then confirm in one short sentence. \
        It is now \(f.string(from: now)) (\(timeZone.identifier)); give reminder times in that local time.
        """
    }

    /// The chat's line for a call, OpenPets style: what it does, in words.
    static func title(_ name: String, _ input: [String: Any]) -> String {
        let action = input["action"] as? String ?? ""
        switch name {
        case "create_reminder":
            let text = (input["text"] as? String).map { " · \($0)" } ?? ""
            if let m = number(input["in_minutes"]) { return "Create a reminder in \(BuddyTimeText.duration(m * 60))\(text)" }
            if let at = input["at"] as? String { return "Create a reminder at \(at)\(text)" }
            return "Create a reminder\(text)"
        case "list_reminders": return "List reminders"
        case "update_reminder": return action == "snooze" ? "Snooze a reminder" : "Complete a reminder"
        case "focus_session":
            switch action {
            case "start": return "Start a focus session\(number(input["minutes"]).map { " for \(Int($0)) minutes" } ?? "")"
            case "status": return "Check the focus session"
            case "skip": return "Skip ahead in the focus session"
            default: return "\(action.capitalized) the focus session"
            }
        case "timer":
            let secs = (number(input["minutes"]) ?? 0) * 60 + (number(input["seconds"]) ?? 0)
            switch action {
            case "start": return "Start a timer for \(BuddyTimeText.duration(secs))"
            case "add": return "Add \(BuddyTimeText.duration(secs)) to the timer"
            case "status": return "Check the timer"
            default: return "\(action.capitalized) the timer"
            }
        case "water_reminder":
            if let on = input["enabled"] as? Bool { return on ? "Turn on water reminders" : "Turn off water reminders" }
            return "Change water reminders"
        case "log_water":
            if let ml = number(input["ml"]) { return ml < 0 ? "Undo \(BuddyWater.amount(Int(-ml))) of water" : "Log \(BuddyWater.amount(Int(ml))) of water" }
            if let g = number(input["glasses"]) { return "Log \(g == g.rounded() ? "\(Int(g))" : "\(g)") glass\(g == 1 ? "" : "es") of water" }
            return "Log a glass of water"
        case "water_status": return "Check water today"
        case "breathing_exercise":
            let p = input["pattern"] as? String ?? ""
            return p == "stop" ? "Stop the breathing exercise" : "Start a breathing exercise"
        case "buddy_action": return "Buddy: \(action)"
        case "system_status": return "Check system status"
        case "activity_summary": return "Summarize activity"
        default: return name
        }
    }

    /// Models send numbers as numbers or strings.
    static func number(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    // MARK: Schema pieces

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any],
                             required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": description, "input_schema": schema]
    }

    private static func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
    private static func num(_ d: String) -> [String: Any] { ["type": "number", "description": d] }
    private static func enumStr(_ values: [String], _ d: String) -> [String: Any] {
        var s: [String: Any] = ["type": "string", "enum": values]
        if !d.isEmpty { s["description"] = d }
        return s
    }
}

/// A tool call as the chat shows it.
struct ChatToolRun: Equatable, Sendable {
    enum Status: Equatable, Sendable { case running, completed, failed }
    var title: String
    var status: Status
}
