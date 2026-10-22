import Foundation

// MARK: - SessionTracker (coucou-custom fork)
//
// What each agent session is doing, one entry per session_id. Upstream groups everything by
// pill (one per app): two Claude Code sessions share one card, one ticker and one terminal.
// This keeps them apart for the Sessions view and the home-card switcher.
//
// Pure Foundation, fed the raw hook payloads, so it compiles into a standalone test.
// Field names checked against Claude Code 2.1.300 hook payloads:
//   • subagents: PreToolUse/PostToolUse of the `Agent` tool (tool_input.description,
//     subagent_type; tool_use_id), SubagentStart/SubagentStop (agent_id, agent_type), and
//     every tool call made inside a subagent carries agent_id.
//   • todos: TodoWrite (tool_input.todos[content,status,activeForm]) or TaskCreate
//     (subject, activeForm; result task.id) + TaskUpdate (taskId, status).
//   • Stop arrives while background subagents still run: background_tasks lists them.

struct SessionTracker {

    enum Status: String, Equatable {
        case working       // a turn is running
        case background    // the turn ended but subagents still run in the background
        case waiting       // asking for a permission or an answer
        case finished
        case failed
        case idle          // started, nothing asked yet
    }

    struct Step: Equatable {
        var text: String
        var date: Date
        var agentId: String?     // nil = the main agent
        var failed = false
    }

    struct Todo: Equatable {
        var id: String
        var content: String
        var activeForm: String?
        var status: String       // pending | in_progress | completed
    }

    struct Subagent: Equatable {
        var id: String           // agent_id once known, else the Agent tool_use_id
        var toolUseId: String?
        var type: String
        var description: String
        var running: Bool
        var startedAt: Date
        var endedAt: Date?
        var lastStep: String?
    }

    struct Session: Identifiable, Equatable {
        let id: String
        var pill: String
        var projectName: String
        var cwd: String
        var hostApp: String?
        var bundleId: String?
        var status: Status = .idle
        var prompt: String?
        var turnStartedAt: Date?
        var firstSeen: Date
        var lastActivity: Date
        var currentStep: String?
        var steps: [Step] = []
        var todos: [Todo] = []
        var subagents: [Subagent] = []
        var finalMessage: String?
        var errorDetail: String?
        var endedAt: Date?
        /// When the user looked at the finished session (or answered it). New work clears it.
        var seenAt: Date?
        /// Background tasks Claude reported at Stop that are not subagents (shells, watchers).
        var otherBackgroundTasks = 0
        /// How to bring this session's own tab forward: warp_focus_url, tty, iterm_session_id,
        /// kitty_window_id, kitty_listen_on, wezterm_pane, tmux, tmux_pane (relay coucou_terminal).
        var terminal: [String: String] = [:]
        /// The notch already opened "done" for the current prompt: the extra turns that follow
        /// background agents' completion notices must not open it again.
        var announcedDone = false

        var runningSubagents: Int { subagents.filter(\.running).count }
        var isBusy: Bool { status == .working || status == .background || status == .waiting }
        /// Something worth showing: a SessionStart alone (a window opened) is not.
        var hasWork: Bool { !(prompt ?? "").isEmpty || !steps.isEmpty || finalMessage != nil || errorDetail != nil }
        /// Listed while it runs or waits, and once done until the user has seen it.
        var needsAttention: Bool {
            hasWork && (isBusy || ((status == .finished || status == .failed) && seenAt == nil))
        }
    }

    static let maxSteps = 100
    /// A closed session stays visible this long, so its last answer can still be read.
    static let keepEnded: TimeInterval = 10 * 60
    static let maxSilence: TimeInterval = 12 * 60 * 60
    /// A turn or subagent with no event for this long is over: an event was lost on the way.
    static let maxTurnSilence: TimeInterval = 30 * 60

    private(set) var sessions: [String: Session] = [:]

    /// Sessions in the order they first appeared (stable tabs).
    var ordered: [Session] { sessions.values.sorted { $0.firstSeen < $1.firstSeen } }

    // MARK: Applying an event

