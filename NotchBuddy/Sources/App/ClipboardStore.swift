#if !APPSTORE
import AppKit
import SwiftUI
import Carbon.HIToolbox
import UniformTypeIdentifiers

// MARK: - Clipboard history (coucou-custom fork)
//
// What you copy, kept on this Mac: text, links, colours, code, images and files, newest first,
// pinned ones first of all. The store polls the general pasteboard twice a second (a change
// count compare, nearly free) and skips what should never be kept: things marked transient,
// concealed or auto-generated (the nspasteboard.org convention, used by password managers and
// by Coucou's own dictation), Universal Clipboard arrivals, and copies made in the apps you
// skip (Passwords and Keychain Access always). Images are kept as PNG files beside the index;
// the index itself stays in memory unless "Keep on disk" is on.

struct ClipItem: Identifiable, Codable, Equatable {
    let id: UUID
    var kind: KeepKind
    /// Plain text; for an image, its pixel size; for files, the names.
    var text: String
    /// The files copied, as paths (kind .file).
    var paths: [String] = []
    /// The PNG for an image, in the clips folder.
    var imageFile: String?
    /// RTF for rich text, in the clips folder, so a paste keeps the formatting.
    var rtfFile: String?
    var appName: String
    var appBundle: String
    var at: Date
    var pinned = false

    var imageURL: URL? { imageFile.map { ClipboardStore.folder.appendingPathComponent($0) } }
    var rtfURL: URL? { rtfFile.map { ClipboardStore.folder.appendingPathComponent($0) } }
    var firstLine: String { text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text }
    /// A hex colour for a .color item ("#22D3EE").
    var hex: String? { kind == .color ? ClipboardStore.hexColor(in: text) : nil }
    var domain: String? {
        guard kind == .link, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return url.host?.replacingOccurrences(of: "www.", with: "")
    }
}

// MARK: Settings

@MainActor
final class ClipboardSettings: ObservableObject {
    static let shared = ClipboardSettings()

    nonisolated static let enabledKey = "coucouClipEnabled"
    nonisolated static let layoutKey = "coucouClipLayout"
    static let retentionKey = "coucouClipKeep"
    static let retentionDaysKey = "coucouClipKeepDays"
    static let maxItemsKey = "coucouClipMax"
    static let diskKey = "coucouClipOnDisk"
    static let skippedKey = "coucouClipSkippedApps"
    static let enterPastesKey = "coucouClipEnterPastes"
    static let pausedUntilKey = "coucouClipPausedUntil"

    /// Always skipped, whatever the list says.
    static let alwaysSkipped = ["com.apple.Passwords", "com.apple.keychainaccess"]

    private let ud = UserDefaults.standard

    @Published var enabled: Bool { didSet { ud.set(enabled, forKey: Self.enabledKey) } }
    @Published var layout: KeepLayout {
        didSet {
            ud.set(layout.rawValue, forKey: Self.layoutKey)
            NotificationCenter.default.post(name: KeepLayout.changed, object: IslandView.clipboard)
        }
    }
    @Published var retention: KeepRetention { didSet { ud.set(retention.rawValue, forKey: Self.retentionKey); ClipboardStore.shared.prune() } }
    @Published var retentionDays: Int { didSet { ud.set(retentionDays, forKey: Self.retentionDaysKey); ClipboardStore.shared.prune() } }
    /// 0 = no limit.
    @Published var maxItems: Int { didSet { ud.set(maxItems, forKey: Self.maxItemsKey); ClipboardStore.shared.prune() } }
    @Published var keepOnDisk: Bool { didSet { ud.set(keepOnDisk, forKey: Self.diskKey); ClipboardStore.shared.save() } }
    /// Bundle identifiers whose copies are not kept (besides `alwaysSkipped`).
    @Published var skippedApps: [String] { didSet { ud.set(skippedApps, forKey: Self.skippedKey) } }
    @Published var enterPastes: Bool { didSet { ud.set(enterPastes, forKey: Self.enterPastesKey) } }
    /// Recording is paused until then (nil: not paused; .distantFuture: until resumed by hand).
    @Published var pausedUntil: Date? { didSet { ud.set(pausedUntil, forKey: Self.pausedUntilKey) } }

