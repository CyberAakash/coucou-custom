#if !APPSTORE
import AppKit
import SwiftUI

// MARK: - The clipboard page in the notch (coucou-custom fork)
//
// The same card as the shelf: a search field, a Filter button (the kinds as chips), Recording /
// Paused and the layout toggle, then what you copied as cards in a carousel grouped by time
// (240 pt) or a grid (330 pt). ↩ pastes into the app in front, ⌘↩ copies, ⌘. pins, ⌫ deletes;
// right-click brings the actions.

struct ClipboardView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var store = ClipboardStore.shared
    @ObservedObject private var settings = ClipboardSettings.shared
    @StateObject private var toast = KeepToastModel()
    @State private var query = ""
    @State private var kinds: Set<KeepKind> = []
    @State private var filterOpen = false
    @FocusState private var searching: Bool
    @Environment(\.islandViewActive) private var active

    private var visible: [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return store.items
            .filter { (kinds.isEmpty || kinds.contains($0.kind)) && (q.isEmpty || $0.text.lowercased().contains(q) || $0.appName.lowercased().contains(q)) }
            .sorted { ($0.pinned ? 1 : 0, $0.at) > ($1.pinned ? 1 : 0, $1.at) }
    }

    private var counts: [KeepKind: Int] { store.items.reduce(into: [:]) { $0[$1.kind, default: 0] += 1 } }
    /// The cards keep their height: the island grows by the filter row instead (KeepPanels).
    private var cardsHeight: CGFloat { settings.layout == .grid ? 212 : 118 }

    var body: some View {
        ZStack {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    KeepSearchField(placeholder: "Search what you copied", text: $query, focus: $searching, onKey: handleKey)
                    KeepFilterButton(kinds: $kinds, open: $filterOpen)
                    recordingChip
                    KeepLayoutToggle(layout: $settings.layout)
                }
                if filterOpen {
                    KeepFilterPanel(kinds: $kinds, available: KeepKind.clipboardKinds, counts: counts)
                }
                if visible.isEmpty {
                    emptyState
                } else if settings.layout == .grid {
                    grid
                } else {
                    carousel
                }
                Spacer(minLength: 0)
                KeepHints(hints: [("↩", settings.enterPastes ? "Paste" : "Copy"), ("⌘↩", "Copy"), ("⌘.", "Pin"), ("⌫", "Delete")], trailing: trailingHint)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if let text = toast.text {
                VStack { Spacer(); KeepToast(text: text).padding(.bottom, 24) }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: filterOpen)
        .onChange(of: filterOpen) { _, on in KeepPanels.setFilter(on, for: .clipboard) }
        .onChange(of: active) { _, on in
            if on { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { searching = true } } else { query = ""; filterOpen = false }
        }
        .onAppear {
            if active { searching = true }
            if KeepDebug.filterOpen { filterOpen = true }
        }
    }

    private var recordingChip: some View {
        Button {
            if settings.isPaused { settings.pausedUntil = nil } else if settings.enabled { settings.pausedUntil = .distantFuture } else { settings.enabled = true }
        } label: {
            HStack(spacing: 4) {
                Circle().fill(settings.recording ? Color(hex: "#34D399") : Color(hex: "#6B7079")).frame(width: 6, height: 6)
                    .modifier(KeepBreath(on: settings.recording))
                Text(settings.recording ? "Recording" : "Paused")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(settings.recording ? Color(hex: "#34D399") : Color(hex: "#8E939C"))
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Capsule().fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help(settings.recording ? "Pause recording" : "Resume recording")
    }

    // MARK: Layouts

    private var grid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(visible) { item in card(item, width: nil, height: 102, previewHeight: 50) }
            }
            .padding(.bottom, 2)
        }
        .frame(height: cardsHeight)
    }

    private var carousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 7) {
                ForEach(groups, id: \.label) { group in
                    KeepSectionLabel(text: group.label).frame(height: cardsHeight)
                    ForEach(group.items) { item in card(item, width: 118, height: cardsHeight, previewHeight: 56) }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
        .frame(height: cardsHeight)
    }

    private var groups: [(label: String, items: [ClipItem])] {
        var out: [(label: String, items: [ClipItem])] = []
        for item in visible {
            let label = item.pinned ? "PINNED" : KeepBucket.label(item.at)
            if let i = out.firstIndex(where: { $0.label == label }) { out[i].items.append(item) } else { out.append((label, [item])) }
        }
        return out
    }

    private func card(_ item: ClipItem, width: CGFloat?, height: CGFloat, previewHeight: CGFloat) -> some View {
        KeepCard(name: title(item), detail: "\(item.appName) · \(KeepBucket.ago(item.at))", badge: badge(item), badgeTint: tint(item),
                 pinned: item.pinned, selected: store.selected == item.id, width: width, height: height,
                 onTap: { store.selected = item.id },
                 onDoubleTap: { primary(item) }) {
            ClipPreview(item: item, height: previewHeight)
        }
        .contextMenu { ClipContextMenu(item: item, state: state, toast: toast) }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            Text(store.items.isEmpty ? "Nothing kept yet" : "Nothing matches")
                .font(.system(size: 13, weight: .semibold))
            Text(store.items.isEmpty ? (settings.recording ? "Copy something: it shows up here, on this Mac only." : "Recording is paused.")
                                     : "Try another word, or clear the filter.")
                .font(.system(size: 11.5)).foregroundColor(Color(hex: "#8E939C"))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: cardsHeight)
    }

    private var trailingHint: String {
        if let id = store.selected, let item = store.items.first(where: { $0.id == id }) { return store.leaves(item) }
        let count = "\(store.items.count) item\(store.items.count == 1 ? "" : "s")"
        if !query.isEmpty || !kinds.isEmpty { return "\(visible.count) of \(count)" }
        return count
    }

    // MARK: Text

    private func title(_ item: ClipItem) -> String {
        switch item.kind {
        case .image: return "Image · \(item.text)"
        case .color: return item.hex ?? item.text
        case .link: return item.domain ?? item.firstLine
        default: return item.firstLine
        }
    }

    private func badge(_ item: ClipItem) -> String { item.kind.rawValue.uppercased() }

    private func tint(_ item: ClipItem) -> Color? {
        switch item.kind {
        case .link: return Color(hex: "#3B9EFF")
        case .code: return Color(hex: "#34D399")
        case .file: return Color(hex: "#A78BFA")
        case .image, .color: return nil
        default: return Color(hex: "#C5C8CD")
        }
    }

    // MARK: Actions

    private func primary(_ item: ClipItem) {
        if settings.enterPastes {
            toast.say(store.paste(item) ? "Pasted into the app in front" : "Copied · Accessibility is needed to paste for you")
        } else {
            store.copy(item); toast.say("Copied")
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let list = visible
        let current = list.firstIndex { $0.id == store.selected }
        let item = store.items.first { $0.id == store.selected }
        switch press.key {
        case .rightArrow, .leftArrow:
            guard !list.isEmpty else { return .ignored }
            let step = press.key == .rightArrow ? 1 : -1
            store.selected = list[((current ?? -step) + step + list.count) % list.count].id
            return .handled
        case .downArrow, .upArrow:
            guard settings.layout == .grid, !list.isEmpty else { return .ignored }
            let step = press.key == .downArrow ? 4 : -4
            store.selected = list[max(0, min(list.count - 1, (current ?? 0) + step))].id
            return .handled
        case .return:
            guard let item else { return .ignored }
            if press.modifiers.contains(.command) { store.copy(item); toast.say("Copied") } else { primary(item) }
            return .handled
        case .delete:
            guard query.isEmpty, let item else { return .ignored }
            store.delete(item.id); toast.say("Deleted")
            return .handled
        case .escape:
            if filterOpen { filterOpen = false; return .handled }
            guard !query.isEmpty else { return .ignored }
            query = ""
            return .handled
        default:
            if press.modifiers.contains(.command), press.characters == ".", let item { store.togglePin(item.id); return .handled }
            return .ignored
        }
    }
}

