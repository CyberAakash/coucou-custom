#if !APPSTORE
import AppKit
import Carbon.HIToolbox

// MARK: - TerminalInput (coucou-custom fork)
//
// The Sessions view's message box: the text reaches the session as if typed at its prompt, so
// Claude Code treats it as a real user prompt and answers in the terminal (the hooks then show
// the turn in the notch). Claude Code has no supported way for another app to inject a prompt
// into a running interactive session (channels need a launch flag; the cross-session socket
// speaks as another session, not the user), so the terminal itself carries it:
//   • iTerm2 (`write text`), Terminal.app (`do script … in tab`), tmux (`send-keys`), kitty
//     (`kitten @ send-text`), WezTerm (`wezterm cli send-text`): straight into the tab, no focus.
//   • Warp and the rest: TerminalFocus brings the session's tab forward, the text is pasted
//     (⌘V: a bracketed paste, so several lines stay one message) and Return pressed; the
//     clipboard and the app that was in front come back.

@MainActor
enum TerminalInput {

    enum Failure: LocalizedError {
        case empty, noAccessibility, tabNotInFront, failed
        var errorDescription: String? {
            switch self {
            case .empty: return "Nothing to send."
            case .noAccessibility: return "Coucou needs the Accessibility permission to type in this terminal."
            case .tabNotInFront: return "Couldn't bring the session's tab forward."
            case .failed: return "The terminal didn't take the message."
            }
        }
    }

    static func send(_ raw: String, to s: SessionTracker.Session) async -> Result<Void, Failure> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        let oneLine = text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
        let t = s.terminal
        let app = s.hostApp ?? s.bundleId ?? ""

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
        return await pasteIntoFocusedTab(text, session: s)
    }

    // MARK: Warp and the rest: focus the tab, paste, Return

    private static func pasteIntoFocusedTab(_ text: String, session s: SessionTracker.Session) async -> Result<Void, Failure> {
        guard AXIsProcessTrusted() else { return .failure(.noAccessibility) }
        guard let app = s.hostApp ?? s.bundleId else { return .failure(.tabNotInFront) }
        let previous = NSWorkspace.shared.frontmostApplication
        TerminalFocus.open(s) { TerminalFocus.activate(app) }
        // Warp switches tab on its URL and comes forward a moment later.
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(80))
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == app { break }
        }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == app else { return .failure(.tabNotInFront) }
        try? await Task.sleep(for: .milliseconds(180))

        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t, $0) } })
        }
        board.clearContents()
        board.setString(text, forType: .string)
        let stamp = board.changeCount

        key(FlowPaste.vKeyCode(), flags: .maskCommand)
        try? await Task.sleep(for: .milliseconds(160))
        key(CGKeyCode(kVK_Return), flags: [])

        // Put the clipboard back (unless the user copied something meanwhile) and give the
        // front back to the app the user was in.
        try? await Task.sleep(for: .milliseconds(450))
        if board.changeCount == stamp {
            board.clearContents()
            if !saved.isEmpty {
                board.writeObjects(saved.map { entry in
                    let item = NSPasteboardItem()
                    for (type, data) in entry { item.setData(data, forType: type) }
                    return item
                })
            }
        }
        if let previous, previous.bundleIdentifier != app, previous.bundleIdentifier != Bundle.main.bundleIdentifier {
            previous.activate()
        }
        return .success(())
    }

    private static func key(_ code: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
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
