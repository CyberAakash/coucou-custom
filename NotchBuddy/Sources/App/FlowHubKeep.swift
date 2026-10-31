#if !APPSTORE
import AppKit
import SwiftUI

// MARK: - Coucou window → Shelf (coucou-custom fork)
//
// Two tabs: Manage (search, kinds, the files as cards, the chosen one's detail and actions)
// and Settings (what the shelf does in the notch, how long files stay, the apps that open them).

enum HubKeepTab: String, CaseIterable, Identifiable {
    case manage, settings
    var id: String { rawValue }
    var label: String { self == .manage ? "Manage" : "Settings" }
}

struct HubKeepTabs: View {
    @Binding var tab: HubKeepTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(HubKeepTab.allCases) { t in
                Button { withAnimation(.easeOut(duration: 0.15)) { tab = t } } label: {
                    Text(t.label)
                        .font(.system(size: 13, weight: tab == t ? .semibold : .medium))
                        .foregroundColor(tab == t ? HubTheme.text : HubTheme.secondary)
                        .padding(.horizontal, 16)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(tab == t ? 0.08 : 0)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(HubTheme.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(HubTheme.line))
    }
}

/// The window's search field, as the Buddy page draws it.
struct HubKeepSearch: View {
    let placeholder: String
    @Binding var text: String
    var count: String = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundColor(HubTheme.secondary)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 13))
            if !count.isEmpty { Text(count).font(.system(size: 11)).foregroundColor(HubTheme.muted).monospacedDigit() }
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

struct HubShelfPage: View {
    @ObservedObject private var shelf = FileShelf.shared
    @ObservedObject private var settings = ShelfSettings.shared
    @State private var tab: HubKeepTab = .manage
    @State private var query = ""
    @State private var kind: KeepKind?
    @State private var selected: UUID?
    @State private var note = ""

