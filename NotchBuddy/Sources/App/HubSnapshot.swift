#if DEBUG && !APPSTORE
import AppKit
import SwiftUI

// coucou-custom fork, Debug builds only: draws pages of the Coucou window off screen and saves
// them as PNGs, to check a layout without opening the window over someone's work. Triggered by the
// distributed notification below; always writes to ~/Library/Caches/NotchBuddy/hub-snapshots
// (whatever the sender asks), and only renders, never changes a setting.

@MainActor
enum HubSnapshot {
    static let notification = Notification.Name("fr.louisraille.NotchBuddy.debug.hubSnapshot")
    private static var window: NSWindow?

    static func install() {
        DistributedNotificationCenter.default().addObserver(forName: notification, object: nil, queue: .main) { _ in
            Task { @MainActor in await render() }
        }
    }

    private static func render() async {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchBuddy/hub-snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let router = HubRouter()
        let host = NSHostingView(rootView: FlowHubView(router: router, windowState: HubWindowState()))
        let win = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1180, height: 2600),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host
        win.orderFrontRegardless()
        window = win
        for page in [HubPage.general, .agents, .chat, .integrations, .voice, .shortcuts, .pills, .buddy, .runner] {
            router.page = page
            try? await Task.sleep(for: .seconds(1.2))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(page.rawValue).png"))
        }
        win.orderOut(nil)
        window = nil
        appendAppLog("nb.log", "[Hub] snapshots written to \(dir.path)")
    }
}
#endif
