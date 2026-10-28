import Foundation

// MARK: - IslandCloseChord (coucou-custom fork)
//
// Close the open notch from the keyboard while busy elsewhere: Escape twice in quick succession
// (settable), from any app, on top of the recorded "Close the notch" shortcut. A single Escape
// typed in another app keeps folding ordinary views as upstream does, but never a Finished or
// Error card you may not have seen; the double tap is the deliberate "I saw it, go away".

enum IslandCloseChord {
    static let enabledKey  = "islandCloseDoubleEscape"
    static let intervalKey = "islandCloseDoubleEscapeInterval"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Longest gap between the two taps, in seconds.
    static var interval: TimeInterval {
        get { UserDefaults.standard.object(forKey: intervalKey) as? Double ?? Speed.normal.interval }
        set { UserDefaults.standard.set(newValue, forKey: intervalKey) }
    }

    enum Speed: Double, CaseIterable, Identifiable {
        case quick = 0.3, normal = 0.45, relaxed = 0.7
        var id: Double { rawValue }
        var interval: TimeInterval { rawValue }
        var label: String {
            switch self {
            case .quick: return "Quick"
            case .normal: return "Normal"
            case .relaxed: return "Relaxed"
            }
        }
    }
}

/// Two taps of one key within `interval` make a double tap; the pair is then consumed, so three
/// quick taps are one double tap and a lone tap, not two. A pure value: tested standalone.
struct DoubleTapDetector {
    var interval: TimeInterval
    private var last: TimeInterval?

    init(interval: TimeInterval) { self.interval = interval }

    /// Feed one tap; true when it completes a double tap.
    mutating func tap(at time: TimeInterval) -> Bool {
        if let last, time - last <= interval, time >= last {
            self.last = nil
            return true
        }
        last = time
        return false
    }
}
