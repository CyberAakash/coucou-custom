import Foundation
import CoreGraphics

// coucou-custom fork: the Buddy (desktop pet) — the pet package format, its animations and the
// reactions, as OpenPets / Codex Pets define them (github.com/OpenPetsHQ/openpets,
// apps/desktop/src/codex-pets-core.ts and reaction-animation-mapping.ts). Pure logic, no AppKit,
// so `scripts/test-buddy.sh` compiles it on its own.

// MARK: - Atlas layout

/// A Codex pet atlas: a grid of 192 × 208 px cells. V1 has 9 animation rows; V2 adds two rows of
/// 16 static gaze cells. The manifest decides the version, never the image size: OpenPets reads
/// a V1 pet whose image is taller as V1 and ignores the extra rows.
struct BuddyAtlasLayout: Equatable {
    let version: Int
    let rows: Int
    static let frameWidth = 192
    static let frameHeight = 208
    static let columns = 8

    static let v1 = BuddyAtlasLayout(version: 1, rows: 9)
    static let v2 = BuddyAtlasLayout(version: 2, rows: 11)

    var minimumPixelWidth: Int { Self.columns * Self.frameWidth }
    var minimumPixelHeight: Int { rows * Self.frameHeight }
    var hasGaze: Bool { version == 2 }

    /// The cell's rect in atlas pixels, y measured down from the top (CGImage cropping space).
    static func cellRect(row: Int, column: Int) -> CGRect {
        CGRect(x: column * frameWidth, y: row * frameHeight, width: frameWidth, height: frameHeight)
    }
}

// MARK: - Manifest

/// `pet.json`. Only the fields OpenPets requires or that change how the pet is drawn; other keys
/// (kind, tags, wardrobe…) are allowed and ignored.
struct BuddyPetManifest: Equatable {
    let id: String
    let displayName: String
    let description: String
    let spritesheetPath: String
    let layout: BuddyAtlasLayout
    /// Where the pet looks from, normalized within one frame from its top-left (V2 only).
    let gazeAnchor: CGPoint?

    enum ParseError: Error, Equatable, CustomStringConvertible {
        case notAnObject
        case badField(String)
        case unsupportedSpritesheet(String)

        var description: String {
            switch self {
            case .notAnObject: return "pet.json is not a JSON object."
            case .badField(let f): return "pet.json has a missing or invalid \"\(f)\"."
            case .unsupportedSpritesheet(let p):
                return "Only spritesheet.webp atlases are supported (this pet uses \(p))."
            }
        }
    }

    /// `^[a-z0-9][a-z0-9_-]{0,63}$`, as in OpenPets.
    static func isValidId(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, (1...64).contains(id.unicodeScalars.count) else { return false }
        func lowerAlnum(_ s: Unicode.Scalar) -> Bool { ("a"..."z").contains(s) || ("0"..."9").contains(s) }
        guard lowerAlnum(first) else { return false }
        return id.unicodeScalars.allSatisfy { lowerAlnum($0) || $0 == "_" || $0 == "-" }
    }

    static func parse(_ data: Data) throws -> BuddyPetManifest {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ParseError.notAnObject
        }
        guard let id = obj["id"] as? String, isValidId(id) else { throw ParseError.badField("id") }
        func text(_ key: String, max: Int) throws -> String {
            guard let s = obj[key] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  s.count <= max else { throw ParseError.badField(key) }
            return s
        }
        let name = try text("displayName", max: 80)
        let desc = try text("description", max: 500)
        guard let path = obj["spritesheetPath"] as? String else { throw ParseError.badField("spritesheetPath") }
        guard path == "spritesheet.webp" else {
            if path == "spritesheet.svg" { throw ParseError.unsupportedSpritesheet(path) }
            throw ParseError.badField("spritesheetPath")
        }
        var layout = BuddyAtlasLayout.v1
        if let v = obj["spriteVersionNumber"] {
            guard (v as? NSNumber)?.intValue == 2, !(v is Bool) else { throw ParseError.badField("spriteVersionNumber") }
            layout = .v2
        }
        var anchor: CGPoint?
        if let a = obj["gazeAnchor"] {
            guard let d = a as? [String: Any], let x = (d["x"] as? NSNumber)?.doubleValue,
                  let y = (d["y"] as? NSNumber)?.doubleValue, (0...1).contains(x), (0...1).contains(y)
            else { throw ParseError.badField("gazeAnchor") }
            anchor = CGPoint(x: x, y: y)
        }
        return BuddyPetManifest(id: id, displayName: name, description: desc,
                                spritesheetPath: path, layout: layout, gazeAnchor: anchor)
    }
}

