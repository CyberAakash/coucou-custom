#if !APPSTORE
import SwiftUI

// coucou-custom fork: an OpenPets / Codex pet drawn on the desktop in place of Mochi. The cell
// comes from the controller's BuddyAnimator, so what is drawn is what the click-through tests.

/// A pet loaded for the desktop: its package, decoded atlas and animation state.
@MainActor
final class BuddyLoadedPet {
    let entry: BuddyPetEntry
    let atlas: BuddyAtlas
    let animator = BuddyAnimator()
    /// The V2 gaze direction to show while idle, set by the controller's poll.
    var gaze: Int?

    init(entry: BuddyPetEntry, atlas: BuddyAtlas) {
        self.entry = entry
        self.atlas = atlas
    }

    /// The selected pet, decoded; nil for Mochi or when the pet is gone or unreadable.
    static func load(id: String) -> BuddyLoadedPet? {
        guard id != BuddySettings.mochiId, let entry = BuddyPetStore.shared.pet(id: id) else { return nil }
        do {
            return BuddyLoadedPet(entry: entry, atlas: try BuddyAtlas.load(url: entry.spritesheetURL,
                                                                           layout: entry.manifest.layout))
        } catch {
            appendAppLog("buddy.log", "\(escapedForLog(id)) not loaded: \(escapedForLog("\(error)"))")
            return nil
        }
    }
}

struct BuddyPetView: View {
    let pet: BuddyLoadedPet
    @ObservedObject var viewState: DesktopBotViewState

    var body: some View {
        // Cells change at most every ~90 ms (running-right): 15 fps is enough, 5 asleep.
        TimelineView(.animation(minimumInterval: viewState.isSleeping ? 1.0 / 5 : 1.0 / 15,
                                paused: viewState.paused)) { timeline in
            Canvas { ctx, size in
                let c = pet.animator.cell(now: timeline.date, gaze: pet.gaze)
                guard let img = pet.atlas.cell(row: c.row, column: c.column) else { return }
                var g = ctx
                if pet.animator.flipped {
                    g.translateBy(x: size.width, y: 0)
                    g.scaleBy(x: -1, y: 1)
                }
                g.draw(Image(decorative: img, scale: 1),
                       in: BuddySpriteGeometry.spriteRect(panelSide: min(size.width, size.height)))
            }
        }
        .scaleEffect(viewState.isHovered ? 1.05 : 1.0, anchor: .bottom)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: viewState.isHovered)
    }
}
#endif
