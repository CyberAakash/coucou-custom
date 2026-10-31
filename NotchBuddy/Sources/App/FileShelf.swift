#if !APPSTORE
import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - File shelf (coucou-custom fork)
//
// Files dropped on the notch land on a shelf (after Nusa's shelf): cards in the island, as a
// grid or a carousel, searched and filtered by kind, dragged back out into Finder or any app,
// opened (in the app you chose for that extension), looked at, asked about or emailed. The
// shelf keeps the files where they are (paths, not copies); a file that moved or went leaves
// the shelf on load, and files leave by themselves after the time you set. With the shelf off,
// a drop runs upstream's upload sequence (gulp, progress bar, "what to do with it") as before.

struct ShelfItem: Identifiable, Codable, Equatable {
    let id: UUID
    let path: String
    let addedAt: Date

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }

    /// The kind the chips filter by.
    var kind: KeepKind {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue, ext.isEmpty { return .folder }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .image) || type.conforms(to: .movie) { return .image }
            if type.conforms(to: .sourceCode) || ["swift", "py", "js", "ts", "json", "yml", "yaml", "sh", "rb", "go", "rs"].contains(ext) { return .code }
            if type.conforms(to: .archive) || type.conforms(to: .diskImage) || ["zip", "tar", "gz"].contains(ext) { return .archive }
            if type.conforms(to: .plainText) || type.conforms(to: .text) || ["md", "rtf"].contains(ext) { return .text }
        }
        return .document
    }
}

/// What a kept thing is, for the chips and the badges (shared with the clipboard).
enum KeepKind: String, CaseIterable, Identifiable, Codable {
    case image, document, text, code, archive, folder
    case link, color, file
    var id: String { rawValue }

    var label: String {
        switch self {
        case .image: return "Images"
        case .document: return "Docs"
        case .text: return "Text"
        case .code: return "Code"
        case .archive: return "Archives"
        case .folder: return "Folders"
        case .link: return "Links"
        case .color: return "Colors"
        case .file: return "Files"
        }
    }

    /// What a shelf can hold, in the filter's order; a new kind added here shows up by itself.
    static let shelfKinds: [KeepKind] = [.image, .document, .text, .code, .archive, .folder]
    /// What the clipboard can hold.
    static let clipboardKinds: [KeepKind] = [.text, .link, .image, .color, .code, .file]
}

/// Grid or carousel, per page (the shelf, the clipboard).
enum KeepLayout: String, CaseIterable, Identifiable {
    case grid, carousel
    var id: String { rawValue }

    var label: String { self == .grid ? "Grid" : "Carousel" }

    /// The island's height for a page in this layout: the grid needs two rows.
    var islandHeight: CGFloat { self == .grid ? 330 : 240 }

    /// Posted when a setting changes a page's layout, so an open island follows.
    static let changed = Notification.Name("coucou.keepLayoutChanged")
}

/// How long kept things stay.
enum KeepRetention: String, CaseIterable, Identifiable {
    case forever, days7, days14, days30, custom
    var id: String { rawValue }

    var label: String {
        switch self {
        case .forever: return "Permanently"
        case .days7: return "7 days"
        case .days14: return "14 days"
        case .days30: return "30 days"
        case .custom: return "Custom"
        }
    }

    func days(custom: Int) -> Int? {
        switch self {
        case .forever: return nil
        case .days7: return 7
        case .days14: return 14
        case .days30: return 30
        case .custom: return max(1, custom)
        }
    }
}

// MARK: - Settings

/// Settings → Shelf → Settings. UserDefaults-backed so the nonisolated `islandSize` can read the layout.
@MainActor
final class ShelfSettings: ObservableObject {
    static let shared = ShelfSettings()

    nonisolated static let enabledKey = "coucouShelfEnabled"
    nonisolated static let layoutKey = "coucouShelfLayout"
    static let previewsKey = "coucouShelfPreviews"
    static let retentionKey = "coucouShelfKeep"
    static let retentionDaysKey = "coucouShelfKeepDays"
    static let maxItemsKey = "coucouShelfMax"
    static let persistKey = "coucouShelfPersist"
    static let defaultAppsKey = "coucouShelfDefaultApps"

    private let ud = UserDefaults.standard

