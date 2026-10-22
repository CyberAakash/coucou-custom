#if !APPSTORE
import AppKit

// MARK: - TerminalInput (coucou-custom fork)
//
// The Sessions view's message box. Nothing ever switches app or tab:
//   • First choice: the session's cross-session inbox (Claude Code v2.1.224+, on by default). Every
//     session listens on a per-user Unix socket, exported to its hooks as
//     CLAUDE_CODE_MESSAGING_SOCKET / _TOKEN (the relay records them). Claude reads a message
//     between tool calls while busy, and starts a turn with it when idle. It arrives as a message
//     from another session ("Message from …"), so it can't approve permissions or run commands.
//   • Otherwise the terminal's own no-focus input: iTerm2 `write text`, Terminal.app
//     `do script … in tab`, tmux `send-keys`, kitty `kitten @ send-text`, WezTerm `send-text`.
//   • Otherwise (e.g. Warp before the session's next hook event): not sent, never a focus switch.

@MainActor
enum TerminalInput {

    enum Failure: LocalizedError {
        case empty, noRoute, failed
        var errorDescription: String? {
            switch self {
            case .empty: return "Nothing to send."
            case .noRoute: return "This session can't take messages yet: it will after its next step."
            case .failed: return "The session didn't take the message."
            }
        }
    }

    static func send(_ raw: String, to s: SessionTracker.Session) async -> Result<Void, Failure> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        let oneLine = text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
        let t = s.terminal
        let app = s.hostApp ?? s.bundleId ?? ""

        if let path = inboxPath(t["messaging_socket"]) {
            if await postToInbox(path: path, token: t["messaging_token"], text: text) { return .success(()) }
            appendAppLog("nb.log", "[Sessions] inbox of \(s.projectName) refused the connection; trying the terminal")
        }

        // tmux first: it owns the pane whatever the host terminal.
        if let pane = t["tmux_pane"], pane.range(of: #"^%\d+$"#, options: .regularExpression) != nil,
           let socket = t["tmux"]?.split(separator: ",").first.map(String.init), socket.hasPrefix("/"),
           let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
               .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            if await run(tmux, ["-S", socket, "send-keys", "-t", pane, "-l", "--", oneLine]),
               await run(tmux, ["-S", socket, "send-keys", "-t", pane, "Enter"]) {
                return .success(())
            }
        }

        switch app {
        case "com.googlecode.iterm2":
            if let uuid = TerminalFocus.itermUUID(t["iterm_session_id"]),
               await script("""
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if unique id of s is "\(uuid)" then
                                    tell s to write text "\(appleScriptEscaped(oneLine))"
                                    return true
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                return false
                """) { return .success(()) }
        case "com.apple.Terminal":
            if let tty = TerminalFocus.validTTY(t["tty"]),
               await script("""
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "/dev/\(tty)" then
                                do script "\(appleScriptEscaped(oneLine))" in t
                                return true
                            end if
                        end repeat
                    end repeat
                end tell
                return false
                """) { return .success(()) }
        case "net.kovidgoyal.kitty":
            if let id = TerminalFocus.digits(t["kitty_window_id"]), let socket = t["kitty_listen_on"], socket.hasPrefix("unix:"),
               let kitten = tool("net.kovidgoyal.kitty", "kitten"),
               await run(kitten, ["@", "--to", socket, "send-text", "--match", "id:\(id)", "--", oneLine + "\r"]) {
                return .success(())
            }
        case "com.github.wez.wezterm":
            if let pane = TerminalFocus.digits(t["wezterm_pane"]), let wezterm = tool("com.github.wez.wezterm", "wezterm"),
               await run(wezterm, ["cli", "send-text", "--pane-id", pane, "--no-paste", oneLine + "\r"]) {
                return .success(())
            }
        default:
            break
        }
        return .failure(.noRoute)
    }

    // MARK: Cross-session inbox

    /// The socket the session's own hooks were given, if it is still a socket of this user.
    nonisolated static func inboxPath(_ raw: String?) -> String? {
        guard var path = raw?.trimmingCharacters(in: .whitespaces), !path.isEmpty else { return nil }
        if path.hasPrefix("uds:") { path.removeFirst(4) }
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid() else { return nil }
        return path
    }

    /// One newline-delimited JSON user message, after the auth line when a token is known
    /// (optional on macOS). Claude Code acknowledges nothing: a clean write is success.
    private static func postToInbox(path: String, token: String?, text: String) async -> Bool {
        var lines: [[String: Any]] = []
        if let token, !token.isEmpty { lines.append(["type": "auth", "token": token]) }
        lines.append(["type": "user", "message": ["role": "user", "content": text]])
        let payload = lines.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
            .map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
        let bytes = Array(payload.utf8)
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else { cont.resume(returning: false); return }
                defer { close(fd) }
                var timeout = timeval(tv_sec: 3, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var addr = sockaddr_un()
                addr.sun_family = sa_family_t(AF_UNIX)
                let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
                guard path.utf8.count < maxLen else { cont.resume(returning: false); return }
                withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                    for (i, b) in path.utf8.enumerated() { raw[i] = b }
                }
                let connected = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                guard connected == 0 else { cont.resume(returning: false); return }
                var sent = 0
                while sent < bytes.count {
                    let n = bytes[sent...].withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
                    if n <= 0 { cont.resume(returning: false); return }
                    sent += n
                }
                cont.resume(returning: true)
            }
        }
    }

    // MARK: Helpers

    /// Inside an AppleScript string literal only the backslash and the quote need escaping.
    nonisolated static func appleScriptEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func script(_ source: String) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                cont.resume(returning: error == nil && (result?.booleanValue ?? false))
            }
        }
    }

    private static func run(_ path: String, _ args: [String]) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: false); return }
                let deadline = Date().addingTimeInterval(3)
                while p.isRunning && Date() < deadline { usleep(20_000) }
                if p.isRunning { p.terminate(); cont.resume(returning: false); return }
                cont.resume(returning: p.terminationStatus == 0)
            }
        }
    }

    private static func tool(_ bundleId: String, _ name: String) -> String? {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        let path = app.appendingPathComponent("Contents/MacOS/\(name)").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}
#endif
