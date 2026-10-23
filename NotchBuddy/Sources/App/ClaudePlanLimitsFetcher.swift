#if !APPSTORE
import Foundation

// coucou-custom fork: asks the installed Claude Code for the plan's limits (its `get_usage` control
// request, the data behind /usage): Anthropic's signed `claude`, on the user's own login, with no
// prompt, no tools, no settings (so no hooks: it never shows as an agent session), nothing saved.
// Asked only while something shows the plan (the menu-bar panel open, the plan beside the icon, a
// brief being made), at most once a minute; the status line's two windows stand in meanwhile.

@MainActor
final class ClaudePlanLimitsFetcher: ObservableObject {
    static let shared = ClaudePlanLimitsFetcher()

    @Published private(set) var limits: ClaudePlanLimits?
    @Published private(set) var lastError: String?
    private var inFlight = false
    private var lastAttempt = Date.distantPast

    static let minInterval: TimeInterval = 60

    /// The CLI's answer when there is one, else the status line's windows.
    var best: ClaudePlanLimits? {
        if let limits { return limits }
        guard let u = AppState.shared.claudePlanUsage else { return nil }
        return ClaudePlanLimits.from(PlanUsageWindows(
            fiveHour: u.fiveHour.map { ($0.usedPct, $0.resetsAt) },
            sevenDay: u.sevenDay.map { ($0.usedPct, $0.resetsAt) },
            updatedAt: u.updatedAt))
    }

    /// Asks again when the last attempt is older than `maxAge` (never more than once a minute).
    func refresh(maxAge: TimeInterval = minInterval) {
        Task { _ = await fetch(maxAge: maxAge) }
    }

    /// The limits, asked anew when older than `maxAge`; waits for an answer already on its way.
    func fetch(maxAge: TimeInterval = minInterval) async -> ClaudePlanLimits? {
        while inFlight { try? await Task.sleep(for: .milliseconds(200)) }
        guard Date().timeIntervalSince(lastAttempt) >= max(maxAge, Self.minInterval) else { return best }
        guard let path = ClaudeCodeCLI.executablePath(), ClaudeCodeCLI.isSignedByAnthropic(path) else {
            lastError = "Claude Code is not installed or not signed by Anthropic."
            return best
        }
        inFlight = true
        lastAttempt = Date()
        let result = await Task.detached(priority: .utility) { Self.ask(path: path) }.value
        inFlight = false
        switch result {
        case .success(let l): limits = l; lastError = nil
        case .failure(let e): lastError = e.message
        }
        return best
    }

    struct Failure: Error { let message: String }

    nonisolated private static func ask(path: String) -> Result<ClaudePlanLimits, Failure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                             "--setting-sources", "", "--strict-mcp-config", "--tools", "",
                             "--disable-slash-commands", "--no-session-persistence"]
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Coucou/ClaudeCodeUsage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        process.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        // An inherited key would answer for the API account, not the subscription.
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        env["PATH"] = [URL(fileURLWithPath: path).deletingLastPathComponent().path, "/opt/homebrew/bin",
                       "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
        process.environment = env
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .failure(Failure(message: "Claude Code could not start.")) }
        let request = #"{"type":"control_request","request_id":"coucou-usage","request":{"subtype":"get_usage","skip_behaviors":true}}"#
        input.fileHandleForWriting.write(Data((request + "\n").utf8))

        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: deadline)
        defer {
            deadline.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        var buffer = Data()
        let reader = output.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      obj["type"] as? String == "control_response",
                      let outer = obj["response"] as? [String: Any],
                      outer["request_id"] as? String == "coucou-usage" else { continue }
                guard outer["subtype"] as? String == "success", let response = outer["response"] as? [String: Any] else {
                    return .failure(Failure(message: (outer["error"] as? String) ?? "Claude Code could not read the plan."))
                }
                guard let limits = ClaudePlanLimits.parse(response) else {
                    return .failure(Failure(message: "No plan limits for this account (an API key or another provider)."))
                }
                return .success(limits)
            }
        }
        return .failure(Failure(message: "Claude Code gave no answer."))
    }
}
#endif
