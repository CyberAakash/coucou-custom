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
        case minimal = 44, standard = 80, wide = 120
        var id: Int { rawValue }
        var label: String {
            switch self {
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

    static var wing: CGFloat {
        CGFloat(Wing(rawValue: UserDefaults.standard.integer(forKey: wingKey))?.rawValue ?? Wing.standard.rawValue)
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
