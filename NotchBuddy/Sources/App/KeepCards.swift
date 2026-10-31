#if !APPSTORE
import AppKit
import SwiftUI
import Quartz
import QuickLookThumbnailing

// MARK: - The "Keep" pages' shared parts (coucou-custom fork)
//
// The shelf and the clipboard show the same card: a preview on top, a kind badge, a name and
// a line of detail, in a grid of four or a carousel grouped by time. Thumbnails come from
// Quick Look off the main thread and are kept in memory and on disk, so scrolling never waits.
// A Filter button opens the kinds as chips (as many as there are kinds, present ones first), and
// the detail panels show a real Quick Look preview.

// MARK: Thumbnails

/// Quick Look thumbnails, cached by path and modification date.
final class KeepThumbnails: @unchecked Sendable {
    static let shared = KeepThumbnails()

    private let memory = NSCache<NSString, NSImage>()
    private let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NotchBuddy/thumbs", isDirectory: true)
    private let queue = DispatchQueue(label: "coucou.keep.thumbs", qos: .utility)
    /// One Quick Look request per key at a time; a second asker gets nil and the cache later.
    private let inFlight = InFlight()

    private final class InFlight: @unchecked Sendable {
        private var keys: Set<String> = []
        private let lock = NSLock()
        func begin(_ k: String) -> Bool { lock.lock(); defer { lock.unlock() }; return keys.insert(k).inserted }
        func end(_ k: String) { lock.lock(); keys.remove(k); lock.unlock() }
    }

    private init() {
        memory.countLimit = 200
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func key(_ url: URL, size: CGSize) -> String {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let raw = "\(url.path)|\(Int(mtime))|\(Int(size.width))x\(Int(size.height))"
        return raw.utf8.reduce(into: UInt64(1469598103934665603)) { $0 = ($0 ^ UInt64($1)) &* 1099511628211 }.description
    }

    /// The cached thumbnail at once, if there is one.
    func cached(_ url: URL, size: CGSize) -> NSImage? {
        memory.object(forKey: key(url, size: size) as NSString)
    }

    /// The thumbnail, from memory, disk or Quick Look (in that order); nil when the file has
    /// none (a folder, an archive): the caller shows the icon instead.
    func thumbnail(_ url: URL, size: CGSize) async -> NSImage? {
        let k = key(url, size: size)
        if let hit = memory.object(forKey: k as NSString) { return hit }
        let file = folder.appendingPathComponent(k + ".png")
        if let data = try? Data(contentsOf: file), let image = NSImage(data: data) {
            memory.setObject(image, forKey: k as NSString)
            return image
        }
        guard inFlight.begin(k) else { return nil }
        defer { inFlight.end(k) }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let image = rep.nsImage
        memory.setObject(image, forKey: k as NSString)
        queue.async {
            if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: file, options: .atomic)
            }
        }
        return image
    }
}

/// A file's preview: the thumbnail when there is one, the icon meanwhile and otherwise.
/// Fills the width it is given; `size` is the thumbnail asked of Quick Look.
struct KeepFilePreview: View {
    let url: URL
    let size: CGSize
    var showsThumbnail = true
    @State private var thumb: NSImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.white.opacity(0.04)
                if let thumb {
                    Image(nsImage: thumb)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .transition(.opacity)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: min(geo.size.height - 8, 44), height: min(geo.size.height - 8, 44))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: size.height)
        .animation(.easeOut(duration: 0.18), value: thumb != nil)
        .task(id: url.path + (showsThumbnail ? "+" : "-")) {
            guard showsThumbnail else { thumb = nil; return }
            if let hit = KeepThumbnails.shared.cached(url, size: size) { thumb = hit; return }
            let image = await KeepThumbnails.shared.thumbnail(url, size: size)
            if !Task.isCancelled { thumb = image }
        }
    }
}

/// A real Quick Look preview (a PDF's pages, an image, text, a movie), for the detail panels.
/// The preview sits in a clipping box that follows the SwiftUI frame: QLPreviewView would
/// otherwise draw past it.
struct KeepQuickLook: NSViewRepresentable {
    let url: URL
    var cornerRadius: CGFloat = 0