    private init() {
        enabled = ud.object(forKey: Self.enabledKey) as? Bool ?? true
        layout = KeepLayout(rawValue: ud.string(forKey: Self.layoutKey) ?? "") ?? .carousel
        retention = KeepRetention(rawValue: ud.string(forKey: Self.retentionKey) ?? "") ?? .days7
        retentionDays = max(1, ud.object(forKey: Self.retentionDaysKey) as? Int ?? 13)
        maxItems = ud.object(forKey: Self.maxItemsKey) as? Int ?? 100
        keepOnDisk = ud.object(forKey: Self.diskKey) as? Bool ?? false
        skippedApps = ud.stringArray(forKey: Self.skippedKey) ?? ["com.1password.1password", "com.bitwarden.desktop"]
        enterPastes = ud.object(forKey: Self.enterPastesKey) as? Bool ?? true
        pausedUntil = ud.object(forKey: Self.pausedUntilKey) as? Date
    }

    nonisolated static var layoutForSize: KeepLayout {
        KeepLayout(rawValue: UserDefaults.standard.string(forKey: layoutKey) ?? "") ?? .carousel
    }

    var keepDays: Int? { retention.days(custom: retentionDays) }

    var isPaused: Bool {
        guard let until = pausedUntil else { return false }
        if until < .now { return false }
        return true
    }

    /// Recording right now: on, and not paused.
    var recording: Bool { enabled && !isPaused }

    func skips(_ bundle: String?) -> Bool {
        guard let bundle else { return false }
        return Self.alwaysSkipped.contains(bundle) || skippedApps.contains(bundle)
    }
}

// MARK: Store

