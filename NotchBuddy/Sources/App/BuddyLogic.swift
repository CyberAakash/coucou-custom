import Foundation
import CoreGraphics

// coucou-custom fork: the Buddy (Settings → Buddy) — its sizes, the room around it in its
// window, where it stands and when it speaks. Pure logic, no AppKit, so `scripts/test-buddy.sh`
// compiles it on its own. Sizes, per-display spots and speech follow OpenPets
// (github.com/OpenPetsHQ/openpets).

// MARK: - Sizes

/// OpenPets' size presets (0.35 to 1.25), relative to Medium: Mochi's square is 120 pt at Medium,
/// the size of the desktop Mochi.
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

    /// The size chips in Settings.
    var short: String {
        switch self {
        case .extraSmall: return "XS"
        case .small: return "S"
        case .medium: return "M"
        case .large: return "L"
        case .huge: return "XL"
        }
    }

    /// Unknown stored values fall back to Medium; OpenPets' old 1.5 maps to Huge.
    static func from(stored: Double) -> BuddySize {
        if stored == 1.5 { return .huge }
        return BuddySize(rawValue: stored) ?? .medium
    }

    static let mochiMediumPanel: CGFloat = 120

    /// Side of Mochi's square.
    var side: CGFloat { (Self.mochiMediumPanel * rawValue / BuddySize.medium.rawValue).rounded() }
}

// MARK: - Window margins

/// Room around Mochi's square in its window, as fractions of the square's side, so what is drawn
/// past the square is not cut off by the window. Measured on BotEngine (every state, emote and
/// outfit, dancing): Mochi reaches 24 % above its square (the proud emote, "zZ", hearts, the party
/// hat), 7 % right ("zZ"), 1 % left (witch hat), never below; hover scales it 1.07 about its centre.
struct BuddyInsets: Equatable {
    let top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat

    /// Top: the measured 24 %, hover, and the Jump action (it lifts Mochi 0.35 R, about 10 %).
    static let mochi = BuddyInsets(top: 0.42, left: 0.12, bottom: 0.04, right: 0.12)

    /// The window around a square of `side`, in whole points; `strip` is the companions' room on
    /// each side (BuddyCompanionLayout.roam).
    func panelSize(side s: CGFloat, strip: CGFloat = 0) -> CGSize {
        CGSize(width: s + (s * left).rounded() + (s * right).rounded() + 2 * strip,
               height: s + (s * top).rounded() + (s * bottom).rounded())
    }

    /// The square inside the window: AppKit (y up) from the window's bottom-left.
    func innerOrigin(side s: CGFloat, strip: CGFloat = 0) -> CGPoint {
        CGPoint(x: strip + (s * left).rounded(), y: (s * bottom).rounded())
    }

    /// The square inside the window, SwiftUI (y down) from its top-left.
    func innerRectTopDown(side s: CGFloat, strip: CGFloat = 0) -> CGRect {
        CGRect(x: strip + (s * left).rounded(), y: (s * top).rounded(), width: s, height: s)
    }
}

// MARK: - Placement

/// Where the Buddy stands. Its spot is kept per display, as OpenPets does, keyed by the display's
/// frame ("x,y,wxh") because display ids change across reboots; up to 8 displays are remembered.
/// The spot is the pet's foot (bottom centre), so a size change keeps it standing in place.
struct BuddySpot: Codable, Equatable {
    let screen: String
    let x: Double
    let y: Double
}

enum BuddyPlacement {
    static let maxRememberedScreens = 8
    static let defaultMargin: CGFloat = 24

    static func screenKey(_ frame: CGRect) -> String {
        "\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))x\(Int(frame.height))"
    }

    static func origin(foot: CGPoint, side: CGFloat) -> CGPoint {
        CGPoint(x: foot.x - side / 2, y: foot.y)
    }

