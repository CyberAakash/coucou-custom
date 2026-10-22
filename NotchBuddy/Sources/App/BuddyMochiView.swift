#if !APPSTORE
import SwiftUI

// coucou-custom fork: the Buddy's Mochi — its own BotEngine, never the notch's. The view only
// draws; the owner (BuddyController on the desktop, the preview in Settings) sets the engine's
// state, look, outfit and colour.

/// What the Buddy's drawing needs from its owner each frame.
@MainActor
final class BuddyViewState: ObservableObject {
    /// Stop drawing (screen asleep or locked).
    @Published var paused = false
    /// Under the cursor: a little bigger.
    @Published var isHovered = false
    /// 0…1, eased toward `isHovered` frame by frame (drawn in the canvas, so only Mochi grows,
    /// not its companions).
    var hoverLevel: CGFloat = 0
}

/// Mochi drawn as the desktop Mochi is (DesktopBotView), but in a square inside a bigger canvas so
/// hats, emotes, "zZ" and the hover scale that reach past the square show (BuddyInsets), with its
/// companions on each side.
struct BuddyMochiView: View {
    let engine: BotEngine
    @ObservedObject var viewState: BuddyViewState
    /// Mochi's square in the view (y down).
    let inner: CGRect
    /// The view's size: the square, its room and the companions' strips.
    let canvas: CGSize
    var companions: BuddyCompanions? = nil

    var body: some View {
        TimelineView(.animation(paused: viewState.paused)) { timeline in
            Canvas { ctx, _ in
                _ = timeline.date   // redraw every tick (see BotCanvasView)
                MochiFrameClock.advance(engine)
                if let companions {
                    companions.step()
                    companions.draw(ctx, canvas: canvas, square: inner)
                }
                // Hover: 1.07 about the square's centre, eased (as DesktopBotView's spring, roughly).
                let target: CGFloat = viewState.isHovered ? 1 : 0
                viewState.hoverLevel += (target - viewState.hoverLevel) * 0.3
                let k = 1 + 0.07 * viewState.hoverLevel
                var c = ctx
                c.translateBy(x: inner.midX, y: inner.midY)
                c.scaleBy(x: k, y: k)
                c.translateBy(x: -inner.midX, y: -inner.midY)
                BuddyMochiView.draw(engine, in: c, square: inner)
            }
        }
    }

    /// One frame of Mochi in `square`, layered as DesktopBotView does (rigid roll with an outfit).
    static func draw(_ engine: BotEngine, in ctx: GraphicsContext, square: CGRect) {
        let size = square.size
        var c = ctx
        c.translateBy(x: square.minX, y: square.minY)
        engine.applyDance(&c, size: size)
        if engine.outfit != .none && engine.outfitPresence > 0.05 && abs(engine.roll) > 0.001 {
            let center = engine.bodyCenter(size: size)
            var rigid = c
            rigid.translateBy(x: center.x, y: center.y)
            rigid.rotate(by: .radians(engine.roll))
            rigid.translateBy(x: -center.x, y: -center.y)
            drawBody(engine, rigid, size)
        } else {
            drawBody(engine, c, size)
        }
        engine.drawHandsAndExtras(context: c, size: size)
    }

    private static func drawBody(_ engine: BotEngine, _ ctx: GraphicsContext, _ size: CGSize) {
        engine.drawHandsBehind(context: ctx, size: size)
        engine.drawOutfitBehind(context: ctx, size: size)
        engine.draw(context: ctx, size: size)
        engine.drawOutfitFront(context: ctx, size: size)
    }
}

/// A still Mochi in an outfit and a colour: one frame, no timer (the outfit and colour pickers).
struct BuddyMochiThumb: View {
    var outfit: Outfit = .none
    var color: String = ""

    var body: some View {
        Canvas { ctx, size in
            // Posed as MochiStill poses its engine: idle, eyes open, looking ahead.
            let engine = BotEngine()
            engine.state = .idle
            engine.cfg = BotStates[.idle]!
            engine.open = 1
            engine.bodyColor = color.isEmpty ? nil : cgColorFromHex(color)
            engine.setOutfit(outfit, animated: false)
            let s = min(size.width, size.height / (1 + BuddyInsets.mochi.top))
            let square = CGRect(x: (size.width - s) / 2, y: size.height - s, width: s, height: s)
            BuddyMochiView.draw(engine, in: ctx, square: square)
        }
    }
}
#endif
