#if !APPSTORE
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - File shelf (coucou-custom fork)
//
// Files dropped on the notch wait on a shelf (after Nusa's shelf): a row of icons in the
// island, dragged back out into Finder, a mail or any app. The shelf keeps the files where
// they are (paths, not copies): a file that moved or went is dropped from the shelf on load.

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

    /// Settings → General → "File shelf" (default on) and "After a drop".
    static let enabledKey = "coucouShelfEnabled"
    static let dropModeKey = "coucouShelfDropMode"
    static let maxItems = 12

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    /// "shelf": a drop lands on the shelf and the island shows it; "ask" (default): the
    /// upload sequence runs as before, the shelf keeps the file as well.
    static var dropGoesToShelf: Bool { UserDefaults.standard.string(forKey: dropModeKey) == "shelf" }

    @Published private(set) var items: [ShelfItem] = []
    /// A file is being dragged out: the island stays open for the drag (fsm.isHeldOpen).
    @Published var dragging = false
    private var dragReset: DispatchWorkItem?
    /// The file of the drag in progress: dropped back on the island, it is left alone.
    private(set) var draggedPath: String?

    private static var file: URL { HookServer.supportDir.appendingPathComponent("shelf.json") }

    private init() { load() }

    /// Adds the files (newest first); a file already on the shelf moves to the front.
    func add(_ urls: [URL]) {
        var next = items
        for url in urls.reversed() {
            let path = url.standardizedFileURL.path
            next.removeAll { $0.path == path }
            next.insert(ShelfItem(id: UUID(), path: path, addedAt: .now), at: 0)
        }
        if next.count > Self.maxItems { next = Array(next.prefix(Self.maxItems)) }
        set(next)
        appendAppLog("nb.log", "[Shelf] +\(urls.count) file(s), \(next.count) on the shelf")
    }

    func remove(_ item: ShelfItem) { set(items.filter { $0.id != item.id }) }

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
                    Spacer()
                    if !shelf.items.isEmpty {
                        Button("Clear") { shelf.clear() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(hex: "#8E939C"))
                    }
                }
                if shelf.items.isEmpty {
                    Text("Drop files on the notch: they wait here until you drag them out.")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "#9398A1"))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 6) {
                            ForEach(shelf.items) { item in
                                ShelfItemView(item: item)
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

private struct ShelfItemView: View {
    let item: ShelfItem
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
        .background(hovered ? Color.white.opacity(0.07) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
        .onDrag {
            FileShelf.shared.beginDrag(item)
            return NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
        }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(item.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Divider()
            Button("Remove from the shelf") { FileShelf.shared.remove(item) }
        }
        .help(item.path)
    }
}
#endif
