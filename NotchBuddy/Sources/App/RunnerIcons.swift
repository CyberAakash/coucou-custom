#if !APPSTORE
import AppKit
import SwiftUI

// coucou-custom fork: every icon the menu bar can wear — Coucou's own, Mochi drawn in code (a
// mood, an outfit, a colour), RunCat Neo's eight runners (bundled, Apache-2.0, by Takuto Nakamura,
// Kyome22), and the runners you add (made here, from the Runner Gallery, or Noto's animated emoji).

/// What the Mochi icon does in its loop.
enum MochiIconMood: String, CaseIterable, Identifiable {
    case hop, happy, look, dance, sleepy
    var id: String { rawValue }

    var label: String {
        switch self {
        case .hop: "Hop"
        case .happy: "Happy"
        case .look: "Look around"
        case .dance: "Dance"
        case .sleepy: "Sleepy"
        }
    }
}

/// The Mochi icon's colour.
enum MochiIconTint: String, CaseIterable, Identifiable {
    /// The menu bar's own colour, his eyes cut out.
    case menuBar
    case orange
    /// The desktop Buddy's colour (Settings → Buddy).
    case buddy
    case white
    var id: String { rawValue }

    var label: String {
        switch self {
        case .menuBar: "Menu bar"
        case .orange: "Orange"
        case .buddy: "Buddy's"
        case .white: "White"
        }
    }
}

/// RunCat Neo's built-in runners, as its RunnerKind declares them: frame count and play order.
enum RunCatBuiltIn: String, CaseIterable, Identifiable {
    case cat, dog, slime, drop, coffee, newtonCradle = "newton-cradle", engine, mochi
    var id: String { rawValue }

    var name: String {
        switch self {
        case .cat: "Cat"
        case .dog: "Dog"
        case .slime: "Slime"
        case .drop: "Drop"
        case .coffee: "Coffee"
        case .newtonCradle: "Newton's Cradle"
        case .engine: "Engine"
        case .mochi: "RunCat's Mochi"
        }
    }

    var frameCount: Int { self == .coffee || self == .engine ? 10 : 5 }

    /// RunnerKind.frameOrder: slime is the party horn, the cradle the pendulum, mochi the swing.
    var order: [Int] {
        switch self {
        case .slime: [0, 1, 2, 3, 4, 4, 3, 2, 1]
        case .newtonCradle: [0, 1, 2, 1, 0, 3, 4, 3]
        case .mochi: [0, 1, 2, 3, 4, 3, 2, 1]
        default: Array(0..<frameCount)
        }
    }

    static let credit = "RunCat by Takuto Nakamura (Kyome22)"
}

@MainActor
enum RunnerIcon {
    static let classic = "classic"
    static let mochi = "mochi"
    static let runCatPrefix = "runcat:"

    /// The built-in tiles, in the picker's order.
    static var builtIns: [String] { [classic, mochi] + RunCatBuiltIn.allCases.map { runCatPrefix + $0.rawValue } }

    static func runCat(_ id: String) -> RunCatBuiltIn? {
        id.hasPrefix(runCatPrefix) ? RunCatBuiltIn(rawValue: String(id.dropFirst(runCatPrefix.count))) : nil
    }

    static func name(_ id: String) -> String {
        if id == classic { return "Coucou" }
        if id == mochi { return "Mochi" }
        if let r = runCat(id) { return r.name }
        return RunnerLibrary.shared.runner(id)?.name ?? "Mochi"
    }

    /// Older choices carried over (the first Runner build had "mochi-color").
    static func migrate(_ id: String) -> String { id == "mochi-color" ? mochi : id }
}

@MainActor
enum RunnerIconFrames {
    private static var cache: [String: RunnerFrames] = [:]

    static func invalidate() { cache = [:] }

