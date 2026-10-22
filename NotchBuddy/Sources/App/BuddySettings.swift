import Foundation
import Combine

// coucou-custom fork: Settings → Buddy. The desktop Buddy is a Mochi of its own, apart from the
// notch's: its own look (outfit, colour, size) and behaviour, stored in UserDefaults.

@MainActor
final class BuddySettings: ObservableObject {
    static let shared = BuddySettings()

    static let enabledKey = "buddyEnabled"
    static let sizeKey = "buddySize"
    static let outfitKey = "buddyOutfit"
    static let colorKey = "buddyColor"
    static let reactKey = "buddyReactToAgents"
    static let speechKey = "buddySpeechBubbles"
    static let followKey = "buddyFollowCursor"
    static let napKey = "buddyNapWhenIdle"
    static let spotsKey = "buddySpots"

    /// Body colours offered in Settings ("" is Mochi's own); the Flow window's palette.
    static let colors = ["", "#F5F6F8", "#FB923C", "#F472B6", "#A78BFA", "#3B9EFF", "#22D3EE", "#34D399", "#F7B32B"]

    private let defaults: UserDefaults

    /// The Buddy is on the desktop.
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Self.enabledKey) } }
    @Published var size: BuddySize { didSet { defaults.set(size.rawValue, forKey: Self.sizeKey) } }
    /// Its own outfit: the notch's wardrobe does not dress it.
    @Published var outfit: Outfit { didSet { defaults.set(outfit.rawValue, forKey: Self.outfitKey) } }
    /// Body colour as "#RRGGBB", or "" for Mochi's own.
    @Published var color: String { didSet { defaults.set(color, forKey: Self.colorKey) } }
    /// It plays what your agents do (thinking, working, waiting, done); off, it just hangs out.
    @Published var reactToAgents: Bool { didSet { defaults.set(reactToAgents, forKey: Self.reactKey) } }
    /// It says a short line when a permission or a question waits, or something fails.
    @Published var speechBubbles: Bool { didSet { defaults.set(speechBubbles, forKey: Self.speechKey) } }
    /// Its eyes follow the cursor.
    @Published var followCursor: Bool { didSet { defaults.set(followCursor, forKey: Self.followKey) } }
    /// It naps after two quiet minutes with the cursor away.
    @Published var napWhenIdle: Bool { didSet { defaults.set(napWhenIdle, forKey: Self.napKey) } }
    /// Where it stands, per display (BuddyPlacement).
    var spots: [BuddySpot] {
        get {
            guard let d = defaults.data(forKey: Self.spotsKey) else { return [] }
            return (try? JSONDecoder().decode([BuddySpot].self, from: d)) ?? []
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.spotsKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ key: String, default value: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
        }
        enabled = bool(Self.enabledKey, default: true)
        size = defaults.object(forKey: Self.sizeKey) == nil ? .medium : BuddySize.from(stored: defaults.double(forKey: Self.sizeKey))
        outfit = defaults.string(forKey: Self.outfitKey).flatMap(Outfit.init(rawValue:)) ?? .auto
        let c = defaults.string(forKey: Self.colorKey) ?? ""
        color = Self.colors.contains(c) ? c : ""
        reactToAgents = bool(Self.reactKey, default: true)
        speechBubbles = bool(Self.speechKey, default: true)
        followCursor = bool(Self.followKey, default: true)
        napWhenIdle = bool(Self.napKey, default: true)
    }

    /// The outfit worn today ("Auto" follows the seasons, as the notch's).
    func resolvedOutfit(on date: Date = .now) -> Outfit {
        Outfit.resolved(selection: outfit, date: date, calendar: .current)
    }
}
