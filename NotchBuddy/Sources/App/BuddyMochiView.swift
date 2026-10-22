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
    /// Wearing the Buddy's own nightcap (BotEngine has no such outfit).
    var nightcap = false
    /// Its shadow's opacity (BuddyShadow), 0 for none.
    var shadow: Double = 0
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
                    companions.draw(ctx, canvas: canvas, square: inner, shadow: viewState.shadow)
                }
                BuddyMochiView.drawShadow(engine, in: ctx, square: inner, opacity: viewState.shadow)
                // Hover: 1.07 about the square's centre, eased (as DesktopBotView's spring, roughly).
                let target: CGFloat = viewState.isHovered ? 1 : 0
                viewState.hoverLevel += (target - viewState.hoverLevel) * 0.3
                let k = 1 + 0.07 * viewState.hoverLevel
                var c = ctx
                c.translateBy(x: inner.midX, y: inner.midY)
                c.scaleBy(x: k, y: k)
                c.translateBy(x: -inner.midX, y: -inner.midY)
                BuddyMochiView.draw(engine, in: c, square: inner, nightcap: viewState.nightcap)
            }
        }
    }

    /// One frame of Mochi in `square`, layered as DesktopBotView does (rigid roll with an outfit).
    static func draw(_ engine: BotEngine, in ctx: GraphicsContext, square: CGRect, nightcap: Bool = false) {
        let size = square.size
        var c = ctx
        c.translateBy(x: square.minX, y: square.minY)
        engine.applyDance(&c, size: size)
        let wearing = (engine.outfit != .none && engine.outfitPresence > 0.05) || nightcap
        if wearing && abs(engine.roll) > 0.001 {
            let center = engine.bodyCenter(size: size)
            var rigid = c
            rigid.translateBy(x: center.x, y: center.y)
            rigid.rotate(by: .radians(engine.roll))
            rigid.translateBy(x: -center.x, y: -center.y)
            drawBody(engine, rigid, size, nightcap: nightcap)
        } else {
            drawBody(engine, c, size, nightcap: nightcap)
        }
        engine.drawHandsAndExtras(context: c, size: size)
    }

    private static func drawBody(_ engine: BotEngine, _ ctx: GraphicsContext, _ size: CGSize, nightcap: Bool) {
        engine.drawHandsBehind(context: ctx, size: size)
        engine.drawOutfitBehind(context: ctx, size: size)
        engine.draw(context: ctx, size: size)
        engine.drawOutfitFront(context: ctx, size: size)
        if nightcap { BuddyNightcap.draw(engine, in: ctx, size: size) }
    }

    /// On the floor under the body; smaller and lighter as Mochi jumps (oy < 0 is up, in R).
    static func drawShadow(_ engine: BotEngine, in ctx: GraphicsContext, square: CGRect, opacity: Double) {
        guard opacity > 0 else { return }
        let lift = max(0, -engine.oy) * 0.3
        let e = BuddyShadow.ellipse(square: square, lift: lift)
        let r = e.rect.offsetBy(dx: engine.ox * square.width * 0.3, dy: 0)
        ctx.fill(Path(ellipseIn: r), with: .radialGradient(
            Gradient(colors: [.black.opacity(opacity * e.fade), .black.opacity(0)]),
            center: CGPoint(x: r.midX, y: r.midY), startRadius: 0, endRadius: r.width / 2))
    }
}