@MainActor
final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()

    nonisolated static let folder = HookServer.supportDir.appendingPathComponent("clipboard", isDirectory: true)
    private static var indexFile: URL { folder.appendingPathComponent("clipboard.json") }
    private static let transientTypes: Set<String> = [
        "org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType", "org.nspasteboard.AutoGeneratedType",
        "de.petermaurer.TransientPasteboardType", "com.agilebits.onepassword", "com.apple.is-remote-clipboard",
    ]
    private static let maxText = 16_384
    private static let maxImageSide: CGFloat = 1600

    @Published private(set) var items: [ClipItem] = []
    @Published var selected: UUID?

    private var timer: Timer?
    private var lastChange = NSPasteboard.general.changeCount
    /// A change we made ourselves (copy, paste): not recorded.
    private var ownChange: Int?
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in ClipboardStore.shared.poll() }
        }
        appendAppLog("nb.log", "[Clipboard] watching (\(items.count) kept, on disk: \(ClipboardSettings.shared.keepOnDisk))")
    }

    // MARK: Polling

    private func poll() {
        let board = NSPasteboard.general
        let count = board.changeCount
        guard count != lastChange else { return }
        lastChange = count
        if count == ownChange { return }
        let settings = ClipboardSettings.shared
        guard settings.recording else { return }
        let types = Set((board.types ?? []).map(\.rawValue))
        if !types.isDisjoint(with: Self.transientTypes) { return }
        let front = NSWorkspace.shared.frontmostApplication
        if settings.skips(front?.bundleIdentifier) { return }
        guard let item = Self.read(board, front: front) else { return }
        add(item)
    }

    /// What the pasteboard holds, as one item: files, then an image, then text.
    private static func read(_ board: NSPasteboard, front: NSRunningApplication?) -> ClipItem? {
        let app = front?.localizedName ?? "Unknown"
        let bundle = front?.bundleIdentifier ?? ""
        let id = UUID()
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return ClipItem(id: id, kind: .file, text: urls.map(\.lastPathComponent).joined(separator: ", "), paths: urls.map(\.path),
                            appName: app, appBundle: bundle, at: .now)
        }
        if let image = NSImage(pasteboard: board), image.isValid, image.size.width > 0 {
            guard let png = downsampledPNG(image) else { return nil }
            let name = id.uuidString + ".png"
            try? png.data.write(to: folder.appendingPathComponent(name), options: .atomic)
            return ClipItem(id: id, kind: .image, text: "\(Int(png.size.width)) × \(Int(png.size.height))", imageFile: name,
                            appName: app, appBundle: bundle, at: .now)
        }
        guard var text = board.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if text.count > maxText { text = String(text.prefix(maxText)) }
        var rtfName: String?
        if let rtf = board.data(forType: .rtf), rtf.count < 2_000_000 {
            rtfName = id.uuidString + ".rtf"
            try? rtf.write(to: folder.appendingPathComponent(rtfName!), options: .atomic)
        }
        return ClipItem(id: id, kind: classify(text, board: board), text: text, rtfFile: rtfName, appName: app, appBundle: bundle, at: .now)
    }

    static func classify(_ text: String, board: NSPasteboard? = nil) -> KeepKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if board?.availableType(from: [.color]) != nil || (hexColor(in: trimmed) != nil && trimmed.count <= 24) { return .color }
        if !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed), let scheme = url.scheme,
           ["http", "https", "mailto", "ftp"].contains(scheme.lowercased()) { return .link }
        let lines = trimmed.split(whereSeparator: \.isNewline)
        let codeMarks = ["{", "}", ";", "=>", "func ", "def ", "import ", "const ", "let ", "var ", "class ", "#include", "return "]
        let hits = codeMarks.filter { trimmed.contains($0) }.count
        if hits >= 2 && (lines.count > 1 || trimmed.contains("{")) { return .code }
        return .text
    }

    /// "#22D3EE" from "#22d3ee", "22D3EE", "rgb(34, 211, 238)".
    nonisolated static func hexColor(in text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let m = t.range(of: #"^#?([0-9a-fA-F]{6})([0-9a-fA-F]{2})?$"#, options: .regularExpression) {
            var hex = String(t[m]).uppercased()
            if !hex.hasPrefix("#") { hex = "#" + hex }
            return String(hex.prefix(7))
        }
        if t.lowercased().hasPrefix("rgb") {
            let nums = t.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) }
            if nums.count >= 3, nums.prefix(3).allSatisfy({ (0...255).contains($0) }) {
                return String(format: "#%02X%02X%02X", nums[0], nums[1], nums[2])
            }
        }
        return nil
    }

    private static func downsampledPNG(_ image: NSImage) -> (data: Data, size: CGSize)? {
        guard let tiff = image.tiffRepresentation, let source = CGImageSourceCreateWithData(tiff as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxImageSide),
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return (png, CGSize(width: cg.width, height: cg.height))
    }

    // MARK: Items

    private func add(_ item: ClipItem) {
        var next = items
        // The same thing copied again moves to the front, keeping its pin.
        if let i = next.firstIndex(where: { $0.kind == item.kind && $0.text == item.text && $0.paths == item.paths }) {
            var moved = next.remove(at: i)
            moved.at = .now
            removeFiles(of: item)
            next.insert(moved, at: 0)
        } else {
            next.insert(item, at: 0)
        }
        items = next
        prune()
        save()
        appendAppLog("nb.log", "[Clipboard] +\(item.kind.rawValue) from \(item.appName) (\(items.count) kept)")
    }

    func delete(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        removeFiles(of: item)
        items.removeAll { $0.id == id }
        if selected == id { selected = items.first?.id }
        save()
    }

    func togglePin(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].pinned.toggle()
        save()
    }

    /// Everything but the pinned items.
    func clear() {
        items.filter { !$0.pinned }.forEach(removeFiles)
        items.removeAll { !$0.pinned }
        save()
        appendAppLog("nb.log", "[Clipboard] cleared")
    }

    func prune() {
        let settings = ClipboardSettings.shared
        var next = items
        if let days = settings.keepDays {
            let limit = Date().addingTimeInterval(-Double(days) * 86400)
            next.removeAll { !$0.pinned && $0.at < limit }
        }
        if settings.maxItems > 0 {
            var unpinned = 0
            next = next.filter { item in
                if item.pinned { return true }
                unpinned += 1
                return unpinned <= settings.maxItems
            }
        }
        if next.count != items.count {
            let gone = items.filter { item in !next.contains { $0.id == item.id } }
            gone.forEach(removeFiles)
            items = next
            save()
        }
    }

    func leaves(_ item: ClipItem) -> String {
        if item.pinned { return "Pinned: stays until you unpin it." }
        guard let days = ClipboardSettings.shared.keepDays else { return "Stays until you delete it." }
        let left = max(0, Int((Double(days) * 86400 - Date().timeIntervalSince(item.at)) / 86400))
        return left == 0 ? "Leaves today." : "Leaves by itself in \(left) day\(left == 1 ? "" : "s")."
    }

    private func removeFiles(of item: ClipItem) {
        if let url = item.imageURL { try? FileManager.default.removeItem(at: url) }
        if let url = item.rtfURL { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: Actions

    /// Puts the item back on the clipboard (not recorded again).
    func copy(_ item: ClipItem, plain: Bool = false) {
        let board = NSPasteboard.general
        board.clearContents()
        switch item.kind {
        case .file:
            board.writeObjects(item.paths.map { URL(fileURLWithPath: $0) as NSURL })
        case .image:
            if let url = item.imageURL, let image = NSImage(contentsOf: url) { board.writeObjects([image]) }
        default:
            if !plain, let url = item.rtfURL, let rtf = try? Data(contentsOf: url) {
                board.declareTypes([.rtf, .string], owner: nil)
                board.setData(rtf, forType: .rtf)
                board.setString(item.text, forType: .string)
            } else {
                board.setString(item.text, forType: .string)
            }
        }
        ownChange = board.changeCount
        lastChange = board.changeCount
    }

    /// Copies, then sends ⌘V to the app in front (⌃V in a terminal). False without the
    /// Accessibility permission: the item then stays on the clipboard for a paste by hand.
    @discardableResult
    func paste(_ item: ClipItem, plain: Bool = false) -> Bool {
        copy(item, plain: plain)
        guard AXIsProcessTrusted() else { return false }
        let app = AppState.shared.lastExternalApp ?? NSWorkspace.shared.frontmostApplication
        let terminal = CapturePaste.isTerminal(app)
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = terminal ? CGKeyCode(kVK_ANSI_V) : FlowPaste.vKeyCode()
        let flags: CGEventFlags = terminal ? .maskControl : .maskCommand
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        appendAppLog("nb.log", "[Clipboard] pasted \(item.kind.rawValue) into \(app?.localizedName ?? "the front app")")
        return true
    }

    /// The item as a file on the shelf: text as .txt, an image as its PNG, files as themselves.
    func putOnShelf(_ item: ClipItem) {
        let shelfFolder = HookServer.supportDir.appendingPathComponent("shelf-clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: shelfFolder, withIntermediateDirectories: true)
        let stamp = Self.stamp.string(from: item.at)
        switch item.kind {
        case .file:
            FileShelf.shared.add(item.paths.map { URL(fileURLWithPath: $0) })
        case .image:
            guard let src = item.imageURL else { return }
            let dest = shelfFolder.appendingPathComponent("Image \(stamp).png")
            try? FileManager.default.copyItem(at: src, to: dest)
            FileShelf.shared.add([dest])
        default:
            let stem = String(item.firstLine.prefix(32)).replacingOccurrences(of: "/", with: "-")
            let dest = shelfFolder.appendingPathComponent("\(stem.isEmpty ? "Clip" : stem) \(stamp).txt")
            try? item.text.write(to: dest, atomically: true, encoding: .utf8)
            FileShelf.shared.add([dest])
        }
        appendAppLog("nb.log", "[Clipboard] \(item.kind.rawValue) put on the shelf")
    }

    /// The chat, with the item as its context (a file for images and files, the text otherwise).
    func askClaude(_ item: ClipItem, state: AppState) {
        switch item.kind {
        case .image:
            if let url = item.imageURL { state.promptContext = .file(name: "Copied image", fileURL: url) }
        case .file:
            if let first = item.paths.first { state.promptContext = .file(name: URL(fileURLWithPath: first).lastPathComponent, fileURL: URL(fileURLWithPath: first)) }
        default:
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(item.id.uuidString.prefix(8)).txt")
            try? item.text.write(to: dest, atomically: true, encoding: .utf8)
            state.promptContext = .file(name: String(item.firstLine.prefix(40)), fileURL: dest)
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.view = .prompt }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"; return f
    }()

    // MARK: Storage

    func save() {
        guard ClipboardSettings.shared.keepOnDisk else {
            try? FileManager.default.removeItem(at: Self.indexFile)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: Self.indexFile, options: .atomic)
    }

    private func load() {
        guard ClipboardSettings.shared.keepOnDisk, let data = try? Data(contentsOf: Self.indexFile) else {
            // Nothing kept across launches: image and rtf files from earlier runs go too.
            if let files = try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil) {
                files.filter { $0.lastPathComponent != "clipboard.json" }.forEach { try? FileManager.default.removeItem(at: $0) }
            }
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = (try? decoder.decode([ClipItem].self, from: data)) ?? []
        prune()
    }
}
#endif
