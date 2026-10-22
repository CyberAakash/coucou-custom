import Foundation

// MARK: - NotchAlertRules (coucou-custom fork)
//
// When the notch opens by itself. Upstream opens "finished" at every Stop, including a Stop
// that only launched background agents, and again at each Stop that follows one of them
// finishing. Here it opens once, when the session's work is really over (SessionTracker says
// .finished: no background task, no running subagent), and for approvals and questions as
// before. Everything else is an ambient pulse (sound, wiggle, orbit ring: NotchPulse).
// Pure Foundation so the rules compile into a standalone test.

enum NotchAlertRules {
    static let openOnFinishKey = "coucouOpenOnFinish"
    static let openOnErrorKey = "coucouOpenOnError"
    static let ambientKey = "coucouAmbientPulse"
    /// Open on finish even while the session's terminal is the front app (upstream: light only).
    static let openWhenTerminalInFrontKey = "coucouOpenWhenTerminalInFront"

    /// Bursts (five subagents starting together) make one sound, not five.
    static let soundSpacing: TimeInterval = 0.8

    static func setting(_ key: String, default value: Bool = true) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    /// True when the session has nothing left running. An untracked session (nil) keeps
    /// upstream's behaviour: its Stop is the end.
    static func sessionDone(_ status: SessionTracker.Status?) -> Bool {
        guard let status else { return true }
        return status != .background && status != .working
    }

    /// The Stop of a session opens the notch only when its work is over and the user wants it.
    static func opensOnStop(status: SessionTracker.Status?, openOnFinish: Bool) -> Bool {
        openOnFinish && sessionDone(status)
    }

    static func playsSound(last: Date, now: Date) -> Bool {
        now.timeIntervalSince(last) >= soundSpacing
    }
}
