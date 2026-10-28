import Foundation

// MARK: - IslandCloseChord (coucou-custom fork)
//
// Close the open notch with one easy key, tapped twice, from any app: the left Control key by
// default. Flow dictation owns the right-hand modifiers and Fn (hold or double tap), Claude Code
// reads Esc Esc in its own window as rewind, and macOS takes Fn twice for dictation, so those
// are not the default; Escape stays available for setups without Claude Code. A tap counts only
// when the key goes down and up on its own (⌃C is not a tap). A single Escape typed in another
// app keeps folding ordinary views as upstream does, but never a Finished or Error card.

enum IslandCloseChord {
    static let enabledKey  = "islandCloseDoubleTap"
    static let keyKey      = "islandCloseDoubleTapKey"
    static let intervalKey = "islandCloseDoubleTapInterval"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var key: Key {
        get { UserDefaults.standard.string(forKey: keyKey).flatMap(Key.init(rawValue:)) ?? .leftControl }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: keyKey) }
    }

    /// Longest gap between the two taps, in seconds.
    static var interval: TimeInterval {
        get { UserDefaults.standard.object(forKey: intervalKey) as? Double ?? Speed.normal.interval }
        set { UserDefaults.standard.set(newValue, forKey: intervalKey) }
    }

    /// The key tapped twice. Left-hand modifiers only: Flow dictation uses the right-hand ones.
    enum Key: String, CaseIterable, Identifiable {
        case leftControl, leftOption, leftCommand, escape
        var id: String { rawValue }

        var label: String {
            switch self {
            case .leftControl: return "⌃ Control twice"
            case .leftOption:  return "⌥ Option twice"
            case .leftCommand: return "⌘ Command twice"
            case .escape:      return "⎋ Escape twice"
            }
        }

        /// NSEvent key code of the physical key.
        var keyCode: UInt16 {
            switch self {
            case .leftControl: return 59
            case .leftOption:  return 58
            case .leftCommand: return 55
            case .escape:      return 53
            }
        }

        var isModifier: Bool { self != .escape }

        /// Device-dependent modifier bit that says this very key (left, not right) is down.
        var deviceBit: UInt {
            switch self {
            case .leftControl: return 0x0001   // NX_DEVICELCTLKEYMASK
            case .leftOption:  return 0x0020   // NX_DEVICELALTKEYMASK
            case .leftCommand: return 0x0008   // NX_DEVICELCMDKEYMASK
            case .escape:      return 0
            }
        }

        var note: String? {
            switch self {
            case .escape: return "Claude Code reads Esc Esc in its own window as rewind; the double tap fires there too."
            default: return nil
            }
        }
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

/// A modifier key "tap": down, then up, with no other key pressed in between and no other
/// modifier held. Feed it the raw key events; it tells when a clean tap ended.
struct ModifierTapTracker {
    private var downAt: TimeInterval?
    private var spoiled = false

    /// The chosen key went down (`otherModifiersHeld`: ⌘ ⇧ ⌥ ⌃ other than itself were already held).
    mutating func keyDown(at time: TimeInterval, otherModifiersHeld: Bool) {
        downAt = time
        spoiled = otherModifiersHeld
    }

    /// Any other key went down while ours was held: not a tap.
    mutating func otherKeyDown() {
        if downAt != nil { spoiled = true }
    }

    /// The chosen key went up. True when it was a clean tap.
    mutating func keyUp() -> Bool {
        defer { downAt = nil; spoiled = false }
        return downAt != nil && !spoiled
    }
}