    @Published var enabled: Bool { didSet { ud.set(enabled, forKey: Self.enabledKey) } }
    @Published var layout: KeepLayout {
        didSet {
            ud.set(layout.rawValue, forKey: Self.layoutKey)
            NotificationCenter.default.post(name: KeepLayout.changed, object: IslandView.shelf)
        }
    }
    @Published var previews: Bool { didSet { ud.set(previews, forKey: Self.previewsKey) } }
    @Published var retention: KeepRetention { didSet { ud.set(retention.rawValue, forKey: Self.retentionKey); FileShelf.shared.prune() } }
    @Published var retentionDays: Int { didSet { ud.set(retentionDays, forKey: Self.retentionDaysKey); FileShelf.shared.prune() } }
    /// 0 = no limit.
    @Published var maxItems: Int { didSet { ud.set(maxItems, forKey: Self.maxItemsKey); FileShelf.shared.prune() } }
    @Published var persist: Bool { didSet { ud.set(persist, forKey: Self.persistKey) } }
    /// Extension → the application's path, for Open. Set from "Open with ▸ Set the default" or the Shelf page.
    @Published var defaultApps: [String: String] { didSet { ud.set(defaultApps, forKey: Self.defaultAppsKey) } }

    private init() {
        enabled = ud.object(forKey: Self.enabledKey) as? Bool ?? true
        layout = KeepLayout(rawValue: ud.string(forKey: Self.layoutKey) ?? "") ?? .grid
        previews = ud.object(forKey: Self.previewsKey) as? Bool ?? true
        retention = KeepRetention(rawValue: ud.string(forKey: Self.retentionKey) ?? "") ?? .days7
        retentionDays = max(1, ud.object(forKey: Self.retentionDaysKey) as? Int ?? 10)
        maxItems = ud.object(forKey: Self.maxItemsKey) as? Int ?? 24
        persist = ud.object(forKey: Self.persistKey) as? Bool ?? true
        defaultApps = ud.dictionary(forKey: Self.defaultAppsKey) as? [String: String] ?? [:]
    }

    /// Read without the main actor, for `islandSize`.
    nonisolated static var layoutForSize: KeepLayout {
        KeepLayout(rawValue: UserDefaults.standard.string(forKey: layoutKey) ?? "") ?? .grid
    }

    var keepDays: Int? { retention.days(custom: retentionDays) }

    func defaultApp(for ext: String) -> URL? {
        guard let path = defaultApps[ext.lowercased()], FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    func setDefaultApp(_ app: URL?, for ext: String) {
        var next = defaultApps
        if let app { next[ext.lowercased()] = app.path } else { next.removeValue(forKey: ext.lowercased()) }
        defaultApps = next
    }
}

// MARK: - The shelf

@MainActor
final class FileShelf: ObservableObject {
    static let shared = FileShelf()

    /// The drop handler and the header read this without the settings object.
    static var enabled: Bool { UserDefaults.standard.object(forKey: ShelfSettings.enabledKey) as? Bool ?? true }

    @Published private(set) var items: [ShelfItem] = []
    /// The files the actions act on: the last dropped, or the ones clicked (⌘-click adds).
    @Published var selected: Set<UUID> = []
    /// A file is being dragged out: the island stays open for the drag (fsm.isHeldOpen).
    @Published var dragging = false
    private var dragReset: DispatchWorkItem?
    /// The file of the drag in progress: dropped back on the island, it is left alone.
    private(set) var draggedPath: String?
    private var pruneTimer: Timer?

    private static var file: URL { HookServer.supportDir.appendingPathComponent("shelf.json") }