// MARK: - Animations

/// The atlas rows (OpenPets `defaultPetSprite.states`).
enum BuddyAnimation: String, CaseIterable, Identifiable {
    case idle
    case runningRight = "running-right"
    case runningLeft = "running-left"
    case waving, jumping, failed, waiting, running, review

    var id: String { rawValue }

    var row: Int {
        switch self {
        case .idle: return 0
        case .runningRight: return 1
        case .runningLeft: return 2
        case .waving: return 3
        case .jumping: return 4
        case .failed: return 5
        case .waiting: return 6
        case .running: return 7
        case .review: return 8
        }
    }

    var frames: Int {
        switch self {
        case .idle: return 6
        case .runningRight, .runningLeft: return 8
        case .waving: return 4
        case .jumping: return 5
        case .failed: return 8
        case .waiting, .running, .review: return 6
        }
    }

    /// One pass through the row, in seconds. Waiting has OpenPets' two speeds (1010 / 2200 ms).
    func duration(relaxedWaiting: Bool) -> TimeInterval {
        switch self {
        case .idle: return 5.5
        case .runningRight, .runningLeft: return 1.06
        case .waving: return 0.7
        case .jumping: return 0.84
        case .failed: return 1.22
        case .waiting: return relaxedWaiting ? 2.2 : 1.01
        case .running: return 0.82
        case .review: return 1.03
        }
    }

    /// Passes before a one-shot animation hands back to idle; nil loops.
    var iterations: Int? {
        switch self {
        case .waving, .jumping, .failed: return 2
        default: return nil
        }
    }

    /// The rows a reaction can be set to in Settings (OpenPets `selectableAnimationMetadata`).
    static let selectable: [BuddyAnimation] = [.idle, .review, .running, .waiting, .waving, .jumping, .failed]

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .runningRight: return "Running right"
        case .runningLeft: return "Running left"
        case .waving: return "Waving"
        case .jumping: return "Jumping"
        case .failed: return "Failed"
        case .waiting: return "Waiting"
        case .running: return "Running"
        case .review: return "Review"
        }
    }

    /// The frame shown `elapsed` seconds into the animation, or nil once a one-shot is over.
    func frame(at elapsed: TimeInterval, relaxedWaiting: Bool) -> Int? {
        let d = duration(relaxedWaiting: relaxedWaiting)
        let t = max(0, elapsed)
        if let n = iterations, t >= d * Double(n) { return nil }
        let perFrame = d / Double(frames)
        return Int(t / perFrame) % frames
    }
}

// MARK: - Reactions

/// What the pet is reacting to. OpenPets' reaction set, reduced to the ones Coucou can tell apart:
/// Coucou's states do not distinguish editing / running / testing from working, and nothing
/// sends "celebrating".
enum BuddyReaction: String, CaseIterable, Identifiable {
    case idle, thinking, working, waiting, waving, success, error

    var id: String { rawValue }

    /// OpenPets `defaultReactionToSpriteState`.
    var defaultAnimation: BuddyAnimation {
        switch self {
        case .idle: return .idle
        case .thinking: return .review
        case .working: return .running
        case .waiting: return .waiting
        case .waving: return .waving
        case .success: return .jumping
        case .error: return .failed
        }
    }

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .thinking: return "Thinking"
        case .working: return "Working"
        case .waiting: return "Waiting"
        case .waving: return "Clicked"
        case .success: return "Done"
        case .error: return "Error"
        }
    }

    var detail: String {
        switch self {
        case .idle: return "Nothing running, or asleep."
        case .thinking: return "The agent is reasoning."
        case .working: return "The agent is running tools or searching."
        case .waiting: return "A permission, a question, or a rate limit."
        case .waving: return "You clicked the pet."
        case .success: return "A session finished."
        case .error: return "Something failed."
        }
    }

    /// Coucou's state → reaction. Same intent as OpenPets' Claude Code hook mapping
    /// (UserPromptSubmit → thinking, PermissionRequest → waiting, Stop → success,
    /// StopFailure → error), from the states Coucou already derives for every agent.
    static func forState(_ state: BotState) -> BuddyReaction {
        switch state {
        case .idle, .sleeping: return .idle
        case .thinking: return .thinking
        case .working, .searching: return .working
        case .approval, .question, .ratelimit: return .waiting
        case .error, .dizzy: return .error
        case .finished: return .success
        }
    }

    func animation(overrides: [String: String]) -> BuddyAnimation {
        if let raw = overrides[rawValue], let a = BuddyAnimation(rawValue: raw),
           BuddyAnimation.selectable.contains(a) { return a }
        return defaultAnimation
    }

    /// Drops unknown reactions, unknown animations and entries equal to the default
    /// (OpenPets `normalizeReactionAnimationOverrides`).
    static func normalized(_ overrides: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in overrides {
            guard let r = BuddyReaction(rawValue: k), let a = BuddyAnimation(rawValue: v),
                  BuddyAnimation.selectable.contains(a), a != r.defaultAnimation else { continue }
            out[k] = v
        }
        return out
    }
}

