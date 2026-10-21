import Foundation

// MARK: - TerminalFocus tests (coucou-custom fork): the values that reach AppleScript / CLIs.

func appendAppLog(_ file: String, _ line: String) {}   // the app's logger, not needed here

@main
enum TerminalFocusTests {
    static var failures = 0
    static func check(_ label: String, _ ok: Bool) {
        print(ok ? "✓ \(label)" : "✗ \(label)")
        if !ok { failures += 1 }
    }

    static func main() {
        // Warp
        check("warp focus url", TerminalFocus.warpURL("warp://session/b27ae6ba8434448e87dc803b0dc01a08") != nil)
        check("warp: other action refused", TerminalFocus.warpURL("warp://action/new_tab?path=/") == nil)
        check("warp: other scheme refused", TerminalFocus.warpURL("https://session/b27ae6ba8434448e87dc803b0dc01a08") == nil)
        check("warp: trailing junk refused", TerminalFocus.warpURL("warp://session/b27ae6ba8434448e87dc803b0dc01a08?x=1") == nil)
        // tty
        check("tty ttys012", TerminalFocus.validTTY("ttys012") == "ttys012")
        check("tty /dev/ttys3", TerminalFocus.validTTY("/dev/ttys3") == "ttys3")
        check("tty injection refused", TerminalFocus.validTTY("ttys1\" then do shell script \"x") == nil)
        check("tty ?? refused", TerminalFocus.validTTY("??") == nil)
        // iTerm2
        check("iterm uuid", TerminalFocus.itermUUID("w0t1p0:1C6F0A7E-6A1B-4C3D-9E8F-0123456789AB") == "1C6F0A7E-6A1B-4C3D-9E8F-0123456789AB")
        check("iterm injection refused", TerminalFocus.itermUUID("w0t0p0:\" & (do shell script \"id\") & \"") == nil)
        // numbers, paths
        check("digits", TerminalFocus.digits("42") == "42" && TerminalFocus.digits("4 2") == nil && TerminalFocus.digits("1;rm") == nil)
        check("path ok", TerminalFocus.safeAppleScriptString("/Users/x/my project") == "/Users/x/my project")
        check("path with quote refused", TerminalFocus.safeAppleScriptString("/Users/x/a\"b") == nil)
        check("relative path refused", TerminalFocus.safeAppleScriptString("x/y") == nil)

        // The tracker keeps each session's handles, and the latest value of each.
        var t = SessionTracker()
        t.apply(event: "UserPromptSubmit", payload: ["session_id": "A", "prompt": "x",
            "coucou_terminal": ["warp_focus_url": "warp://session/aa11", "tty": "ttys001"]],
            pill: "integration_claude", projectName: "p", hostApp: "dev.warp.Warp-Stable")
        t.apply(event: "PreToolUse", payload: ["session_id": "A", "tool_name": "Bash",
            "coucou_terminal": ["warp_focus_url": "warp://session/aa11"]],
            pill: "integration_claude", projectName: "p", hostApp: "dev.warp.Warp-Stable")
        t.apply(event: "UserPromptSubmit", payload: ["session_id": "B", "prompt": "y", "iterm_session_id": "w0t0p0:U"],
            pill: "integration_claude", projectName: "q", hostApp: "com.googlecode.iterm2")
        check("tty kept when a later event has none", t.sessions["A"]?.terminal["tty"] == "ttys001")
        check("warp url kept", t.sessions["A"]?.terminal["warp_focus_url"] == "warp://session/aa11")
        check("iterm id stored, per session", t.sessions["B"]?.terminal["iterm_session_id"] == "w0t0p0:U"
              && t.sessions["A"]?.terminal["iterm_session_id"] == nil)

        print(failures == 0 ? "\nTerminalFocusTests: all passed" : "\n\(failures) failed")
        if failures > 0 { exit(1) }
    }
}
