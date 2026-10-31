#if !APPSTORE
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - File shelf (coucou-custom fork)
//
// Files dropped on the notch land on a shelf (after Nusa's shelf): a row of icons in the
// island, dragged back out into Finder, a mail or any app, or sent on from there (Ask Claude,
// Send by email, Open). The shelf keeps the files where they are (paths, not copies): a file
// that moved or went is dropped from the shelf on load. With the shelf off, a drop runs
// upstream's upload sequence (gulp, progress bar, "what to do with it") as before.

struct ShelfItem: Identifiable, Codable, Equatable {
    let id: UUID
    let path: String
    let addedAt: Date

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
}

@MainActor
final class FileShelf: ObservableObject {
    static let shared = FileShelf()

    /// Settings → General → "File shelf" (default on).
    static let enabledKey = "coucouShelfEnabled"
    static let maxItems = 12

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    @Published private(set) var items: [ShelfItem] = []
    /// The file the actions act on: the last dropped, or the one clicked.
    @Published var selected: UUID?
    /// A file is being dragged out: the island stays open for the drag (fsm.isHeldOpen).
    @Published var dragging = false
    private var dragReset: DispatchWorkItem?
    /// The file of the drag in progress: dropped back on the island, it is left alone.
    private(set) var draggedPath: String?

    private static var file: URL { HookServer.supportDir.appendingPathComponent("shelf.json") }

    private init() { load() }

    /// Adds the files (newest first) and selects the first; a file already on the shelf
    /// moves to the front and keeps its place in nothing else.
    func add(_ urls: [URL]) {
        var next = items
        for url in urls.reversed() {
            let path = url.standardizedFileURL.path
            next.removeAll { $0.path == path }
            next.insert(ShelfItem(id: UUID(), path: path, addedAt: .now), at: 0)
        }
        if next.count > Self.maxItems { next = Array(next.prefix(Self.maxItems)) }
        set(next)
        selected = next.first?.id
        appendAppLog("nb.log", "[Shelf] +\(urls.count) file(s), \(next.count) on the shelf")
    }

    func remove(_ item: ShelfItem) {
        set(items.filter { $0.id != item.id })
        if selected == item.id { selected = items.first?.id }
    }

    var selectedItem: ShelfItem? { items.first { $0.id == selected } ?? items.first }

    /// A permission or a question waits, or a Finished/Error card is on screen: the drop
    /// must not take the notch over. The file lands quietly; the tray tab fills.
    static func dropsQuietly(_ state: AppState) -> Bool {
        state.pendingApproval != nil || state.pendingQuestion != nil
            || (state.mode == .expanded && (state.view == .finished || state.view == .error))
    }

    // MARK: What to do with a file (upstream's "choose" buttons, on the shelf)

    /// The chat, with the file as its context.
    func askClaude(_ item: ShelfItem, state: AppState) {
        state.droppedFile = DroppedFile(url: item.url, name: item.name)
        state.promptContext = .file(name: item.name, fileURL: item.url)
        appendAppLog("nb.log", "[Shelf] ask Claude about \(item.name)")
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.view = .prompt }
    }

    /// The mail card, with the file attached.
    func sendByEmail(_ item: ShelfItem, state: AppState) {
        state.droppedFile = DroppedFile(url: item.url, name: item.name)
        appendAppLog("nb.log", "[Shelf] email \(item.name)")
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.view = .mail }
    }

    func clear() {
        set([])
        appendAppLog("nb.log", "[Shelf] cleared")
    }

    /// Called from the item's onDrag: holds the island open while the drag lasts.
    func beginDrag(_ item: ShelfItem) {
        dragging = true
        draggedPath = item.path
        dragReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in self?.endDrag() }
        dragReset = reset
        // A drag ends with no callback here; a few seconds covers the drop in another app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: reset)
    }

    func endDrag() {
        dragReset?.cancel()
        dragging = false
        draggedPath = nil
    }

    /// True when these are the shelf's own file coming back from a drag that started on it:
    /// nothing to upload, nothing to copy, the shelf already has it.
    func isOwnDrag(_ urls: [URL]) -> Bool {
        guard dragging, let draggedPath else { return false }
        return !urls.isEmpty && urls.allSatisfy { $0.standardizedFileURL.path == draggedPath }
    }

    private func set(_ next: [ShelfItem]) {
        guard next != items else { return }
        items = next
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.file),
              let saved = try? JSONDecoder().decode([ShelfItem].self, from: data) else { return }
        items = saved.filter { FileManager.default.fileExists(atPath: $0.path) }
        selected = items.first?.id
        if items.count != saved.count { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? FileManager.default.createDirectory(at: HookServer.supportDir, withIntermediateDirectories: true)
        try? data.write(to: Self.file, options: .atomic)
    }
}