    final class Box: NSView {
        let preview = QLPreviewView(frame: .zero, style: .compact) ?? QLPreviewView()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            preview.autostarts = false
            preview.shouldCloseWithWindow = false
            preview.autoresizingMask = [.width, .height]
            addSubview(preview)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            preview.frame = bounds
        }
    }

    func makeNSView(context: Context) -> Box {
        let box = Box(frame: .zero)
        box.layer?.cornerRadius = cornerRadius
        box.preview.previewItem = url as NSURL
        return box
    }

    func updateNSView(_ box: Box, context: Context) {
        box.layer?.cornerRadius = cornerRadius
        if (box.preview.previewItem as? NSURL) != (url as NSURL) { box.preview.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ box: Box, coordinator: ()) { box.preview.close() }
}

/// For checking the look from a terminal (KeepSnapshots): the pages open their filter when set.
enum KeepDebug {
    nonisolated(unsafe) static var filterOpen = false
}

/// Which pages have their filter row open: the island is one row taller then (islandSize).
enum KeepPanels {
    nonisolated(unsafe) private static var open: Set<String> = []
    static let filterRow: CGFloat = 28

    nonisolated static func filterOpen(_ view: IslandView) -> Bool { open.contains(view.rawValue) }

    @MainActor static func setFilter(_ on: Bool, for view: IslandView) {
        if on { open.insert(view.rawValue) } else { open.remove(view.rawValue) }
        NotificationCenter.default.post(name: KeepLayout.changed, object: view)
    }

    /// The page's island height: its layout's, plus the filter row when open.
    nonisolated static func islandHeight(_ view: IslandView, layout: KeepLayout) -> CGFloat {
        layout.islandHeight + (filterOpen(view) ? filterRow : 0)
    }
}

// MARK: Card

/// The card block: a preview area, a kind badge at its top right, a name and a detail line.
struct KeepCard<Preview: View>: View {
    let name: String
    let detail: String
    let badge: String
    var badgeTint: Color? = nil
    var pinned = false
    let selected: Bool
    var width: CGFloat? = nil
    let height: CGFloat
    var onTap: () -> Void = {}
    var onDoubleTap: () -> Void = {}
    var onCommandTap: () -> Void = {}
    @ViewBuilder var preview: () -> Preview
    @State private var hovered = false

    var body: some View {
        Button(action: onTap) { face }
            .buttonStyle(KeepCardPress(selected: selected, hovered: hovered))
            .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleTap() })
            .simultaneousGesture(TapGesture().modifiers(.command).onEnded { onCommandTap() })
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.15), value: hovered)
            .animation(.easeOut(duration: 0.15), value: selected)
    }

    private var face: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                preview()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(badge)
                    .font(.system(size: 7.5, weight: .bold))
                    .tracking(0.3)
                    .foregroundColor(badgeTint ?? Color(hex: "#E1E3E6"))
                    .padding(.horizontal, 5)
                    .frame(height: 13)
                    .background(Capsule().fill((badgeTint ?? .black).opacity(badgeTint == nil ? 0.65 : 0.2)))
                    .padding(4)
                if pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Color(hex: "#F5A524"))
                        .padding(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text(name)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(Color(hex: "#F5F6F8"))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 6)
            Spacer(minLength: 2)
            Text(detail)
                .font(.system(size: 8.5))
                .foregroundColor(Color(hex: "#8E939C"))
                .lineLimit(1)
        }
        .padding(8)
        .frame(width: width, height: height, alignment: .topLeading)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// The card's fill, ring and press: selected 12 % white, hovered 8 %, else 5 %; pressed scales to 0.985.
struct KeepCardPress: ButtonStyle {
    let selected: Bool
    let hovered: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.12 : (hovered ? 0.08 : 0.05)))
            )
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(selected ? 0.22 : 0), lineWidth: 1.5))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .offset(y: hovered && !configuration.isPressed ? -1 : 0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: Search, filter, layout toggle, hints

struct KeepSearchField: View {
    let placeholder: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    var onKey: (KeyPress) -> KeyPress.Result

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Color(hex: "#8E939C"))
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused(focus)
                .writingToolsBehavior(.disabled)
                .onKeyPress(phases: .down, action: onKey)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundColor(Color(hex: "#6B7079"))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(Capsule().fill(Color.white.opacity(focus.wrappedValue ? 0.09 : 0.07)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(focus.wrappedValue ? 0.14 : 0)))
        .animation(.easeOut(duration: 0.15), value: focus.wrappedValue)
    }
}

