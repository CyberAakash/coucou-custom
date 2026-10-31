#if !APPSTORE
import AppKit
import SwiftUI
import QuickLookThumbnailing

// MARK: - The "Keep" pages' shared parts (coucou-custom fork)
//
// The shelf and the clipboard show the same card: a preview on top, a kind badge, a name and
// a line of detail, in a grid of four or a carousel grouped by time. Thumbnails come from
// Quick Look off the main thread and are kept in memory and on disk, so scrolling never waits.

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
struct KeepFilePreview: View {
    let url: URL
    let size: CGSize
    var showsThumbnail = true
    @State private var thumb: NSImage?

    var body: some View {
        ZStack {
            if let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .transition(.opacity)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: min(size.height - 8, 44), height: min(size.height - 8, 44))
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(.easeOut(duration: 0.18), value: thumb != nil)
        .task(id: url.path + (showsThumbnail ? "+" : "-")) {
            guard showsThumbnail else { thumb = nil; return }
            if let hit = KeepThumbnails.shared.cached(url, size: size) { thumb = hit; return }
            let image = await KeepThumbnails.shared.thumbnail(url, size: size)
            if !Task.isCancelled { thumb = image }
        }
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
    @ViewBuilder var preview: () -> Preview
    @State private var hovered = false
    @State private var pressed = false

    var body: some View {
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
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.12 : (hovered ? 0.08 : 0.05)))
        )
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(selected ? 0.22 : 0), lineWidth: 1.5))
        .scaleEffect(pressed ? 0.985 : 1)
        .offset(y: hovered && !pressed ? -1 : 0)
        .animation(.easeOut(duration: 0.15), value: hovered)
        .animation(.easeOut(duration: 0.15), value: selected)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: pressed)
        .onHover { hovered = $0 }
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in pressed = true }.onEnded { _ in pressed = false })
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: Search, chips, layout toggle, hints

struct KeepSearchField: View {
    let placeholder: String
    @Binding var text: String
    let count: String
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
            Text(count)
                .font(.system(size: 9.5))
                .foregroundColor(Color(hex: "#6B7079"))
                .monospacedDigit()
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(Capsule().fill(Color.white.opacity(focus.wrappedValue ? 0.09 : 0.07)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(focus.wrappedValue ? 0.14 : 0)))
        .animation(.easeOut(duration: 0.15), value: focus.wrappedValue)
    }
}

struct KeepChip: View {
    let label: String
    let on: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10.5, weight: on ? .semibold : .medium))
                .foregroundColor(on ? Color(hex: "#0B0C0E") : Color(hex: "#B0B5BE"))
                .padding(.horizontal, 9)
                .frame(height: 20)
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
#endif
