#if !APPSTORE
import AppKit
import SwiftUI

// MARK: - Coucou window → Shelf and Clipboard (coucou-custom fork)
//
// Each page is laid out like the Buddy pages: the banner with its switch, a full-width tab bar
// (Files / Settings, History / Settings), then cards. The first tab manages what is kept: a
// search, a Filter button with the kinds as chips, the items as cards, and the chosen one in a
// detail panel with a real Quick Look preview, its facts and round action buttons. The second
// tab holds the settings.

enum HubKeepTab: String, CaseIterable, Identifiable {
    case items, settings
    var id: String { rawValue }
}

/// The window's search field, as the Buddy page draws it (no count inside: it lives beside the grid).
struct HubKeepSearch: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundColor(HubTheme.secondary)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 13))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(HubTheme.secondary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(HubTheme.field))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
    }
}

/// A settings row inside a HubCard, as the General page draws them.
struct HubKeepRow<C: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var control: () -> C

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundColor(HubTheme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            control()
        }
    }
}

/// The 52 × 28 number box, for "Custom" days.
struct HubKeepDays: View {
    @Binding var days: Int
    var body: some View {
        HStack(spacing: 8) {
            TextField("", value: $days, format: .number)
                .textFieldStyle(.plain).font(.system(size: 13, weight: .semibold)).multilineTextAlignment(.center)
                .frame(width: 52, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(HubTheme.field))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
            Text("days").font(.system(size: 12)).foregroundColor(HubTheme.secondary)
        }
    }
}

// MARK: - Shelf

struct HubShelfPage: View {
    static let tint = Color(hex: "#22D3EE")

    @ObservedObject private var shelf = FileShelf.shared
    @ObservedObject private var settings = ShelfSettings.shared
    @AppStorage("shelfSettingsTab") private var tabRaw = HubKeepTab.items.rawValue
    @State private var query = ""
    @State private var kinds: Set<KeepKind> = []
    @State private var filterOpen = false
    @State private var selected: UUID?
    @State private var note = ""

    private var tab: HubKeepTab { HubKeepTab(rawValue: tabRaw) ?? .items }
    private var visible: [ShelfItem] {
        let q = query.lowercased()
        return shelf.items.filter { (kinds.isEmpty || kinds.contains($0.kind)) && (q.isEmpty || $0.name.lowercased().contains(q)) }
    }
    private var counts: [KeepKind: Int] { shelf.items.reduce(into: [:]) { $0[$1.kind, default: 0] += 1 } }
    private var shown: ShelfItem? { shelf.items.first { $0.id == selected } ?? visible.first }

    var body: some View {
        HubPageScaffold(title: "Shelf",
                        subtitle: "Files dropped on the notch wait here until you drag them out, open them or send them on. Paths only, never copies.",
                        trailing: { HubBannerSwitch(title: "On the notch", tint: Self.tint, isOn: $settings.enabled) },
                        pinned: {
            BriefSegmented(options: [BriefSegmentedOption(value: HubKeepTab.items, title: "Files", symbol: "tray.full"),
                                     BriefSegmentedOption(value: HubKeepTab.settings, title: "Settings", symbol: "slider.horizontal.3")],
                           selection: Binding(get: { tab }, set: { tabRaw = $0.rawValue }),
                           tint: Self.tint, height: 38)
        }, aside: {
            HubLabel("Selected")
            detail
        }, showsAside: tab == .items) {
            if tab == .items { files } else { settingsTab }
        }
    }

    // MARK: Files

