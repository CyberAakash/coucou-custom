import Foundation
import Combine

// coucou-custom fork: Settings → Buddy. What the desktop pet is and how it behaves, stored in
// UserDefaults. Defaults reproduce the desktop Mochi as it was: Mochi, Medium (120 pt).

@MainActor
final class BuddySettings: ObservableObject {
    static let shared = BuddySettings()

    /// The built-in pet: Coucou's own Mochi, drawn in code.
    static let mochiId = "mochi"

    static let petKey = "buddyPetId"
    static let sizeKey = "buddySize"
    static let flippedKey = "buddyFlippedPets"
    static let gazeKey = "buddyCursorGaze"
    static let relaxedWaitingKey = "buddyRelaxedWaiting"
    static let overridesKey = "buddyReactionOverrides"

    private let defaults: UserDefaults

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