    mutating func apply(event: String, payload: [String: Any], pill: String, projectName: String,
                        hostApp: String?, errorDetail: String? = nil, now: Date = Date()) {
        // Some agent plugins send session_id: "" when they have none (OpenCode, Amp).
        let ids = [payload["session_id"], payload["conversation_id"]].compactMap { $0 as? String }
        guard let id = ids.first(where: { !$0.isEmpty }) else { return }
        var s = sessions[id] ?? Session(id: id, pill: pill, projectName: projectName,
                                        cwd: payload["cwd"] as? String ?? "", firstSeen: now, lastActivity: now)
        s.pill = pill
        if !projectName.isEmpty { s.projectName = projectName }
        if let cwd = payload["cwd"] as? String, !cwd.isEmpty { s.cwd = cwd }
        if let hostApp { s.hostApp = hostApp }
        if let bundle = payload["bundle_id"] as? String, !bundle.isEmpty { s.bundleId = bundle }
        if let ids = payload["coucou_terminal"] as? [String: Any] {
            for (k, v) in ids { if let v = v as? String, !v.isEmpty { s.terminal[k] = v } }
        }
        if let iterm = payload["iterm_session_id"] as? String, !iterm.isEmpty { s.terminal["iterm_session_id"] = iterm }
        s.lastActivity = now
        s.endedAt = nil

        let agentId = payload["agent_id"] as? String
        let tool = payload["tool_name"] as? String ?? ""
        let input = payload["tool_input"] as? [String: Any] ?? [:]

        switch event {
        case "SessionStart":
            if s.status == .finished || s.status == .failed { s.status = .idle }

        case "UserPromptSubmit":
            let prompt = (payload["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // A background subagent finishing comes back as a synthetic prompt: work continues,
            // but it is not what the user asked.
            s.seenAt = nil
            if !prompt.hasPrefix("<task-notification>") {
                s.announcedDone = false
                s.prompt = prompt
                s.turnStartedAt = now
                s.finalMessage = nil
                s.errorDetail = nil
                s.steps.removeAll()
                s.subagents.removeAll { !$0.running }
            }
            s.status = .working

        case "PreToolUse":
            s.status = .working
            s.seenAt = nil
            let text = Self.stepText(tool: tool, input: input)
            if let agentId {
                if let i = s.subagents.firstIndex(where: { $0.id == agentId }) { s.subagents[i].lastStep = text }
            } else {
                s.currentStep = text
            }
            append(Step(text: text, date: now, agentId: agentId), to: &s)
            applyTodos(tool: tool, input: input, to: &s)
            if tool == "Agent" || tool == "Task" {
                s.subagents.append(Subagent(
                    id: payload["tool_use_id"] as? String ?? UUID().uuidString,
                    toolUseId: payload["tool_use_id"] as? String,
                    type: input["subagent_type"] as? String ?? "agent",
                    description: input["description"] as? String ?? "Subagent",
                    running: true, startedAt: now))
            }

        case "PostToolUse":
            if tool == "TaskCreate", let taskId = Self.createdTaskId(payload["tool_response"]) {
                // The todo was added at PreToolUse under a placeholder id; give it the real one.
                if let i = s.todos.lastIndex(where: { $0.id.hasPrefix("pending:") }) { s.todos[i].id = taskId }
            }
            if tool == "Agent" || tool == "Task", let useId = payload["tool_use_id"] as? String,
               var i = s.subagents.firstIndex(where: { $0.toolUseId == useId }) {
                let response = payload["tool_response"] as? [String: Any]
                if let realId = response?["agentId"] as? String, s.subagents[i].id != realId {
                    // SubagentStart may have arrived first and added its own entry: keep one.
                    if let dup = s.subagents.firstIndex(where: { $0.id == realId }) {
                        s.subagents[i].running = s.subagents[i].running && s.subagents[dup].running
                        s.subagents[i].lastStep = s.subagents[dup].lastStep ?? s.subagents[i].lastStep
                        s.subagents.remove(at: dup)
                        if dup < i { i -= 1 }
                    }
                    s.subagents[i].id = realId
                }
                // A synchronous subagent is done when its tool returns; an async one keeps running.
                if response?["isAsync"] as? Bool != true { endSubagent(at: i, now: now, in: &s) }
            }

        case "PostToolUseFailure":
            if let i = s.steps.lastIndex(where: { $0.agentId == agentId }) { s.steps[i].failed = true }
            // A denied or interrupted Agent call never starts its subagent.
            if tool == "Agent" || tool == "Task", let useId = payload["tool_use_id"] as? String,
               let i = s.subagents.firstIndex(where: { $0.toolUseId == useId }) {
                endSubagent(at: i, now: now, in: &s)
            }

        case "PermissionRequest":
            s.status = .waiting

        case "Notification":
            let message = payload["message"] as? String ?? ""
            if message.hasSuffix("?") || message.lowercased().contains("permission") { s.status = .waiting }

        case "SubagentStart":
            guard let agentId else { break }
            let type = payload["agent_type"] as? String ?? "agent"
            if s.subagents.contains(where: { $0.id == agentId }) { break }
            // Link to the Agent call that launched it: the newest running one of that type
            // still known by its tool_use_id.
            if let i = s.subagents.lastIndex(where: { $0.running && $0.id == $0.toolUseId && $0.type == type }) {
                s.subagents[i].id = agentId
            } else {
                s.subagents.append(Subagent(id: agentId, toolUseId: nil, type: type, description: type,
                                            running: true, startedAt: now))
            }

        case "SubagentStop":
            if let agentId {
                for i in s.subagents.indices where s.subagents[i].id == agentId { endSubagent(at: i, now: now, in: &s) }
            }

        case "Stop":
            guard agentId == nil else { break }
            if let message = payload["last_assistant_message"] as? String, !message.isEmpty {
                s.finalMessage = message
            }
            let background = (payload["background_tasks"] as? [[String: Any]] ?? [])
                .filter { ($0["status"] as? String) == "running" }
            s.otherBackgroundTasks = background.filter { ($0["type"] as? String) != "subagent" }.count
            s.status = background.isEmpty && s.runningSubagents == 0 ? .finished : .background
            s.currentStep = nil

        case "Interrupt":   // Codex: the user stopped the turn
            s.status = .finished
            s.currentStep = nil
            for i in s.subagents.indices where s.subagents[i].running { endSubagent(at: i, now: now, in: &s) }

        case "StopFailure":
            s.status = .failed
            s.errorDetail = errorDetail ?? payload["error"] as? String ?? "The session stopped on an error."
            s.currentStep = nil

        case "SessionEnd":
            if s.isBusy { s.status = .finished }
            s.endedAt = now
            s.subagents = s.subagents.map { var a = $0; a.running = false; return a }

        default:
            break
        }
        sessions[id] = s
    }

    /// Drops sessions closed more than `keepEnded` ago and silent ones; marks a turn that went
    /// silent as finished rather than spinning forever.
    mutating func sweep(now: Date = Date()) {
        sessions = sessions.filter { _, s in
            if let ended = s.endedAt { return now.timeIntervalSince(ended) < Self.keepEnded }
            return now.timeIntervalSince(s.lastActivity) < Self.maxSilence
        }
        for (id, var s) in sessions where s.isBusy && s.status != .waiting
            && now.timeIntervalSince(s.lastActivity) >= Self.maxTurnSilence {
            for i in s.subagents.indices where s.subagents[i].running { s.subagents[i].running = false; s.subagents[i].endedAt = now }
            s.otherBackgroundTasks = 0
            s.status = .finished
            s.currentStep = nil
            sessions[id] = s
        }
    }

    mutating func remove(_ id: String) { sessions[id] = nil }

    mutating func markAnnounced(_ id: String) {
        sessions[id]?.announcedDone = true
    }

    mutating func markSeen(_ id: String, now: Date = Date()) {
        guard var s = sessions[id], s.seenAt == nil, !s.isBusy else { return }
        s.seenAt = now
        sessions[id] = s
    }

    // MARK: Helpers

    /// Ends one subagent; a turn that only waited on background work is then finished.
    private func endSubagent(at i: Int, now: Date, in s: inout Session) {
        s.subagents[i].running = false
        s.subagents[i].endedAt = s.subagents[i].endedAt ?? now
        if s.status == .background, s.runningSubagents == 0, s.otherBackgroundTasks == 0 { s.status = .finished }
    }

    private func append(_ step: Step, to s: inout Session) {
        s.steps.append(step)
        if s.steps.count > Self.maxSteps { s.steps.removeFirst(s.steps.count - Self.maxSteps) }
    }

    private func applyTodos(tool: String, input: [String: Any], to s: inout Session) {
        switch tool {
        case "TodoWrite":
            guard let todos = input["todos"] as? [[String: Any]] else { return }
            s.todos = todos.enumerated().map { i, t in
                Todo(id: t["id"] as? String ?? String(i), content: t["content"] as? String ?? "",
                     activeForm: t["activeForm"] as? String, status: t["status"] as? String ?? "pending")
            }
        case "TaskCreate":
            s.todos.append(Todo(id: "pending:\(s.todos.count)", content: input["subject"] as? String ?? "Task",
                                activeForm: input["activeForm"] as? String, status: "pending"))
        case "TaskUpdate":
            let taskId = (input["taskId"] as? String) ?? (input["taskId"] as? Int).map(String.init) ?? ""
            guard let i = s.todos.firstIndex(where: { $0.id == taskId }) else { return }
            if let status = input["status"] as? String {
                if status == "deleted" { s.todos.remove(at: i); return }
                s.todos[i].status = status
            }
            if let subject = input["subject"] as? String { s.todos[i].content = subject }
            if let form = input["activeForm"] as? String { s.todos[i].activeForm = form }
        default:
            break
        }
    }

    /// TaskCreate answers `{task: {id, subject}}`, sometimes as a JSON string.
    static func createdTaskId(_ response: Any?) -> String? {
        var object = response as? [String: Any]
        if object == nil, let text = response as? String, let data = text.data(using: .utf8) {
            object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        let task = (object?["task"] as? [String: Any]) ?? (object?["data"] as? [String: Any])?["task"] as? [String: Any]
        if let id = task?["id"] as? String { return id }
        if let id = task?["id"] as? Int { return String(id) }
        return nil
    }

    static func stepText(tool: String, input: [String: Any]) -> String {
        func file(_ key: String = "file_path") -> String {
            URL(fileURLWithPath: input[key] as? String ?? "").lastPathComponent
        }
        func short(_ text: String, _ limit: Int = 90) -> String {
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return line.count > limit ? String(line.prefix(limit)) + "…" : line
        }
        switch tool {
        case "Bash":          return "Runs · " + short(input["command"] as? String ?? "")
        case "Read":          return "Reads · " + file()
        case "Edit", "MultiEdit": return "Edits · " + file()
        case "Write":         return "Writes · " + file()
        case "NotebookEdit":  return "Edits · " + file("notebook_path")
        case "Grep":          return "Searches · " + short(input["pattern"] as? String ?? "", 60)
        case "Glob":          return "Finds · " + short(input["pattern"] as? String ?? "", 60)
        case "WebSearch":     return "Web · " + short(input["query"] as? String ?? "", 60)
        case "WebFetch":      return "Fetches · " + (URL(string: input["url"] as? String ?? "")?.host ?? "page")
        case "Agent", "Task": return "Starts subagent · " + (input["description"] as? String ?? "")
        case "TodoWrite", "TaskCreate", "TaskUpdate": return "Updates tasks"
        case "AskUserQuestion": return "Asks you a question"
        default:
            if tool.hasPrefix("mcp__") {
                // mcp__<server>__<tool>; server names contain single underscores.
                let parts = tool.components(separatedBy: "__")
                return parts.count >= 3 ? "\(parts[1]) · \(parts.dropFirst(2).joined(separator: "__"))" : tool
            }
            return tool.isEmpty ? "Works" : tool
        }
    }
}