// MARK: - Gaze (V2 atlases)

/// OpenPets' V2 cursor gaze: 16 sectors, index 0 straight up, clockwise in 22.5° steps.
enum BuddyGaze {
    static let sectorCount = 16
    static let deadZone: CGFloat = 24
    /// The pet looks at the cursor only while it moved in the last 1.2 s.
    static let idleReset: TimeInterval = 1.2

    /// `cursor` and `anchor` in one y-down space. nil inside the dead zone.
    static func direction(cursor: CGPoint, anchor: CGPoint, deadZone: CGFloat = deadZone) -> Int? {
        let dx = cursor.x - anchor.x
        let dy = cursor.y - anchor.y
        guard hypot(dx, dy) > deadZone else { return nil }
        let sectorAngle = 2 * Double.pi / Double(sectorCount)
        let angle = atan2(Double(dx), Double(-dy))
        let sector = Int(floor((angle + sectorAngle / 2) / sectorAngle))
        return (sector + sectorCount) % sectorCount
    }

    static func mirrored(_ index: Int) -> Int { (sectorCount - index) % sectorCount }

    /// The static cell for a direction. A flipped pet is drawn mirrored, so it shows the mirrored
    /// cell to keep looking at the cursor.
    static func cell(direction: Int, flipped: Bool) -> (row: Int, column: Int)? {
        guard (0..<sectorCount).contains(direction) else { return nil }
        let i = flipped ? mirrored(direction) : direction
        return i < 8 ? (9, i) : (10, i - 8)
    }

    static func isActive(lastCursorMove: Date?, now: Date) -> Bool {
        guard let m = lastCursorMove else { return false }
        return now.timeIntervalSince(m) < idleReset
    }
}

// MARK: - Sizes

/// OpenPets' size presets. The pet's cell is drawn at 192 × 208 × scale points; Mochi keeps its
/// 120 pt panel at Medium (Coucou's existing size) and scales by the same ratio.
enum BuddySize: Double, CaseIterable, Identifiable {
    case extraSmall = 0.35, small = 0.5, medium = 0.75, large = 1.0, huge = 1.25

    var id: Double { rawValue }

    var label: String {
        switch self {
        case .extraSmall: return "Extra small"
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .huge: return "Huge"
        }
    }

    /// Unknown stored values fall back to Medium; OpenPets' old 1.5 maps to Huge.
    static func from(stored: Double) -> BuddySize {
        if stored == 1.5 { return .huge }
        return BuddySize(rawValue: stored) ?? .medium
    }

    static let mochiMediumPanel: CGFloat = 120

    /// Side of the square desktop panel.
    func panelSide(isMochi: Bool) -> CGFloat {
        if isMochi { return (Self.mochiMediumPanel * rawValue / BuddySize.medium.rawValue).rounded() }
        return (CGFloat(BuddyAtlasLayout.frameHeight) * rawValue).rounded()
    }
}

// MARK: - Sprite placement and hit testing

enum BuddySpriteGeometry {
    /// The cell drawn inside a square panel: aspect-fit, centered, standing on the bottom edge.
    /// Panel-local, y-down.
    static func spriteRect(panelSide s: CGFloat) -> CGRect {
        let fw = CGFloat(BuddyAtlasLayout.frameWidth), fh = CGFloat(BuddyAtlasLayout.frameHeight)
        let k = min(s / fw, s / fh)
        let w = fw * k, h = fh * k
        return CGRect(x: (s - w) / 2, y: s - h, width: w, height: h)
    }

