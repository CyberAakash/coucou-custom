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
            // "routines#alerts": the page with that tab chosen (its AppStorage key, set in this process).
            let items = (parts.first ?? "").split(separator: ",").map { $0.split(separator: "#", maxSplits: 1).map(String.init) }
            let pages = items.compactMap { HubPage(rawValue: $0[0]) }
            let tabs = Dictionary(items.compactMap { i in i.count > 1 ? (i[0], i[1]) : nil }, uniquingKeysWith: { a, _ in a })
            let width = parts.count > 1 ? CGFloat(Double(parts[1]) ?? 1180) : 1180
            Task { @MainActor in await render(pages: pages, width: width, tabs: tabs) }
        }
        // Opens the real window on a page, so its behaviour under the pointer (and its CPU) can be checked.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("fr.louisraille.NotchBuddy.debug.openHub"), object: nil, queue: .main) { note in
            let spec = (note.object as? String) ?? ""
            Task { @MainActor in
                if spec == "close" { FlowHubController.shared.window?.close() } else { FlowHubController.shared.show(HubPage(rawValue: spec)) }
            }
        }
    }

    /// The AppStorage key holding a page's chosen tab, for "page#tab".
    private static let tabKeys: [String: String] = ["routines": "routinesSettingsSection", "buddy": "buddySettingsSection",
                                                    "brief": "briefsSettingsTab", "shelf": "shelfSettingsTab", "clipboard": "clipboardSettingsTab",
                                                    "agenda": "agendaSettingsTab"]

    private static func render(pages: [HubPage], width: CGFloat, tabs: [String: String] = [:]) async {
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
            var restore: (String, Any?)?
            if let tab = tabs[page.rawValue], let key = tabKeys[page.rawValue] {
                restore = (key, UserDefaults.standard.object(forKey: key))
                UserDefaults.standard.set(tab, forKey: key)
            }
            defer { if let (key, old) = restore { UserDefaults.standard.set(old, forKey: key) } }
            router.page = page
            try? await Task.sleep(for: .seconds(1.2))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(page.rawValue)\(tabs[page.rawValue].map { "-" + $0 } ?? "")-\(Int(width)).png"))
        }
        win.orderOut(nil)
        window = nil
        appendAppLog("nb.log", "[Hub] snapshots written to \(dir.path)")
    }
}
#endif
