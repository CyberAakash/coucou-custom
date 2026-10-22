import Foundation

// coucou-custom fork: the notch chat's slash commands — quick actions run at once through the
// Buddy's tools (BuddyToolCatalog), without asking the model. "/focus 25", "/remind in 10m
// stretch", "/water", "/breathe box"… Parsing here; ChatSlash runs them in the chat.

struct BuddySlashCommand: Equatable, Sendable, Identifiable {
    let name: String
    /// What follows it, as a hint ("[minutes]").
    let args: String
    let summary: String
    let symbol: String

    var id: String { name }
    /// Runs as typed, nothing more needed.
    var takesNothing: Bool { args.isEmpty }
}

enum BuddySlash {
    static let commands: [BuddySlashCommand] = [
        .init(name: "focus", args: "[minutes | pause | resume | skip | end]", summary: "Start or control a focus session", symbol: "brain.head.profile"),
        .init(name: "timer", args: "<minutes> [label] | pause | resume | +5 | cancel", summary: "A countdown on the Buddy", symbol: "timer"),
        .init(name: "remind", args: "<in 10m | at 15:30> <what>", summary: "Set a reminder", symbol: "bell"),
        .init(name: "reminders", args: "", summary: "Your pending reminders", symbol: "list.bullet"),
        .init(name: "water", args: "[ml | 2 glasses | status]", summary: "Log a glass of water", symbol: "drop"),
        .init(name: "breathe", args: "[calm | box | 478 | energize | quick]", summary: "A breathing session with Mochi", symbol: "leaf"),
        .init(name: "status", args: "", summary: "Your Mac right now", symbol: "gauge.with.dots.needle.33percent"),
        .init(name: "summary", args: "", summary: "Your agents and routines", symbol: "list.bullet.rectangle"),
        .init(name: "dance", args: "", summary: "Make the Buddy dance", symbol: "figure.dance"),
        .init(name: "clear", args: "", summary: "Start a new conversation", symbol: "plus.bubble"),
        .init(name: "help", args: "", summary: "Every slash command", symbol: "questionmark.circle"),
    ]

    /// The commands matching what is typed: while the name is being typed, those it starts;
    /// once a space follows, the one it names (for its hint). Empty when it is not a command.
    static func suggestions(for text: String) -> [BuddySlashCommand] {
        guard text.hasPrefix("/") else { return [] }
        let body = text.dropFirst()
        if let space = body.firstIndex(of: " ") {
            let name = body[..<space].lowercased()
            return commands.filter { $0.name == name }
        }
        let typed = body.lowercased()
        return commands.filter { $0.name.hasPrefix(typed) }
    }

    enum Action: Equatable {
        case tool(String, [String: String])
        case clear
        case help
    }

    /// nil when `text` is not a slash command; `.failure` with the usage when it is one, badly
    /// written. Tool inputs are strings (BuddyToolCatalog.number reads them).
    static func parse(_ text: String) -> Result<Action, Usage>? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("/"), t.count > 1 else { return nil }
        let words = t.dropFirst().split(separator: " ").map(String.init)
        guard let name = words.first?.lowercased(), let cmd = commands.first(where: { $0.name == name }) else { return nil }
        let rest = Array(words.dropFirst())
        let arg = rest.first?.lowercased()
        func bad() -> Result<Action, Usage> { .failure(Usage(command: cmd)) }