    private var visible: [ShelfItem] {
        let q = query.lowercased()
        return shelf.items.filter { (kind == nil || $0.kind == kind) && (q.isEmpty || $0.name.lowercased().contains(q)) }
    }
    private var shown: ShelfItem? { shelf.items.first { $0.id == selected } ?? visible.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HubHero(page: .shelf, title: "Shelf",
                        subtitle: shelf.items.isEmpty ? "Files dropped on the notch wait here until you drag them out."
                                                      : "Files dropped on the notch wait here until you drag them out. \(shelf.items.count) on the shelf.",
                        compact: true)
                HubKeepTabs(tab: $tab)
                if tab == .manage { manage } else { settingsTab }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 28)
            .frame(maxWidth: 1100, alignment: .leading)
        }
    }

    // MARK: Manage

    private var manage: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    HubKeepSearch(placeholder: "Search the shelf", text: $query,
                                  count: query.isEmpty ? "\(shelf.items.count) files" : "\(visible.count) of \(shelf.items.count)")
                    Picker("", selection: $kind) {
                        Text("All").tag(KeepKind?.none)
                        ForEach(KeepKind.shelfChips) { Text($0.label).tag(KeepKind?.some($0)) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if visible.isEmpty {
                    Text(shelf.items.isEmpty ? "Nothing here. Drop files on the notch and they wait on the shelf." : "Nothing matches “\(query)”.")
                        .font(.system(size: 13.5)).foregroundColor(HubTheme.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 30)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                        ForEach(visible) { item in
                            KeepCard(name: item.name, detail: detail(item), badge: item.ext.isEmpty ? (item.kind == .folder ? "FOLDER" : "FILE") : item.ext.uppercased(),
                                     selected: shown?.id == item.id, height: 150) {
                                KeepFilePreview(url: item.url, size: CGSize(width: 180, height: 72), showsThumbnail: settings.previews)
                                    .frame(height: 72).frame(maxWidth: .infinity)
                                    .background(Color.white.opacity(0.04))
                            }
                            .highPriorityGesture(TapGesture(count: 2).onEnded { shelf.open(item) })
                            .onTapGesture { selected = item.id }
                            .onDrag { shelf.beginDrag(item); return NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                HubLabel("Selected")
                HubCard(padding: 16) {
                    if let item = shown {
                        KeepFilePreview(url: item.url, size: CGSize(width: 268, height: 110), showsThumbnail: settings.previews)
                            .frame(maxWidth: .infinity).frame(height: 110)
                            .background(Color.white.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Text(item.name).font(.system(size: 14, weight: .semibold))
                        Text(detail(item) + " · " + KeepBucket.ago(item.addedAt) + " ago").font(.system(size: 12)).foregroundColor(HubTheme.secondary)
                        Text(item.path).font(.system(size: 11)).foregroundColor(HubTheme.muted).lineLimit(2).truncationMode(.middle)
                        Text(shelf.leaves(item)).font(.system(size: 11)).foregroundColor(HubTheme.muted)
                        HStack(spacing: 8) {
                            Button("Open") { shelf.open(item) }.buttonStyle(HubButtonStyle(primary: true))
                            Menu {
                                ForEach(shelf.apps(for: item), id: \.path) { app in
                                    Button(appName(app)) { shelf.open(item, with: app) }
                                }
                            } label: {
                                Text("Open with · \(ShelfSettings.shared.defaultApp(for: item.ext).map(appName) ?? "macOS")")
                            }
                            .menuStyle(.borderlessButton).fixedSize()
                        }
                        HStack(spacing: 8) {
                            Button("Show in Finder") { shelf.showInFinder([item]) }.buttonStyle(HubButtonStyle())
                            Button("Copy") { shelf.copy([item]); note = "Copied" }.buttonStyle(HubButtonStyle())
                            Button("Remove") { shelf.remove(item); selected = nil }.buttonStyle(HubButtonStyle()).foregroundColor(HubTheme.red)
                        }
                        if !note.isEmpty { Text(note).font(.system(size: 11)).foregroundColor(HubTheme.green) }
                    } else {
                        Text("Click a file to see it here.").font(.system(size: 13)).foregroundColor(HubTheme.secondary)
                    }
                }
                if !shelf.items.isEmpty {
                    Button("Clear the shelf") { shelf.clear(); selected = nil }.buttonStyle(HubButtonStyle()).foregroundColor(HubTheme.red)
                }
            }
            .frame(width: 300)
        }
    }

    // MARK: Settings

    private var settingsTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            HubLabel("In the notch")
            HubCard(padding: 4) {
                VStack(spacing: 0) {
                    row("File shelf", "Files dropped on the notch land on the shelf. Off, a drop asks what to do with the file right away, as upstream does.") {
                        Toggle("", isOn: $settings.enabled).toggleStyle(.switch).labelsHidden()
                    }
                    HubDivider()
                    row("Layout", "Grid shows two rows and grows the notch to 330 pt. Carousel keeps the notch at 240 pt and scrolls sideways, newest first.") {
                        Picker("", selection: $settings.layout) { ForEach(KeepLayout.allCases) { Text($0.label).tag($0) } }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    HubDivider()
                    row("Previews", "Quick Look thumbnails for images, PDFs and documents, made in the background and kept on disk. Off: file icons only.") {
                        Toggle("", isOn: $settings.previews).toggleStyle(.switch).labelsHidden()
                    }
                }
                .padding(.horizontal, 14)
            }
            HubLabel("Keeping")
            HubCard(padding: 4) {
                VStack(spacing: 0) {
                    row("Keep files for", keepDetail) {
                        HStack(spacing: 8) {
                            Picker("", selection: $settings.retention) { ForEach(KeepRetention.allCases) { Text($0.label).tag($0) } }
                                .pickerStyle(.segmented).labelsHidden().fixedSize()
                            if settings.retention == .custom {
                                TextField("", value: $settings.retentionDays, format: .number)
                                    .textFieldStyle(.plain).font(.system(size: 13, weight: .semibold)).multilineTextAlignment(.center)
                                    .frame(width: 52, height: 28)
                                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(HubTheme.field))
                                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
                                Text("days").font(.system(size: 12)).foregroundColor(HubTheme.secondary)
                            }
                        }
                    }
                    HubDivider()
                    row("Shelf size", "How many files the shelf holds before the oldest goes.") {
                        Picker("", selection: $settings.maxItems) {
                            Text("12").tag(12); Text("24").tag(24); Text("48").tag(48); Text("No limit").tag(0)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    HubDivider()
                    row("Remember across restarts", "The shelf list is saved on this Mac (paths only, never copies).") {
                        Toggle("", isOn: $settings.persist).toggleStyle(.switch).labelsHidden()
                    }
                }
                .padding(.horizontal, 14)
            }
            HubLabel("Default apps")
            HubCard(padding: 4) {
                VStack(spacing: 0) {
                    let exts = Array(Set(shelf.items.map(\.ext).filter { !$0.isEmpty } + settings.defaultApps.keys)).sorted()
                    if exts.isEmpty {
                        row("No files yet", "Once files are on the shelf, each extension gets a row here.") { EmptyView() }
                    }
                    ForEach(exts, id: \.self) { ext in
                        let sample = shelf.items.first { $0.ext == ext } ?? ShelfItem(id: UUID(), path: "/tmp/x." + ext, addedAt: .now)
                        row("." + ext, "Open uses this; Open with ▸ in the notch lists every app and can set it too.") {
                            Menu {
                                ForEach(shelf.apps(for: sample), id: \.path) { app in
                                    Button(appName(app)) { settings.setDefaultApp(app, for: ext) }
                                }
                                Divider()
                                Button("As macOS would") { settings.setDefaultApp(nil, for: ext) }
                            } label: {
                                Text(settings.defaultApp(for: ext).map(appName) ?? "As macOS would")
                            }
                            .menuStyle(.borderlessButton).fixedSize()
                        }
                        if ext != exts.last { HubDivider() }
                    }
                }
                .padding(.horizontal, 14)
            }
        }
    }

    private var keepDetail: String {
        guard let days = settings.keepDays else { return "Files stay on the shelf until you remove them." }
        return "Files leave the shelf by themselves \(days) days after they arrived; the files themselves stay where they are."
    }

    private func row<C: View>(_ title: String, _ detail: String, @ViewBuilder control: () -> C) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundColor(HubTheme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.vertical, 12)
    }

    private func detail(_ item: ShelfItem) -> String {
        let values = try? item.url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true {
            let n = (try? FileManager.default.contentsOfDirectory(atPath: item.path).count) ?? 0
            return "Folder · \(n) item\(n == 1 ? "" : "s")"
        }
        if let bytes = values?.fileSize { return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
        return item.url.deletingLastPathComponent().lastPathComponent
    }

    private func appName(_ app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }
}
#endif
