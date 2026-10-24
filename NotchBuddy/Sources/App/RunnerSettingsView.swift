#if !APPSTORE
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// coucou-custom fork: the Coucou window's Menu bar page — Coucou's one menu-bar item: its icon (Coucou's
// own, Mochi, RunCat's runners, yours, the Runner Gallery's), its speed, the numbers beside it, the
// panel a click opens, and the Custom Metrics files.

struct HubRunnerPage: View {
    @ObservedObject private var settings = RunnerSettings.shared
    @ObservedObject private var library = RunnerLibrary.shared
    @ObservedObject private var sampler = RunnerSampler.shared
    @State private var toast = ""

    var body: some View {
        ZStack(alignment: .bottom) {
            // The page's one banner: its title and its switches.
            HubPageScaffold(title: String(localized: "Menu bar"), subtitle: String(localized: "hub.notch.menubar"),
                            trailing: { RunnerBanner(settings: settings) }) {
                HubLabel("Preview")
                RunnerHeroCard(settings: settings, sampler: sampler)

                HubLabel("Icon")
                RunnerPickerCard(settings: settings, library: library)

                HubLabel("Runner Gallery")
                RunnerGalleryCard(library: library, toast: $toast)

                HubLabel("Animated emoji")
                NotoEmojiCard(library: library, toast: $toast)

                HubLabel("Speed")
                RunnerSpeedCard(settings: settings)

                HubLabel("Beside the icon")
                RunnerMenuBarCard(settings: settings, sampler: sampler)

                HubLabel("Panel")
                MenuBarPanelSettingsCard(settings: settings)

                HubLabel("Custom Metrics")
                RunnerMetricsSourcesCard(settings: settings, toast: $toast)
            }
            HubToast(message: $toast)
        }
        .onAppear { RunnerMetricsCenter.shared.hold() }
        .onDisappear { RunnerMetricsCenter.shared.release() }
    }
}

// MARK: - Shared pieces

