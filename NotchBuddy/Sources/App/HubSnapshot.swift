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
        DistributedNotificationCenter.default().addObserver(forName: notification, object: nil, queue: .main) { note in
            // object: "buddy,runner@1000" renders those pages in a 1000 pt wide window; "@1000" every page; empty: every page at 1180.
            let spec = (note.object as? String ?? "")
            let parts = spec.split(separator: "@", omittingEmptySubsequences: false).map(String.init)
            let pages = (parts.first ?? "").split(separator: ",").compactMap { HubPage(rawValue: String($0)) }
            let width = parts.count > 1 ? CGFloat(Double(parts[1]) ?? 1180) : 1180
            Task { @MainActor in await render(pages: pages, width: width) }
        }
        // Opens the real window on a page, so its behaviour under the pointer (and its CPU) can be checked.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("fr.louisraille.NotchBuddy.debug.openHub"), object: nil, queue: .main) { note in
            let spec = (note.object as? String) ?? ""
            Task { @MainActor in
                if spec == "close" { FlowHubController.shared.window?.close() } else { FlowHubController.shared.show(HubPage(rawValue: spec)) }
            }
        }
    }

    private static func render(pages: [HubPage], width: CGFloat) async {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchBuddy/hub-snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let router = HubRouter()
        let host = NSHostingView(rootView: FlowHubView(router: router, windowState: HubWindowState()))
        let win = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: width, height: 2600),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host
        win.orderFrontRegardless()
        window = win
        let all: [HubPage] = [.general, .agents, .chat, .integrations, .voice, .shortcuts, .pills, .buddy, .runner, .brief, .shelf, .clipboard]
        for page in pages.isEmpty ? all : pages {
            router.page = page
            try? await Task.sleep(for: .seconds(1.2))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(page.rawValue)-\(Int(width)).png"))
        }
        win.orderOut(nil)
        window = nil
        appendAppLog("nb.log", "[Hub] snapshots written to \(dir.path)")
    }
}
#endif
