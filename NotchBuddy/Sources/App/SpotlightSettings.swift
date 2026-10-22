import Foundation

// MARK: - SpotlightSettings (coucou-custom fork)
//
// The user's look for the notch spotlight (NotchHalo), set in Settings → Behavior → Spotlight.
// Pure Foundation so the clamping and the falloff compile into a standalone test.

enum SpotlightSettings {
    static let brightnessKey = "coucouSpotlightBrightness"
    static let sizeKey = "coucouSpotlightSize"
    static let softnessKey = "coucouSpotlightSoftness"
    static let colorModeKey = "coucouSpotlightColorMode"
    static let colorKey = "coucouSpotlightColor"
    static let motionKey = "coucouSpotlightMotion"
    static let breatheKey = "coucouSpotlightBreathe"

    static let brightnessRange: ClosedRange<Double> = 0.1...1
    static let sizeRange: ClosedRange<Double> = 0.6...1.5
    static let softnessRange: ClosedRange<Double> = 0.3...1.6
    static let defaultBrightness = 0.55
    static let defaultColor = "#A78BFA"

    enum ColorMode: String, CaseIterable {
        case byEvent, single, white
    }

    static func clamped(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Opacity along the radius (location 0 at the notch, 1 at the rim): the light lives at the
    /// notch and the outer half is only a haze. Softer spreads the light a little further out.
    static func falloff(softness: Double) -> [(location: Double, opacity: Double)] {
        let s = clamped(softness, softnessRange)
        let spread = 0.8 + 0.25 * s   // 0.875…1.2
        return [(0, 1), (0.15 * spread, 0.5), (0.4 * spread, 0.2), (0.7 * spread, 0.06), (1, 0)]
    }
}