    /// The frames for an icon id, in play order. Unknown or broken: Coucou's own icon.
    static func frames(for id: String) -> RunnerFrames {
        if id == RunnerIcon.mochi { return mochi(RunnerSettings.shared.mochiStyle) }
        if let hit = cache[id] { return hit }
        var result: RunnerFrames?
        if id == RunnerIcon.classic {
            result = classic()
        } else if let r = RunnerIcon.runCat(id) {
            result = runCat(r)
        } else if let runner = RunnerLibrary.shared.runner(id) {
            let images = RunnerLibrary.shared.frameImages(runner)
            if images.count == runner.frameCount, !images.isEmpty {
                result = RunnerFrames(images: runner.playableOrder.map { images[$0] }, isTemplate: runner.isTemplate)
            }
        }
        let frames = result ?? classic()
        cache[id] = frames
        return frames
    }

    /// Coucou's menu-bar icon, 24 × 18 pt, as the app has always shown it.
    static func classic() -> RunnerFrames {
        guard let image = NSImage(named: "MenuBarIcon") else { return RunnerFrames(images: [], isTemplate: true) }
        let size = NSSize(width: 48, height: 36)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 36, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return RunnerFrames(images: [], isTemplate: true) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return RunnerFrames(images: rep.cgImage.map { [$0] } ?? [], isTemplate: true)
    }

    static func runCat(_ r: RunCatBuiltIn) -> RunnerFrames? {
        let images: [CGImage] = (0..<r.frameCount).compactMap { i in
            Bundle.main.url(forResource: "\(r.rawValue)-frame-\(i)", withExtension: "png",
                            subdirectory: "runners/runcat/\(r.rawValue)").flatMap(RunnerImages.image(from:))
        }
        guard images.count == r.frameCount else { return nil }
        return RunnerFrames(images: r.order.map { images[$0] }, isTemplate: true)
    }

    // MARK: - Mochi

    struct MochiStyle: Hashable {
        var mood: MochiIconMood
        var outfit: BuddyOutfit
        var tint: MochiIconTint
        var buddyHex: String
    }

    private static var mochiCache: [MochiStyle: RunnerFrames] = [:]

    static func mochi(_ style: MochiStyle) -> RunnerFrames {
        if let hit = mochiCache[style] { return hit }
        let hex: String = switch style.tint {
        case .menuBar, .white: "#FFFFFF"
        case .orange: "#FB923C"
        case .buddy: style.buddyHex.isEmpty ? "#FFFFFF" : style.buddyHex
        }
        // The square that keeps his head (or hat) inside 18 pt at the top of the hop: his feet
        // stand 0.22 side above the square's bottom and its top reaches `top` sides above it,
        // so the top is at feet − side × (top − 0.22), feet being 17.5 − lift down the stage.
        let top = BuddyHeadroom.top(style.outfit)
        let lift = poses(style.mood).map(\.lift).max() ?? 0
        let side = min(20, (17.5 - lift - 0.5) / max(0.3, top - 0.22))
        let images = poses(style.mood).compactMap { pose -> CGImage? in
            let renderer = ImageRenderer(content: MochiIconPose(pose: pose, side: side, outfit: style.outfit, bodyHex: hex))
            renderer.scale = 2
            guard let cg = renderer.cgImage else { return nil }
            return style.tint == .menuBar ? templateMask(cg) : cg
        }
        let frames = RunnerFrames(images: images, isTemplate: style.tint == .menuBar)
        mochiCache[style] = frames
        return frames
    }

    struct Pose {
        var lift: CGFloat = 0
        var squash: CGFloat = 1
        var yaw: CGFloat = 0
        var pitch: CGFloat = 0
        var tilt: CGFloat = 0
        var eye: EyeShape? = nil
    }

