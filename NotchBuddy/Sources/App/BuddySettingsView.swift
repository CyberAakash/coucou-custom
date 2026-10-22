#if !APPSTORE
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

// coucou-custom fork: Settings → Buddy. The desktop pet: Mochi (the default) or an OpenPets /
// Codex pet, its size, side, animations and where it stands.

struct BuddySettingsView: View {
    @ObservedObject private var settings = BuddySettings.shared
    @ObservedObject private var store = BuddyPetStore.shared
    @ObservedObject private var state = AppState.shared
    /// Mirrors the stored "on the desktop" flag (DesktopMochiController keeps it).
    @AppStorage(DesktopMochiController.enabledKey) private var onDesktop = false

    @State private var thumbnails: [String: CGImage] = [:]
    @State private var importMessage: String = ""
    @State private var pendingReplace: URL?
    @State private var previewAnimation: BuddyAnimation = .idle

    private var selectedPet: BuddyPetEntry? { settings.isMochi ? nil : store.pet(id: settings.petId) }

    var body: some View {
        desktopBox
        petBox
        if let pet = selectedPet { petDetailBox(pet) }
        if !settings.isMochi { animationsBox }
    }

    // MARK: - On the desktop

    private var desktopBox: some View {
        GroupBox("On the desktop") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Show the buddy on the desktop", isOn: Binding(
                    get: { onDesktop },
                    set: { DesktopMochiController.shared.setOnDesktop($0) }))
                Text("It floats above your windows on every Space. Drag it anywhere, click it to play, double-click it (or drag it onto the notch) to send it home. It steps aside to the notch while a permission or a question waits.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Size", selection: $settings.size) {
                    ForEach(BuddySize.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                HStack {
                    Button("Reset position") { DesktopMochiController.shared.resetPosition() }
                    Text("Back to the bottom-right corner.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(6)
        }
    }

    // MARK: - Which pet

    private var petBox: some View {
        GroupBox("Pet") {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92, maximum: 120), spacing: 10)], spacing: 10) {
                    petTile(id: BuddySettings.mochiId, name: "Mochi", subtitle: "Default") {
                        MochiStill(showBadge: false).padding(8)
                    }
                    ForEach(store.pets) { pet in
                        petTile(id: pet.id, name: pet.manifest.displayName, subtitle: pet.sourceLabel) {
                            if let img = thumbnails[pet.id] {
                                Image(decorative: img, scale: 1).resizable().scaledToFit()
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                }

                if store.pets.isEmpty {
                    Text("No other pets yet. Import an OpenPets or Codex pet (a folder or .zip with pet.json and spritesheet.webp), or put one in ~/.codex/pets.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button("Import pet…") { chooseImport() }
                    Button("Show imported pets") { revealInstallFolder() }
                    Button("Refresh") { store.refresh(); loadThumbnails() }
                }
                if !importMessage.isEmpty {
                    Text(importMessage)
                        .font(.system(size: 11))
                        .foregroundColor(importMessage.hasPrefix("❌") ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !store.skipped.isEmpty {
                    DisclosureGroup("\(store.skipped.count) folder(s) not loaded") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(store.skipped, id: \.name) { s in
                                Text("\(s.name): \(s.reason)")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 11))
                }
                if settings.isMochi {
                    Divider()
                    Picker("Mochi's outfit", selection: $state.mochiOutfitSelection) {
                        ForEach(Outfit.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Text("The same wardrobe as in the notch. Right-click Mochi on the desktop to open it.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                if !settings.isMochi && selectedPet == nil {
                    Text("❌ The selected pet (\(settings.petId)) is not on this Mac any more; Mochi is shown.")
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
            }
            .padding(6)
        }
        .onAppear { loadThumbnails() }
        .onChange(of: store.pets) { _, _ in loadThumbnails() }
        .alert("Replace the imported pet?", isPresented: Binding(
            get: { pendingReplace != nil }, set: { if !$0 { pendingReplace = nil } })) {
            Button("Replace", role: .destructive) {
                if let url = pendingReplace { runImport(url, replace: true) }
                pendingReplace = nil
            }
            Button("Cancel", role: .cancel) { pendingReplace = nil }
        } message: {
            Text("A pet with the same id is already imported. Its files will be replaced.")
        }
    }

    private func petTile<Art: View>(id: String, name: String, subtitle: String,
                                    @ViewBuilder art: () -> Art) -> some View {
        let selected = settings.petId == id || (id == BuddySettings.mochiId && settings.isMochi)
        return Button {
            settings.petId = id
        } label: {
            VStack(spacing: 4) {
                art()
                    .frame(width: 64, height: 64)
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(6)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(selected ? 0.10 : 0.03)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - The selected pet

    private func petDetailBox(_ pet: BuddyPetEntry) -> some View {
        GroupBox(pet.manifest.displayName) {
            HStack(alignment: .top, spacing: 14) {
                BuddyPreview(entry: pet, animation: previewAnimation,
                             flipped: settings.isFlipped(pet.id), relaxedWaiting: settings.relaxedWaiting)
                    .frame(width: 110, height: 120)
                VStack(alignment: .leading, spacing: 8) {
                    Text(pet.manifest.description)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(pet.sourceLabel) · \(pet.manifest.layout.hasGaze ? "V2 (looks at the cursor)" : "V1")")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Picker("Preview", selection: $previewAnimation) {
                        ForEach(BuddyAnimation.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(maxWidth: 260)
                    Toggle("Face the other way", isOn: Binding(
                        get: { settings.isFlipped(pet.id) }, set: { settings.setFlipped(pet.id, $0) }))
                    HStack(spacing: 8) {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([pet.folder]) }
                        if pet.removable {
                            Button("Remove", role: .destructive) { remove(pet) }
                        }
                    }
                }
            }
            .padding(6)
        }
    }

    // MARK: - Animations

    private var animationsBox: some View {
        GroupBox("Animations") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Look at the cursor while idle (V2 pets)", isOn: $settings.cursorGaze)
                Toggle("Relaxed waiting animation", isOn: $settings.relaxedWaiting)
                Text("Waiting plays in 2.2 s instead of 1 s.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Divider()
                Text("What the pet plays for each state of your agents")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                ForEach(BuddyReaction.allCases) { r in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.label).font(.system(size: 12))
                            Text(r.detail).font(.system(size: 10)).foregroundColor(.secondary)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { settings.animation(for: r) },
                            set: { settings.setAnimation($0, for: r); previewAnimation = $0 })) {
                            ForEach(BuddyAnimation.selectable) { a in
                                Text(a == r.defaultAnimation ? "\(a.label) (default)" : a.label).tag(a)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                    }
                }
                Button("Reset to defaults") { settings.resetReactions() }
                    .disabled(settings.reactionOverrides.isEmpty)
            }
            .padding(6)
        }
    }

    // MARK: - Actions

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .folder]
        panel.message = "Choose a pet folder or .zip (pet.json + spritesheet.webp)"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runImport(url, replace: false)
    }

    private func runImport(_ url: URL, replace: Bool) {
        do {
            let pet = try store.importPackage(at: url, replace: replace)
            settings.petId = pet.id
            importMessage = "Imported \(pet.manifest.displayName)."
        } catch BuddyPetStore.ImportError.alreadyInstalled {
            pendingReplace = url
        } catch {
            importMessage = "❌ \(error)"
        }
    }

    private func remove(_ pet: BuddyPetEntry) {
        if settings.petId == pet.id { settings.petId = BuddySettings.mochiId }
        do {
            try store.remove(id: pet.id)
            importMessage = "Removed \(pet.manifest.displayName)."
        } catch {
            importMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func revealInstallFolder() {
        try? FileManager.default.createDirectory(at: store.installDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.installDir)
    }

    /// The first idle frame of each pet, decoded off the main thread.
    private func loadThumbnails() {
        let missing = store.pets.filter { thumbnails[$0.id] == nil }.map { ($0.id, $0.spritesheetURL) }
        guard !missing.isEmpty else { return }
        Task.detached(priority: .utility) {
            var out: [String: CGImage] = [:]
            for (id, url) in missing {
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
                      let cell = img.cropping(to: BuddyAtlasLayout.cellRect(row: 0, column: 0)) else { continue }
                out[id] = cell
            }
            let result = out
            await MainActor.run { thumbnails.merge(result) { $1 } }
        }
    }
}

/// The selected pet playing one animation on a loop, in Settings.
private struct BuddyPreview: View {
    let entry: BuddyPetEntry
    let animation: BuddyAnimation
    let flipped: Bool
    let relaxedWaiting: Bool

    @State private var atlas: BuddyAtlas?
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15)) { tl in
            Canvas { ctx, size in
                guard let atlas else { return }
                // Loop one-shots too, so they can be seen.
                let d = animation.duration(relaxedWaiting: relaxedWaiting) * Double(animation.iterations ?? 1)
                let t = tl.date.timeIntervalSince(start).truncatingRemainder(dividingBy: d)
                let f = animation.frame(at: t, relaxedWaiting: relaxedWaiting) ?? 0
                guard let img = atlas.cell(row: animation.row, column: f) else { return }
                var g = ctx
                if flipped { g.translateBy(x: size.width, y: 0); g.scaleBy(x: -1, y: 1) }
                let fw = CGFloat(BuddyAtlasLayout.frameWidth), fh = CGFloat(BuddyAtlasLayout.frameHeight)
                let k = min(size.width / fw, size.height / fh)
                let w = fw * k, h = fh * k
                g.draw(Image(decorative: img, scale: 1),
                       in: CGRect(x: (size.width - w) / 2, y: size.height - h, width: w, height: h))
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .task(id: entry.id) {
            atlas = try? BuddyAtlas.load(url: entry.spritesheetURL, layout: entry.manifest.layout)
        }
        .onChange(of: animation) { _, _ in start = Date() }
    }
}
#endif