// MARK: - Shelf card

struct ShelfView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var shelf = FileShelf.shared

    var body: some View {
        ZStack {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(shelf.items.isEmpty ? "Shelf" : "Shelf · \(shelf.items.count)")
                        .font(.system(size: 13, weight: .semibold))
                    if let item = shelf.selectedItem {
                        // What to do with the selected file (upstream's "choose" step, here).
                        ShelfAction(icon: "bubble.left.fill", label: "Ask Claude") { shelf.askClaude(item, state: state) }
                        ShelfAction(icon: "paperplane.fill", label: "Email") { shelf.sendByEmail(item, state: state) }
                        ShelfAction(icon: "arrow.up.forward.square", label: "Open") { NSWorkspace.shared.open(item.url) }
                    }
                    Spacer()
                    if !shelf.items.isEmpty {
                        Button("Clear") { shelf.clear() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(hex: "#8E939C"))
                    }
                }
                if shelf.items.isEmpty {
                    Text(state.fileDragOver ? "Let go: the file lands here."
                                            : "Drop files on the notch: they wait here, to drag out, ask Claude about or email.")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: state.fileDragOver ? "#F5F6F8" : "#9398A1"))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 6) {
                            ForEach(shelf.items) { item in
                                ShelfItemView(item: item, selected: shelf.selected == item.id, state: state)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(.leading, 118)
            .padding(.trailing, 14)
            .padding(.vertical, 8)
        }
    }
}

/// One of the header's small actions.
private struct ShelfAction: View {
    let icon: String
    let label: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                Text(label).font(.system(size: 10.5, weight: .medium))
            }
            .foregroundColor(hovered ? Color(hex: "#F5F6F8") : Color(hex: "#B0B5BE"))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.white.opacity(hovered ? 0.12 : 0.07))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct ShelfItemView: View {
    let item: ShelfItem
    let selected: Bool
    @ObservedObject var state: AppState
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 34, height: 34)
            Text(item.name)
                .font(.system(size: 9.5))
                .foregroundColor(Color(hex: "#C9CDD4"))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 66)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
        .background(selected ? Color.white.opacity(0.12) : (hovered ? Color.white.opacity(0.07) : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(selected ? 0.18 : 0)))
        .animation(.easeOut(duration: 0.2), value: selected)
        .overlay(alignment: .topTrailing) {
            if hovered {
                Button {
                    FileShelf.shared.remove(item)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#B0B5BE"))
                }
                .buttonStyle(.plain)
                .offset(x: 2, y: -2)
            }
        }
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
        .onTapGesture(count: 1) { FileShelf.shared.selected = item.id }
        .onDrag {
            FileShelf.shared.beginDrag(item)
            return NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
        }
        .contextMenu {
            Button("Ask Claude about it") { FileShelf.shared.askClaude(item, state: state) }
            Button("Send by email") { FileShelf.shared.sendByEmail(item, state: state) }
            Divider()
            Button("Open") { NSWorkspace.shared.open(item.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Divider()
            Button("Remove from the shelf") { FileShelf.shared.remove(item) }
        }
        .help(item.path)
    }
}
#endif