    static func poses(_ mood: MochiIconMood) -> [Pose] {
        switch mood {
        case .hop:
            return [Pose(squash: 0.86), Pose(lift: 1.3, yaw: 0.15), Pose(lift: 2.8, squash: 1.06, yaw: 0.3),
                    Pose(lift: 3.4, squash: 1.04, yaw: 0.35), Pose(lift: 2.8, yaw: 0.3), Pose(lift: 1.3, yaw: 0.15),
                    Pose(squash: 0.84), Pose(squash: 0.95)]
        case .happy:
            return [Pose(squash: 0.84, eye: .happy), Pose(lift: 1.6, squash: 1.04, eye: .happy),
                    Pose(lift: 3.2, squash: 1.08, tilt: 0.08, eye: .happy), Pose(lift: 1.6, squash: 1.04, eye: .happy),
                    Pose(squash: 0.84, eye: .happy), Pose(lift: 1.6, squash: 1.04, eye: .happy),
                    Pose(lift: 3.2, squash: 1.08, tilt: -0.08, eye: .happy), Pose(lift: 1.6, squash: 1.04, eye: .happy)]
        case .look:
            return [Pose(), Pose(yaw: -0.25), Pose(yaw: -0.5), Pose(yaw: -0.5), Pose(yaw: -0.5, eye: .closed),
                    Pose(yaw: -0.2), Pose(yaw: 0.25), Pose(yaw: 0.5), Pose(yaw: 0.5, pitch: -0.2), Pose(yaw: 0.25)]
        case .dance:
            return [Pose(squash: 0.94, tilt: -0.16, eye: .happy), Pose(lift: 1.2, tilt: -0.08), Pose(lift: 2, squash: 1.05),
                    Pose(lift: 1.2, tilt: 0.08), Pose(squash: 0.94, tilt: 0.16, eye: .happy), Pose(lift: 1.2, tilt: 0.08),
                    Pose(lift: 2, squash: 1.05), Pose(lift: 1.2, tilt: -0.08)]
        case .sleepy:
            return [Pose(squash: 0.96, eye: .closed), Pose(squash: 0.98, eye: .closed), Pose(squash: 1.0, eye: .closed),
                    Pose(squash: 1.02, eye: .closed), Pose(squash: 1.0, eye: .closed), Pose(squash: 0.98, eye: .closed)]
        }
    }

    /// For the menu bar's colour only the alpha counts: dark pixels (his eyes) become holes, so
    /// he keeps his face when the menu bar tints him.
    static func templateMask(_ image: CGImage) -> CGImage {
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

/// One frame: Mochi on a 22 × 18 pt stage, his feet near the bottom, hopping up.
private struct MochiIconPose: View {
    let pose: RunnerIconFrames.Pose
    let side: CGFloat
    let outfit: BuddyOutfit
    let bodyHex: String

    var body: some View {
        Canvas { ctx, size in
            let engine = BotEngine()
            engine.isMini = true
            engine.state = .idle
            engine.cfg = BotStates[.idle]!
            engine.bodyColor = cgColorFromHex(bodyHex)
            engine.yaw = pose.yaw
            engine.pitch = pose.pitch
            engine.tilt = pose.tilt
            engine.open = 1
            if let eye = pose.eye {
                engine.permanentEye = eye
                engine.eyeOverride = eye
                engine.eyeOverrideUntil = .greatestFiniteMagnitude
            }
            engine.setOutfit(outfit.engineOutfit ?? .none, animated: false)
            // His feet sit about 0.22 side above the square's bottom: put them 0.5 pt above the
            // stage's, then lift and squash from there.
            let feet = size.height - 0.5 - pose.lift
            let square = CGRect(x: (size.width - side) / 2, y: feet - side * 0.78, width: side, height: side)
            var c = ctx
            c.translateBy(x: square.midX, y: feet)
            c.scaleBy(x: 2 - pose.squash, y: pose.squash)
            c.translateBy(x: -square.midX, y: -feet)
            BuddyMochiView.draw(engine, in: c, square: square, nightcap: outfit == .nightcap)
        }
        .frame(width: 22, height: 18)
    }
}
#endif
