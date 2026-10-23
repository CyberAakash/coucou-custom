#if !APPSTORE
import AppKit
import Combine
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// coucou-custom fork: the menu-bar Runner's settings and its custom runners on disk.

@MainActor
final class RunnerSettings: ObservableObject {
    static let shared = RunnerSettings()

    private let defaults = UserDefaults.standard

    /// One menu-bar item for Coucou: its icon is the one chosen here and a click opens the
    /// panel (Coucou's own item is hidden). Off: Coucou's item as upstream has it, and the
    /// Runner as a second item when `enabled`.
    @Published var unified: Bool { didSet { defaults.set(unified, forKey: "menuBarUnified") } }
    /// The second item, when not unified.
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "runnerEnabled") } }
    /// RunnerIcon: "classic", "mochi", "runcat:<name>", or a custom runner's id.
    @Published var runnerID: String { didSet { defaults.set(runnerID, forKey: "runnerID") } }
    @Published var mochiMood: MochiIconMood { didSet { defaults.set(mochiMood.rawValue, forKey: "menuBarMochiMood") } }
    @Published var mochiOutfit: BuddyOutfit { didSet { defaults.set(mochiOutfit.rawValue, forKey: "menuBarMochiOutfit") } }
    @Published var mochiTint: MochiIconTint { didSet { defaults.set(mochiTint.rawValue, forKey: "menuBarMochiTint") } }
    @Published var speedSource: RunnerSpeedSource { didSet { defaults.set(speedSource.rawValue, forKey: "runnerSpeedSource") } }
    @Published var slowerUnderLoad: Bool { didSet { defaults.set(slowerUnderLoad, forKey: "runnerSlowerUnderLoad") } }
    @Published var flipped: Bool { didSet { defaults.set(flipped, forKey: "runnerFlipped") } }
    /// Seconds between two readings of the Mac (RunCat's 3, 5 or 10).
    @Published var interval: Int { didSet { defaults.set(interval, forKey: "runnerInterval") } }
    /// The Mac's numbers shown next to the Runner, in SystemMetricKind order.
    @Published var menuBarMetrics: Set<SystemMetricKind> {
        didSet { defaults.set(menuBarMetrics.map(\.rawValue).sorted(), forKey: "runnerMenuBarMetrics") }
    }
    @Published var coucouMetrics: Set<RunnerCoucouMetric> {
        didSet { defaults.set(coucouMetrics.map(\.rawValue).sorted(), forKey: "runnerCoucouMetrics") }
    }
    @Published var sources: [MetricsSourceConfig] { didSet { saveSources() } }
    /// The panel's sections, in their order (hidden ones left out).
    @Published var panelSections: [MenuBarPanelSection] {
        didSet { defaults.set(panelSections.map(\.rawValue), forKey: "menuBarPanelSections") }
    }
    /// The Mac's tiles in the panel.
    @Published var panelMacTiles: Set<SystemMetricKind> {
        didSet { defaults.set(panelMacTiles.map(\.rawValue).sorted(), forKey: "menuBarPanelMacTiles") }
    }

    static let intervals = [3, 5, 10]

    private init() {
        unified = defaults.object(forKey: "menuBarUnified") as? Bool ?? true
        enabled = defaults.bool(forKey: "runnerEnabled")
        let storedID = defaults.string(forKey: "runnerID")
        runnerID = storedID.map(RunnerIcon.migrate) ?? RunnerIcon.classic
        mochiMood = MochiIconMood(rawValue: defaults.string(forKey: "menuBarMochiMood") ?? "") ?? .hop
        mochiOutfit = BuddyOutfit(rawValue: defaults.string(forKey: "menuBarMochiOutfit") ?? "") ?? .none
        // The first Runner build's "mochi-color" was the orange Mochi.
        mochiTint = MochiIconTint(rawValue: defaults.string(forKey: "menuBarMochiTint") ?? "")
            ?? (storedID == "mochi-color" ? .orange : .menuBar)
        speedSource = RunnerSpeedSource(rawValue: defaults.string(forKey: "runnerSpeedSource") ?? "") ?? .cpu
        slowerUnderLoad = defaults.bool(forKey: "runnerSlowerUnderLoad")
        flipped = defaults.bool(forKey: "runnerFlipped")
        let stored = defaults.integer(forKey: "runnerInterval")
        interval = Self.intervals.contains(stored) ? stored : 5
        menuBarMetrics = Set((defaults.stringArray(forKey: "runnerMenuBarMetrics") ?? []).compactMap(SystemMetricKind.init))
        coucouMetrics = Set((defaults.stringArray(forKey: "runnerCoucouMetrics") ?? []).compactMap(RunnerCoucouMetric.init))
        panelSections = defaults.stringArray(forKey: "menuBarPanelSections").map { $0.compactMap(MenuBarPanelSection.init(rawValue:)) }
            ?? MenuBarPanelSection.allCases
        panelMacTiles = defaults.stringArray(forKey: "menuBarPanelMacTiles").map { Set($0.compactMap(SystemMetricKind.init)) }
            ?? [.cpu, .memory, .storage, .battery]
        if let data = defaults.data(forKey: "runnerMetricsSources"),
           let list = try? JSONDecoder().decode([MetricsSourceConfig].self, from: data) {
            sources = list
        } else {
            sources = []
        }
    }

    private func saveSources() {
        if let data = try? JSONEncoder().encode(sources) { defaults.set(data, forKey: "runnerMetricsSources") }
    }

    var mochiStyle: RunnerIconFrames.MochiStyle {
        RunnerIconFrames.MochiStyle(mood: mochiMood, outfit: mochiOutfit, tint: mochiTint, buddyHex: BuddySettings.shared.color)
    }

    func toggle(_ kind: SystemMetricKind, _ on: Bool) {
        if on { menuBarMetrics.insert(kind) } else { menuBarMetrics.remove(kind) }
    }

    func toggle(_ section: MenuBarPanelSection, _ on: Bool) {
        if on, !panelSections.contains(section) { panelSections.append(section) }
        if !on { panelSections.removeAll { $0 == section } }
    }

    func move(_ section: MenuBarPanelSection, by delta: Int) {
        guard let i = panelSections.firstIndex(of: section), panelSections.indices.contains(i + delta) else { return }
        panelSections.swapAt(i, i + delta)
    }

    func toggle(_ metric: RunnerCoucouMetric, _ on: Bool) {
        if on { coucouMetrics.insert(metric) } else { coucouMetrics.remove(metric) }
    }
}