/// The Buddy's pajamas: a soft striped nightcap with a pompom, flopping to one side. Drawn in
/// Mochi's body space (BotEngine's centre, tilt and squash, as the shared outfits are), so it
/// follows bounces, squashes and the head's turn.
@MainActor
enum BuddyNightcap {
    static func draw(_ engine: BotEngine, in ctx: GraphicsContext, size: CGSize) {
        let R = size.width * 0.3, rx = R * 1.14, ry = R * 0.88
        let center = engine.bodyCenter(size: size)
        let c = outfitBodyTransform(context: ctx, cx: center.x, cy: center.y, tilt: engine.tilt, sx: engine.sx, sy: engine.sy)
        let turn = engine.yaw * rx * 0.22            // the cap turns with the head
        let brimY = -ry * 0.6, brimL = -rx * 0.84 + turn, brimR = rx * 0.84 + turn
        let tip = CGPoint(x: rx * 1.08 + turn * 1.3, y: -ry * 0.5)

        // The cap, one outline that never crosses itself: up the left side, over the crown,
        // flopping down to the right to the pompom, back in, down to the brim.
        var cap = Path()
        cap.move(to: CGPoint(x: brimL, y: brimY))
        cap.addCurve(to: CGPoint(x: turn + rx * 0.1, y: -ry * 1.45),
                     control1: CGPoint(x: brimL - rx * 0.02, y: -ry * 1.1),
                     control2: CGPoint(x: turn - rx * 0.45, y: -ry * 1.45))
        cap.addCurve(to: tip,
                     control1: CGPoint(x: turn + rx * 0.62, y: -ry * 1.45),
                     control2: CGPoint(x: tip.x - rx * 0.05, y: tip.y - ry * 0.7))
        cap.addCurve(to: CGPoint(x: turn + rx * 0.55, y: -ry * 0.95),
                     control1: CGPoint(x: tip.x - rx * 0.12, y: tip.y - ry * 0.2),
                     control2: CGPoint(x: turn + rx * 0.7, y: -ry * 0.92))
        cap.addQuadCurve(to: CGPoint(x: brimR, y: brimY), control: CGPoint(x: brimR + rx * 0.02, y: -ry * 0.82))
        cap.addQuadCurve(to: CGPoint(x: brimL, y: brimY), control: CGPoint(x: turn, y: brimY - ry * 0.22))
        cap.closeSubpath()
        c.fill(cap, with: .linearGradient(
            Gradient(colors: [Color(hex: "#9CC0F2"), Color(hex: "#5B86D6")]),
            startPoint: CGPoint(x: turn, y: -ry * 1.45), endPoint: CGPoint(x: turn, y: brimY)))

        // Pajama stripes, inside the cap.
        var stripes = c
        stripes.clip(to: cap)
        for i in 0..<5 {
            let y = brimY - ry * (0.18 + CGFloat(i) * 0.17)
            var band = Path()
            band.move(to: CGPoint(x: -rx * 1.4, y: y))
            band.addQuadCurve(to: CGPoint(x: rx * 1.4, y: y + ry * 0.1), control: CGPoint(x: 0, y: y - ry * 0.12))
            stripes.stroke(band, with: .color(.white.opacity(0.55)), lineWidth: ry * 0.06)
        }

        // The brim: a soft white band across the head.
        var brim = Path()
        brim.move(to: CGPoint(x: brimL - rx * 0.03, y: brimY))
        brim.addQuadCurve(to: CGPoint(x: brimR + rx * 0.03, y: brimY), control: CGPoint(x: turn, y: brimY - ry * 0.2))
        c.stroke(brim, with: .color(Color(hex: "#F4F7FD")), style: StrokeStyle(lineWidth: ry * 0.2, lineCap: .round))

        // The pompom.
        let r = ry * 0.2
        c.fill(Path(ellipseIn: CGRect(x: tip.x - r, y: tip.y - r, width: r * 2, height: r * 2)),
               with: .radialGradient(Gradient(colors: [.white, Color(hex: "#DCE4F2")]),
                                     center: CGPoint(x: tip.x - r * 0.3, y: tip.y - r * 0.3), startRadius: 0, endRadius: r * 1.2))
    }
}

/// A still Mochi in an outfit and a colour: one frame, no timer (the outfit and colour pickers).
struct BuddyMochiThumb: View {
    var outfit: BuddyOutfit = .none
    var color: String = ""

    var body: some View {
        Canvas { ctx, size in
            // Posed as MochiStill poses its engine: idle, eyes open, looking ahead.
            let engine = BotEngine()
            engine.state = .idle
            engine.cfg = BotStates[.idle]!
            engine.open = 1
            engine.bodyColor = color.isEmpty ? nil : cgColorFromHex(color)
            engine.setOutfit(outfit.engineOutfit ?? .none, animated: false)
            let s = min(size.width, size.height / (1 + BuddyInsets.mochi.top))
            let square = CGRect(x: (size.width - s) / 2, y: size.height - s, width: s, height: s)
            BuddyMochiView.draw(engine, in: ctx, square: square, nightcap: outfit == .nightcap)
        }
    }
}
#endif
