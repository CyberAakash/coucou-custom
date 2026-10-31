#if !APPSTORE && DEBUG
import AppKit
import SwiftUI

// MARK: - Debug: render the Keep pages to PNG (coucou-custom fork)
//
// `fr.louisraille.NotchBuddy.debug.snapshot` (object: "shelf", "clipboard", or empty for both)
// renders the notch page (the window's pages: `debug.hubSnapshot`, HubSnapshot.swift) in an off-screen window at 2× and writes
// `~/Library/Caches/NotchBuddy/snap-<name>.png`, so the look can be checked from a terminal
// without a screen. Thumbnails and Quick Look need a moment: the picture is taken after 2.5 s.

enum KeepSnapshots {
    static func install() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("fr.louisraille.NotchBuddy.debug.snapshot"), object: nil, queue: .main
        ) { note in
            let which = (note.object as? String ?? "").trimmingCharacters(in: .whitespaces)
            MainActor.assumeIsolated {
                // "shelf", "clipboard", "shelf:carousel", "shelf:filter", "clipboard:grid"…, or empty for both.
                let names = which.isEmpty ? ["shelf", "clipboard"] : [which]
                for (i, name) in names.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 3.2) { snapshot(name) }
                }
            }
        }
    }

    @MainActor
    private static func snapshot(_ spec: String) {
        let state = AppState.shared
        let parts = spec.split(separator: ":").map(String.init)
        let name = parts[0]
        let options = Set(parts.dropFirst())
        // Options change a setting for the picture and put it back after.
        let shelfLayout = ShelfSettings.shared.layout, clipLayout = ClipboardSettings.shared.layout
        if options.contains("carousel") { ShelfSettings.shared.layout = .carousel; ClipboardSettings.shared.layout = .carousel }
        if options.contains("grid") { ShelfSettings.shared.layout = .grid; ClipboardSettings.shared.layout = .grid }
        KeepDebug.filterOpen = options.contains("filter")
        let restore = { ShelfSettings.shared.layout = shelfLayout; ClipboardSettings.shared.layout = clipLayout }
        let view: AnyView
        let size: CGSize
        switch name {
        case "shelf":
            let h = KeepPanels.islandHeight(.shelf, layout: ShelfSettings.shared.layout) + (KeepDebug.filterOpen ? KeepPanels.filterRow : 0)
            size = CGSize(width: 640, height: h)
            view = AnyView(islandFrame(height: h) { ShelfView(state: state) })
        case "clipboard":
            let h = KeepPanels.islandHeight(.clipboard, layout: ClipboardSettings.shared.layout) + (KeepDebug.filterOpen ? KeepPanels.filterRow : 0)
            size = CGSize(width: 640, height: h)
            view = AnyView(islandFrame(height: h) { ClipboardView(state: state) })
        default:
            appendAppLog("nb.log", "[Snapshot] unknown page \(name)")
            restore()
            return
        }
        let hosting = NSHostingView(rootView: view.environment(\.islandViewActive, true).frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.alphaValue = 0
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("NotchBuddy")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("snap-\(spec.replacingOccurrences(of: ":", with: "-")).png")
            if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: file) }
            appendAppLog("nb.log", "[Snapshot] \(name) → \(file.path) (\(Int(size.width))×\(Int(size.height)))")
            window.orderOut(nil)
            restore()
            KeepDebug.filterOpen = false
        }
    }

    /// The island's black body, its header's height left empty, the card below it.
    @MainActor
    private static func islandFrame<V: View>(height: CGFloat, @ViewBuilder content: () -> V) -> some View {
        ZStack(alignment: .top) {
            Color.black
            VStack(spacing: 0) {
                Color.clear.frame(height: 42)
                content().frame(height: height - 52)
                Color.clear.frame(height: 10)
            }
            .padding(.horizontal, 10)
        }
        .frame(width: 640, height: height)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22))
    }
}
#endif