    static func foot(origin: CGPoint, side: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + side / 2, y: origin.y)
    }

    /// Bottom-right of the display's usable area.
    static func defaultFoot(visibleFrame vf: CGRect, side: CGFloat, margin: CGFloat = defaultMargin) -> CGPoint {
        CGPoint(x: vf.maxX - margin - side / 2, y: vf.minY + margin)
    }

    /// Keeps the whole square inside the display's usable area (no menu bar, no Dock): where it
    /// lands when it is put back on a display.
    static func clamp(origin: CGPoint, side: CGFloat, visibleFrame vf: CGRect) -> CGPoint {
        CGPoint(x: min(max(origin.x, vf.minX), max(vf.minX, vf.maxX - side)),
                y: min(max(origin.y, vf.minY), max(vf.minY, vf.maxY - side)))
    }

    /// Where a drag may take it: anywhere its centre stays on the display, so it reaches every edge
    /// and can hang up to half off it (as OpenPets' roaming pets, which only need their anchor on a
    /// display). `frame` is the whole display, menu bar and Dock included.
    static func clampLoose(origin: CGPoint, side: CGFloat, frame f: CGRect) -> CGPoint {
        CGPoint(x: min(max(origin.x, f.minX - side / 2), f.maxX - side / 2),
                y: min(max(origin.y, f.minY - side / 2), f.maxY - side / 2))
    }

    /// The square's centre is on one of the displays, edges included: clampLoose stops it with its
    /// centre exactly on an edge, where CGRect.contains says no for the top and right ones.
    static func isOnScreen(origin: CGPoint, side: CGFloat, frames: [CGRect]) -> Bool {
        let c = CGPoint(x: origin.x + side / 2, y: origin.y + side / 2)
        return frames.contains { c.x >= $0.minX && c.x <= $0.maxX && c.y >= $0.minY && c.y <= $0.maxY }
    }

    static func spot(for screen: String, in spots: [BuddySpot]) -> BuddySpot? {
        spots.first { $0.screen == screen }
    }

    /// The display's new spot first, then the others, at most 8.
    static func remembering(_ spot: BuddySpot, in spots: [BuddySpot]) -> [BuddySpot] {
        Array(([spot] + spots.filter { $0.screen != spot.screen }).prefix(maxRememberedScreens))
    }
}

// MARK: - Companions

/// The little Mochis around the Buddy, as on the Coucou window's banner: up to 6. They start right
/// beside it, half on each side, and roam the whole stage, crossing behind it to the other side.
/// The stage widens with their number.
/// Where the companions stay: on the Buddy's left, its right, or both sides.
enum BuddyCompanionSide: String, CaseIterable, Identifiable {
    case left, both, right

    var id: String { rawValue }
    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

struct BuddyCompanionLayout: Equatable {
    static let maxCount = 6
    /// A companion's drawing is this much of the Buddy's square (its body about two thirds of it).
    static let scale: CGFloat = 0.42
    /// Their floor: the Buddy's own (its body ends at 78 % of its square, measured on BotEngine).
    static let floor: CGFloat = 0.8
    /// Mochi's body is 0.684 of its square wide (rx = 1.14 × 0.3 of the square, BotEngine).
    static let bodyHalfWidth: CGFloat = 0.342

    let count: Int
    let side: CGFloat
    let placement: BuddyCompanionSide

    init(count: Int, side: CGFloat, placement: BuddyCompanionSide = .both) {
        self.count = min(max(count, 0), Self.maxCount)
        self.side = side
        self.placement = placement
    }

    var left: Int {
        switch placement {
        case .both: (count + 1) / 2
        case .left: count
        case .right: 0
        }
    }
    var right: Int { count - left }
    /// One companion's drawing, in points.
    var size: CGFloat { (side * Self.scale).rounded() }
    /// Room added on each side of the Buddy's window for them to roam: more of them, more room.
    /// The window stays centred on the Buddy when they keep to one side (its spot is its foot), so
    /// the other side's room is empty, and clicks pass through it.
    var roam: CGFloat {
        guard count > 0 else { return 0 }
        return (size * (0.75 * CGFloat(count) + 0.6)).rounded()
    }
    /// How high above the floor they can be: a jump and an emote.
    var stripHeight: CGFloat { (size * 1.9).rounded() }

    /// Where companion `i` starts (its centre's x in the window): beside the Buddy's body, the
    /// extra one on the left, the first ones nearest. `squareMidX`: the Buddy's square centre.
    func startX(_ i: Int, squareMidX: CGFloat) -> CGFloat {
        let onLeft: Bool, k: CGFloat
        switch placement {
        case .both: onLeft = i % 2 == 0; k = CGFloat(i / 2)
        case .left: onLeft = true; k = CGFloat(i)
        case .right: onLeft = false; k = CGFloat(i)
        }
        let body = side * Self.bodyHalfWidth
        let near = body + size * (Self.bodyHalfWidth + 0.12)   // just clear of the Buddy's body
        let offset = near + k * size * 0.78
        return onLeft ? squareMidX - offset : squareMidX + offset
    }

