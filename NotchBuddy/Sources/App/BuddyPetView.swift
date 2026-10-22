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
    /// The pet's square in the view (y down); the rest of the view is room for hover.
    let inner: CGRect

    var body: some View {
        // Cells change at most every ~90 ms (running-right): 15 fps is enough, 5 asleep.
        TimelineView(.animation(minimumInterval: viewState.isSleeping ? 1.0 / 5 : 1.0 / 15,
                                paused: viewState.paused)) { timeline in
            Canvas { ctx, _ in
                let c = pet.animator.cell(now: timeline.date, gaze: pet.gaze)
                guard let img = pet.atlas.cell(row: c.row, column: c.column) else { return }
                var g = ctx
                g.translateBy(x: inner.minX, y: inner.minY)
                if pet.animator.flipped {
                    g.translateBy(x: inner.width, y: 0)
                    g.scaleBy(x: -1, y: 1)
                }
                g.draw(Image(decorative: img, scale: 1), in: BuddySpriteGeometry.spriteRect(panelSide: inner.width))
            }
        }
        .scaleEffect(viewState.isHovered ? 1.05 : 1.0, anchor: anchor(x: inner.midX, y: inner.maxY))
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: viewState.isHovered)
    }

    private func anchor(x: CGFloat, y: CGFloat) -> UnitPoint {
        let size = BuddyInsets.pet.panelSize(side: inner.width)
        return UnitPoint(x: x / size.width, y: y / size.height)
    }
}

/// The Buddy's own Mochi: drawn as DesktopBotView draws the desktop Mochi, but in a square inside a
/// bigger canvas, so hats, emotes, "zZ" and the hover scale that reach past the square show.
struct BuddyMochiView: View {
    @ObservedObject var appState: AppState
    let engine: BotEngine
    @ObservedObject var viewState: DesktopBotViewState
    /// Mochi's square in the view (y down).
    let inner: CGRect

    var body: some View {
        TimelineView(.animation(paused: viewState.paused)) { timeline in
            Canvas { ctx, _ in
                _ = timeline.date   // force redraw every tick (see BotCanvasView)
                engine.lookX = tanh((appState.mousePosition.x - viewState.lookOrigin.x) / 260)
                engine.lookY = -tanh((appState.mousePosition.y - viewState.lookOrigin.y) / 200)
                engine.moodTarget = MachineVitals.shared.mood
                engine.setOutfit(appState.resolvedOutfit, animated: true)
                // Dance when music plays (same rules as the desktop Mochi)
                let music = appState.musicPlaying && appState.activeIntegrations.contains("integration_music")
                let spotify = SpotifyController.shared.isPlaying && appState.activeIntegrations.contains(SpotifyController.pillId)
                let allowed: Set<BotState> = [.idle, .working, .thinking, .searching, .finished]
                engine.setDancing((music || spotify) && allowed.contains(appState.effectiveState))
                MochiFrameClock.advance(engine)

                let size = inner.size
                var c = ctx
                c.translateBy(x: inner.minX, y: inner.minY)
                engine.applyDance(&c, size: size)
                if engine.outfit != .none && engine.outfitPresence > 0.05 && abs(engine.roll) > 0.001 {
                    let center = engine.bodyCenter(size: size)
                    var rigid = c
                    rigid.translateBy(x: center.x, y: center.y)
                    rigid.rotate(by: .radians(engine.roll))
                    rigid.translateBy(x: -center.x, y: -center.y)
                    engine.drawHandsBehind(context: rigid, size: size)
                    engine.drawOutfitBehind(context: rigid, size: size)
                    engine.draw(context: rigid, size: size)
                    engine.drawOutfitFront(context: rigid, size: size)
                } else {
                    engine.drawHandsBehind(context: c, size: size)
                    engine.drawOutfitBehind(context: c, size: size)
                    engine.draw(context: c, size: size)
                    engine.drawOutfitFront(context: c, size: size)
                }
                engine.drawHandsAndExtras(context: c, size: size)
            }
        }
        .scaleEffect(viewState.isHovered ? 1.07 : 1.0, anchor: anchor)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: viewState.isHovered)
        .onChange(of: appState.effectiveState) { _, newState in
            engine.setState(viewState.isSleeping ? .sleeping : newState)
        }
        .onAppear {
            engine.setState(viewState.isSleeping ? .sleeping : appState.effectiveState, force: true)
            engine.setOutfit(appState.resolvedOutfit, animated: false)
        }
    }

    /// The square's centre, as DesktopBotView scales about its (square) view's centre.
    private var anchor: UnitPoint {
        let size = BuddyInsets.mochi.panelSize(side: inner.width)
        return UnitPoint(x: inner.midX / size.width, y: inner.midY / size.height)
    }
}
#endif