/// A row of choices, one on (the window's chips).
struct RunnerChips<Value: Hashable>: View {
    let values: [Value]
    let label: (Value) -> String
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 4) {
            ForEach(values, id: \.self) { v in
                let on = selection == v
                Button { selection = v } label: {
                    Text(label(v))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(on ? HubTheme.onAccent : HubTheme.body)
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(on ? HubTheme.accent : Color.white.opacity(0.05)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A runner playing in SwiftUI, for previews. Only animates while the window is on screen.
struct RunnerPreview: View {
    let frames: [CGImage]
    let isTemplate: Bool
    var speed: Double = 1
    var flipped = false
    var scale: CGFloat = 1
    var animate = true
    @Environment(\.hubVisible) private var visible

    var body: some View {
        let step = RunnerSpeed.frameSeconds / max(0.25, speed)
        TimelineView(.animation(minimumInterval: step, paused: !animate || !visible || frames.count < 2)) { context in
            let index = frames.isEmpty ? 0 : Int(context.date.timeIntervalSinceReferenceDate / step) % frames.count
            frame(at: index)
        }
    }

    @ViewBuilder private func frame(at index: Int) -> some View {
        if frames.indices.contains(index) {
            let img = frames[index]
            let image = Image(decorative: img, scale: 2 / scale)
            Group {
                if isTemplate {
                    image.renderingMode(.template).foregroundColor(HubTheme.text)
                } else {
                    image
                }
            }
            .scaleEffect(x: flipped ? -1 : 1, y: 1)
            .frame(width: CGFloat(img.width) / 2 * scale, height: CGFloat(img.height) / 2 * scale)
        } else {
            Color.clear.frame(width: 22 * scale, height: 18 * scale)
        }
    }
}

/// A strip drawn like the menu bar, the runner on it.
struct RunnerMenuBarStrip<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 10) {
            content()
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
    }
}

// MARK: - The banner's switches, and the preview

private struct RunnerBanner: View {
    @ObservedObject var settings: RunnerSettings

    var body: some View {
        HStack(spacing: 8) {
            HubBannerSwitch(title: "One menu-bar item", tint: HubTheme.accent, isOn: $settings.unified)
            if !settings.unified {
                HubBannerSwitch(title: "Runner as a second item", tint: HubTheme.accent, isOn: $settings.enabled)
                    .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
            }
        }
        .animation(BriefLayout.spring, value: settings.unified)
    }
}

private struct RunnerHeroCard: View {
    @ObservedObject var settings: RunnerSettings
    @ObservedObject var sampler: RunnerSampler
    @ObservedObject private var library = RunnerLibrary.shared

    private var load: Double {
        switch settings.speedSource {
        case .cpu: sampler.sample.cpu ?? 0
        case .memory: sampler.sample.memoryFraction ?? 0
        case .agents: RunnerSpeed.agentLoad(working: RunnerStatusItem.workingAgents(AppState.shared.tasks))
        }
    }

    var body: some View {
        let frames = RunnerStatusItem.frames(for: settings.runnerID)
        let speed = RunnerSpeed.speed(load: load, slowerUnderLoad: settings.slowerUnderLoad)
        let shows = settings.unified || settings.enabled
        HubCard(padding: 20) {
            HStack(alignment: .center, spacing: 22) {
                VStack(spacing: 12) {
                    RunnerPreview(frames: frames.images, isTemplate: frames.isTemplate,
                                  speed: sampler.running ? speed : 2, flipped: settings.flipped, scale: 3)
                        .frame(width: 200, height: 84)
                    RunnerMenuBarStrip {
                        if !settings.unified {
                            Image(nsImage: NSImage(named: "MenuBarIcon") ?? NSImage()).renderingMode(.template)
                                .resizable().frame(width: 20, height: 15)
                        }
                        if shows {
                            RunnerPreview(frames: frames.images, isTemplate: frames.isTemplate,
                                          speed: sampler.running ? speed : 2, flipped: settings.flipped)
                        }
                        Image(systemName: "wifi").font(.system(size: 12, weight: .semibold))
                        Image(systemName: "battery.75percent").font(.system(size: 13))
                        Text("9:41").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(HubTheme.text)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.25)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.06)))

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Circle().fill(HubTheme.green).frame(width: 7, height: 7)
                        Text(settings.unified ? "One item · \(RunnerIcon.name(settings.runnerID))" : (settings.enabled ? "Two items" : "Coucou's item only"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(HubTheme.green)
                    }
                    Text("Click it for your agents, the Claude plan, the Mac, your routines and your metrics; right-click it for Coucou's menu.")
                        .font(.system(size: 13))
                        .foregroundColor(HubTheme.body)
                        .fixedSize(horizontal: false, vertical: true)
                    if sampler.running {
                        Text(speedLine(speed))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundColor(HubTheme.secondary)
                    }
                    HubNote(text: "A still icon with no numbers beside it reads nothing. A running one, or numbers, read the Mac every \(settings.interval) s; the animation itself runs in Core Animation.")
                }
            }
        }
    }

    private func speedLine(_ speed: Double) -> String {
        let what: String
        switch settings.speedSource {
        case .cpu: what = "CPU " + MetricsFormat.percent(load)
        case .memory: what = "Memory " + MetricsFormat.percent(load)
        case .agents: what = RunnerCoucouMetric.agentsText(working: RunnerStatusItem.workingAgents(AppState.shared.tasks)) + " working"
        }
        return "\(what) · speed \(String(format: "%.1f", speed))×"
    }
}

// MARK: - The panel's sections

private struct MenuBarPanelSettingsCard: View {
    @ObservedObject var settings: RunnerSettings

    var body: some View {
        HubCard {
            Text("What a click on the icon shows, top to bottom: drag a section to move it. The gear at its top opens these settings; the bar at its bottom keeps the Daily brief, the Weekly brief and Quit.")
                .font(.system(size: 12.5)).foregroundColor(HubTheme.body).fixedSize(horizontal: false, vertical: true)
            HubReorderList(items: $settings.panelSections,
                           fixed: MenuBarPanelSection.allCases.filter { !settings.panelSections.contains($0) }) { section in
                sectionRow(section)
            }
        }
    }

