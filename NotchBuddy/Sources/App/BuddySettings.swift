import Foundation
import Combine

// coucou-custom fork: Settings → Buddy. The desktop Buddy is a Mochi of its own, apart from the
// notch's: its own look (outfit, colour, size) and behaviour, stored in UserDefaults.

@MainActor
final class BuddySettings: ObservableObject {
    static let shared = BuddySettings()

    static let enabledKey = "buddyEnabled"
    /// Read once to carry an older preset over: the size is stored under sizeScaleKey.
    static let sizeKey = "buddySize"
    static let sizeScaleKey = "buddySizeScale"
    static let outfitKey = "buddyOutfit"
    static let colorKey = "buddyColor"
    static let reactKey = "buddyReactToAgents"
    static let speechKey = "buddySpeechBubbles"
    static let followKey = "buddyFollowCursor"
    static let napKey = "buddyNapWhenIdle"
    static let spotsKey = "buddySpots"
    static let companionsKey = "buddyCompanions"
    static let companionsMatchKey = "buddyCompanionsMatch"
    static let companionSideKey = "buddyCompanionSide"
    static let scheduleKey = "buddyWardrobeSchedule"
    /// Read once to carry an older preset over: the shadow is stored under shadowOpacityKey.
    static let shadowKey = "buddyShadow"
    static let shadowOpacityKey = "buddyShadowOpacity"
    static let clicksKey = "buddyClicks"

    private let defaults: UserDefaults

    /// The Buddy is on the desktop.
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Self.enabledKey) } }
    /// Any scale in BuddySize.customRange; the presets are shortcuts to some of them.
    @Published var sizeScale: Double {
        didSet {
            let n = min(max(sizeScale, BuddySize.customRange.lowerBound), BuddySize.customRange.upperBound)
            if n != sizeScale { sizeScale = n; return }
            defaults.set(sizeScale, forKey: Self.sizeScaleKey)
        }
    }
    /// Its wardrobe (its own: the notch's does not dress it). "Always wear" this outfit; nil follows
    /// the schedule ("Automatic"). Stored under the old outfit key: "auto" is Automatic.
    @Published var alwaysWear: BuddyOutfit? {
        didSet { defaults.set(alwaysWear?.rawValue ?? "auto", forKey: Self.outfitKey) }
    }
    /// The user's schedule; nil follows the Buddy's own (BuddyWardrobe.defaultSchedule). An empty
    /// one is meaningful: never change on its own.
    @Published var userSchedule: [BuddyWardrobeRule]? {
        didSet {
            if let s = userSchedule, let d = BuddyWardrobe.encode(s) { defaults.set(d, forKey: Self.scheduleKey) }
            else { defaults.removeObject(forKey: Self.scheduleKey) }
        }
    }
    /// Any opacity in BuddyShadow.customRange; the presets are shortcuts to some of them.
    @Published var shadowOpacity: Double {
        didSet {
            let n = min(max(shadowOpacity, BuddyShadow.customRange.lowerBound), BuddyShadow.customRange.upperBound)
            if n != shadowOpacity { shadowOpacity = n; return }
            defaults.set(shadowOpacity, forKey: Self.shadowOpacityKey)
        }
    }
    /// What each click gesture does.
    @Published var clicks: [BuddyGesture: BuddyClickBinding] {
        didSet {
            let byName = Dictionary(uniqueKeysWithValues: clicks.map { ($0.key.rawValue, $0.value) })
            defaults.set(try? JSONEncoder().encode(byName), forKey: Self.clicksKey)
        }
    }
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
    /// Which side of the Buddy they keep to.
    @Published var companionSide: BuddyCompanionSide {
        didSet { defaults.set(companionSide.rawValue, forKey: Self.companionSideKey) }
    }
    /// The companions take the Buddy's colour; otherwise each has one of the window's palette.
    @Published var companionsMatch: Bool { didSet { defaults.set(companionsMatch, forKey: Self.companionsMatchKey) } }
    /// It plays what your agents do (thinking, working, waiting, done); off, it just hangs out.
    @Published var reactToAgents: Bool { didSet { defaults.set(reactToAgents, forKey: Self.reactKey) } }
    /// It says a short line when a permission or a question waits, or something fails.
    @Published var speechBubbles: Bool { didSet { defaults.set(speechBubbles, forKey: Self.speechKey) } }
    /// Its eyes follow the cursor.
    @Published var followCursor: Bool { didSet { defaults.set(followCursor, forKey: Self.followKey) } }
    /// It naps when you are idle (BuddyNap).
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
        let preset = defaults.object(forKey: Self.sizeKey) == nil ? BuddySize.medium : BuddySize.from(stored: defaults.double(forKey: Self.sizeKey))
        sizeScale = min(max(defaults.object(forKey: Self.sizeScaleKey) as? Double ?? preset.rawValue,
                            BuddySize.customRange.lowerBound), BuddySize.customRange.upperBound)
        let worn = defaults.string(forKey: Self.outfitKey) ?? "auto"
        alwaysWear = worn == "auto" ? nil : BuddyOutfit(rawValue: worn)
        userSchedule = defaults.data(forKey: Self.scheduleKey).flatMap(BuddyWardrobe.decode)
        let shade = defaults.string(forKey: Self.shadowKey).flatMap(BuddyShadow.init(rawValue:)) ?? .soft
        shadowOpacity = min(max(defaults.object(forKey: Self.shadowOpacityKey) as? Double ?? shade.opacity,
                                BuddyShadow.customRange.lowerBound), BuddyShadow.customRange.upperBound)
        var c = BuddyClickBinding.defaults
        if let d = defaults.data(forKey: Self.clicksKey),
           let byName = try? JSONDecoder().decode([String: BuddyClickBinding].self, from: d) {
            for (k, v) in byName { if let g = BuddyGesture(rawValue: k) { c[g] = v } }
        }
        clicks = c
        color = BuddyColor.normalized(defaults.string(forKey: Self.colorKey) ?? "") ?? ""
        companions = min(max(defaults.integer(forKey: Self.companionsKey), 0), BuddyCompanionLayout.maxCount)
        companionsMatch = bool(Self.companionsMatchKey, default: false)
        companionSide = defaults.string(forKey: Self.companionSideKey).flatMap(BuddyCompanionSide.init(rawValue:)) ?? .both
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

    /// The schedule in use: the user's, or the Buddy's own.
    var schedule: [BuddyWardrobeRule] { userSchedule ?? BuddyWardrobe.defaultSchedule }

    /// What it wears now.
    func resolvedOutfit(on date: Date = .now, calendar: Calendar = .current) -> BuddyOutfit {
        BuddyWardrobe.resolve(always: alwaysWear, schedule: schedule, at: date, calendar: calendar)
    }

    /// The rule wearing now, when following the schedule.
    func activeRule(on date: Date = .now, calendar: Calendar = .current) -> Int? {
        alwaysWear == nil ? BuddyWardrobe.activeRule(schedule, at: date, calendar: calendar) : nil
    }

    func binding(_ g: BuddyGesture) -> BuddyClickBinding {
        clicks[g] ?? BuddyClickBinding.defaults[g] ?? .init(action: .none)
    }

    func setBinding(_ b: BuddyClickBinding, for g: BuddyGesture) {
        var c = clicks
        c[g] = b
        clicks = c
    }

    /// Edits start from the schedule in use, so the first edit copies the Buddy's own.
    func editSchedule(_ change: (inout [BuddyWardrobeRule]) -> Void) {
        var s = schedule
        change(&s)
        userSchedule = Array(s.prefix(BuddyWardrobe.maxRules))
    }
}
