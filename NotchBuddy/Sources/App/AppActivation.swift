import AppKit

// MARK: - AppActivation (coucou-custom fork)
//
// Since macOS 14, activation is cooperative: `NSRunningApplication.activate()` asked by an app
// that is not itself active is silently ignored, and still returns true. Coucou lives in
// non-activating panels (the notch, the Buddy), so it is almost never the active app when
// "Open terminal" is clicked: the terminal's tab switched behind the front app and the terminal
// never came forward. Here Coucou takes activation for the click it just received, yields it to
// the target, asks it to activate, and checks; if the target is still not in front it is opened
// through Launch Services, which brings a running app forward.
@MainActor
enum AppActivation {
    /// Brings the app forward. False when it is not running.
    @discardableResult
    static func bringToFront(bundleId: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else { return false }
        bringToFront(app)
        return true
    }

    static func bringToFront(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            NSApp.activate()
            NSApp.yieldActivation(to: app)
            app.activate(from: .current, options: [])
        } else {
            app.activate()
        }
        // Checked shortly after: activation lands asynchronously.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            guard front != app.bundleIdentifier else {
                appendAppLog("nb.log", "[Terminal] \(app.localizedName ?? "app") in front")
                return
            }
            appendAppLog("nb.log", "[Terminal] \(app.localizedName ?? "app") not in front (\(front ?? "?")), opening it")
            if let url = app.bundleURL {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
            }
        }
    }

    #if DEBUG && !APPSTORE
    /// `fr.louisraille.NotchBuddy.debug.openTerminal` (object: a session id, or empty for the
    /// Claude pill's card session, as the Finished card's button uses): runs what the card's
    /// "Open terminal" runs, so the whole path can be checked from a terminal.
    static func installDebugHook() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("fr.louisraille.NotchBuddy.debug.openTerminal"), object: nil, queue: .main
        ) { note in
            // "click": what the Finished card's button does (open the card's session, then mark it seen).
            let id = note.object as? String ?? ""
            MainActor.assumeIsolated {
                let pill = "integration_claude"
                let s = id.isEmpty || id == "click" ? LiveSessions.shared.cardSession(for: pill) : LiveSessions.shared.session(id)
                appendAppLog("nb.log", "[Terminal] debug open: \(s?.projectName ?? "no session")")
                TerminalFocus.open(s, from: id == "click" ? "debug click" : "debug") { TerminalFocus.openDefaultTerminal() }
                if id == "click" { LiveSessions.shared.markShownSeen(pill: pill) }
            }
        }
    }
    #endif
}
