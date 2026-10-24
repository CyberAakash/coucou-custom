#if !APPSTORE
import AppKit

// MARK: - TerminalFocus (coucou-custom fork)
//
// "Open terminal" brings the session's own tab forward, not just the terminal app. The hook relay
// records per-tab handles (SessionTracker.Session.terminal); each terminal is driven its own way:
//   • Warp: undocumented WARP_FOCUS_URL (warp://session/<uuid>, exported in every Warp shell)
//     switches to the tab; Warp does not come to the front on its own, so it is activated too.
//   • Terminal.app: AppleScript, the tab whose tty is the session's.
//   • iTerm2: AppleScript, the session whose unique id ends ITERM_SESSION_ID.
//   • Ghostty 1.3+: AppleScript `focus`, the terminal whose working directory is the session's.
//   • kitty / WezTerm: their CLIs (kitty needs remote control on, with a listen socket).
//   • tmux inside any of them: select the pane first, then focus the host tab as above.
// Every value that reaches a script or a command is validated first; anything unknown falls
// back to bringing the app forward, as upstream does.

@MainActor
enum TerminalFocus {

    static let defaultKey = "coucouDefaultTerminal"

    /// Settings → Agents → Default terminal: opened when a session's own terminal is unknown,
    /// instead of Terminal.app. nil = Automatic.
    static var defaultTerminal: String? {
        let id = UserDefaults.standard.string(forKey: defaultKey) ?? ""
        return id.isEmpty ? nil : id
    }

    static let choices: [(id: String, name: String)] = [
        ("dev.warp.Warp-Stable", "Warp"),
        ("com.apple.Terminal", "Terminal"),
        ("com.googlecode.iterm2", "iTerm2"),
        ("com.mitchellh.ghostty", "Ghostty"),
        ("net.kovidgoyal.kitty", "kitty"),
        ("com.github.wez.wezterm", "WezTerm"),
    ]

    static var installedChoices: [(id: String, name: String)] {
        choices.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
    }

