import AppKit
import Combine

// MARK: - LiveSessions (coucou-custom fork)
//
// The observable side of SessionTracker: which sessions are live, which one is selected, and
// opening a session's own terminal. Fed by one call in HookServer.processEvent.
@MainActor
final class LiveSessions: ObservableObject {
    static let shared = LiveSessions()

    @Published private(set) var sessions: [SessionTracker.Session] = []
    @Published private(set) var selectedID: String?

    private var tracker = SessionTracker()
    private var userPickedAt: Date?

    func record(event: String, payload: [String: Any], pill: String, projectName: String, hostApp: String?) {
        let detail = event == "StopFailure" ? HookServer.stopFailureDetail(payload) : nil
        tracker.apply(event: event, payload: payload, pill: pill, projectName: projectName,
                      hostApp: hostApp, errorDetail: detail)
        tracker.sweep()
        sessions = tracker.ordered

        let id = (payload["session_id"] ?? payload["conversation_id"]) as? String
        let asksUser = event == "PermissionRequest"
            || (event == "PreToolUse" && payload["tool_name"] as? String == "AskUserQuestion")
        if asksUser, let id {
            selectedID = id                           // show the session that needs you
        } else if selectedID.flatMap({ tracker.sessions[$0] }) == nil {
            selectedID = mostRecent?.id
        } else if event == "UserPromptSubmit", let id, !userPickedRecently {
            selectedID = id                           // follow the session you just typed in
        }
    }

    var selected: SessionTracker.Session? {
        selectedID.flatMap { id in sessions.first { $0.id == id } } ?? mostRecent
    }

    func sessions(for pill: String) -> [SessionTracker.Session] { sessions.filter { $0.pill == pill } }

    /// The session the home card shows for `pill`: the selected one if it belongs to the pill,
    /// else the pill's most recently active.
    func shown(for pill: String) -> SessionTracker.Session? {
        if let s = selected, s.pill == pill { return s }
        return sessions(for: pill).max { $0.lastActivity < $1.lastActivity }
    }

    func select(_ id: String) {
        selectedID = id
        userPickedAt = Date()
    }

    /// Next / previous session of `pill` (wraps), from the one the home card shows.
    func cycle(pill: String, by delta: Int) {
        let list = sessions(for: pill)
        guard list.count > 1 else { return }
        let current = list.firstIndex { $0.id == shown(for: pill)?.id } ?? 0
        select(list[(current + delta + list.count) % list.count].id)
    }

    func refresh() {
        tracker.sweep()
        sessions = tracker.ordered
    }

    private var mostRecent: SessionTracker.Session? { sessions.max { $0.lastActivity < $1.lastActivity } }
    /// A session picked by hand stays put for a while even if another one gets a prompt.
    private var userPickedRecently: Bool { userPickedAt.map { Date().timeIntervalSince($0) < 120 } ?? false }

    #if !APPSTORE
    /// The terminal (or VS Code) this exact session runs in, as `openSessionApp` does for a pill.
    func openTerminal(_ s: SessionTracker.Session) {
        if !(s.pill == "integration_claude" && ClaudeHost.activate(s.hostApp)),
           !TerminalTarget.activate(sessionBundleId: s.bundleId) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        }
    }
    #endif
}