/// "Filter" with a funnel; shows the kinds chosen ("Images · Code") and opens the panel.
struct KeepFilterButton: View {
    @Binding var kinds: Set<KeepKind>
    @Binding var open: Bool
    var compact = true
    @State private var hovered = false

    private var label: String {
        if kinds.isEmpty { return "Filter" }
        return kinds.sorted { $0.rawValue < $1.rawValue }.map(\.label).joined(separator: " · ")
    }

    var body: some View {
        Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { open.toggle() } } label: {
            HStack(spacing: 5) {
                Image(systemName: kinds.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    .font(.system(size: compact ? 11 : 12, weight: .semibold))
                Text(label).font(.system(size: compact ? 10.5 : 12.5, weight: kinds.isEmpty ? .medium : .semibold)).lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: compact ? 7 : 8, weight: .bold))
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .foregroundColor(kinds.isEmpty ? Color(hex: "#B0B5BE") : Color(hex: "#F5F6F8"))
            .padding(.horizontal, compact ? 9 : 12)
            .frame(height: compact ? 26 : 34)
            .background(
                RoundedRectangle(cornerRadius: compact ? 13 : 9, style: .continuous)
                    .fill(kinds.isEmpty ? Color.white.opacity(open || hovered ? 0.1 : 0.07) : Color(hex: "#F5F6F8").opacity(0.16))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.15), value: open)
    }
}

/// The kinds as chips, present ones first, then the rest; one at a time.
struct KeepFilterPanel: View {
    @Binding var kinds: Set<KeepKind>
    /// Every kind this page can hold, in its order.
    let available: [KeepKind]
    /// How many items each kind has right now (a kind with none is dimmed, not hidden).
    let counts: [KeepKind: Int]
    var compact = true

    private var ordered: [KeepKind] {
        available.sorted { (counts[$0] ?? 0 > 0 ? 0 : 1, available.firstIndex(of: $0)!) < (counts[$1] ?? 0 > 0 ? 0 : 1, available.firstIndex(of: $1)!) }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ordered) { k in
                let n = counts[k] ?? 0
                KeepChip(label: n > 0 ? "\(k.label) \(n)" : k.label, on: kinds.contains(k), dimmed: n == 0, size: compact ? 10.5 : 12) {
                    // One kind at a time; the chip on again clears the filter.
                    withAnimation(.easeOut(duration: 0.15)) { kinds = kinds.contains(k) ? [] : [k] }
                }
            }
            if !kinds.isEmpty {
                Button("Clear") { withAnimation(.easeOut(duration: 0.15)) { kinds = [] } }
                    .buttonStyle(.plain)
                    .font(.system(size: compact ? 10.5 : 12, weight: .medium))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .padding(.leading, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, compact ? 2 : 0)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct KeepChip: View {
    let label: String
    let on: Bool
    var dimmed = false
    var size: CGFloat = 10.5
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: size, weight: on ? .semibold : .medium))
                .foregroundColor(on ? Color(hex: "#0B0C0E") : Color(hex: dimmed ? "#6B7079" : "#B0B5BE"))
                .padding(.horizontal, size > 11 ? 11 : 9)
                .frame(height: size > 11 ? 26 : 20)
                .background(Capsule().fill(on ? Color(hex: "#F5F6F8") : Color.white.opacity(hovered ? 0.1 : 0.06)))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.15), value: on)
    }
}

struct KeepLayoutToggle: View {
    @Binding var layout: KeepLayout

    var body: some View {
        HStack(spacing: 1) {
            option(.grid, "square.grid.2x2.fill", "Grid")
            option(.carousel, "rectangle.split.3x1.fill", "Carousel")
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }

    private func option(_ value: KeepLayout, _ symbol: String, _ help: String) -> some View {
        Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { layout = value } } label: {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(layout == value ? Color(hex: "#0B0C0E") : Color(hex: "#8E939C"))
                .frame(width: 22, height: 16)
                .background(Capsule().fill(layout == value ? Color(hex: "#F5F6F8") : Color.clear))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// "↩ Open · Space Quick Look": the key hints under a page.
struct KeepHints: View {
    let hints: [(key: String, label: String)]
    let trailing: String

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(hints.enumerated()), id: \.offset) { _, h in
                HStack(spacing: 3) {
                    Text(h.key)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color(hex: "#C5C8CD"))
                        .padding(.horizontal, 4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)))
                    Text(h.label).font(.system(size: 9.5)).foregroundColor(Color(hex: "#6B7079"))
                }
            }
            Spacer(minLength: 8)
            Text(trailing)
                .font(.system(size: 9.5))
                .foregroundColor(Color(hex: "#6B7079"))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// The vertical "JUST NOW" label between a carousel's groups.