    private var files: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    HubKeepSearch(placeholder: "Search the shelf", text: $query)
                    KeepFilterButton(kinds: $kinds, open: $filterOpen, compact: false)
                }
                if filterOpen {
                    KeepFilterPanel(kinds: $kinds, available: KeepKind.shelfKinds, counts: counts, compact: false)
                }
                HStack {
                    HubLabel(countLabel)
                    Spacer()
                    if !shelf.items.isEmpty {
                        Button("Clear the shelf") { shelf.clear(); selected = nil }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundColor(HubTheme.red)
                    }
                }
                .padding(.top, 4)
                if visible.isEmpty {
                    HubEmptyState(text: shelf.items.isEmpty ? "Nothing here. Drop files on the notch and they wait on the shelf."
                                                            : "Nothing matches. Try another word, or clear the filter.", state: .idle)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                        ForEach(visible) { item in
                            KeepCard(name: item.name, detail: detail(item), badge: badge(item), selected: shown?.id == item.id, height: 150,
                                     onTap: { selected = item.id }, onDoubleTap: { shelf.open(item) }) {
                                KeepFilePreview(url: item.url, size: CGSize(width: 180, height: 72), showsThumbnail: settings.previews)
                            }
                            .onDrag { shelf.beginDrag(item); return NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
                            .contextMenu {
                                Button("Open") { shelf.open(item) }
                                Button("Show in Finder") { shelf.showInFinder([item]) }
                                Button("Copy") { shelf.copy([item]) }
                                Divider()
                                Button("Remove from the shelf", role: .destructive) { shelf.remove(item) }
                            }
                        }
                    }
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: filterOpen)
        }
    }

    private var countLabel: String {
        let all = "\(shelf.items.count) file\(shelf.items.count == 1 ? "" : "s")"
        return (query.isEmpty && kinds.isEmpty) ? all : "\(visible.count) of \(all)"
    }

    @ViewBuilder private var detail: some View {
        if let item = shown {
            HubCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    KeepQuickLook(url: item.url, cornerRadius: 10)
                        .frame(height: 180)
                        .frame(maxWidth: .infinity)
                        .padding(12)
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.system(size: 14, weight: .semibold)).lineLimit(2).truncationMode(.middle)
                            Text(shelf.leaves(item)).font(.system(size: 11.5)).foregroundColor(HubTheme.muted)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            KeepFact(label: "Kind", value: kindLine(item))
                            KeepFact(label: "Size", value: sizeLine(item))
                            KeepFact(label: "Where", value: item.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            KeepFact(label: "Modified", value: modifiedLine(item))
                            KeepFact(label: "On the shelf", value: "\(KeepBucket.ago(item.addedAt)) ago")
                            KeepFact(label: "Opens in", value: ShelfSettings.shared.defaultApp(for: item.ext).map(appName) ?? "As macOS would")
                        }
                        HStack(spacing: 6) {
                            KeepActionButton(symbol: "arrow.up.forward.app", label: "Open", primary: true) { shelf.open(item) }
                            KeepActionButton(symbol: "square.grid.2x2", label: "Open with", menu: { openWithMenu(item) })
                            KeepActionButton(symbol: "folder", label: "Finder") { shelf.showInFinder([item]) }
                            KeepActionButton(symbol: "doc.on.doc", label: "Copy") { shelf.copy([item]); flash("Copied") }
                            KeepActionButton(symbol: "trash", label: "Remove", tint: HubTheme.red) { shelf.remove(item); selected = nil }
                        }
                        if !note.isEmpty { Text(note).font(.system(size: 11)).foregroundColor(HubTheme.green).transition(.opacity) }
                    }
                    .padding([.horizontal, .bottom], 16)
                }
            }
        } else {
            HubCard { Text("Click a file to see it here.").font(.system(size: 13)).foregroundColor(HubTheme.secondary) }
        }
    }

    // MARK: Settings

    private var settingsTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            HubLabel("In the notch")
            HubCard {
                HubKeepRow(title: "Layout", detail: "Grid shows two rows and grows the notch to 330 pt. Carousel keeps the notch at 240 pt and scrolls sideways, newest first.") {
                    Picker("", selection: $settings.layout) { ForEach(KeepLayout.allCases) { Text($0.label).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                HubDivider()
                HubKeepRow(title: "Previews", detail: "Quick Look thumbnails for images, PDFs and documents, made in the background and kept on disk. Off: file icons only.") {
                    Toggle("", isOn: $settings.previews).toggleStyle(.switch).labelsHidden()
                }
            }
            HubLabel("Keeping")
            HubCard {
                HubKeepRow(title: "Keep files for", detail: keepDetail) {
                    HStack(spacing: 8) {
                        Picker("", selection: $settings.retention) { ForEach(KeepRetention.allCases) { Text($0.label).tag($0) } }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                        if settings.retention == .custom { HubKeepDays(days: $settings.retentionDays) }
                    }
                }
                HubDivider()
                HubKeepRow(title: "Shelf size", detail: "How many files the shelf holds before the oldest goes.") {
                    Picker("", selection: $settings.maxItems) { Text("12").tag(12); Text("24").tag(24); Text("48").tag(48); Text("No limit").tag(0) }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                HubDivider()
                HubKeepRow(title: "Remember across restarts", detail: "The shelf list is saved on this Mac (paths only, never copies).") {
                    Toggle("", isOn: $settings.persist).toggleStyle(.switch).labelsHidden()
                }
            }
            HubLabel("Default apps")
            HubCard {
                let exts = Array(Set(shelf.items.map(\.ext).filter { !$0.isEmpty } + settings.defaultApps.keys)).sorted()
                if exts.isEmpty {
                    Text("Once files are on the shelf, each extension gets a row here. Open with ▸ in the notch sets them too.")
                        .font(.system(size: 12)).foregroundColor(HubTheme.secondary)
                }
                ForEach(Array(exts.enumerated()), id: \.element) { i, ext in
                    if i > 0 { HubDivider() }
                    let sample = shelf.items.first { $0.ext == ext } ?? ShelfItem(id: UUID(), path: "/tmp/x." + ext, addedAt: .now)
                    HubKeepRow(title: "." + ext, detail: "What Open uses for these files.") {
                        Menu {
                            ForEach(shelf.apps(for: sample), id: \.path) { app in Button(appName(app)) { settings.setDefaultApp(app, for: ext) } }
                            Divider()
                            Button("As macOS would") { settings.setDefaultApp(nil, for: ext) }
                        } label: {
                            Text(settings.defaultApp(for: ext).map(appName) ?? "As macOS would")
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                }
            }
        }
    }

    /// The apps that open the file, then "Set the default for .ext" with the same apps.
    private func openWithMenu(_ item: ShelfItem) -> NSMenu {
        let menu = NSMenu()
        let apps = shelf.apps(for: item)
        for app in apps {
            let it = NSMenuItem(title: appName(app), action: #selector(KeepMenuTarget.run(_:)), keyEquivalent: "")
            it.image = NSWorkspace.shared.icon(forFile: app.path).resized(to: 16)
            it.target = KeepMenuTarget.shared
            it.representedObject = KeepMenuTarget.Action { shelf.open(item, with: app) }
            menu.addItem(it)
        }
        menu.addItem(.separator())
        let sub = NSMenu()
        for app in apps {
            let it = NSMenuItem(title: appName(app), action: #selector(KeepMenuTarget.run(_:)), keyEquivalent: "")
            it.target = KeepMenuTarget.shared
            it.representedObject = KeepMenuTarget.Action { settings.setDefaultApp(app, for: item.ext) }
            sub.addItem(it)
        }
        sub.addItem(.separator())
        let none = NSMenuItem(title: "As macOS would", action: #selector(KeepMenuTarget.run(_:)), keyEquivalent: "")
        none.target = KeepMenuTarget.shared
        none.representedObject = KeepMenuTarget.Action { settings.setDefaultApp(nil, for: item.ext) }
        sub.addItem(none)
        let parent = NSMenuItem(title: "Set the default for .\(item.ext.isEmpty ? "file" : item.ext)", action: nil, keyEquivalent: "")
        parent.submenu = sub
        menu.addItem(parent)
        return menu
    }

    private var keepDetail: String {
        guard let days = settings.keepDays else { return "Files stay on the shelf until you remove them." }
        return "Files leave the shelf by themselves \(days) days after they arrived; the files themselves stay where they are."
    }

    // MARK: Text

    private func flash(_ t: String) {
        withAnimation { note = t }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { note = "" } }
    }

    private func badge(_ item: ShelfItem) -> String { item.ext.isEmpty ? (item.kind == .folder ? "FOLDER" : "FILE") : item.ext.uppercased() }

    private func detail(_ item: ShelfItem) -> String {
        let values = try? item.url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true {
            let n = (try? FileManager.default.contentsOfDirectory(atPath: item.path).count) ?? 0
            return "Folder · \(n) item\(n == 1 ? "" : "s")"
        }
        if let bytes = values?.fileSize { return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
        return item.url.deletingLastPathComponent().lastPathComponent
    }

    private func kindLine(_ item: ShelfItem) -> String {
        (try? item.url.resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription) ?? item.kind.label
    }

    private func sizeLine(_ item: ShelfItem) -> String {
        let values = try? item.url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true { return detail(item) }
        return values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—"
    }

    private func modifiedLine(_ item: ShelfItem) -> String {
        guard let date = (try? item.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func appName(_ app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }
}

// MARK: - Clipboard

struct HubClipboardPage: View {
    static let tint = Color(hex: "#A78BFA")

    @ObservedObject private var store = ClipboardStore.shared
    @ObservedObject private var settings = ClipboardSettings.shared
    @AppStorage("clipboardSettingsTab") private var tabRaw = HubKeepTab.items.rawValue
    @State private var query = ""
    @State private var kinds: Set<KeepKind> = []
    @State private var filterOpen = false
    @State private var selected: UUID?
    @State private var note = ""

    private var tab: HubKeepTab { HubKeepTab(rawValue: tabRaw) ?? .items }
    private var visible: [ClipItem] {
        let q = query.lowercased()
        return store.items
            .filter { (kinds.isEmpty || kinds.contains($0.kind)) && (q.isEmpty || $0.text.lowercased().contains(q) || $0.appName.lowercased().contains(q)) }
            .sorted { ($0.pinned ? 1 : 0, $0.at) > ($1.pinned ? 1 : 0, $1.at) }
    }
    private var counts: [KeepKind: Int] { store.items.reduce(into: [:]) { $0[$1.kind, default: 0] += 1 } }
    private var shown: ClipItem? { store.items.first { $0.id == selected } ?? visible.first }

    var body: some View {
        HubPageScaffold(title: "Clipboard",
                        subtitle: "What you copied, kept on this Mac: text, links, colours, code, images and files. Nothing leaves it.",
                        trailing: { HubBannerSwitch(title: settings.isPaused ? "Paused" : "Recording", tint: Self.tint, isOn: $settings.enabled) },
                        pinned: {
            BriefSegmented(options: [BriefSegmentedOption(value: HubKeepTab.items, title: "History", symbol: "list.clipboard"),
                                     BriefSegmentedOption(value: HubKeepTab.settings, title: "Settings", symbol: "slider.horizontal.3")],
                           selection: Binding(get: { tab }, set: { tabRaw = $0.rawValue }),
                           tint: Self.tint, height: 38)
        }, aside: {
            HubLabel("Selected")
            detail
        }, showsAside: tab == .items) {
            if tab == .items { history } else { settingsTab }
        }
    }

    // MARK: History

    private var history: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    HubKeepSearch(placeholder: "Search what you copied", text: $query)
                    KeepFilterButton(kinds: $kinds, open: $filterOpen, compact: false)
                }
                if filterOpen {
                    KeepFilterPanel(kinds: $kinds, available: KeepKind.clipboardKinds, counts: counts, compact: false)
                }
                HStack {
                    HubLabel(countLabel)
                    Spacer()
                    if store.items.contains(where: { !$0.pinned }) {
                        Button("Clear the history") { store.clear(); selected = nil }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundColor(HubTheme.red)
                    }
                }
                .padding(.top, 4)
                if visible.isEmpty {
                    HubEmptyState(text: store.items.isEmpty ? "Nothing kept yet. Copy something: it shows up here."
                                                            : "Nothing matches. Try another word, or clear the filter.", state: .idle)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                        ForEach(visible) { item in
                            KeepCard(name: title(item), detail: "\(item.appName) · \(KeepBucket.ago(item.at)) ago", badge: item.kind.rawValue.uppercased(),
                                     pinned: item.pinned, selected: shown?.id == item.id, height: 150,
                                     onTap: { selected = item.id }, onDoubleTap: { store.copy(item); flash("Copied") }) {
                                ClipPreview(item: item, height: 72)
                            }
                            .contextMenu {
                                Button("Copy") { store.copy(item) }
                                Button("Put on the shelf") { store.putOnShelf(item) }
                                Button(item.pinned ? "Unpin" : "Pin") { store.togglePin(item.id) }
                                Divider()
                                Button("Delete", role: .destructive) { store.delete(item.id) }
                            }
                        }
                    }
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: filterOpen)
        }
    }

    private var countLabel: String {
        let all = "\(store.items.count) item\(store.items.count == 1 ? "" : "s")"
        return (query.isEmpty && kinds.isEmpty) ? all : "\(visible.count) of \(all)"
    }

    @ViewBuilder private var detail: some View {
        if let item = shown {
            HubCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Group {
                        if item.kind == .image, let url = item.imageURL {
                            KeepQuickLook(url: url, cornerRadius: 10)
                        } else if item.kind == .file, let first = item.paths.first {
                            KeepQuickLook(url: URL(fileURLWithPath: first), cornerRadius: 10)
                        } else {
                            ClipPreview(item: item, height: 180, large: true)
                                .background(Color.black.opacity(0.3))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                    .frame(height: 180)
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title(item)).font(.system(size: 14, weight: .semibold)).lineLimit(2).truncationMode(.middle)
                            Text(store.leaves(item)).font(.system(size: 11.5)).foregroundColor(HubTheme.muted)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            KeepFact(label: "Kind", value: item.kind.label)
                            KeepFact(label: "From", value: item.appName)
                            KeepFact(label: "Copied", value: item.at.formatted(date: .abbreviated, time: .shortened))
                            if item.kind == .text || item.kind == .code {
                                KeepFact(label: "Length", value: "\(item.text.count) characters · \(item.text.split(whereSeparator: \.isNewline).count) lines")
                            }
                            if item.kind == .file { KeepFact(label: "Files", value: item.text) }
                        }
                        HStack(spacing: 6) {
                            KeepActionButton(symbol: "doc.on.doc", label: "Copy", primary: true) { store.copy(item); flash("Copied") }
                            KeepActionButton(symbol: "tray.and.arrow.down", label: "To shelf") { store.putOnShelf(item); flash("On the shelf") }
                            KeepActionButton(symbol: item.pinned ? "pin.slash" : "pin", label: item.pinned ? "Unpin" : "Pin") { store.togglePin(item.id) }
                            KeepActionButton(symbol: "trash", label: "Delete", tint: HubTheme.red) { store.delete(item.id); selected = nil }
                        }
                        if !note.isEmpty { Text(note).font(.system(size: 11)).foregroundColor(HubTheme.green).transition(.opacity) }
                    }
                    .padding([.horizontal, .bottom], 16)
                }
            }
        } else {
            HubCard { Text("Click an item to see it here.").font(.system(size: 13)).foregroundColor(HubTheme.secondary) }
        }
    }

    // MARK: Settings

    private var settingsTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            HubLabel("Recording")
            HubCard {
                HubKeepRow(title: "Skip these apps", detail: "Nothing copied in them is kept. Passwords and Keychain Access are always skipped; so is anything an app marks as a secret or passing through.") {
                    VStack(alignment: .trailing, spacing: 6) {
                        ForEach(settings.skippedApps, id: \.self) { bundle in
                            HStack(spacing: 6) {
                                Text(appName(bundle)).font(.system(size: 12.5))
                                Button { settings.skippedApps.removeAll { $0 == bundle } } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundColor(HubTheme.secondary)
                                }.buttonStyle(.plain)
                            }
                        }
                        Button("Add an app…") { addSkippedApp() }.buttonStyle(HubButtonStyle())
                    }
                }
                HubDivider()
                HubKeepRow(title: "Pause", detail: settings.isPaused ? "Paused: nothing new is kept until you resume." : "Stop keeping copies for a while; the notch shows Paused.") {
                    Menu {
                        Button("Pause for 1 hour") { settings.pausedUntil = Date().addingTimeInterval(3600) }
                        Button("Pause until tomorrow") { settings.pausedUntil = Calendar.current.startOfDay(for: Date().addingTimeInterval(86400)) }
                        Button("Pause until I resume") { settings.pausedUntil = .distantFuture }
                        if settings.isPaused { Divider(); Button("Resume now") { settings.pausedUntil = nil } }
                    } label: { Text(settings.isPaused ? "Paused" : "Not paused") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
            HubLabel("In the notch")
            HubCard {
                HubKeepRow(title: "Layout", detail: "Carousel keeps the notch at 240 pt, newest first, grouped by time. Grid shows two rows and grows the notch to 330 pt.") {
                    Picker("", selection: $settings.layout) { ForEach(KeepLayout.allCases) { Text($0.label).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                HubDivider()
                HubKeepRow(title: "Shortcut", detail: "Opens the notch on the Clipboard page: Settings → Shortcuts → Open the clipboard (⌘⇧V by default).") { EmptyView() }
                HubDivider()
                HubKeepRow(title: "↩ pastes", detail: "Return and a double-click paste into the app in front (this needs the Accessibility permission); off, they only copy.") {
                    Toggle("", isOn: $settings.enterPastes).toggleStyle(.switch).labelsHidden()
                }
            }
            HubLabel("Keeping")
            HubCard {
                HubKeepRow(title: "Keep items for", detail: keepDetail) {
                    HStack(spacing: 8) {
                        Picker("", selection: $settings.retention) { ForEach(KeepRetention.allCases) { Text($0.label).tag($0) } }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                        if settings.retention == .custom { HubKeepDays(days: $settings.retentionDays) }
                    }
                }
                HubDivider()
                HubKeepRow(title: "History size", detail: "How many items are kept before the oldest unpinned one goes.") {
                    Picker("", selection: $settings.maxItems) { Text("50").tag(50); Text("100").tag(100); Text("500").tag(500); Text("No limit").tag(0) }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                HubDivider()
                HubKeepRow(title: "Keep on disk", detail: "Off, the history lives in memory and is gone when Coucou quits. Images are kept as PNG files beside it.") {
                    Toggle("", isOn: $settings.keepOnDisk).toggleStyle(.switch).labelsHidden()
                }
            }
        }
    }

    private var keepDetail: String {
        guard let days = settings.keepDays else { return "Items stay until you delete them." }
        return "Items leave by themselves \(days) days after they were copied; pinned items stay."
    }

    private func flash(_ t: String) {
        withAnimation { note = t }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { note = "" } }
    }

    private func title(_ item: ClipItem) -> String {
        switch item.kind {
        case .image: return "Image · \(item.text)"
        case .color: return item.hex ?? item.text
        case .link: return item.domain ?? item.firstLine
        default: return item.firstLine
        }
    }

    private func appName(_ bundle: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundle
    }

    private func addSkippedApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url)?.bundleIdentifier else { return }
        if !settings.skippedApps.contains(bundle) { settings.skippedApps.append(bundle) }
    }
}
#endif
