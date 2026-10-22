#if !APPSTORE
import AppKit

/// ⌘W / ⌘Q (coucou-custom fork):
///   • ⌘W closes Coucou's window: the app keeps running in the notch and the menu bar, and leaves
///     the Dock and ⌘-Tab (.accessory) while it has no window open.
///   • ⌘Q quits for real (so do the menu-bar Quit, Restart Coucou and a logout).
/// While a Coucou window (the hub, Settings) is open, Coucou is a regular Dock app. This replaces
/// the earlier "Run in background" switch and "Quit Coucou completely" button.
@MainActor
enum BackgroundMode {
    private static var installed = false

    /// Called once at launch: no window yet, so no Dock icon.
    static func install() {
        guard !installed else { return }
        installed = true
        NSApp.setActivationPolicy(.accessory)
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { if let window, isAppWindow(window) { showInDock(true) } }
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let window, isAppWindow(window) else { return }
                // The closing window is still visible here: decide on the next turn.
                DispatchQueue.main.async {
                    if !NSApp.windows.contains(where: { $0.isVisible && isAppWindow($0) }) { showInDock(false) }
                }
            }
        }
        // ⌘W on Coucou's window even where no menu item carries the shortcut.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w",
                  let window = NSApp.keyWindow, isAppWindow(window) else { return event }
            window.performClose(nil)
            return nil
        }
    }

    /// Coucou's own windows (the hub, Settings): titled, normal level. The notch island, the Flow
    /// pill and other overlays sit above the normal level, and some aren't NSPanels.
    static func isAppWindow(_ w: NSWindow) -> Bool {
        w.styleMask.contains(.titled) && !(w is NSPanel) && w.level == .normal
    }

    /// Coucou's window is about to show (FlowHubController.show, which Settings also goes
    /// through): rejoin the Dock first. didBecomeKey alone doesn't fire reliably for an
    /// .accessory app.
    static func windowWillShow() { showInDock(true) }

    private static func showInDock(_ on: Bool) {
        let policy: NSApplication.ActivationPolicy = on ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if on { NSApp.activate(ignoringOtherApps: true) }
    }

    /// Menu-bar Quit and Restart Coucou.
    static func quitCompletely() {
        NSApp.terminate(nil)
    }

    /// ⌘Q quits for real.
    static func shouldTerminate() -> NSApplication.TerminateReply { .terminateNow }
}
#endif