        switch name {
        case "focus":
            guard let arg else { return .success(.tool("focus_session", ["action": "start"])) }
            if ["pause", "resume", "skip", "end", "stop", "status"].contains(arg) {
                return .success(.tool("focus_session", ["action": arg == "stop" ? "end" : arg]))
            }
            guard let d = duration(rest.joined(separator: " ")), d >= 60 else { return bad() }
            return .success(.tool("focus_session", ["action": "start", "minutes": "\(Int(d / 60))"]))
        case "timer":
            guard let arg else { return bad() }
            if ["pause", "resume", "cancel", "stop", "status"].contains(arg) {
                return .success(.tool("timer", ["action": arg == "stop" ? "cancel" : arg]))
            }
            if arg.hasPrefix("+"), let d = duration(String(arg.dropFirst())) {
                return .success(.tool("timer", ["action": "add", "seconds": "\(Int(d))"]))
            }
            // "/timer 10 tea", "/timer 1h30m", "/timer 10 minutes tea"
            var take = 1
            if rest.count > 1, duration(rest[0] + rest[1]) != nil, Double(rest[0]) != nil, Double(rest[1]) == nil,
               unit(rest[1]) != nil { take = 2 }
            guard let d = duration(rest.prefix(take).joined()) else { return bad() }
            var input = ["action": "start", "seconds": "\(Int(d))"]
            let label = rest.dropFirst(take).joined(separator: " ")
            if !label.isEmpty { input["label"] = label }
            return .success(.tool("timer", input))
        case "remind":
            return remind(rest).map { .success(.tool("create_reminder", $0)) } ?? bad()
        case "reminders":
            return .success(.tool("list_reminders", [:]))
        case "water":
            guard let arg else { return .success(.tool("log_water", [:])) }
            if arg == "status" { return .success(.tool("water_status", [:])) }
            if arg == "on" || arg == "off" { return .success(.tool("water_reminder", ["enabled": arg == "on" ? "true" : "false"])) }
            if let n = Double(arg), rest.count > 1, rest[1].lowercased().hasPrefix("glass") {
                return .success(.tool("log_water", ["glasses": "\(n)"]))
            }
            let lower = arg.replacingOccurrences(of: ",", with: ".")
            if lower.hasSuffix("l"), !lower.hasSuffix("ml"), let l = Double(lower.dropLast()) {
                return .success(.tool("log_water", ["ml": "\(Int(l * 1000))"]))
            }
            let digits = lower.hasSuffix("ml") ? String(lower.dropLast(2)) : lower
            guard let ml = Int(digits), ml != 0 else { return bad() }
            return .success(.tool("log_water", ["ml": "\(ml)"]))
        case "breathe":
            let pattern: String? = switch arg {
            case nil, "calm", "4-6": "calm"
            case "box", "4-4-4-4": "box"
            case "478", "4-7-8", "sleep", "calming": "calming"
            case "energize", "energise", "energizing", "4-4-6": "energizing"
            case "quick", "reset", "3-3-3": "quick_reset"
            case "stop": "stop"
            default: nil
            }
            return pattern.map { .success(.tool("breathing_exercise", ["pattern": $0])) } ?? bad()
        case "status": return .success(.tool("system_status", [:]))
        case "summary": return .success(.tool("activity_summary", [:]))
        case "dance": return .success(.tool("buddy_action", ["action": "dance"]))
        case "clear": return .success(.clear)
        case "help": return .success(.help)
        default: return nil
        }
    }

    struct Usage: Error, Equatable {
        let command: BuddySlashCommand
        var text: String { "Usage: `/\(command.name) \(command.args)` — \(command.summary.lowercased())." }
    }

    /// "/remind in 10m stretch", "/remind 10 minutes to stretch", "/remind at 3:30 pm call Sam",
    /// "/remind 15:30 call Sam".
    static func remind(_ words: [String]) -> [String: String]? {
        var w = words
        var mode = ""
        if let f = w.first?.lowercased(), f == "in" || f == "at" { mode = f; w.removeFirst() }
        guard !w.isEmpty else { return nil }
        var when: [String: String]?
        var used = 0
        // A duration, maybe two words ("10 minutes").
        if mode != "at" {
            if w.count > 1, Double(w[0]) != nil, unit(w[1]) != nil, let d = duration(w[0] + w[1]) {
                when = ["in_minutes": "\(d / 60)"]; used = 2
            } else if let d = duration(w[0]), !w[0].contains(":") {
                when = ["in_minutes": "\(d / 60)"]; used = 1
            }
        }
        // A clock time, maybe two words ("3:30 pm").
        if when == nil, mode != "in" {
            if w.count > 1, ["am", "pm"].contains(w[1].lowercased()), BuddyReminders.clock(w[0] + w[1]) != nil {
                when = ["at": w[0] + w[1]]; used = 2
            } else if BuddyReminders.clock(w[0]) != nil {
                when = ["at": w[0]]; used = 1
            }
        }
        guard var input = when else { return nil }
        var text = w.dropFirst(used)
        if text.first?.lowercased() == "to" { text = text.dropFirst() }
        guard !text.isEmpty else { return nil }
        input["text"] = text.joined(separator: " ")
        return input
    }

    /// Seconds in "25" (minutes), "25m", "90s", "1h", "1h30m", "1.5h", "10min", "2hours".
    static func duration(_ s: String) -> TimeInterval? {
        let t = s.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty else { return nil }
        if let n = Double(t) { return n > 0 ? n * 60 : nil }
        var total: TimeInterval = 0
        var number = ""
        var rest = Substring(t)
        while !rest.isEmpty {
            while let c = rest.first, c.isNumber || c == "." { number.append(c); rest = rest.dropFirst() }
            var word = ""
            while let c = rest.first, c.isLetter { word.append(c); rest = rest.dropFirst() }
            guard let n = Double(number), let k = unit(word) else { return nil }
            total += n * k
            number = ""
        }
        return total > 0 ? total : nil
    }

    /// Seconds in one of a unit word, nil if it is not one.
    static func unit(_ w: String) -> TimeInterval? {
        switch w.lowercased() {
        case "s", "sec", "secs", "second", "seconds": 1
        case "m", "min", "mins", "minute", "minutes": 60
        case "h", "hr", "hrs", "hour", "hours": 3600
        default: nil
        }
    }

    /// The /help answer.
    static var helpText: String {
        "Slash commands run at once on your Mac:\n\n" + commands.map { c in
            "- `/\(c.name)\(c.args.isEmpty ? "" : " " + c.args)` — \(c.summary)"
        }.joined(separator: "\n")
    }
}