/// The preview area of a clipboard card: the words, the image, the colour, the files.
struct ClipPreview: View {
    let item: ClipItem
    let height: CGFloat
    var large = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch item.kind {
            case .image:
                if let url = item.imageURL {
                    KeepFilePreview(url: url, size: CGSize(width: large ? 300 : 140, height: height))
                } else {
                    Color.white.opacity(0.04)
                }
            case .color:
                if let hex = item.hex {
                    Color(hex: hex)
                    Text(hex).font(.system(size: large ? 14 : 10, weight: .bold, design: .monospaced)).foregroundColor(Color(hex: "#0E0F11"))
                        .padding(large ? 12 : 6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            case .file:
                Color.white.opacity(0.04)
                if let first = item.paths.first {
                    KeepFilePreview(url: URL(fileURLWithPath: first), size: CGSize(width: large ? 300 : 140, height: height))
                }
            default:
                Color.white.opacity(0.04)
                Text(item.text)
                    .font(item.kind == .code ? .system(size: large ? 11.5 : 8.5, design: .monospaced) : .system(size: large ? 12.5 : 9.5))
                    .foregroundColor(Color(hex: item.kind == .code ? "#C9CDD4" : "#E1E3E6"))
                    .lineLimit(large ? 10 : (item.kind == .code ? 4 : 3))
                    .fixedSize(horizontal: false, vertical: large)
                    .padding(large ? 14 : 6)
                    // The kind badge sits at the top right: the words stop short of it.
                    .padding(.trailing, large ? 0 : 36)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: large ? 72 : height, maxHeight: height)
        .fixedSize(horizontal: false, vertical: large)
        .clipped()
    }
}

private struct ClipContextMenu: View {
    let item: ClipItem
    @ObservedObject var state: AppState
    @ObservedObject var toast: KeepToastModel
    private var store: ClipboardStore { ClipboardStore.shared }
    private var frontApp: String { AppState.shared.lastExternalApp?.localizedName ?? "the app in front" }

    var body: some View {
        Button("Paste into \(frontApp)") { toast.say(store.paste(item) ? "Pasted into \(frontApp)" : "Copied · Accessibility is needed to paste for you") }
        Button("Copy") { store.copy(item); toast.say("Copied") }
        if item.kind != .image && item.kind != .file {
            Button("Paste as plain text") { toast.say(store.paste(item, plain: true) ? "Pasted as plain text" : "Copied as plain text") }
        }
        Divider()
        Button("Ask Claude about it") { store.askClaude(item, state: state) }
        Button("Put on the shelf") { store.putOnShelf(item); toast.say("On the shelf") }
        Button(item.pinned ? "Unpin" : "Pin") { store.togglePin(item.id) }
        Divider()
        Button("Delete", role: .destructive) { store.delete(item.id); toast.say("Deleted") }
    }
}

/// The recording dot breathes while recording (opacity only).
struct KeepBreath: ViewModifier {
    let on: Bool
    @State private var dim = false
    func body(content: Content) -> some View {
        content
            .opacity(on && dim ? 0.35 : 1)
            .animation(on ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: dim)
            .onAppear { dim = on }
            .onChange(of: on) { _, v in dim = v }
    }
}
#endif
