import Foundation

/// Picks which app "Open terminal" / ⌃⌥T should bring to the front.
/// Foundation only, so it can be tested without AppKit (see scripts/test-terminal-target.sh).
enum TerminalTarget {
    /// Terminals tried, in order, when the session's own app is unknown or not running.
    static let knownTerminals = [
        "com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty",
        "com.mitchellh.ghostty", "com.cmuxterm.app", "dev.warp.Warp-Stable",
        "com.github.wez.wezterm", "org.alacritty",
    ]

    /// Bundle IDs to try, in order: the app the session runs in (from the hook's
    /// `bundle_id`, i.e. `__CFBundleIdentifier`), then the known terminals.
    static func candidates(sessionBundleId: String?) -> [String] {
        let own = sessionBundleId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // coucou-custom fork: terminals seen running a session (ClaudeHost.seen) are tried too.
        let seen = (UserDefaults.standard.dictionary(forKey: "coucouSeenTerminals") ?? [:]).keys.sorted()
        let all = knownTerminals + seen.filter { !knownTerminals.contains($0) }
        guard !own.isEmpty else { return all }
        return [own] + all.filter { $0 != own }
    }

    /// First candidate that is currently running, or nil.
    static func pick(sessionBundleId: String?, running: Set<String>) -> String? {
        candidates(sessionBundleId: sessionBundleId).first { running.contains($0) }
    }
}
