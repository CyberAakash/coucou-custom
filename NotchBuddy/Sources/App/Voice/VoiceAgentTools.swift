#if !APPSTORE
import AppKit
import Foundation

// MARK: - VoiceAgentTools (coucou-custom fork)
//
// The brain's extra tools: cards for the notch, opening links, and Claude Code tasks. Buddy's
// twelve tools (reminders, focus, timers, water, breathing…) join through `BuddyToolCatalog`
// when the assistant is on in Settings → Buddy.
enum VoiceAgentTools {
    static let names = ["show_cards", "open_url", "agent_sessions", "start_agent_task", "tell_agent"]

    @MainActor static var tools: [[String: Any]] {
        var t: [[String: Any]] = [
            [
                "name": "show_cards",
                "description": "Show cards in the notch beside what you say. Use it whenever the answer has links, several results, products, files, songs, a question with choices, or an image. Keep the spoken sentence short and put the details in the cards.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "cards": ["type": "array", "items": [
                            "type": "object",
                            "properties": [
                                "kind": ["type": "string", "enum": ["answer", "items", "question", "preview"]],
                                "title": ["type": "string"],
                                "text": ["type": "string", "description": "answer: the text, a few sentences at most"],
                                "items": ["type": "array", "items": ["type": "object", "properties": [
                                    "title": ["type": "string"], "detail": ["type": "string", "description": "price, size, date…"],
                                    "source": ["type": "string"], "url": ["type": "string"], "image_url": ["type": "string"]],
                                    "required": ["title"]]],
                                "choices": ["type": "array", "items": ["type": "string"], "description": "question: 2 to 4 short choices"],
                                "url": ["type": "string"], "image_url": ["type": "string"],
                            ],
                            "required": ["kind"],
                        ]],
                    ],
                    "required": ["cards"],
                ],
            ],
            [
                "name": "open_url",
                "description": "Open a web page or file in the user's default app (e.g. the second result they asked for).",
                "input_schema": ["type": "object", "properties": ["url": ["type": "string"]], "required": ["url"]],
            ],
            [
                "name": "agent_sessions",
                "description": "List the Claude Code sessions the notch tracks: project, id, status, current step, folder.",
                "input_schema": ["type": "object", "properties": [:]],
            ],
            [
                "name": "start_agent_task",
                "description": "Ask to start a Claude Code session in a project folder with an instruction. Shows a card the user must click to approve; nothing starts before that click, and you never say it started. folder: a known project name or a path.",
                "input_schema": ["type": "object",
                                 "properties": ["folder": ["type": "string"], "instruction": ["type": "string"]],
                                 "required": ["folder", "instruction"]],
            ],
            [
                "name": "tell_agent",
                "description": "Ask to send an instruction to an existing Claude Code session (by project name or id). Shows a card the user must click to approve.",
                "input_schema": ["type": "object",
                                 "properties": ["session": ["type": "string"], "text": ["type": "string"]],
                                 "required": ["session", "text"]],
            ],
        ]
        if BuddyToolRunner.enabled { t += BuddyToolCatalog.tools }
        return t
    }

    @MainActor static var allNames: [String] { names + (BuddyToolRunner.enabled ? BuddyToolCatalog.names : []) }

    /// What the system prompt says about these tools.
    @MainActor static var promptLines: String {
        let folders = AgentTaskRunner.knownFolders().prefix(24).map { URL(fileURLWithPath: $0).lastPathComponent }
        var s = """
        Cards: call show_cards whenever the answer has links, several results, products, files, songs, \
        a question with choices or an image; say one short sentence and let the card carry the details. \
        The user can answer a question card by voice or by clicking a choice, and can say \
        "open the second one": then call open_url with that item's url.
        Claude Code: agent_sessions lists the sessions the notch tracks. start_agent_task and tell_agent \
        only show a card the user clicks to approve; say that the card is waiting for their click, never \
        that the task started. Permission prompts inside a session are never answered by voice.
        """
        if !folders.isEmpty { s += "\nKnown project folders: \(folders.joined(separator: ", "))." }
        if BuddyToolRunner.enabled {
            s += "\nBuddy tools: reminders, focus sessions, timers, water, breathing, system status and an activity summary are available as tools; use them for those requests."
        }
        return s
    }

    /// Runs one of these tools. nil when the name is not ours.
    @MainActor static func run(_ name: String, _ input: [String: Any]) async -> (String, Bool)? {
        let state = AppState.shared
        switch name {
        case "show_cards":
            let cards = VoiceCard.parse(input["cards"] as? [[String: Any]] ?? [])
            guard !cards.isEmpty else { return ("no card had content", false) }
            // Later cards join earlier ones of the turn; a new turn starts clean (the controller clears).
            state.voiceCards = (state.voiceCards.filter { $0.kind == .confirm || $0.kind == .progress } + cards).suffix(4).map { $0 }
            appendAppLog("nb.log", "[Voice] cards shown: \(cards.map { "\($0.kind.rawValue)(\($0.items.count))" }.joined(separator: " "))")
            return ("shown: \(cards.map { $0.kind.rawValue }.joined(separator: ", "))", false)
        case "open_url":
            guard let raw = input["url"] as? String, let url = URL(string: raw) ?? URL(string: "https://" + raw) else { return ("no url", false) }
            NSWorkspace.shared.open(url)
            return ("opened \(url.host ?? url.lastPathComponent)", true)
        case "agent_sessions":
            return (AgentTaskRunner.sessionsSummary(), false)
        case "start_agent_task":
            let instruction = (input["instruction"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instruction.isEmpty else { return ("no instruction", false) }
            guard let folder = AgentTaskRunner.resolveFolder(input["folder"] as? String ?? "") else {
                let known = AgentTaskRunner.knownFolders().prefix(6).map { URL(fileURLWithPath: $0).lastPathComponent }
                return ("unknown folder; known projects: \(known.joined(separator: ", ")). Ask the user which one.", false)
            }
            let action = AgentAction.startTask(folder: folder, instruction: instruction)
            state.voiceCards = state.voiceCards.filter { $0.kind != .confirm } + [VoiceCard(kind: .confirm, title: "Start a Claude Code task", text: action.summary, action: action)]
            return ("card shown; waiting for the user's click to start", false)
        case "tell_agent":
            let text = (input["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return ("no text", false) }
            guard let session = AgentTaskRunner.session(matching: input["session"] as? String ?? "") else {
                return ("unknown session. " + AgentTaskRunner.sessionsSummary(), false)
            }
            let action = AgentAction.tellSession(id: session.id, text: text)
            state.voiceCards = state.voiceCards.filter { $0.kind != .confirm } + [VoiceCard(kind: .confirm, title: "Tell \(session.projectName)", text: action.summary, action: action)]
            return ("card shown; waiting for the user's click to send", false)
        default:
            if BuddyToolRunner.enabled, BuddyToolCatalog.names.contains(name) {
                return await BuddyToolRunner.run(name, input)
            }
            return nil
        }
    }

    /// The user clicked Approve on a confirm card: run it and follow it with a progress card.
    @MainActor static func approve(_ card: VoiceCard) {
        guard let action = card.action else { return }
        let state = AppState.shared
        state.voiceCards.removeAll { $0.id == card.id }
        guard let id = AgentTaskRunner.run(action) else {
            state.voiceCards.append(VoiceCard(kind: .answer, title: "Could not start", text: "Claude Code was not found on this Mac."))
            return
        }
        let title: String
        switch action {
        case .startTask(let folder, _): title = URL(fileURLWithPath: folder).lastPathComponent
        case .tellSession: title = LiveSessions.shared.session(id)?.projectName ?? "Session"
        }
        state.voiceCards.append(VoiceCard(kind: .progress, title: title, text: action.summary, sessionID: id))
    }
}
#endif
