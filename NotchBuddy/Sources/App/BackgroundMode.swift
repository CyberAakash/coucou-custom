#if !APPSTORE
import AppKit

/// "Run in background" (coucou-custom fork): no Dock icon, not in ⌘-Tab, and ⌘Q, Dock → Quit or
/// an AppleScript quit only hide Coucou. It stops for real only from Settings → App → "Quit Coucou
/// completely", the menu-bar Quit, Restart Coucou, or a logout / restart / shutdown.
@MainActor
enum BackgroundMode {
    /// The inverse of the upstream "Show in Dock" setting (same key): one switch, not two that
    /// could disagree. Turning it on also switches the activation policy to `.accessory`.
    static var isOn: Bool {
        get { !FlowHubController.showInDock }
        set { FlowHubController.showInDock = !newValue }
    }

    private static var quitRequested = false

    static func quitCompletely() {
        quitRequested = true
        NSApp.terminate(nil)
    }

    static func shouldTerminate() -> NSApplication.TerminateReply {
        if quitRequested || !isOn || isSystemSessionEnding() { return .terminateNow }
        // Coucou's own windows (the hub, Settings), not the notch island and pill panels.
        for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) && !(window is NSPanel) {
            window.close()
        }
        // Not NSApp.hide: hiding the app hides the notch island too, and it stays dead until
        // something unhides Coucou. Giving focus back to the previous app is enough.
        NSApp.deactivate()
        return .terminateCancel
    }

    /// Cancelling the quit sent at logout, restart or shutdown would stall the Mac until the user
    /// dealt with Coucou, so those always go through.
    private static func isSystemSessionEnding() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
        else { return false }
        let ending: [OSType] = [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart,
                                kAEShowShutdownDialog, kAEShutDown].map { OSType($0) }
        return ending.contains(reason)
    }
}
#endif