    /// Where they may roam (centres' x in the window): the whole stage, or their side of it up to
    /// the Buddy's middle (behind it); only where the display is (`visible`, the display's span in
    /// the window), so a Buddy by an edge keeps them in sight — behind it, if that is all there is.
    func roamRange(stageWidth: CGFloat, squareMidX: CGFloat, visible: ClosedRange<CGFloat>? = nil) -> ClosedRange<CGFloat> {
        var lo = size / 2, hi = max(lo, stageWidth - size / 2)
        if let v = visible {
            lo = max(lo, v.lowerBound + size / 2)
            hi = min(hi, v.upperBound - size / 2)
            if lo > hi { let m = min(max(squareMidX, v.lowerBound), v.upperBound); return m...m }
        }
        switch placement {
        case .both: return lo...hi
        case .left:
            let top = min(hi, squareMidX)
            return top >= lo ? lo...top : lo...lo
        case .right:
            let bottom = max(lo, squareMidX)
            return bottom <= hi ? bottom...hi : hi...hi
        }
    }
}

// MARK: - Shadow

/// The Buddy's shadow on its floor (the companions' too).
enum BuddyShadow: String, CaseIterable, Identifiable {
    case off, soft, medium, strong

    var id: String { rawValue }
    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    var opacity: Double {
        switch self {
        case .off: return 0
        case .soft: return 0.14
        case .medium: return 0.24
        case .strong: return 0.36
        }
    }

    /// Under the body, on the floor (y down in the window); `lift`: how far up the body is, as a
    /// fraction of the square (0 on the floor). A jump makes it smaller and lighter.
    static func ellipse(square: CGRect, lift: CGFloat) -> (rect: CGRect, fade: Double) {
        let k = max(0.45, 1 - lift * 2.2)
        let w = square.width * 0.6 * k, h = square.width * 0.075 * k
        let y = square.minY + square.height * BuddyCompanionLayout.floor
        return (CGRect(x: square.midX - w / 2, y: y - h / 2, width: w, height: h), Double(max(0.35, 1 - lift * 2.5)))
    }
}

// MARK: - Napping

/// When the Buddy naps: only when you are idle — no keyboard, mouse or trackpad input for two
/// minutes (the system's idle time) — and your agents have been quiet as long. The desktop
/// Mochi's rule (agents quiet and the cursor 150 pt away) put it to sleep while you worked
/// elsewhere on screen, as the Buddy usually sits in a corner.
enum BuddyNap {
    static let after: TimeInterval = 120

    static func shouldNap(enabled: Bool, userIdle: TimeInterval, agentsQuiet: TimeInterval) -> Bool {
        enabled && userIdle >= after && agentsQuiet >= after
    }
}

// MARK: - Clicks

/// Click, double click, triple click, and many clicks (4 or more, the notch's "slaps").
enum BuddyGesture: String, CaseIterable, Identifiable {
    case click, double, triple, many

    var id: String { rawValue }

    static func from(count: Int) -> BuddyGesture {
        switch count {
        case ...1: return .click
        case 2: return .double
        case 3: return .triple
        default: return .many
        }
    }

    var label: String {
        switch self {
        case .click: return "Click"
        case .double: return "Double click"
        case .triple: return "Triple click"
        case .many: return "Many clicks"
        }
    }

    var detail: String {
        switch self {
        case .click: return "One click."
        case .double: return "Two quick clicks."
        case .triple: return "Three quick clicks."
        case .many: return "Four or more, like slapping the notch's Mochi."
        }
    }

