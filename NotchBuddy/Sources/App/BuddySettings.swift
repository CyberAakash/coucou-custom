import Foundation
import Combine

// coucou-custom fork: Settings → Buddy. The desktop pet (its own window, apart from the notch's
// Mochi): which pet, its size and how it behaves, stored in UserDefaults.

@MainActor
final class BuddySettings: ObservableObject {
    static let shared = BuddySettings()

    /// The built-in pet: Coucou's own Mochi, drawn in code.
    static let mochiId = "mochi"

    static let enabledKey = "buddyEnabled"
    static let speechKey = "buddySpeechBubbles"
    static let spotsKey = "buddySpots"
    static let petKey = "buddyPetId"
    static let sizeKey = "buddySize"
    static let flippedKey = "buddyFlippedPets"
    static let gazeKey = "buddyCursorGaze"
    static let relaxedWaitingKey = "buddyRelaxedWaiting"
    static let overridesKey = "buddyReactionOverrides"

    private let defaults: UserDefaults

    /// The Buddy is on the desktop.
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Self.enabledKey) } }
    /// It says a short line when a permission or a question waits, or something fails.
    @Published var speechBubbles: Bool { didSet { defaults.set(speechBubbles, forKey: Self.speechKey) } }
    /// Where it stands, per display (BuddyPlacement).
    var spots: [BuddySpot] {
        get {
            guard let d = defaults.data(forKey: Self.spotsKey) else { return [] }
            return (try? JSONDecoder().decode([BuddySpot].self, from: d)) ?? []
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.spotsKey) }
    }

    /// Which pet is on the desktop: `mochiId` or an installed pet's id.
    @Published var petId: String { didSet { defaults.set(petId, forKey: Self.petKey) } }
    @Published var size: BuddySize { didSet { defaults.set(size.rawValue, forKey: Self.sizeKey) } }
    /// Ids of the pets drawn mirrored (OpenPets keeps the flip per pet).
    @Published var flippedPets: Set<String> {
        didSet { defaults.set(flippedPets.sorted(), forKey: Self.flippedKey) }
    }
    /// V2 pets look at the cursor while idle.
    @Published var cursorGaze: Bool { didSet { defaults.set(cursorGaze, forKey: Self.gazeKey) } }
    /// OpenPets' "Relaxed" waiting animation (2.2 s instead of 1.01 s).
    @Published var relaxedWaiting: Bool { didSet { defaults.set(relaxedWaiting, forKey: Self.relaxedWaitingKey) } }
    /// Reaction → animation, only where it differs from the default.
    @Published var reactionOverrides: [String: String] {
        didSet {
            let n = BuddyReaction.normalized(reactionOverrides)
            if n != reactionOverrides { reactionOverrides = n; return }
            defaults.set(n, forKey: Self.overridesKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: Self.enabledKey) == nil ? true : defaults.bool(forKey: Self.enabledKey)
        speechBubbles = defaults.object(forKey: Self.speechKey) == nil ? true : defaults.bool(forKey: Self.speechKey)
        petId = defaults.string(forKey: Self.petKey) ?? Self.mochiId
        size = defaults.object(forKey: Self.sizeKey) == nil ? .medium : BuddySize.from(stored: defaults.double(forKey: Self.sizeKey))
        flippedPets = Set(defaults.stringArray(forKey: Self.flippedKey) ?? [])
        cursorGaze = defaults.object(forKey: Self.gazeKey) == nil ? true : defaults.bool(forKey: Self.gazeKey)
        relaxedWaiting = defaults.bool(forKey: Self.relaxedWaitingKey)
        reactionOverrides = BuddyReaction.normalized(defaults.dictionary(forKey: Self.overridesKey) as? [String: String] ?? [:])
    }

    var isMochi: Bool { petId == Self.mochiId }

    func isFlipped(_ id: String) -> Bool { flippedPets.contains(id) }

    func setFlipped(_ id: String, _ on: Bool) {
        if on { flippedPets.insert(id) } else { flippedPets.remove(id) }
    }

    func animation(for reaction: BuddyReaction) -> BuddyAnimation {
        reaction.animation(overrides: reactionOverrides)
    }

    func setAnimation(_ a: BuddyAnimation, for reaction: BuddyReaction) {
        var o = reactionOverrides
        o[reaction.rawValue] = a.rawValue
        reactionOverrides = o
    }

    func resetReactions() { reactionOverrides = [:] }
}
