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

    /// The window around a square of `side`, in whole points.
    func panelSize(side s: CGFloat) -> CGSize {
        CGSize(width: s + (s * left).rounded() + (s * right).rounded(),
               height: s + (s * top).rounded() + (s * bottom).rounded())
    }

    /// The square inside the window: AppKit (y up) from the window's bottom-left.
    func innerOrigin(side s: CGFloat) -> CGPoint {
        CGPoint(x: (s * left).rounded(), y: (s * bottom).rounded())
    }

    /// The square inside the window, SwiftUI (y down) from its top-left.
    func innerRectTopDown(side s: CGFloat) -> CGRect {
        CGRect(x: (s * left).rounded(), y: (s * top).rounded(), width: s, height: s)
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

    /// Keeps the whole panel inside the display's usable area (no menu bar, no Dock).
    static func clamp(origin: CGPoint, side: CGFloat, visibleFrame vf: CGRect) -> CGPoint {
        CGPoint(x: min(max(origin.x, vf.minX), max(vf.minX, vf.maxX - side)),
                y: min(max(origin.y, vf.minY), max(vf.minY, vf.maxY - side)))
    }

    static func spot(for screen: String, in spots: [BuddySpot]) -> BuddySpot? {
        spots.first { $0.screen == screen }
    }

    /// The display's new spot first, then the others, at most 8.
    static func remembering(_ spot: BuddySpot, in spots: [BuddySpot]) -> [BuddySpot] {
        Array(([spot] + spots.filter { $0.screen != spot.screen }).prefix(maxRememberedScreens))
    }
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