/// A runner ready to play: its frames (36 px high CGImages) in play order.
struct RunnerFrames {
    let images: [CGImage]
    let isTemplate: Bool

    /// Points in the menu bar: the frames are @2x.
    var size: CGSize {
        guard let first = images.first else { return .zero }
        return CGSize(width: CGFloat(first.width) / 2, height: CGFloat(first.height) / 2)
    }
}

// MARK: - Custom runners on disk

@MainActor
final class RunnerLibrary: ObservableObject {
    static let shared = RunnerLibrary()

    @Published private(set) var runners: [CustomRunner] = []
    /// Decoded frames by runner id: the page and the menu bar ask often, the files never change.
    private var imageCache: [String: [CGImage]] = [:]

    /// ~/Library/Application Support/NotchBuddy/Runners: runners.json and one folder per runner.
    let directory: URL

    init(directory: URL = HookServer.supportDir.appendingPathComponent("Runners", isDirectory: true)) {
        self.directory = directory
        reload()
    }

    private var indexURL: URL { directory.appendingPathComponent("runners.json") }

    func reload() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([CustomRunner].self, from: data) else {
            runners = []
            return
        }
        runners = list
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(runners).write(to: indexURL, options: .atomic)
    }

    func runner(_ id: String) -> CustomRunner? { runners.first { $0.id == id } }

    func installedGalleryNames() -> Set<String> { Set(runners.compactMap(\.galleryName)) }

    /// Saves the frames as frame-0.png… and adds the runner. The PNGs are written as given, so a
    /// frame keeps its exact pixels.
    @discardableResult
    func add(name: String, isTemplate: Bool, frames: [Data], playback: RunnerPlayback,
             author: String? = nil, galleryName: String? = nil) throws -> CustomRunner {
        let id = UUID().uuidString
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            for (i, png) in frames.enumerated() {
                try png.write(to: folder.appendingPathComponent("frame-\(i).png"), options: .atomic)
            }
            let runner = CustomRunner(id: id, name: CustomRunner.uniqueName(name, existing: runners.map(\.name)),
                                      isTemplate: isTemplate, frameOrder: playback.order(count: frames.count),
                                      frameCount: frames.count, author: author, galleryName: galleryName)
            runners.append(runner)
            try save()
            return runner
        } catch {
            try? FileManager.default.removeItem(at: folder)
            reload()
            throw error
        }
    }

    func delete(_ id: String) {
        imageCache[id] = nil
        runners.removeAll { $0.id == id }
        RunnerIconFrames.invalidate()
        try? save()
        // Only ever a UUID folder of ours.
        if UUID(uuidString: id) != nil {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(id, isDirectory: true))
        }
    }

    func update(_ runner: CustomRunner) {
        guard let i = runners.firstIndex(where: { $0.id == runner.id }) else { return }
        var r = runner
        r.name = CustomRunner.uniqueName(r.name, existing: runners.filter { $0.id != r.id }.map(\.name))
        runners[i] = r
        RunnerIconFrames.invalidate()
        try? save()
    }

    func move(from source: IndexSet, to destination: Int) {
        runners.move(fromOffsets: source, toOffset: destination)
        try? save()
    }

    /// The runner's frames, once each (not in play order).
    func frameImages(_ runner: CustomRunner) -> [CGImage] {
        if let hit = imageCache[runner.id], hit.count == runner.frameCount { return hit }
        let folder = directory.appendingPathComponent(runner.id, isDirectory: true)
        let images = (0..<runner.frameCount).compactMap { i in
            RunnerImages.image(from: folder.appendingPathComponent("frame-\(i).png"))
        }
        if images.count == runner.frameCount { imageCache[runner.id] = images }
        return images
    }
}

