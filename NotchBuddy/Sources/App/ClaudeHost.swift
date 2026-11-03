import AppKit

// MARK: - ClaudeHost
//
// The app a Claude Code session runs in, from the hook payload's term_program /
// bundle_id. VS Code sessions keep the original "VS Code" pill; sessions from a
// terminal also route to integration_claude and the pill says "Claude Code".

struct ClaudeHost: Equatable {
    let bundleId: String
    let name: String

    /// UserDefaults key: show terminal sessions' questions and permission requests in the
    /// notch (they then wait for the notch). Off by default: the terminal asks itself.
    static let terminalCardsKey = "terminalCardsEnabled"
    static var terminalCardsEnabled: Bool { UserDefaults.standard.bool(forKey: terminalCardsKey) }

    /// Terminals (and agent apps like Conductor) accepted for Claude Code sessions.
    /// Keyed by bundle id; the second
    /// table maps TERM_PROGRAM for hooks that run without __CFBundleIdentifier.
    private static let terminals: [String: String] = [
        "dev.warp.Warp-Stable":       "Warp",
        "dev.warp.Warp-Preview":      "Warp",
        "com.apple.Terminal":         "Terminal",
        "com.googlecode.iterm2":      "iTerm",
        "com.mitchellh.ghostty":      "Ghostty",
        "net.kovidgoyal.kitty":       "kitty",
        "org.alacritty":              "Alacritty",
        "com.github.wez.wezterm":     "WezTerm",
        "co.zeit.hyper":              "Hyper",
        "dev.zed.Zed":                "Zed",
        "com.cmuxterm.app":           "cmux",    // sets TERM_PROGRAM=ghostty: the bundle id decides
        "com.stablyai.orca":          "Orca",
        "com.conductor.app":          "Conductor", // runs Claude Code with no TERM_PROGRAM
    ]
    private static let termPrograms: [String: String] = [
        "warpterminal":   "dev.warp.Warp-Stable",
        "apple_terminal": "com.apple.Terminal",
        "iterm.app":      "com.googlecode.iterm2",
        "ghostty":        "com.mitchellh.ghostty",
        "kitty":          "net.kovidgoyal.kitty",
        "alacritty":      "org.alacritty",
        "wezterm":        "com.github.wez.wezterm",
        "hyper":          "co.zeit.hyper",
        "zed":            "dev.zed.Zed",
    ]

    /// The terminal a session runs in (coucou-custom fork: any terminal, not only the listed
    /// ones): a listed one; a build of one (`com.mitchellh.ghostty.debug`, a fork, a nightly),
    /// named after the app itself; any other app on this Mac a shell runs Claude Code in (a new
    /// terminal, an IDE's terminal); then TERM_PROGRAM for hooks without a bundle id.
    static func terminal(termProgram: String, bundleId: String) -> ClaudeHost? {
        if let name = terminals[bundleId] { return ClaudeHost(bundleId: bundleId, name: name) }
        if family(bundleId) != nil || isOtherApp(bundleId) {
            let name = appName(bundleId) ?? family(bundleId).flatMap { terminals[$0] } ?? bundleId
            remember(bundleId, name)
            return ClaudeHost(bundleId: bundleId, name: name)
        }
        if let id = termPrograms[termProgram.lowercased()], let name = terminals[id] {
            return ClaudeHost(bundleId: id, name: name)
        }
        return nil
    }

    /// The listed terminal a bundle id belongs to: itself, or one it extends
    /// ("com.mitchellh.ghostty.debug" → "com.mitchellh.ghostty").
    static func family(_ id: String) -> String? {
        guard !id.isEmpty else { return nil }
        if terminals[id] != nil { return id }
        return terminals.keys.first { id.hasPrefix($0 + ".") || id.hasPrefix($0 + "-") }
    }

    /// An app on this Mac that is not one Coucou routes another way (Claude's own apps run
    /// their sessions themselves).
    private static func isOtherApp(_ id: String) -> Bool {
        guard !id.isEmpty, !id.hasPrefix("com.anthropic.") else { return false }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
    }

    static func appName(_ id: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let info = Bundle(url: url)?.infoDictionary
        return (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String)
            ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Terminals seen running a session, beyond the listed ones: offered as the default terminal
    /// and tried when a session's own is not running.
    static let seenKey = "coucouSeenTerminals"
    static var seen: [String: String] { UserDefaults.standard.dictionary(forKey: seenKey) as? [String: String] ?? [:] }

    private static func remember(_ id: String, _ name: String) {
        var all = seen
        guard all[id] != name else { return }
        all[id] = name
        UserDefaults.standard.set(all, forKey: seenKey)
    }

    /// The app name for a task's host; nil host means VS Code (the original routing).
    static func name(for hostBundleId: String?) -> String {
        guard let id = hostBundleId else { return "VS Code" }
        return terminals[id] ?? seen[id] ?? appName(id) ?? "VS Code"
    }

    /// Pill label for integration_claude: "VS Code" for editor sessions, "Claude Code" otherwise.
    static func pillName(hostApp: String?) -> String {
        hostApp == nil ? "VS Code" : "Claude Code"
    }

    /// Brings the session's terminal forward (launching it if needed). false when not a terminal host.
    @MainActor @discardableResult
    static func activate(_ hostBundleId: String?) -> Bool {
        guard let id = hostBundleId, terminals[id] != nil || seen[id] != nil
                || NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil else { return false }
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == id }) {
            AppActivation.bringToFront(running)   // coucou-custom fork: activate() alone is ignored since macOS 14
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        }
        return true
    }
}
