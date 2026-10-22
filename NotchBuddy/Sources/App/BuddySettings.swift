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
    static let companionsKey = "buddyCompanions"
    static let companionsMatchKey = "buddyCompanionsMatch"

    private let defaults: UserDefaults

    /// The Buddy is on the desktop.
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Self.enabledKey) } }
    @Published var size: BuddySize { didSet { defaults.set(size.rawValue, forKey: Self.sizeKey) } }
    /// Its own outfit: the notch's wardrobe does not dress it.
    @Published var outfit: Outfit { didSet { defaults.set(outfit.rawValue, forKey: Self.outfitKey) } }
    /// Body colour as "#RRGGBB" (any colour), or "" for Mochi's own.
    @Published var color: String {
        didSet {
            let n = color.isEmpty ? "" : (BuddyColor.normalized(color) ?? "")
            if n != color { color = n; return }
            defaults.set(color, forKey: Self.colorKey)
        }
    }
    /// Little Mochis around it (0…6), as on the Coucou window's banner.
    @Published var companions: Int {
        didSet {
            let n = min(max(companions, 0), BuddyCompanionLayout.maxCount)
            if n != companions { companions = n; return }
            defaults.set(companions, forKey: Self.companionsKey)
        }
    }
    /// The companions take the Buddy's colour; otherwise each has one of the window's palette.
    @Published var companionsMatch: Bool { didSet { defaults.set(companionsMatch, forKey: Self.companionsMatchKey) } }
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
        color = BuddyColor.normalized(defaults.string(forKey: Self.colorKey) ?? "") ?? ""
        companions = min(max(defaults.integer(forKey: Self.companionsKey), 0), BuddyCompanionLayout.maxCount)
        companionsMatch = bool(Self.companionsMatchKey, default: false)
        reactToAgents = bool(Self.reactKey, default: true)
        speechBubbles = bool(Self.speechKey, default: true)
        followCursor = bool(Self.followKey, default: true)
        napWhenIdle = bool(Self.napKey, default: true)
    }

    /// Companion `i`'s colour ("" for Mochi's own).
    func companionColor(_ i: Int) -> String {
        if companionsMatch { return color }   // "" = Mochi's own, like the Buddy
        return BuddyColor.companions[i % BuddyColor.companions.count]
    }

    /// The outfit worn today ("Auto" follows the seasons, as the notch's).
    func resolvedOutfit(on date: Date = .now) -> Outfit {
        Outfit.resolved(selection: outfit, date: date, calendar: .current)
    }
}