// MARK: - Images

enum RunnerImages {
    static func image(from url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func image(from data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(src) as String? == UTType.png.identifier else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Every frame of an animated PNG (the gallery's preview.png) and its delay in seconds.
    static func animation(from data: Data) -> (frames: [CGImage], delay: Double)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = min(CGImageSourceGetCount(src), 60)
        let frames = (0..<count).compactMap { CGImageSourceCreateImageAtIndex(src, $0, nil) }
        guard !frames.isEmpty else { return nil }
        var delay = 0.1
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            let d = (png[kCGImagePropertyAPNGUnclampedDelayTime] as? Double) ?? (png[kCGImagePropertyAPNGDelayTime] as? Double)
            if let d, d > 0.01 { delay = d }
        }
        return (frames, delay)
    }

    static func png(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// Checks frames against RunCat's rules; the first problem found, with the file it is in.
    static func validate(_ frames: [(name: String, data: Data)]) -> String? {
        if frames.isEmpty { return RunnerFrameRules.message(.empty) }
        if frames.count > RunnerFrameRules.maxFrames { return RunnerFrameRules.message(.tooMany) }
        for f in frames {
            guard let img = image(from: f.data) else { return "\(f.name): " + RunnerFrameRules.message(.notImage) }
            if let problem = RunnerFrameRules.check(width: img.width, height: img.height) {
                return "\(f.name): " + RunnerFrameRules.message(problem)
            }
        }
        return nil
    }
}

#endif
