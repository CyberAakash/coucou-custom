#if !APPSTORE
import AppKit
import Foundation

// MARK: - VoiceCard (coucou-custom fork)

/// What the brain shows beside the sentence it speaks. Six kinds cover what an assistant
/// produces; products, files, songs and search results are all `items`. The brain fills them
/// through the `show_cards` tool, so the same card works for the API brain and the Claude Code
/// brain, and nothing depends on the CLI's output format.
struct VoiceCard: Identifiable, Equatable {
    enum Kind: String, CaseIterable { case answer, items, confirm, progress, question, preview }

    let id = UUID()
    var kind: Kind
    var title: String?
    var text: String?
    var items: [Item] = []
    var choices: [String] = []
    var url: String?
    var imageURL: String?
    /// `confirm`: what a click approves. `progress`: the session it follows.
    var action: AgentAction?
    var sessionID: String?

    struct Item: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var detail: String?
        var source: String?
        var url: String?
        var imageURL: String?
    }

    /// Cards described by the brain: `[{kind, title, text, items: [{title, detail, source, url,
    /// image_url}], choices, url, image_url}]`. Unknown kinds become answers; empty ones are dropped.
    static func parse(_ raw: [[String: Any]]) -> [VoiceCard] {
        raw.compactMap { c in
            let kind = Kind(rawValue: (c["kind"] as? String ?? "answer").lowercased()) ?? .answer
            var card = VoiceCard(kind: kind,
                                 title: (c["title"] as? String)?.nonEmpty,
                                 text: (c["text"] as? String)?.nonEmpty,
                                 url: (c["url"] as? String)?.nonEmpty,
                                 imageURL: (c["image_url"] as? String)?.nonEmpty)
            card.items = ((c["items"] as? [[String: Any]]) ?? []).prefix(6).compactMap { i in
                guard let title = (i["title"] as? String)?.nonEmpty else { return nil }
                return Item(title: title, detail: (i["detail"] as? String)?.nonEmpty, source: (i["source"] as? String)?.nonEmpty,
                            url: (i["url"] as? String)?.nonEmpty, imageURL: (i["image_url"] as? String)?.nonEmpty)
            }
            card.choices = ((c["choices"] as? [String]) ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(4).map { $0 }
            // Confirm and progress cards are made by the agent tools, never described by the brain.
            if kind == .confirm || kind == .progress { card.kind = .answer }
            let empty = card.title == nil && card.text == nil && card.items.isEmpty && card.choices.isEmpty && card.url == nil && card.imageURL == nil
            return empty ? nil : card
        }
    }
}

/// Something the user must click to approve (rule of the fork: never by voice).
enum AgentAction: Equatable {
    case startTask(folder: String, instruction: String)
    case tellSession(id: String, text: String)

    @MainActor var summary: String {
        switch self {
        case .startTask(let folder, let instruction):
            return "Start a Claude Code session in \(URL(fileURLWithPath: folder).lastPathComponent): \(instruction)"
        case .tellSession(let id, let text):
            let name = LiveSessions.shared.session(id)?.projectName ?? String(id.prefix(8))
            return "Tell the \(name) session: \(text)"
        }
    }
}

private extension String {
    var nonEmpty: String? { let t = trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t }
}

// MARK: - AgentTaskRunner

/// Runs Claude Code for the user, headless, so the notch tracks it like any session: a new task
/// gets its own session id (`--session-id`) in the chosen folder; a follow-up resumes an existing
/// one. Spawned by Coucou with TERM_PROGRAM set, the hooks route it to the Claude pill
/// (InstructionRunner's trick). Permission prompts inside are the user's, in the notch, never
/// answered here.
@MainActor
enum AgentTaskRunner {
    private static var running: [String: Process] = [:]

    /// Folders the brain may name: the tracked sessions' working directories (newest first), then
    /// every project Claude Code has been opened in (`~/.claude.json`, which is also its list of
    /// trusted folders), skipping ones that no longer exist.
    static func knownFolders() -> [String] {
        var seen = Set<String>()
        var out = LiveSessions.shared.sessions.sorted { $0.lastActivity > $1.lastActivity }
            .map(\.cwd).filter { !$0.isEmpty && seen.insert($0).inserted }
        let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        if let data = try? Data(contentsOf: config),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let projects = json["projects"] as? [String: Any] {
            var isDir: ObjCBool = false
            for path in projects.keys.sorted() where seen.insert(path).inserted
                && FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue {
                out.append(path)
            }
        }
        return out
    }