struct KeepSectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .tracking(1)
            .foregroundColor(Color(hex: "#6B7079"))
            .fixedSize()
            .rotationEffect(.degrees(-90))
            .frame(width: 12)
    }
}

/// A short confirmation that fades by itself.
struct KeepToast: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(Color(hex: "#0B0C0E"))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color(hex: "#F5F6F8")))
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// "Just now", "Today", "Yesterday", "Earlier": the carousel's groups.
enum KeepBucket {
    static func label(_ date: Date, now: Date = .now) -> String {
        let d = now.timeIntervalSince(date)
        if d < 600 { return "JUST NOW" }
        if d < 86400 { return "TODAY" }
        if d < 2 * 86400 { return "YESTERDAY" }
        return "EARLIER"
    }

    static func ago(_ date: Date, now: Date = .now) -> String {
        let d = now.timeIntervalSince(date)
        if d < 60 { return "\(Int(d)) s" }
        if d < 3600 { return "\(Int(d / 60)) min" }
        if d < 86400 { return "\(Int(d / 3600)) h" }
        return "\(Int(d / 86400)) d"
    }
}

/// Toast timing shared by the pages.
@MainActor
final class KeepToastModel: ObservableObject {
    @Published var text: String?
    private var clear: DispatchWorkItem?
    func say(_ t: String) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { text = t }
        clear?.cancel()
        let work = DispatchWorkItem { [weak self] in withAnimation(.easeOut(duration: 0.2)) { self?.text = nil } }
        clear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }
}

// MARK: Window detail pieces

/// A label / value line of a detail panel ("Size · 2.1 MB").
struct KeepFact: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.system(size: 11.5)).foregroundColor(HubTheme.muted).frame(width: 64, alignment: .leading)
            Text(value).font(.system(size: 12)).foregroundColor(HubTheme.body).lineLimit(2).truncationMode(.middle)
        }
    }
}

/// A round icon button with a label under it, for a detail panel's actions. With `menu`, the
/// click pops that menu up under the button instead.
struct KeepActionButton: View {
    let symbol: String
    let label: String
    var tint: Color = HubTheme.text
    var primary = false
    var action: () -> Void = {}
    /// Named, never trailing: a trailing closure is always the action.
    var menu: (() -> NSMenu)? = nil
    @State private var hovered = false

    var body: some View {
        Button {
            if let menu {
                let m = menu()
                if let event = NSApp.currentEvent, let view = event.window?.contentView {
                    let point = view.convert(event.locationInWindow, from: nil)
                    m.popUp(positioning: nil, at: CGPoint(x: point.x - 20, y: point.y - 10), in: view)
                } else {
                    m.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
                }
            } else {
                action()
            }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(primary ? HubTheme.onAccent : tint)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(primary ? HubTheme.accent : Color.white.opacity(hovered ? 0.12 : 0.07)))
                Text(label).font(.system(size: 10.5, weight: .medium)).foregroundColor(hovered ? HubTheme.text : HubTheme.secondary)
            }
            .frame(width: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(label)
    }
}

extension Notification.Name {
    /// Posted when a drop has landed on the shelf (the page shows a moment of success).
    static let shelfLanded = Notification.Name("coucou.shelfLanded")
}
#endif

#if !APPSTORE
/// NSMenu items made from closures (the Open with menu).
@MainActor
final class KeepMenuTarget: NSObject {
    static let shared = KeepMenuTarget()
    final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }
    @objc func run(_ sender: NSMenuItem) { (sender.representedObject as? Action)?.run() }
}

extension NSImage {
    /// A copy at `side` points, for menu item icons.
    func resized(to side: CGFloat) -> NSImage {
        let out = NSImage(size: NSSize(width: side, height: side))
        out.lockFocus()
        draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .sourceOver, fraction: 1)
        out.unlockFocus()
        return out
    }
}
#endif