    private init() {
        load()
        // Things left too long leave on the hour.
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in FileShelf.shared.prune() }
        }
    }

    var selectedItems: [ShelfItem] { items.filter { selected.contains($0.id) } }
    var firstSelected: ShelfItem? { items.first { selected.contains($0.id) } }

    /// Adds the files (newest first) and selects them; a file already on the shelf moves to the front.
    func add(_ urls: [URL]) {
        var next = items
        var ids: Set<UUID> = []
        for url in urls.reversed() {
            let path = url.standardizedFileURL.path
            next.removeAll { $0.path == path }
            let item = ShelfItem(id: UUID(), path: path, addedAt: .now)
            next.insert(item, at: 0)
            ids.insert(item.id)
        }
        set(next)
        selected = ids
        prune()
        appendAppLog("nb.log", "[Shelf] +\(urls.count) file(s), \(items.count) on the shelf")
    }

    func remove(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        set(items.filter { !ids.contains($0.id) })
        selected.subtract(ids)
        appendAppLog("nb.log", "[Shelf] \(ids.count) removed, \(items.count) left")
    }

    func remove(_ item: ShelfItem) { remove([item.id]) }

    func clear() {
        set([])
        selected = []
        appendAppLog("nb.log", "[Shelf] cleared")
    }

    func select(_ item: ShelfItem, adding: Bool) {
        if adding {
            if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
        } else {
            selected = [item.id]
        }
    }

    /// Drops what is gone, what is too old and what is past the size.
    func prune() {
        let settings = ShelfSettings.shared
        var next = items.filter { FileManager.default.fileExists(atPath: $0.path) }
        if let days = settings.keepDays {
            let limit = Date().addingTimeInterval(-Double(days) * 86400)
            next.removeAll { $0.addedAt < limit }
        }
        if settings.maxItems > 0, next.count > settings.maxItems { next = Array(next.prefix(settings.maxItems)) }
        if next != items {
            appendAppLog("nb.log", "[Shelf] pruned \(items.count - next.count) (keep: \(settings.retention.rawValue), max \(settings.maxItems))")
            set(next)
            selected = selected.filter { id in next.contains { $0.id == id } }
        }
    }

    /// When `item` leaves by itself, in words, for the detail panel.
    func leaves(_ item: ShelfItem) -> String {
        guard let days = ShelfSettings.shared.keepDays else { return "Stays until you remove it." }
        let left = max(0, Int((Double(days) * 86400 - Date().timeIntervalSince(item.addedAt)) / 86400))
        return left == 0 ? "Leaves today." : "Leaves by itself in \(left) day\(left == 1 ? "" : "s")."
    }

    /// A permission or a question waits, or a Finished/Error card is on screen: the drop
    /// must not take the notch over. The file lands quietly; the tray tab fills.
    static func dropsQuietly(_ state: AppState) -> Bool {
        state.pendingApproval != nil || state.pendingQuestion != nil
            || (state.mode == .expanded && (state.view == .finished || state.view == .error))
    }

    // MARK: Opening

    /// The apps that can open `item`, the chosen default first.
    func apps(for item: ShelfItem) -> [URL] {
        var urls = NSWorkspace.shared.urlsForApplications(toOpen: item.url)
        if let chosen = ShelfSettings.shared.defaultApp(for: item.ext) {
            urls.removeAll { $0.standardizedFileURL == chosen.standardizedFileURL }
            urls.insert(chosen, at: 0)
        }
        return Array(urls.prefix(8))
    }

    /// Opens in the app chosen for its extension, else as macOS would.
    func open(_ item: ShelfItem) {
        if let app = ShelfSettings.shared.defaultApp(for: item.ext) {
            NSWorkspace.shared.open([item.url], withApplicationAt: app, configuration: .init()) { _, error in
                if error != nil { NSWorkspace.shared.open(item.url) }
            }
        } else {
            NSWorkspace.shared.open(item.url)
        }
        appendAppLog("nb.log", "[Shelf] open \(item.name)")
    }

    func open(_ item: ShelfItem, with app: URL) {
        NSWorkspace.shared.open([item.url], withApplicationAt: app, configuration: .init(), completionHandler: nil)
        appendAppLog("nb.log", "[Shelf] open \(item.name) with \(app.lastPathComponent)")
    }

    func showInFinder(_ items: [ShelfItem]) {
        NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url))
    }

    func copy(_ items: [ShelfItem]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(items.map { $0.url as NSURL })
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

    // MARK: Drag out

    /// Called from the card's onDrag: holds the island open while the drag lasts.
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

    // MARK: Storage

    private func set(_ next: [ShelfItem]) {
        guard next != items else { return }
        items = next
        save()
    }

    private func load() {
        guard ShelfSettings.shared.persist, let data = try? Data(contentsOf: Self.file),
              let saved = try? JSONDecoder().decode([ShelfItem].self, from: data) else { return }
        items = saved.filter { FileManager.default.fileExists(atPath: $0.path) }
        prune()
        if items.count != saved.count { save() }
    }

    private func save() {
        guard ShelfSettings.shared.persist else {
            try? FileManager.default.removeItem(at: Self.file)
            return
        }
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? FileManager.default.createDirectory(at: HookServer.supportDir, withIntermediateDirectories: true)
        try? data.write(to: Self.file, options: .atomic)
    }
}
#endif