    private func sectionRow(_ section: MenuBarPanelSection) -> some View {
        let on = settings.panelSections.contains(section)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: section.symbol).font(.system(size: 12, weight: .semibold))
                    .foregroundColor(on ? HubTheme.accent : HubTheme.muted)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill((on ? HubTheme.accent : HubTheme.muted).opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title).font(.system(size: 13.5, weight: .medium))
                    Text(section.detail).font(.system(size: 12)).foregroundColor(HubTheme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                BriefSwitch(isOn: Binding(get: { on }, set: { v in withAnimation(BriefLayout.spring) { settings.toggle(section, v) } }),
                            tint: HubTheme.accent)
            }
            if section == .mac, on {
                HStack(spacing: 6) {
                    Text("Tiles").font(.system(size: 12)).foregroundColor(HubTheme.secondary).padding(.leading, 40)
                    ForEach(SystemMetricKind.allCases) { kind in
                        let has = settings.panelMacTiles.contains(kind)
                        Button {
                            if has { settings.panelMacTiles.remove(kind) } else { settings.panelMacTiles.insert(kind) }
                        } label: {
                            Text(kind.rawValue.capitalized)
                                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                                .foregroundColor(has ? HubTheme.onAccent : HubTheme.body)
                                .padding(.horizontal, 8).frame(height: 24)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(has ? HubTheme.accent : Color.white.opacity(0.05)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.03)))
        .opacity(on ? 1 : 0.6)
    }
}

// MARK: - Picking a runner

private struct RunnerPickerCard: View {
    @ObservedObject var settings: RunnerSettings
    @ObservedObject var library: RunnerLibrary
    @State private var editing: CustomRunner?

    var body: some View {
        HubCard {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 10)], spacing: 10) {
                ForEach(RunnerIcon.builtIns, id: \.self) { id in
                    let frames = RunnerIconFrames.frames(for: id)
                    RunnerTile(name: RunnerIcon.name(id), detail: detail(id),
                               frames: frames.images, isTemplate: frames.isTemplate,
                               selected: settings.runnerID == id) {
                        settings.runnerID = id
                    }
                    .help(RunnerIcon.runCat(id) != nil ? "From \(RunCatBuiltIn.credit), Apache-2.0" : "")
                }
                ForEach(library.runners) { runner in
                    let images = library.frameImages(runner)
                    let ordered = images.count == runner.frameCount ? runner.playableOrder.map { images[$0] } : images
                    RunnerTile(name: runner.name, detail: runner.author.map { "by \($0)" } ?? "Your runner",
                               frames: ordered, isTemplate: runner.isTemplate,
                               selected: settings.runnerID == runner.id) {
                        settings.runnerID = runner.id
                    }
                    .contextMenu {
                        Button("Edit…") { editing = runner }
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([library.directory.appendingPathComponent(runner.id)])
                        }
                        Divider()
                        Button("Delete", role: .destructive) { delete(runner) }
                    }
                }
            }
            if settings.runnerID == RunnerIcon.mochi {
                HubDivider()
                MochiIconOptions(settings: settings)
            }
            HubNote(text: "Coucou’s own icon stays still; every other one runs faster as the Mac works harder. The eight RunCat runners are by Takuto Nakamura (Kyome22), Apache-2.0. Right-click one of your runners to rename it, change how it plays, or delete it.")
        }
        .sheet(item: $editing) { runner in
            RunnerEditSheet(runner: runner) { editing = nil }
        }
    }

    private func detail(_ id: String) -> String {
        if id == RunnerIcon.classic { return "Still, as always" }
        if id == RunnerIcon.mochi { return "Drawn by Coucou" }
        return "RunCat · Kyome22"
    }

    private func delete(_ runner: CustomRunner) {
        if settings.runnerID == runner.id { settings.runnerID = RunnerIcon.classic }
        library.delete(runner.id)
    }
}

/// The Mochi icon's mood, outfit and colour.
private struct MochiIconOptions: View {
    @ObservedObject var settings: RunnerSettings

    var body: some View {
        HubRow(title: "Mood", detail: "What he does in his loop.") {
            RunnerChips(values: MochiIconMood.allCases, label: \.label, selection: $settings.mochiMood)
        }
        HubRow(title: "Outfit", detail: "From the Buddy’s wardrobe. Hats make him a little smaller to fit the menu bar.") {
            Picker("", selection: $settings.mochiOutfit) {
                ForEach(BuddyOutfit.allCases) { o in Text(o.name).tag(o) }
            }
            .labelsHidden()
            .frame(width: 170)
        }
        HubRow(title: "Colour", detail: settings.mochiTint == .menuBar
               ? "The menu bar’s own colour, like the other icons; outfits show as shapes."
               : "His body in this colour, outfits in theirs.") {
            RunnerChips(values: MochiIconTint.allCases, label: \.label, selection: $settings.mochiTint)
        }
    }
}

