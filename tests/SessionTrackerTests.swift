import Foundation

// MARK: - SessionTracker tests (coucou-custom fork)
// Payload shapes copied from real Claude Code 2.1.300 hook events.

@main
enum SessionTrackerTests {
    static var failures = 0

    static func check(_ label: String, _ ok: Bool) {
        print(ok ? "✓ \(label)" : "✗ \(label)")
        if !ok { failures += 1 }
    }

    static let t0 = Date(timeIntervalSince1970: 1_000_000)

    static func main() {
        var tracker = SessionTracker()
        func send(_ event: String, _ session: String, at offset: TimeInterval = 0, pill: String = "integration_claude",
                  project: String = "rea", _ extra: [String: Any] = [:]) {
            var payload: [String: Any] = ["session_id": session, "cwd": "/Users/x/\(project)", "hook_event_name": event]
            extra.forEach { payload[$0] = $1 }
            tracker.apply(event: event, payload: payload, pill: pill, projectName: project, hostApp: nil,
                          now: t0.addingTimeInterval(offset))
        }

        // MARK: Two sessions behind one pill stay apart
        send("UserPromptSubmit", "A", ["prompt": "fix the build"])
        send("UserPromptSubmit", "B", at: 1, project: "shop", ["prompt": "write tests"])
        send("PreToolUse", "A", at: 2, ["tool_name": "Bash", "tool_input": ["command": "swift build\nmore"], "tool_use_id": "t1"])
        send("PreToolUse", "B", at: 3, project: "shop", ["tool_name": "Read", "tool_input": ["file_path": "/a/b/Cart.swift"], "tool_use_id": "t2"])
        let a = tracker.sessions["A"]!, b = tracker.sessions["B"]!
        check("two sessions tracked", tracker.sessions.count == 2)
        check("tabs in first-seen order", tracker.ordered.map(\.id) == ["A", "B"])
        check("A keeps its own step", a.steps.map(\.text) == ["Runs · swift build"])
        check("B keeps its own step", b.steps.map(\.text) == ["Reads · Cart.swift"])
        check("B has its own project", b.projectName == "shop" && a.projectName == "rea")
        check("full prompt kept", a.prompt == "fix the build")
        check("working while a tool runs", a.status == .working && a.currentStep == "Runs · swift build")

        // MARK: Todos (TodoWrite)
        send("PreToolUse", "A", at: 4, ["tool_name": "TodoWrite", "tool_input": ["todos": [
            ["content": "Fix build", "status": "in_progress", "activeForm": "Fixing build"],
            ["content": "Run tests", "status": "pending", "activeForm": "Running tests"]]]])
        check("TodoWrite sets todos", tracker.sessions["A"]!.todos.map(\.content) == ["Fix build", "Run tests"])
        check("todo status kept", tracker.sessions["A"]!.todos.first?.status == "in_progress")
        check("todos stay per session", tracker.sessions["B"]!.todos.isEmpty)

        // MARK: Todos (TaskCreate / TaskUpdate)
        send("PreToolUse", "B", at: 5, project: "shop", ["tool_name": "TaskCreate", "tool_input": ["subject": "Add cart tests", "description": "x"]])
        send("PostToolUse", "B", at: 6, project: "shop", ["tool_name": "TaskCreate", "tool_response": ["task": ["id": "1", "subject": "Add cart tests"]]])
        send("PreToolUse", "B", at: 7, project: "shop", ["tool_name": "TaskUpdate", "tool_input": ["taskId": "1", "status": "in_progress"]])
        let bt = tracker.sessions["B"]!.todos
        check("TaskCreate adds a todo with the real id", bt.count == 1 && bt[0].id == "1" && bt[0].content == "Add cart tests")
        check("TaskUpdate changes its status", bt.first?.status == "in_progress")
        check("TaskCreate id from a JSON string", SessionTracker.createdTaskId(#"{"task":{"id":"7"}}"#) == "7")

        // MARK: Subagents (async Agent, as captured)
        send("PreToolUse", "A", at: 8, ["tool_name": "Agent", "tool_use_id": "toolu_agent",
             "tool_input": ["description": "count files", "subagent_type": "general-purpose", "prompt": "…"]])
        send("PostToolUse", "A", at: 9, ["tool_name": "Agent", "tool_use_id": "toolu_agent",
             "tool_response": ["isAsync": true, "status": "async_launched", "agentId": "ab357"]])
        send("SubagentStart", "A", at: 10, ["agent_id": "ab357", "agent_type": "general-purpose"])
        var sub = tracker.sessions["A"]!.subagents
        check("one subagent, linked to its agent id", sub.count == 1 && sub[0].id == "ab357")
        check("described by the Agent call", sub.first?.description == "count files")
        check("async subagent still running after its tool returns", sub.first?.running == true)

        send("Stop", "A", at: 11, ["last_assistant_message": "Started a subagent.",
             "background_tasks": [["id": "ab357", "type": "subagent", "status": "running"]]])
        check("Stop with a running background task → background", tracker.sessions["A"]!.status == .background)

        send("PreToolUse", "A", at: 12, ["tool_name": "Bash", "agent_id": "ab357", "agent_type": "general-purpose",
             "tool_input": ["command": "ls"], "tool_use_id": "t9"])
        let afterSubStep = tracker.sessions["A"]!
        check("subagent step attributed to it", afterSubStep.steps.last?.agentId == "ab357")
        check("subagent shows its last step", afterSubStep.subagents.first?.lastStep == "Runs · ls")
        check("main agent's current step untouched by the subagent", afterSubStep.currentStep == nil)

        send("SubagentStop", "A", at: 13, ["agent_id": "ab357", "agent_type": "general-purpose", "last_assistant_message": "2 files"])
        sub = tracker.sessions["A"]!.subagents
        check("SubagentStop ends it", sub.first?.running == false)
        send("UserPromptSubmit", "A", at: 14, ["prompt": "<task-notification> <task-id>ab357</task-id>"])
        check("task notification keeps the user's prompt", tracker.sessions["A"]!.prompt == "fix the build")
        send("Stop", "A", at: 15, ["last_assistant_message": "Done.\n\nFound **2 files** in the folder.", "background_tasks": []])
        let done = tracker.sessions["A"]!
        check("finished once nothing runs", done.status == .finished)
        check("full final message kept (not one line)", done.finalMessage == "Done.\n\nFound **2 files** in the folder.")

        // MARK: Sync subagent ends with its tool
        send("PreToolUse", "B", at: 16, project: "shop", ["tool_name": "Agent", "tool_use_id": "u2",
             "tool_input": ["description": "review", "subagent_type": "code-reviewer"]])
        send("PostToolUse", "B", at: 17, project: "shop", ["tool_name": "Agent", "tool_use_id": "u2", "tool_response": ["status": "completed"]])
        check("sync subagent done when its tool returns", tracker.sessions["B"]!.subagents.first?.running == false)

        // MARK: A new prompt starts a fresh turn
        send("UserPromptSubmit", "A", at: 20, ["prompt": "now deploy"])
        let fresh = tracker.sessions["A"]!
        check("new turn clears steps and final message", fresh.steps.isEmpty && fresh.finalMessage == nil)
        check("finished subagents cleared on a new turn", fresh.subagents.isEmpty)

        // MARK: Waiting, failure, end, sweep
        send("PermissionRequest", "B", at: 21, project: "shop", ["tool_name": "Bash"])
        check("permission → waiting", tracker.sessions["B"]!.status == .waiting)
        tracker.apply(event: "StopFailure", payload: ["session_id": "B"], pill: "integration_claude",
                      projectName: "shop", hostApp: nil, errorDetail: "Rate limited", now: t0.addingTimeInterval(22))
        check("StopFailure → failed with detail", tracker.sessions["B"]!.status == .failed && tracker.sessions["B"]!.errorDetail == "Rate limited")
        send("SessionEnd", "A", at: 23)
        tracker.sweep(now: t0.addingTimeInterval(23 + 60))
        check("ended session kept a while to read its answer", tracker.sessions["A"] != nil)
        tracker.sweep(now: t0.addingTimeInterval(23 + SessionTracker.keepEnded + 1))
        check("ended session removed after keepEnded", tracker.sessions["A"] == nil && tracker.sessions["B"] != nil)

        // MARK: Steps are capped, step text
        for i in 0..<150 { send("PreToolUse", "C", at: 30 + Double(i), ["tool_name": "Read", "tool_input": ["file_path": "/f\(i)"]]) }
        check("steps capped at maxSteps", tracker.sessions["C"]!.steps.count == SessionTracker.maxSteps
              && tracker.sessions["C"]!.steps.last?.text == "Reads · f149")
        check("mcp tool step", SessionTracker.stepText(tool: "mcp__claude_ai_Canva__create-design", input: [:]) == "claude_ai_Canva · create-design")
        check("ignores events without a session id", { var t = SessionTracker()
            t.apply(event: "Stop", payload: [:], pill: "p", projectName: "x", hostApp: nil); return t.sessions.isEmpty }())

        print(failures == 0 ? "\nSessionTrackerTests: all passed" : "\n\(failures) failed")
        if failures > 0 { exit(1) }
    }
}
