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

    /// Off by default: a running animation in the menu bar is a choice (it keeps a timer and
    /// Core Animation busy while it shows).
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "runnerEnabled") } }
    /// "mochi", "mochi-color", or a custom runner's id.
    @Published var runnerID: String { didSet { defaults.set(runnerID, forKey: "runnerID") } }
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

    static let intervals = [3, 5, 10]

    private init() {
        enabled = defaults.bool(forKey: "runnerEnabled")
        runnerID = defaults.string(forKey: "runnerID") ?? RunnerBuiltIn.mochi.rawValue
        speedSource = RunnerSpeedSource(rawValue: defaults.string(forKey: "runnerSpeedSource") ?? "") ?? .cpu
        slowerUnderLoad = defaults.bool(forKey: "runnerSlowerUnderLoad")
        flipped = defaults.bool(forKey: "runnerFlipped")
        let stored = defaults.integer(forKey: "runnerInterval")
        interval = Self.intervals.contains(stored) ? stored : 5
        menuBarMetrics = Set((defaults.stringArray(forKey: "runnerMenuBarMetrics") ?? []).compactMap(SystemMetricKind.init))
        coucouMetrics = Set((defaults.stringArray(forKey: "runnerCoucouMetrics") ?? []).compactMap(RunnerCoucouMetric.init))
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

    func toggle(_ kind: SystemMetricKind, _ on: Bool) {
        if on { menuBarMetrics.insert(kind) } else { menuBarMetrics.remove(kind) }
    }

    func toggle(_ metric: RunnerCoucouMetric, _ on: Bool) {
        if on { coucouMetrics.insert(metric) } else { coucouMetrics.remove(metric) }
    }
}

/// The runners drawn in code: Mochi hopping, in the menu bar's colour or in Coucou's orange.
enum RunnerBuiltIn: String, CaseIterable {
    case mochi, mochiColor = "mochi-color"

    var name: String {
        switch self {
        case .mochi: "Mochi"
        case .mochiColor: "Mochi · orange"
        }
    }

    var isTemplate: Bool { self == .mochi }
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

// MARK: - Mochi, drawn in code

@MainActor
enum RunnerMochiFrames {
    private static var cache: [RunnerBuiltIn: [CGImage]] = [:]

    /// A hop in 8 frames, 22 × 18 pt (44 × 36 px, the size RunCat's frames have).
    static func frames(_ kind: RunnerBuiltIn) -> [CGImage] {
        if let hit = cache[kind] { return hit }
        // y lift (pt), squash, and where he looks, through one hop.
        let poses: [(lift: CGFloat, squash: CGFloat, yaw: CGFloat)] = [
            (0, 0.86, 0), (1.3, 1.0, 0.15), (2.8, 1.06, 0.3), (3.4, 1.04, 0.35),
            (2.8, 1.0, 0.3), (1.3, 1.0, 0.15), (0, 0.84, 0), (0, 0.95, 0),
        ]
        let images = poses.compactMap { pose -> CGImage? in
            let view = RunnerMochiPose(lift: pose.lift, squash: pose.squash, yaw: pose.yaw,
                                       bodyHex: kind.isTemplate ? "#FFFFFF" : "#FB923C")
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let cg = renderer.cgImage else { return nil }
            return kind.isTemplate ? templateMask(cg) : cg
        }
        cache[kind] = images
        return images
    }

    /// For the menu bar's colour only the alpha counts: dark pixels (his eyes) become holes, so
    /// he keeps his face when the menu bar tints him.
    private static func templateMask(_ image: CGImage) -> CGImage {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let base = ctx.data else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = base.bindMemory(to: UInt8.self, capacity: w * h * 4)
        for i in 0..<(w * h) {
            let o = i * 4
            let a = Double(px[o + 3])
            guard a > 0 else { continue }
            // Premultiplied: un-premultiply for the luminance.
            let lum = (0.299 * Double(px[o]) + 0.587 * Double(px[o + 1]) + 0.114 * Double(px[o + 2])) / a
            let alpha = UInt8(max(0, min(255, a * min(1, lum))))
            px[o] = alpha; px[o + 1] = alpha; px[o + 2] = alpha; px[o + 3] = alpha
        }
        return ctx.makeImage() ?? image
    }
}

/// One frame of the hop.
private struct RunnerMochiPose: View {
    let lift: CGFloat
    let squash: CGFloat
    let yaw: CGFloat
    let bodyHex: String

    var body: some View {
        // His body fills about 2/3 of MochiStill's square, centred: a 20 pt canvas leaves room
        // for a 3.4 pt hop above and the squash below inside the 18 pt frame.
        MochiStill(state: .idle, bodyHex: bodyHex, showBadge: false, pose: MochiPose(yaw: yaw))
            .frame(width: 20, height: 20)
            .scaleEffect(x: 2 - squash, y: squash, anchor: UnitPoint(x: 0.5, y: 0.75))
            .offset(y: 1.6 - lift)
            .frame(width: 22, height: 18)
    }
}
#endif