    /// Brings `session`'s own tab forward; if that is not possible, runs `fallback`.
    /// `from`: which button asked (for the log; two buttons resolving sessions differently
    /// looked identical there).
    static func open(_ session: SessionTracker.Session?, from: String = "?", fallback: @escaping @MainActor () -> Void) {
        guard let session, let plan = plan(for: session) else {
            appendAppLog("nb.log", "[Terminal] (\(from)) no tab known for \(session?.projectName ?? "this pill"): app only")
            fallback(); return
        }
        let app = session.hostApp ?? session.bundleId
        let name = session.projectName
        worker.async {
            let done = plan()
            DispatchQueue.main.async {
                // "asked": a link or script was handed to the terminal; whether it reached the tab
                // is only known to the terminal. The front check below says if it came forward.
                appendAppLog("nb.log", "[Terminal] (\(from)) \(name) \(session.id.prefix(8)): \(done ? "asked \(app ?? "?") for its tab" : "tab not found, app only") (front was \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"))")
                if done {
                    if let app { activate(app) }
                } else {
                    fallback()
                }
            }
        }
    }

    /// Upstream's fallback, with the default terminal in place of Terminal.app.
    static func openDefaultTerminal() {
        let id = defaultTerminal ?? "com.apple.Terminal"
        if !activate(id), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        }
    }

    @discardableResult
    static func activate(_ bundleId: String) -> Bool {
        AppActivation.bringToFront(bundleId: bundleId)
    }

    // MARK: Per-terminal plans (run on `worker`, return true when the tab was focused)

    /// AppleScript and CLIs can block for long if a terminal hangs: never on the main thread.
    private static let worker = DispatchQueue(label: "coucou.terminal-focus")

    private static func plan(for s: SessionTracker.Session) -> (@Sendable () -> Bool)? {
        let t = s.terminal
        let tmux = tmuxStep(t)
        let host: (@Sendable () -> Bool)?
        switch s.hostApp ?? s.bundleId ?? "" {
        case "dev.warp.Warp-Stable", "dev.warp.Warp-Preview":
            host = warpURL(t["warp_focus_url"]).map { url in { @Sendable in NSWorkspace.shared.open(url) } }
        case "com.apple.Terminal":
            host = validTTY(t["tty"]).map { tty in { @Sendable in runScript("""
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "/dev/\(tty)" then
                                set selected of t to true
                                set index of w to 1
                                return true
                            end if
                        end repeat
                    end repeat
                end tell
                return false
                """) } }
        case "com.googlecode.iterm2":
            host = itermUUID(t["iterm_session_id"]).map { uuid in { @Sendable in runScript("""
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if unique id of s is "\(uuid)" then
                                    select w
                                    tell t to select
                                    tell s to select
                                    return true
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                return false
                """) } }
        case "com.mitchellh.ghostty":
            host = safeAppleScriptString(s.cwd).map { cwd in { @Sendable in runScript("""
                tell application "Ghostty"
                    set matches to (every terminal whose working directory is "\(cwd)")
                    if (count of matches) is 0 then return false
                    focus (item 1 of matches)
                    return true
                end tell
                """) } }
        case "net.kovidgoyal.kitty":
            if let id = digits(t["kitty_window_id"]), let socket = t["kitty_listen_on"], socket.hasPrefix("unix:"),
               let kitten = bundledTool("net.kovidgoyal.kitty", "kitten") {
                host = { @Sendable in runTool(kitten, ["@", "--to", socket, "focus-window", "--match", "id:\(id)"]) }
            } else { host = nil }
        case "com.github.wez.wezterm":
            if let pane = digits(t["wezterm_pane"]), let wezterm = bundledTool("com.github.wez.wezterm", "wezterm") {
                host = { @Sendable in runTool(wezterm, ["cli", "activate-pane", "--pane-id", pane]) }
            } else { host = nil }
        default:
            host = nil
        }
        guard tmux != nil || host != nil else { return nil }
        return { @Sendable in
            let inTmux = tmux?() ?? false
            let focused = host?() ?? false
            return focused || inTmux
        }
    }

    private static func tmuxStep(_ t: [String: String]) -> (@Sendable () -> Bool)? {
        guard let pane = t["tmux_pane"], pane.range(of: #"^%\d+$"#, options: .regularExpression) != nil,
              let socket = t["tmux"]?.split(separator: ",").first.map(String.init), socket.hasPrefix("/"),
              let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        return { @Sendable in
            runTool(tmux, ["-S", socket, "select-window", "-t", pane])
                && runTool(tmux, ["-S", socket, "select-pane", "-t", pane])
        }
    }

    // MARK: Validation (values from the hook payload end up in scripts and commands)

    nonisolated static func warpURL(_ raw: String?) -> URL? {
        guard let raw, raw.range(of: #"^warp://session/[0-9a-fA-F-]{16,64}$"#, options: .regularExpression) != nil
        else { return nil }
        return URL(string: raw)
    }

    nonisolated static func validTTY(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let name = raw.hasPrefix("/dev/") ? String(raw.dropFirst(5)) : raw
        return name.range(of: #"^ttys\d{1,4}$"#, options: .regularExpression) != nil ? name : nil
    }

    /// ITERM_SESSION_ID is "w0t1p0:<UUID>"; AppleScript's unique id is the UUID.
    nonisolated static func itermUUID(_ raw: String?) -> String? {
        guard let uuid = raw?.split(separator: ":").last.map(String.init),
              uuid.range(of: #"^[0-9A-Fa-f-]{36}$"#, options: .regularExpression) != nil else { return nil }
        return uuid
    }

    nonisolated static func digits(_ raw: String?) -> String? {
        guard let raw, raw.range(of: #"^\d{1,9}$"#, options: .regularExpression) != nil else { return nil }
        return raw
    }

    /// A path that can sit inside an AppleScript string as is: no quote, backslash or newline.
    nonisolated static func safeAppleScriptString(_ raw: String) -> String? {
        guard raw.hasPrefix("/"), !raw.contains(where: { $0 == "\"" || $0 == "\\" || $0.isNewline }) else { return nil }
        return raw
    }

    // MARK: Running

    nonisolated private static func runScript(_ source: String) -> Bool {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            appendAppLog("nb.log", "[Terminal] focus script failed: \(error[NSAppleScript.errorNumber] ?? "?")")
            return false
        }
        return result?.booleanValue ?? false
    }

    nonisolated private static func runTool(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return false }
        return p.terminationStatus == 0
    }

    nonisolated private static func bundledTool(_ bundleId: String, _ name: String) -> String? {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        let path = app.appendingPathComponent("Contents/MacOS/\(name)").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}
#endif
