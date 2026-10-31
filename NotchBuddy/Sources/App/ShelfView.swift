#if !APPSTORE
import AppKit
import SwiftUI

// MARK: - The shelf page in the notch (coucou-custom fork)
//
// The whole card is the shelf: a search field with the kind chips, then the files as cards in
// a grid of four (the island grows to 330 pt) or a carousel grouped by time (240 pt). Click
// selects, ⌘-click adds, double-click opens; ← → ↩ Space ⌫ work from the search field;
// right-click brings the actions. A card drags out into any app.

struct ShelfView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var shelf = FileShelf.shared
    @ObservedObject private var settings = ShelfSettings.shared
    @StateObject private var toast = KeepToastModel()
    @State private var query = ""
    @State private var kind: KeepKind?
    @State private var preview: ShelfItem?
    @FocusState private var searching: Bool
    @Environment(\.islandViewActive) private var active

    private var visible: [ShelfItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return shelf.items.filter { (kind == nil || $0.kind == kind) && (q.isEmpty || $0.name.lowercased().contains(q)) }
    }

    private var countLabel: String {
        query.isEmpty ? "\(shelf.items.count) file\(shelf.items.count == 1 ? "" : "s")" : "\(visible.count) of \(shelf.items.count)"
    }

    var body: some View {
        ZStack {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    KeepSearchField(placeholder: "Search the shelf", text: $query, count: countLabel, focus: $searching, onKey: handleKey)
                        .frame(minWidth: 150)
                    ForEach(KeepKind.shelfChips) { k in
                        KeepChip(label: k.label, on: kind == k) { withAnimation(.easeOut(duration: 0.15)) { kind = kind == k ? nil : k } }
                    }
                    KeepLayoutToggle(layout: $settings.layout)
                }
                if visible.isEmpty {
                    emptyState
                } else if settings.layout == .grid {
                    grid
                } else {
                    carousel
                }
                Spacer(minLength: 0)
                KeepHints(hints: [("↩", "Open"), ("Space", "Quick Look"), ("⌫", "Remove"), ("⌘click", "Select more")], trailing: trailingHint)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if let item = preview {
                ShelfPreviewOverlay(item: item) { preview = nil }
                    .transition(.opacity)
            }
            if let text = toast.text {
                VStack { Spacer(); KeepToast(text: text).padding(.bottom, 24) }
            }
        }
        .animation(.easeOut(duration: 0.18), value: preview != nil)
        .onChange(of: active) { _, on in
            // The page opens with the search ready for typing; leaving it clears the search.
            if on { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { searching = true } } else { query = ""; preview = nil }
        }
        .onAppear { if active { searching = true } }
    }

    // MARK: Layouts

    private var grid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(visible) { item in card(item, width: nil, height: 102, previewHeight: 50) }
            }
            .padding(.bottom, 2)
        }
        .frame(height: 212)
    }

    private var carousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 7) {
                ForEach(groups, id: \.label) { group in
                    KeepSectionLabel(text: group.label)
                        .frame(height: 118)
                    ForEach(group.items) { item in card(item, width: 118, height: 118, previewHeight: 56) }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
        .frame(height: 118)
    }

    private var groups: [(label: String, items: [ShelfItem])] {
        var out: [(label: String, items: [ShelfItem])] = []
        for item in visible {
            let label = KeepBucket.label(item.addedAt)
            if let i = out.firstIndex(where: { $0.label == label }) { out[i].items.append(item) } else { out.append((label, [item])) }
        }
        return out
    }

    private func card(_ item: ShelfItem, width: CGFloat?, height: CGFloat, previewHeight: CGFloat) -> some View {
        let selected = shelf.selected.contains(item.id)
        return KeepCard(name: item.name, detail: detail(item), badge: badge(item), selected: selected, width: width, height: height) {
            KeepFilePreview(url: item.url, size: CGSize(width: width.map { $0 - 16 } ?? 127, height: previewHeight), showsThumbnail: settings.previews)
                .frame(height: previewHeight)
                .background(Color.white.opacity(0.04))
        }
        .highPriorityGesture(TapGesture(count: 2).onEnded { shelf.open(item) })
        .simultaneousGesture(TapGesture().modifiers(.command).onEnded { shelf.select(item, adding: true) })
        .onTapGesture { shelf.select(item, adding: false) }
        .onDrag {
            shelf.beginDrag(item)
            return NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
        }
        .contextMenu { ShelfContextMenu(item: item, state: state, toast: toast, onPreview: { preview = item }) }
        .help(item.path)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            Text(shelf.items.isEmpty ? "Nothing on the shelf" : "Nothing matches “\(query)”")
                .font(.system(size: 13, weight: .semibold))
            Text(shelf.items.isEmpty ? "Drop files on the notch: they wait here until you drag them out, open them or send them on."
                                      : "Try another word, or clear the chips.")
                .font(.system(size: 11.5))
                .foregroundColor(Color(hex: "#8E939C"))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: settings.layout == .grid ? 212 : 118)
    }

    private var trailingHint: String {
        let sel = shelf.selectedItems
        if sel.count > 1 { return "\(sel.count) selected" }
        if let one = sel.first { return one.name + " · " + detail(one) }
        return settings.layout == .grid ? "Grid · scroll down for more" : "Carousel · newest first"
    }

    // MARK: Text

    private func detail(_ item: ShelfItem) -> String {
        let values = try? item.url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        var parts: [String] = []
        if values?.isDirectory == true {
            let n = (try? FileManager.default.contentsOfDirectory(atPath: item.path).count) ?? 0
            parts.append("Folder · \(n) item\(n == 1 ? "" : "s")")
        } else if let bytes = values?.fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        parts.append(item.url.deletingLastPathComponent().lastPathComponent)
        return parts.joined(separator: " · ")
    }

    private func badge(_ item: ShelfItem) -> String {
        item.kind == .folder ? "FOLDER" : item.ext.isEmpty ? "FILE" : item.ext.uppercased()
    }

    // MARK: Keys (from the search field)

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let list = visible
        let current = list.firstIndex { shelf.selected.contains($0.id) }
        switch press.key {
        case .rightArrow, .leftArrow:
            guard !list.isEmpty else { return .ignored }
            let step = press.key == .rightArrow ? 1 : -1
            let next = list[((current ?? -step) + step + list.count) % list.count]
            shelf.select(next, adding: false)
            return .handled
        case .downArrow, .upArrow:
            guard settings.layout == .grid, !list.isEmpty else { return .ignored }
            let step = press.key == .downArrow ? 4 : -4
            let i = max(0, min(list.count - 1, (current ?? 0) + step))
            shelf.select(list[i], adding: false)
            return .handled
        case .return:
            guard let item = shelf.firstSelected else { return .ignored }
            if press.modifiers.contains(.command) { shelf.askClaude(item, state: state) } else { shelf.open(item) }
            return .handled
        case .space:
            guard query.isEmpty, let item = shelf.firstSelected else { return .ignored }
            preview = preview == nil ? item : nil
            return .handled
        case .delete:
            guard query.isEmpty, !shelf.selected.isEmpty else { return .ignored }
            let n = shelf.selected.count
            shelf.remove(shelf.selected)
            toast.say(n > 1 ? "\(n) removed from the shelf" : "Removed · the file stays where it is")
            return .handled
        case .escape:
            if preview != nil { preview = nil; return .handled }
            if !query.isEmpty { query = ""; return .handled }
            return .ignored
        default:
            return .ignored
        }
    }
}

