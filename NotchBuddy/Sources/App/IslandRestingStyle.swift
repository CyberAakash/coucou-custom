import Foundation

// MARK: - The resting notch's size (coucou-custom fork)
//
// How far the compact island reaches past the notch on each side (its wing: Mochi lives on
// the left one, the mini Mochis and the clock on the right one) and whether it stands a
// little below the notch (after Nusa's minimal notch and notch size). Read from UserDefaults
// where the size is computed (`islandSize` is nonisolated), so a change applies at once.

enum IslandRestingStyle {
    static let wingKey = "coucouRestingWing"
    static let extraHeightKey = "coucouRestingExtraHeight"

    enum Wing: Int, CaseIterable, Identifiable {
        /// -1: from the width of the island's screen (`autoWing`).
        case auto = -1, minimal = 44, standard = 80, wide = 120
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .auto: return "Auto"
            case .minimal: return "Minimal"
            case .standard: return "Standard"
            case .wide: return "Wide"
            }
        }
    }

    enum ExtraHeight: Int, CaseIterable, Identifiable {
        case flush = 0, little = 4, more = 8
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .flush: return "Flush with the notch"
            case .little: return "A little below"
            case .more: return "Below"
            }
        }
    }

    /// The island's screen's width, kept by the window controller whenever the island lands on a
    /// screen: `wing` is read where the size is computed, off the main actor.
    nonisolated(unsafe) static var screenWidth: CGFloat = 1512

    /// Auto: 3.5 % of the screen's width, 44…140 pt, in steps of 4: 53 pt on a 14″ MacBook Pro,
    /// 90 at 2560, 120 at 3440, 140 from 4000.
    static var autoWing: CGFloat {
        let raw = (screenWidth * 0.035 / 4).rounded() * 4
        return min(140, max(44, raw))
    }

    /// One line in nb.log when the wing is Auto: which width it picked for which screen.
    static func logAuto() {
        guard UserDefaults.standard.integer(forKey: wingKey) == Wing.auto.rawValue else { return }
        appendAppLog("nb.log", "[Island] auto wing \(Int(autoWing)) pt for a \(Int(screenWidth)) pt wide screen")
    }

    /// What the right wing's content needs (the clock or a task's time, beside the mini Mochis),
    /// set by `CompactSideContent`: the wing grows to it rather than draw under the notch.
    nonisolated(unsafe) static var contentNeed: CGFloat = 0

    /// The wing as chosen in Settings.
    static var chosenWing: CGFloat {
        let stored = UserDefaults.standard.integer(forKey: wingKey)
        if stored == Wing.auto.rawValue { return autoWing }
        return CGFloat(Wing(rawValue: stored)?.rawValue ?? Wing.standard.rawValue)
    }

    /// The wing drawn: the chosen one, wider when its content needs it.
    static var wing: CGFloat { max(chosenWing, contentNeed) }

    /// Beside a text, the mini Mochis' middle sits this far from the island's right edge (their
    /// grid is 28 pt wide), and the text's right edge this far, 8 pt before them.
    static let gridEdge: CGFloat = 24
    static let textEdge: CGFloat = 46

    /// The wing a text of this width needs at the right edge: alone, centred in the wing; beside
    /// the mini Mochis, ending at `textEdge`. 8 pt stay clear of the notch.
    static func need(textWidth t: CGFloat, besideGrid: Bool) -> CGFloat {
        guard t > 0 else { return 0 }
        return besideGrid ? (textEdge + t + 8).rounded(.up) : (t + 16).rounded(.up)
    }

    static var extraHeight: CGFloat {
        CGFloat(ExtraHeight(rawValue: UserDefaults.standard.integer(forKey: extraHeightKey))?.rawValue ?? 0)
    }

    /// The compact island: the notch plus a wing on each side, a little taller when asked.
    static func compactSize(nw: CGFloat, nh: CGFloat) -> (CGFloat, CGFloat) {
        (nw + wing * 2, nh + extraHeight)
    }

    /// Mochi's middle on the left wing.
    static var mochiX: CGFloat { wing / 2 }

    /// The mini Mochis' middle, measured from the island's right edge.
    static var gridInset: CGFloat { wing / 2 }

    /// Posted when the settings change the size, so a resting island follows at once.
    static let changed = Notification.Name("coucou.islandRestingStyleChanged")
}