private struct RunnerTile: View {
    let name: String
    let detail: String
    let frames: [CGImage]
    let isTemplate: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                RunnerPreview(frames: frames, isTemplate: isTemplate, speed: 2, scale: 1.5, animate: selected || hover)
                    .frame(height: 36)
                VStack(spacing: 2) {
                    Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(detail).font(.system(size: 10.5)).foregroundColor(HubTheme.muted).lineLimit(1)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(selected ? HubTheme.accent.opacity(0.14) : Color.white.opacity(hover ? 0.07 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(selected ? HubTheme.accent : Color.white.opacity(0.06), lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct RunnerEditSheet: View {
    @State var runner: CustomRunner
    let done: () -> Void
    @State private var playback: RunnerPlayback = .loop
    /// What the stored order looked like, so a rename keeps an order of its own (RunCat's [0, 0, 1, 2]).
    @State private var detected: RunnerPlayback = .loop

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit runner").font(.system(size: 15, weight: .bold))
            HubRow(title: "Name") { HubField(placeholder: "Name", text: $runner.name).frame(width: 220) }
            HubRow(title: "Colour", detail: "Monochrome takes the menu bar’s colour; Colour keeps the frames’ own.") {
                RunnerChips(values: [true, false], label: { $0 ? "Monochrome" : "Colour" }, selection: $runner.isTemplate)
            }
            HubRow(title: "Plays") {
                RunnerChips(values: RunnerPlayback.allCases, label: { $0 == .loop ? "Loop" : "Back and forth" }, selection: $playback)
            }
            HStack {
                Spacer()
                Button("Cancel", action: done).buttonStyle(HubButtonStyle())
                Button("Save") {
                    if playback != detected { runner.frameOrder = playback.order(count: runner.frameCount) }
                    RunnerLibrary.shared.update(runner)
                    done()
                }
                .buttonStyle(HubButtonStyle(primary: true))
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(HubTheme.panel)
        .preferredColorScheme(.dark)
        .onAppear {
            detected = RunnerPlayback.detect(order: runner.frameOrder, count: runner.frameCount)
            playback = detected
        }
    }
}

// MARK: - Gallery

private struct RunnerGalleryCard: View {
    @ObservedObject var library: RunnerLibrary
    @Binding var toast: String
    @ObservedObject private var gallery = RunnerGalleryClient.shared
    @State private var tag: String? = nil
    @State private var query = ""

    var body: some View {
        HubCard {
            switch gallery.phase {
            case .idle:
                HubRow(title: "Runners made by the RunCat community",
                       detail: "Over forty runners shared under the Apache-2.0 licence. Browsing loads them from GitHub (runcat-dev/RunnerGallery); nothing is sent.") {
                    Button("Browse the gallery") { gallery.load() }.buttonStyle(HubButtonStyle(primary: true))
                }
            case .failed(let message):
                HubRow(title: "The gallery could not be loaded", detail: message) {
                    Button("Try again") { gallery.load() }.buttonStyle(HubButtonStyle())
                }
            case .loading, .loaded:
                filterBar
                let installed = library.installedGalleryNames()
                let shown = gallery.entries.filter { RunnerGallery.matches($0.metadata, tag: tag, query: query) }
                if gallery.phase == .loading && gallery.entries.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text("Loading the gallery…").foregroundColor(HubTheme.secondary) }
                } else if shown.isEmpty {
                    HubEmptyState(text: "No runner matches.", state: .thinking)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(shown) { entry in
                        RunnerGalleryTile(entry: entry, installed: installed.contains(entry.name),
                                          busy: gallery.installing.contains(entry.name)) {
                            Task {
                                if let problem = await gallery.install(entry) {
                                    toast = "❌ \(entry.metadata.displayName): \(problem)"
                                } else {
                                    toast = "“\(entry.metadata.displayName)” installed. Pick it above."
                                }
                            }
                        }
                    }
                }
                HStack {
                    if gallery.phase == .loading { ProgressView().controlSize(.small) }
                    Text("\(gallery.entries.count) runners").font(.system(size: 11.5)).foregroundColor(HubTheme.muted)
                    Spacer()
                    Button("Open the gallery’s website") { NSWorkspace.shared.open(RunnerGallery.site) }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundColor(HubTheme.accent)
                }
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            HubField(placeholder: "Search by name or author", text: $query).frame(maxWidth: 260)
            RunnerChips(values: [nil] + RunnerGallery.tags.map(Optional.some),
                        label: { $0.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "All" },
                        selection: $tag)
            Spacer(minLength: 0)
        }
    }
}

private struct RunnerGalleryTile: View {
    let entry: RunnerGalleryClient.Entry
    let installed: Bool
    let busy: Bool
    let install: () -> Void
    @State private var hover = false
    @Environment(\.hubVisible) private var visible

    var body: some View {
        VStack(spacing: 8) {
            // The gallery's own preview (an animated PNG), at its own pace, while the pointer is on it.
            TimelineView(.animation(minimumInterval: entry.delay, paused: !hover || !visible || entry.preview.count < 2)) { context in
                let i = entry.preview.isEmpty ? 0 : Int(context.date.timeIntervalSinceReferenceDate / entry.delay) % entry.preview.count
                if entry.preview.indices.contains(i) {
                    let img = entry.preview[i]
                    let image = Image(decorative: img, scale: 2 / 1.5)
                    Group {
                        if entry.metadata.isTemplate {
                            image.renderingMode(.template).foregroundColor(HubTheme.text)
                        } else {
                            image
                        }
                    }
                    .frame(width: CGFloat(img.width) * 0.75, height: CGFloat(img.height) * 0.75)
                } else {
                    Image(systemName: "photo").foregroundColor(HubTheme.muted)
                }
            }
            .frame(height: 36)
            VStack(spacing: 2) {
                Text(entry.metadata.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(entry.metadata.author).font(.system(size: 10.5)).foregroundColor(HubTheme.muted).lineLimit(1)
            }
            if installed {
                Label("Installed", systemImage: "checkmark").font(.system(size: 11.5, weight: .semibold)).foregroundColor(HubTheme.green)
                    .frame(height: 26)
            } else if busy {
                ProgressView().controlSize(.small).frame(height: 26)
            } else {
                Button("Install", action: install)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor(HubTheme.onAccent)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(Capsule().fill(HubTheme.accent))
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(hover ? 0.07 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
        .onHover { hover = $0 }
        .help(entry.metadata.tags.isEmpty ? entry.name : entry.metadata.tags.joined(separator: " · "))
    }
}

// MARK: - Speed

private struct RunnerSpeedCard: View {
    @ObservedObject var settings: RunnerSettings

    var body: some View {
        HubCard {
            HubRow(title: "Runs faster with", detail: detail) {
                RunnerChips(values: RunnerSpeedSource.allCases, label: { s in
                    switch s { case .cpu: "CPU"; case .memory: "Memory"; case .agents: "Agents" }
                }, selection: $settings.speedSource)
            }
            HubDivider()
            HubRow(title: "Slower under load", detail: "The other way round: it slows down as the load grows.") {
                Toggle("", isOn: $settings.slowerUnderLoad).toggleStyle(.switch).labelsHidden()
            }
            HubDivider()
            HubRow(title: "Run the other way", detail: "Flips the frames left to right.") {
                Toggle("", isOn: $settings.flipped).toggleStyle(.switch).labelsHidden()
            }
            HubDivider()
            HubRow(title: "Read the Mac every", detail: "How often the speed and the numbers update.") {
                RunnerChips(values: RunnerSettings.intervals, label: { "\($0) s" }, selection: $settings.interval)
            }
        }
    }

    private var detail: String {
        switch settings.speedSource {
        case .cpu: "The processor’s load, as RunCat does: idle ambles, 100 % sprints."
        case .memory: "How much of the memory is in use."
        case .agents: "Your Claude Code and other agent sessions: each one working makes it faster."
        }
    }
}

// MARK: - Menu bar numbers

private struct RunnerMenuBarCard: View {
    @ObservedObject var settings: RunnerSettings
    @ObservedObject var sampler: RunnerSampler
    @ObservedObject private var app = AppState.shared

    var body: some View {
        HubCard {
            ForEach(Array(SystemMetricKind.allCases.enumerated()), id: \.element) { i, kind in
                if i > 0 { HubDivider() }
                HubRow(title: title(kind), detail: sampler.running ? sampler.sample.menuBarText(kind) : nil) {
                    Toggle("", isOn: Binding(get: { settings.menuBarMetrics.contains(kind) },
                                             set: { settings.toggle(kind, $0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }
            HubDivider()
            HubRow(title: "Claude plan",
                   detail: RunnerStatusItem.claudePlanText() ?? "The 5-hour and weekly windows, from Coucou’s status-line relay (Agents → Plan gauge).") {
                Toggle("", isOn: Binding(get: { settings.coucouMetrics.contains(.claudePlan) },
                                         set: { settings.toggle(RunnerCoucouMetric.claudePlan, $0) }))
                    .toggleStyle(.switch).labelsHidden()
            }
            HubDivider()
            HubRow(title: "Agents at work",
                   detail: RunnerCoucouMetric.agentsText(working: RunnerStatusItem.workingAgents(app.tasks)) + " working now") {
                Toggle("", isOn: Binding(get: { settings.coucouMetrics.contains(.agents) },
                                         set: { settings.toggle(RunnerCoucouMetric.agents, $0) }))
                    .toggleStyle(.switch).labelsHidden()
            }
            HubNote(text: "Shown next to the icon, in this order, then the Custom Metrics set to show in the menu bar.")
        }
    }

    private func title(_ kind: SystemMetricKind) -> String {
        switch kind {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .storage: "Storage"
        case .battery: "Battery"
        case .network: "Network"
        }
    }
}

// MARK: - Custom Metrics sources

private struct RunnerMetricsSourcesCard: View {
    @ObservedObject var settings: RunnerSettings
    @Binding var toast: String
    @ObservedObject private var center = RunnerMetricsCenter.shared
    @State private var path = ""
    @State private var showFormat = false

    var body: some View {
        HubCard {
            Text("Any script can keep a small JSON file up to date; Coucou shows it the moment the file changes, in the Runner’s dashboard and, if you like, in the menu bar. The format is RunCat Neo’s, so its samples (Claude Code status line, Codex hook, Bitcoin price) work as they are.")
                .font(.system(size: 12.5))
                .foregroundColor(HubTheme.body)
                .fixedSize(horizontal: false, vertical: true)

            if settings.sources.isEmpty {
                HubNote(text: "No file yet. Add one, or make a sample to see how it looks.")
            }
            HubReorderList(items: $settings.sources) { source in
                RunnerSourceRow(source: source, state: center.states[source.id],
                                showsInMenuBar: Binding(get: { source.showsInMenuBar }, set: { on in
                                    if let i = settings.sources.firstIndex(where: { $0.id == source.id }) { settings.sources[i].showsInMenuBar = on }
                                }),
                                remove: { settings.sources.removeAll { $0.id == source.id } })
            }

            HubDivider()
            HStack(spacing: 8) {
                HubField(placeholder: "~/.claude/runcat-usage.json", text: $path) { addPath() }
                Button("Add path") { addPath() }.buttonStyle(HubButtonStyle()).disabled(path.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Choose a file…") { choose() }.buttonStyle(HubButtonStyle(primary: true))
            }
            HubNote(text: "A path may point at a file a script hasn’t written yet; it shows as failed until the file appears, checked every 5 seconds.")
            HStack(spacing: 14) {
                Button("Make a sample file") { makeSample() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundColor(HubTheme.accent)
                Button(showFormat ? "Hide the format" : "Show the format") { withAnimation { showFormat.toggle() } }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundColor(HubTheme.accent)
                Button("RunCat’s samples") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/runcat-dev/RunCatNeo/tree/main/docs/samples")!)
                }
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundColor(HubTheme.accent)
            }
            if showFormat { RunnerFormatPanel() }
        }
    }

    private func add(path: String, requireValid: Bool) {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute = URL(fileURLWithPath: expanded).standardizedFileURL.path
        if settings.sources.contains(where: { $0.path == absolute }) {
            toast = "❌ That file is already in the list."
            return
        }
        let result = RunnerMetricsCenter.readOnce(absolute)
        var name = URL(fileURLWithPath: absolute).deletingPathExtension().lastPathComponent
        var symbol: String? = nil
        switch result {
        case .success(let snapshot):
            name = snapshot.title
            symbol = snapshot.symbol
        case .failure(let error):
            if requireValid {
                toast = "❌ \(URL(fileURLWithPath: absolute).lastPathComponent): \(error.message)"
                return
            }
        }
        settings.sources.append(MetricsSourceConfig(id: UUID(), path: absolute, displayName: name, symbol: symbol))
        toast = "“\(name)” added."
    }

    private func addPath() {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        add(path: p, requireValid: false)
        path = ""
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.message = "Choose a Custom Metrics JSON file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        add(path: url.path, requireValid: true)
    }

    private func makeSample() {
        let folder = HookServer.supportDir.appendingPathComponent("Metrics", isDirectory: true)
        let url = folder.appendingPathComponent("sample.json")
        let snapshot = MetricsSnapshot(title: "Sample", symbol: "sparkles", metricsBarValue: "42%", metrics: [
            .init(title: "Text only", formattedValue: "No bar under this row"),
            .init(title: "Progress", formattedValue: "42%", normalizedValue: 0.42),
            .init(title: "Almost there", formattedValue: "9 of 10", normalizedValue: 0.9),
        ], lastUpdatedDate: Date())
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: url, options: .atomic)
            if !settings.sources.contains(where: { $0.path == url.path }) {
                settings.sources.append(MetricsSourceConfig(id: UUID(), path: url.path, displayName: "Sample", symbol: "sparkles", showsInMenuBar: true))
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            toast = "Sample written. Edit it and save: the card changes at once."
        } catch {
            toast = "❌ The sample could not be written: \(error.localizedDescription)"
        }
    }
}

private struct RunnerSourceRow: View {
    let source: MetricsSourceConfig
    let state: MetricsSourceState?
    @Binding var showsInMenuBar: Bool
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: state?.snapshot?.symbol ?? source.symbol ?? MetricsSnapshot.defaultSymbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(HubTheme.accent)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(HubTheme.accent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(state?.snapshot?.title ?? source.displayName).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    if state == nil {
                        HubStatusPill(text: "Not read yet", tone: .off)
                    } else if state?.failed == true {
                        HubStatusPill(text: "Error detected", tone: .warn)
                    } else {
                        HubStatusPill(text: state?.snapshot?.menuBarText ?? "OK", tone: .on)
                    }
                }
                Text((source.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(HubTheme.muted)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                if let error = state?.error, state?.failed == true {
                    HubNote(text: error, warning: true)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Menu bar").font(.system(size: 11.5)).foregroundColor(HubTheme.secondary)
                    Toggle("", isOn: $showsInMenuBar).toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
                HStack(spacing: 4) {
                    HubIconButton(symbol: "folder", help: "Show in Finder") {
                        let url = URL(fileURLWithPath: source.path)
                        if FileManager.default.fileExists(atPath: url.path) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } else {
                            NSWorkspace.shared.open(url.deletingLastPathComponent())
                        }
                    }
                    HubIconButton(symbol: "trash", help: "Remove", action: remove)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.03)))
    }
}

/// The format, with the schema document's own example.
private struct RunnerFormatPanel: View {
    static let example = """
    {
      "title": "Claude Code",
      "symbol": "staroflife",
      "metricsBarValue": "5.4%",
      "metrics": [
        { "title": "Model",   "formattedValue": "Opus 4.7" },
        { "title": "Context", "formattedValue": "5.4%",  "normalizedValue": 0.054 },
        { "title": "5h",      "formattedValue": "16.4%", "normalizedValue": 0.164 }
      ],
      "lastUpdatedDate": "2026-06-05T04:50:40Z"
    }
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("RunCat Neo’s Custom Metrics format").font(.system(size: 12, weight: .semibold))
                Spacer()
                HubIconButton(symbol: "doc.on.doc", help: "Copy") { NSPasteboard.copyText(Self.example) }
            }
            Text(Self.example)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(HubTheme.body)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.35)))
            VStack(alignment: .leading, spacing: 4) {
                bullet("title, metrics and lastUpdatedDate (ISO 8601) are required; an empty metrics list is fine.")
                bullet("symbol is an SF Symbol name; metricsBarValue is the short text for the menu bar (--- when missing).")
                bullet("A row with normalizedValue (0 to 1) gets a bar; formattedValue is shown exactly as written.")
                bullet("Strict JSON, well under 1 MB. Write a temporary file and mv it into place, so Coucou never reads half a file.")
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").foregroundColor(HubTheme.muted)
            Text(text).font(.system(size: 11.5)).foregroundColor(HubTheme.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
