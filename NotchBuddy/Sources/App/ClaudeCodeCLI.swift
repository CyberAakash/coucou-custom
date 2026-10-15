#if !APPSTORE
import Foundation
import Security

enum ClaudeCodeCLIError: LocalizedError {
    case notInstalled
    /// A `claude` was found but it is not Anthropic's signed binary.
    case untrustedBinary(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Claude Code isn't installed. Install it, run `claude` once to sign in, then ask again."
        case .untrustedBinary(let path):
            return "\(path) isn't signed by Anthropic. Update Claude Code, then ask again."
        case .failed(let message):
            return message
        }
    }
}

/// Talks to Claude through the user's installed Claude Code CLI (`claude -p`), so the chat runs on
/// their Claude subscription login instead of an API key. Anthropic only allows subscription
/// credentials through Claude Code itself, which is why this drives the CLI rather than reading
/// its OAuth token and calling the Messages API.
enum ClaudeCodeCLI {

    /// Anthropic PBC's Developer ID team. Without this check any executable named `claude`
    /// earlier on a search path would receive the user's prompts and files.
    private static let anthropicRequirement =
        #"anchor apple generic and certificate leaf[subject.OU] = "Q6L2SF6YDW""#

    struct Reply: Sendable {
        let text: String
        let sessionID: String?
    }

    // MARK: Locating the binary

