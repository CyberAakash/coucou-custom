import Foundation

// MARK: - NotchAlertRules tests (coucou-custom fork)

@main
enum NotchAlertRulesTests {
    static var failures = 0
    static func check(_ label: String, _ ok: Bool) {
        print(ok ? "✓ \(label)" : "✗ \(label)")
        if !ok { failures += 1 }
    }

    static func main() {
        // The tracker's view of a session at its Stop decides.
        var t = SessionTracker()
        func send(_ e: String, _ extra: [String: Any] = [:]) {
            var p: [String: Any] = ["session_id": "S"]; extra.forEach { p[$0] = $1 }
            t.apply(event: e, payload: p, pill: "integration_claude", projectName: "rea", hostApp: nil)
        }
        send("UserPromptSubmit", ["prompt": "go"])
        send("PreToolUse", ["tool_name": "Agent", "tool_use_id": "u", "tool_input": ["description": "d"]])
        send("PostToolUse", ["tool_name": "Agent", "tool_use_id": "u", "tool_response": ["isAsync": true, "agentId": "a"]])
        send("Stop", ["background_tasks": [["id": "a", "type": "subagent", "status": "running"]]])
        check("Stop with a background agent: no open", !NotchAlertRules.opensOnStop(status: t.sessions["S"]?.status, openOnFinish: true))
        send("SubagentStop", ["agent_id": "a"])
        send("UserPromptSubmit", ["prompt": "<task-notification> a done"])
        check("the agent's notification turn is work, not the end", !NotchAlertRules.sessionDone(t.sessions["S"]?.status))
        send("Stop", ["background_tasks": []])
        check("final Stop with nothing running: opens", NotchAlertRules.opensOnStop(status: t.sessions["S"]?.status, openOnFinish: true))
        t.markAnnounced("S")
        send("UserPromptSubmit", ["prompt": "<task-notification> b done"])
        send("Stop", ["background_tasks": []])
        check("a second notice turn after the open: already announced", t.sessions["S"]?.announcedDone == true)
        send("UserPromptSubmit", ["prompt": "next task"])
        check("a real prompt resets it", t.sessions["S"]?.announcedDone == false)
        check("setting off: never opens on finish", !NotchAlertRules.opensOnStop(status: .finished, openOnFinish: false))
        check("untracked session keeps upstream behaviour", NotchAlertRules.opensOnStop(status: nil, openOnFinish: true))
        check("failed counts as done", NotchAlertRules.sessionDone(.failed))

        // Sound spacing
        let t0 = Date()
        check("first sound plays", NotchAlertRules.playsSound(last: .distantPast, now: t0))
        check("burst coalesced", !NotchAlertRules.playsSound(last: t0, now: t0.addingTimeInterval(0.3)))
        check("after the spacing, plays again", NotchAlertRules.playsSound(last: t0, now: t0.addingTimeInterval(0.9)))

        // Spotlight: brightest at the notch, fading to nothing at the rim, at any softness.
        for soft in [0.0, 0.3, 1.0, 1.6, 9.0] {
            let f = SpotlightSettings.falloff(softness: soft)
            let ordered = zip(f, f.dropFirst()).allSatisfy { $0.location < $1.location && $0.opacity > $1.opacity }
            check("falloff decreases outward (softness \(soft))", ordered && f.first?.location == 0 && f.first?.opacity == 1)
            check("falloff reaches 0 at the rim (softness \(soft))", f.last?.location == 1 && f.last?.opacity == 0)
        }
        check("softer spreads the light", SpotlightSettings.falloff(softness: 1.6)[2].location > SpotlightSettings.falloff(softness: 0.3)[2].location)
        check("brightness clamps low", SpotlightSettings.clamped(0, SpotlightSettings.brightnessRange) == 0.1)
        check("brightness clamps high", SpotlightSettings.clamped(3, SpotlightSettings.brightnessRange) == 1)
        check("default brightness is in range", SpotlightSettings.brightnessRange.contains(SpotlightSettings.defaultBrightness))

        print(failures == 0 ? "\nNotchAlertRulesTests: all passed" : "\n\(failures) failed")
        if failures > 0 { exit(1) }
    }
}