    var clicks: Int {
        switch self {
        case .click: return 1
        case .double: return 2
        case .triple: return 3
        case .many: return 4
        }
    }
}

/// What a gesture does.
enum BuddyAction: String, CaseIterable, Codable, Identifiable {
    case none, hello, hearts, wink, surprise, jump, spin, dance, bonk, dizzy, party
    case nextOutfit, openNotch, openCoucou, openSettings, shortcut, open, hide

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "Nothing"
        case .hello: return "Say hi"
        case .hearts: return "Hearts"
        case .wink: return "Wink"
        case .surprise: return "Surprise"
        case .jump: return "Jump"
        case .spin: return "Spin"
        case .dance: return "Dance"
        case .bonk: return "Bonk (3 make it dizzy)"
        case .dizzy: return "Dizzy"
        case .party: return "Party with the companions"
        case .nextOutfit: return "Next outfit"
        case .openNotch: return "Open the notch"
        case .openCoucou: return "Open the Coucou window"
        case .openSettings: return "Open Buddy settings"
        case .shortcut: return "Run a Shortcut…"
        case .open: return "Open an app or a link…"
        case .hide: return "Hide the Buddy"
        }
    }

    /// The Shortcut's name, or the app / link to open.
    var needsParameter: Bool { self == .shortcut || self == .open }

    /// Menu sections: animations, then Coucou, then your own.
    static let animations: [BuddyAction] = [.hello, .hearts, .wink, .surprise, .jump, .spin, .dance, .bonk, .dizzy, .party]
    static let coucou: [BuddyAction] = [.nextOutfit, .openNotch, .openCoucou, .openSettings, .hide]
    static let yours: [BuddyAction] = [.shortcut, .open]
}

struct BuddyClickBinding: Codable, Equatable {
    var action: BuddyAction
    var parameter: String = ""

    static let defaults: [BuddyGesture: BuddyClickBinding] = [
        .click: .init(action: .hello),
        .double: .init(action: .spin),
        .triple: .init(action: .hearts),
        .many: .init(action: .dizzy),
    ]

    /// Runnable: an action that needs a Shortcut or a link has one.
    var isRunnable: Bool {
        action != .none && (!action.needsParameter || !parameter.trimmingCharacters(in: .whitespaces).isEmpty)
    }
}

enum BuddyClicks {
    /// After `count` clicks, wait for another only if a longer gesture does something; otherwise
    /// act at once (no lag on a lone click when nothing is set on double and more).
    static func shouldWait(after count: Int, bindings: [BuddyGesture: BuddyClickBinding]) -> Bool {
        guard count < 4 else { return false }
        return BuddyGesture.allCases.contains { $0.clicks > count && (bindings[$0]?.isRunnable ?? false) }
    }
}

// MARK: - Colours

enum BuddyColor {
    /// "#RRGGBB" (any case, with or without "#") → "#RRGGBB" upper case; nil otherwise.
    static func normalized(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if t.hasPrefix("#") { t.removeFirst() }
        guard t.count == 6, t.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + t
    }

    /// sRGB components 0…1 → "#RRGGBB".
    static func hex(red: Double, green: Double, blue: Double) -> String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// The Coucou window's palette: the companions' colours when they do not match the Buddy.
    static let companions = ["#F5F6F8", "#FB923C", "#F472B6", "#A78BFA", "#3B9EFF", "#34D399", "#F7B32B", "#22D3EE"]
}

// MARK: - Speech bubbles

/// When the Buddy says something. As OpenPets' Claude Code hook: it speaks when a permission or a
/// question waits (3 s cooldown) and when something fails (20 s cooldown), with short canned lines,
/// never the agent's own text; a bubble stays about 4 s.
struct BuddySpeech {
    enum Category: String, CaseIterable { case permission, question, error }

    static let permissionCooldown: TimeInterval = 3
    static let speechCooldown: TimeInterval = 20
    static let displayDuration: TimeInterval = 4

    private(set) var lastSpoken: [Category: Date] = [:]

    static func category(for state: BotState) -> Category? {
        switch state {
        case .approval: return .permission
        case .question: return .question
        case .error: return .error
        default: return nil
        }
    }

    static func cooldown(_ c: Category) -> TimeInterval {
        c == .error ? speechCooldown : permissionCooldown
    }

    /// True, and the category's clock restarts, when it has not spoken within its cooldown.
    mutating func shouldSpeak(_ c: Category, now: Date) -> Bool {
        if let last = lastSpoken[c], now.timeIntervalSince(last) < Self.cooldown(c) { return false }
        lastSpoken[c] = now
        return true
    }

    static let lines: [Category: [String]] = [
        .permission: ["Need your OK", "Can I go ahead?", "Permission, please", "Waiting on you", "Approve this?"],
        .question: ["Quick question", "Your call", "Need an answer", "Which way?", "Got a question"],
        .error: ["Hit a snag", "Something broke", "That failed", "Needs a look", "Uh-oh"],
    ]

    static func line(_ c: Category, pick: Int) -> String {
        let pool = lines[c] ?? []
        guard !pool.isEmpty else { return "" }
        return pool[((pick % pool.count) + pool.count) % pool.count]
    }
}