    /// Native installer, Homebrew, npm (global and nvm). GUI apps get launchd's PATH, not the
    /// user's shell PATH, so `which` alone would miss most installs.
    static func executablePath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/Library/pnpm/claude",
        ]
        let nvmNode = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmNode) {
            let sorted = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            candidates += sorted.map { "\(nvmNode)/\($0)/bin/claude" }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isInstalled: Bool { executablePath() != nil }

    /// Resolves symlinks first: npm's `bin/claude` is a link to the signed `claude.exe`.
    static func isSignedByAnthropic(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(resolved as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(anthropicRequirement as CFString, [], &requirement) == errSecSuccess
        else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement)
            == errSecSuccess
    }

    // MARK: Running a turn

    /// Sends one user turn. `resume` continues an earlier reply's session so the CLI keeps the
    /// conversation; nil starts a new one. `readableFile` lets Claude open that one file (PDFs and
    /// images it cannot get inline). `mcpConfig` is an MCP config file whose servers are the only
    /// ones loaded; their tools still need naming in `allowedTools`. `onText` gets the streamed
    /// text so far, on the main actor.
    static func run(
        prompt: String,
        system: String,
        model: String,
        webSearch: Bool,
        readableFile: URL? = nil,
        mcpConfig: URL? = nil,
        allowedTools: [String] = [],
        resume: String? = nil,
        timeout: TimeInterval = 300,
        onText: (@MainActor @Sendable (String) -> Void)? = nil
    ) async throws -> Reply {
        guard let path = executablePath() else { throw ClaudeCodeCLIError.notInstalled }
        guard isSignedByAnthropic(path) else { throw ClaudeCodeCLIError.untrustedBinary(path) }

        var tools: [String] = []
        if webSearch { tools.append("WebSearch") }
        var allowed = tools + allowedTools
        if let readableFile {
            tools.append("Read")
            // `//` marks an absolute path in Claude Code permission rules.
            allowed.append("Read(/\(readableFile.path))")
        }

        var args = [
            "-p",
            "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--model", model,
            "--system-prompt", system,
            "--tools", tools.joined(separator: ","),
            // Keep the user's MCP servers, hooks, CLAUDE.md and skills out of Mochi's chat:
            // they add hundreds of thousands of tokens per turn, and Coucou's own hooks would
            // show this chat as an agent session in the notch.
            "--strict-mcp-config",
            "--setting-sources", "",
            "--disable-slash-commands",
        ]
        if let mcpConfig { args += ["--mcp-config", mcpConfig.path] }
        if !allowed.isEmpty { args += ["--allowedTools", allowed.joined(separator: ",")] }
        if let resume { args += ["--resume", resume] }

        return try await Task.detached(priority: .userInitiated) {
            try await execute(path: path, args: args, prompt: prompt, timeout: timeout, onText: onText)
        }.value
    }

    /// Sessions resume by working directory, so every chat lives in one folder of its own,
    /// apart from the user's projects.
    private static func workingDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Coucou/ClaudeCodeChat", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func execute(
        path: String,
        args: [String],
        prompt: String,
        timeout: TimeInterval,
        onText: (@MainActor @Sendable (String) -> Void)?
    ) async throws -> Reply {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.currentDirectoryURL = workingDirectory()
        var env = ProcessInfo.processInfo.environment
        // An inherited key would make the CLI bill the API instead of the subscription.
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        env["PATH"] = [URL(fileURLWithPath: path).deletingLastPathComponent().path, "/opt/homebrew/bin",
                       "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
        process.environment = env

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        // Through stdin, not argv: file contents can exceed ARG_MAX and argv shows up in `ps`.
        input.fileHandleForWriting.write(Data(prompt.utf8))
        try? input.fileHandleForWriting.close()

        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer {
            deadline.cancel()
            if process.isRunning { process.terminate() }
        }

        var streamed = ""
        var lastUpdate = Date.distantPast
        var final: (text: String, isError: Bool, session: String?)?

        try await withTaskCancellationHandler {
            for try await line in output.fileHandleForReading.bytes.lines {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                switch obj["type"] as? String {
                case "stream_event":
                    // Subagent output carries a parent tool id; only the main answer is shown.
                    guard obj["parent_tool_use_id"] is NSNull || obj["parent_tool_use_id"] == nil,
                          let event = obj["event"] as? [String: Any] else { continue }
                    if event["type"] as? String == "message_start", !streamed.isEmpty {
                        streamed += "\n\n"
                    }
                    guard event["type"] as? String == "content_block_delta",
                          let delta = event["delta"] as? [String: Any],
                          delta["type"] as? String == "text_delta",
                          let text = delta["text"] as? String else { continue }
                    streamed += text
                    let now = Date()
                    if let onText, now.timeIntervalSince(lastUpdate) >= 1.0 / 15.0 {
                        lastUpdate = now
                        let snapshot = streamed
                        await MainActor.run { onText(snapshot) }
                    }
                case "result":
                    final = (obj["result"] as? String ?? "",
                             obj["is_error"] as? Bool ?? false,
                             obj["session_id"] as? String)
                default:
                    continue
                }
            }
        } onCancel: {
            process.terminate()
        }
        process.waitUntilExit()

        guard let final else {
            let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ClaudeCodeCLIError.failed(stderr.isEmpty
                ? "Claude Code stopped without answering (exit \(process.terminationStatus))."
                : stderr)
        }
        if final.isError {
            throw ClaudeCodeCLIError.failed(final.text.isEmpty ? "Claude Code returned an error." : final.text)
        }
        let text = final.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Reply(text: text.isEmpty ? streamed : text, sessionID: final.session)
    }

    // MARK: Models

    /// A subscription login cannot call `/v1/models`, so this list is fixed: every model the
    /// Claude Code 2.1.300 binary knows that answered on a Pro/Max login on 2026-10-15. Left out:
    /// dated duplicates, retired IDs, and claude-opus-4-0/4-1, which the CLI silently serves with
    /// Opus 5.5. The aliases follow the newest model of each family; any other ID can still be
    /// typed as a custom model.
    static let models: [(id: String, label: String)] = [
        ("sonnet", "Sonnet (always latest)"),
        ("opus", "Opus (always latest)"),
        ("haiku", "Haiku (always latest)"),
        ("claude-fable-5-1", "Claude Fable 5.1"),
        ("claude-fable-5", "Claude Fable 5"),
        ("claude-opus-5-5", "Claude Opus 5.5"),
        ("claude-opus-5", "Claude Opus 5"),
        ("claude-opus-4-8", "Claude Opus 4.8"),
        ("claude-opus-4-7", "Claude Opus 4.7"),
        ("claude-opus-4-6", "Claude Opus 4.6"),
        ("claude-opus-4-5", "Claude Opus 4.5"),
        ("claude-sonnet-5-5", "Claude Sonnet 5.5"),
        ("claude-sonnet-5", "Claude Sonnet 5"),
        ("claude-sonnet-4-6", "Claude Sonnet 4.6"),
        ("claude-sonnet-4-5", "Claude Sonnet 4.5"),
        ("claude-haiku-5-5", "Claude Haiku 5.5"),
        ("claude-haiku-4-5", "Claude Haiku 4.5"),
    ]
}
#endif