    /// The atlas pixel under a panel-local y-down point, for the given cell; nil outside the sprite.
    static func atlasPixel(localTopDown p: CGPoint, panelSide s: CGFloat,
                           row: Int, column: Int, flipped: Bool) -> (x: Int, y: Int)? {
        let r = spriteRect(panelSide: s)
        guard r.contains(p) else { return nil }
        var u = (p.x - r.minX) / r.width
        if flipped { u = 1 - u }
        let v = (p.y - r.minY) / r.height
        let fx = min(BuddyAtlasLayout.frameWidth - 1, max(0, Int(u * CGFloat(BuddyAtlasLayout.frameWidth))))
        let fy = min(BuddyAtlasLayout.frameHeight - 1, max(0, Int(v * CGFloat(BuddyAtlasLayout.frameHeight))))
        return (column * BuddyAtlasLayout.frameWidth + fx, row * BuddyAtlasLayout.frameHeight + fy)
    }

    /// OpenPets `PET_ALPHA_HIT_THRESHOLD` / `PET_ALPHA_SAMPLE_RADIUS`: opaque enough within one
    /// pixel of the point counts as the pet.
    static let alphaThreshold: UInt8 = 64
    static let sampleRadius = 1

    static func isOpaque(alphaAt: (Int, Int) -> UInt8?, x: Int, y: Int) -> Bool {
        for dy in -sampleRadius...sampleRadius {
            for dx in -sampleRadius...sampleRadius {
                if let a = alphaAt(x + dx, y + dy), a >= alphaThreshold { return true }
            }
        }
        return false
    }

    /// Where the pet looks from, panel-local y-down: the manifest's gaze anchor, else the bottom
    /// centre (OpenPets' default when a pet has no anchor).
    static func gazeAnchor(panelSide s: CGFloat, anchor: CGPoint?, flipped: Bool) -> CGPoint {
        guard let a = anchor else { return CGPoint(x: s / 2, y: s) }
        let r = spriteRect(panelSide: s)
        let ax = flipped ? 1 - a.x : a.x
        return CGPoint(x: r.minX + ax * r.width, y: r.minY + a.y * r.height)
    }
}

// MARK: - Animator

/// Which cell the pet shows, from the reaction it is in and the time it entered it. Shared by the
/// view (to draw) and the desktop controller (to hit-test the same frame).
final class BuddyAnimator {
    /// What is playing now.
    private(set) var animation: BuddyAnimation = .idle
    private(set) var startedAt: Date = .distantPast
    /// The current reaction's animation, as last set.
    private(set) var reaction: BuddyAnimation = .idle
    /// The reaction's one-shot has played out: rest on idle until the reaction changes.
    private var reactionDone = false
    /// Set while dragging: the running-left/right rows win over everything else.
    var motion: BuddyAnimation?
    var relaxedWaiting = false
    var flipped = false

    /// Show the animation of a reaction. Re-sending the current one changes nothing, so callers
    /// can send it every frame.
    func setReaction(_ a: BuddyAnimation, now: Date = .now) {
        guard a != reaction else { return }
        reaction = a
        reactionDone = false
        animation = a
        startedAt = now
    }

    /// A one-shot over the current reaction (a click's wave), then back to it.
    func play(_ a: BuddyAnimation, now: Date = .now) {
        animation = a
        startedAt = now
    }

    /// The cell to draw now. `gaze` is a direction when a V2 pet should look at the cursor.
    func cell(now: Date, gaze: Int?) -> (row: Int, column: Int) {
        if let m = motion {
            // A flipped pet is drawn mirrored, so running right on screen is its running-left row.
            let row = flipped ? (m == .runningRight ? BuddyAnimation.runningLeft : .runningRight) : m
            let f = row.frame(at: now.timeIntervalSince(startedAt), relaxedWaiting: relaxedWaiting) ?? 0
            return (row.row, f)
        }
        var f = animation.frame(at: now.timeIntervalSince(startedAt), relaxedWaiting: relaxedWaiting)
        if f == nil {
            if animation == reaction { reactionDone = true }
            animation = reactionDone ? .idle : reaction
            startedAt = now
            f = 0
        }
        if animation == .idle, let g = gaze, let c = BuddyGaze.cell(direction: g, flipped: flipped) { return c }
        return (animation.row, f ?? 0)
    }
}