    /// Resolves what the user said ("rea", "the coucou fork", a path) to a folder.
    static func resolveFolder(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (t as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue { return expanded }
        let want = WakePhrase.normalise(t)
        return knownFolders().first { WakePhrase.normalise(URL(fileURLWithPath: $0).lastPathComponent) == want }
            ?? knownFolders().first { WakePhrase.normalise(URL(fileURLWithPath: $0).lastPathComponent).contains(want) && want.count >= 3 }
    }

    /// Starts the approved action. Returns the session id the Progress card follows.
    static func run(_ action: AgentAction) -> String? {
        guard let claude = claudeExecutable() else {
            appendAppLog("nb.log", "[Voice] agent task: claude not found"); return nil
        }
        let sessionID: String
        var args: [String]
        let cwd: String
        switch action {
        case .startTask(let folder, let instruction):
            sessionID = UUID().uuidString.lowercased()
            args = ["-p", instruction, "--session-id", sessionID]
            cwd = folder
        case .tellSession(let id, let text):
            sessionID = id
            args = ["-p", text, "--resume", id]
            cwd = LiveSessions.shared.session(id)?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = [URL(fileURLWithPath: claude).deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin",
                       "/usr/bin", "/bin", "\(home)/.local/bin", env["PATH"] ?? ""].joined(separator: ":")
        env["TERM_PROGRAM"] = "vscode"
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let logURL = URL(fileURLWithPath: "\(home)/Library/Logs/NotchBuddy/agent-task-last.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let output = try? FileHandle(forWritingTo: logURL)
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = output ?? FileHandle.nullDevice
        process.terminationHandler = { finished in
            try? output?.close()
            let status = finished.terminationStatus
            Task { @MainActor in
                running[sessionID] = nil
                appendAppLog("nb.log", "[Voice] agent task \(sessionID.prefix(8)) ended with \(status)")
            }
        }
        do {
            try process.run()
            running[sessionID] = process
            appendAppLog("nb.log", "[Voice] agent task \(sessionID.prefix(8)) started in \(URL(fileURLWithPath: cwd).lastPathComponent)")
            return sessionID
        } catch {
            appendAppLog("nb.log", "[Voice] agent task could not start: \(error.localizedDescription)")
            return nil
        }
    }

    /// Where `claude` usually lives; the app doesn't get the shell's PATH (as InstructionRunner).
    static func claudeExecutable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = ["\(home)/.claude/local/claude", "\(home)/.local/bin/claude", "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude"]
        // nvm installs: the newest node's bin.
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: "\(home)/.nvm/versions/node") {
            candidates += versions.sorted().reversed().map { "\(home)/.nvm/versions/node/\($0)/bin/claude" }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// One line per tracked session, for the brain.
    static func sessionsSummary() -> String {
        let list = LiveSessions.shared.sessions.sorted { $0.lastActivity > $1.lastActivity }.prefix(8)
        guard !list.isEmpty else { return "No Claude Code session is tracked right now." }
        return list.map { s in
            var line = "\(s.projectName) (id \(s.id.prefix(8)), \(s.status.rawValue))"
            if let step = s.currentStep, !step.isEmpty { line += ": \(step)" }
            else if let final = s.finalMessage, !final.isEmpty { line += ": \(final.prefix(100))" }
            line += " · folder \(s.cwd)"
            return line
        }.joined(separator: "\n")
    }

    static func session(matching idOrPrefix: String) -> SessionTracker.Session? {
        let t = idOrPrefix.trimmingCharacters(in: .whitespaces).lowercased()
        return LiveSessions.shared.sessions.first { $0.id.lowercased().hasPrefix(t) }
            ?? LiveSessions.shared.sessions.sorted { $0.lastActivity > $1.lastActivity }
                .first { WakePhrase.normalise($0.projectName) == WakePhrase.normalise(t) }
    }
}
#endif
