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

    static let mochi = BuddyInsets(top: 0.32, left: 0.12, bottom: 0.04, right: 0.12)

    /// The window around a square of `side`, in whole points; `strip` is the companions' room on
    /// each side (BuddyCompanionLayout.stripWidth).
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

/// The little Mochis around the Buddy, as on the Coucou window's banner: up to 6, half on each
/// side (the extra one on the left), walking on the Buddy's floor in a strip of their own.
struct BuddyCompanionLayout: Equatable {
    static let maxCount = 6
    /// A companion's drawing is this much of the Buddy's square (its body about two thirds of it).
    static let scale: CGFloat = 0.42

    let count: Int
    let side: CGFloat

    init(count: Int, side: CGFloat) {
        self.count = min(max(count, 0), Self.maxCount)
        self.side = side
    }

    var left: Int { (count + 1) / 2 }
    var right: Int { count / 2 }
    /// One companion's drawing, in points.
    var size: CGFloat { (side * Self.scale).rounded() }
    /// Each side's strip: room for its companions plus a little to walk. Both sides get the
    /// width of the fuller one, so the Buddy stays centred in its window.
    var stripWidth: CGFloat {
        guard count > 0 else { return 0 }
        return (size * (CGFloat(left) * 0.9 + 0.7)).rounded()
    }
    /// Their floor: the Buddy's own (its body ends at 78 % of its square, measured on BotEngine).
    static let floor: CGFloat = 0.8
    /// The strip's height above the floor: a hop and an emote.
    var stripHeight: CGFloat { (size * 1.5).rounded() }

    /// Which side companion `i` is on, and its place in that side's strip (0…1).
    func slot(_ i: Int) -> (left: Bool, start: CGFloat) {
        let onLeft = i % 2 == 0
        let k = i / 2
        let n = onLeft ? left : right
        let start: CGFloat = n <= 1 ? 0.5 : CGFloat(k) / CGFloat(n - 1)
        // The left strip's start is mirrored, so the first ones stand nearest the Buddy.
        return (onLeft, onLeft ? 1 - start : start)
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