// MARK: - Actions

private struct ShelfContextMenu: View {
    let item: ShelfItem
    @ObservedObject var state: AppState
    @ObservedObject var toast: KeepToastModel
    let onPreview: () -> Void
    @ObservedObject private var shelf = FileShelf.shared

    /// The selection when the clicked file is part of it, else the file alone.
    private var targets: [ShelfItem] {
        shelf.selected.contains(item.id) && shelf.selected.count > 1 ? shelf.selectedItems : [item]
    }

    var body: some View {
        Button("Open") { targets.forEach { shelf.open($0) } }
        Menu("Open with") {
            ForEach(shelf.apps(for: item), id: \.path) { app in
                Button {
                    targets.forEach { shelf.open($0, with: app) }
                } label: {
                    Label(appName(app) + (ShelfSettings.shared.defaultApp(for: item.ext)?.standardizedFileURL == app.standardizedFileURL ? "  · default" : ""),
                          image: "")
                }
            }
            Divider()
            Menu("Set the default for .\(item.ext.isEmpty ? "file" : item.ext)") {
                ForEach(shelf.apps(for: item), id: \.path) { app in
                    Button(appName(app)) {
                        ShelfSettings.shared.setDefaultApp(app, for: item.ext)
                        toast.say(".\(item.ext) now opens in \(appName(app))")
                    }
                }
                if ShelfSettings.shared.defaultApp(for: item.ext) != nil {
                    Divider()
                    Button("As macOS would") { ShelfSettings.shared.setDefaultApp(nil, for: item.ext) }
                }
            }
        }
        Button("Quick Look") { onPreview() }
        Button("Show in Finder") { shelf.showInFinder(targets) }
        Divider()
        Button("Ask Claude about it") { shelf.askClaude(item, state: state) }
        Button("Send by email") { shelf.sendByEmail(item, state: state) }
        Button("Copy") { shelf.copy(targets); toast.say(targets.count > 1 ? "\(targets.count) files copied" : "Copied") }
        Divider()
        Button(targets.count > 1 ? "Remove \(targets.count) from the shelf" : "Remove from the shelf", role: .destructive) {
            shelf.remove(Set(targets.map(\.id)))
            toast.say(targets.count > 1 ? "\(targets.count) removed from the shelf" : "Removed · the file stays where it is")
        }
    }

    private func appName(_ app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }
}

// MARK: - Quick Look, in the island

/// A larger thumbnail over the card, the name and the details; click or Space closes it.
private struct ShelfPreviewOverlay: View {
    let item: ShelfItem
    let close: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
            VStack(spacing: 8) {
                KeepFilePreview(url: item.url, size: CGSize(width: 300, height: 140))
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
                Text(item.name).font(.system(size: 12, weight: .semibold))
                Text(item.path).font(.system(size: 10)).foregroundColor(Color(hex: "#8E939C")).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 480)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .onTapGesture { close() }
    }
}
#endif
