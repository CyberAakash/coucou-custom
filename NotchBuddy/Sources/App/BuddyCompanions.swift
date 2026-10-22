#if !APPSTORE
import SwiftUI
import QuartzCore

// coucou-custom fork: the little Mochis around the Buddy — the Coucou window banner's mini Mochis
// (HubMochiTroupe: they walk, stop, do a little something, say hello when they meet), on the
// Buddy's floor, half on each side (BuddyCompanionLayout). They nap with it and cheer with it.

@MainActor
final class BuddyCompanions {
    @MainActor final class Mini {
        let engine = BotEngine()
        let left: Bool
        /// Where it stands in its side's strip, 0…1.
        var x: CGFloat
        var target: CGFloat
        var speed: CGFloat = 0.06
        var restUntil: Double
        var hop: CGFloat = 0
        var lastHello: Double = 0

        init(left: Bool, start: CGFloat, color: String) {
            self.left = left
            x = start
            target = start
            restUntil = CACurrentMediaTime() + Double.random(in: 0.5...3)
            engine.isMini = true
            engine.bodyColor = color.isEmpty ? nil : cgColorFromHex(color)
        }
    }

    let layout: BuddyCompanionLayout
    private(set) var minis: [Mini] = []
    private var last = CACurrentMediaTime()
    private(set) var napping = false

    init(layout: BuddyCompanionLayout, colors: (Int) -> String) {
        self.layout = layout
        minis = (0..<layout.count).map { i in
            let slot = layout.slot(i)
            return Mini(left: slot.left, start: slot.start, color: colors(i))
        }
    }

    func recolor(_ colors: (Int) -> String) {
        for (i, m) in minis.enumerated() {
            let c = colors(i)
            m.engine.bodyColor = c.isEmpty ? nil : cgColorFromHex(c)
        }
    }

    /// Asleep with the Buddy: they stop walking and close their eyes.
    func setNapping(_ on: Bool) {
        guard on != napping else { return }
        napping = on
        for m in minis {
            m.engine.setState(on ? .sleeping : .idle)
            m.hop = 0
        }
    }

    /// What the agents just did, in a word: they cheer a finish, look up at a question.
    func react(to state: BotState) {
        guard !napping else { return }
        for (i, m) in minis.enumerated() {
            // A little out of step, as a crowd.
            let delay: TimeInterval = Double(i) * 0.12
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                switch state {
                case .finished: m.engine.triggerEmote(.happy, silent: true); m.engine.squash()
                case .approval, .question: m.engine.triggerEmote(.surprised, silent: true)
                case .error: m.engine.triggerEmote(.annoyed, silent: true)
                default: break
                }
            }
        }
    }

    /// The Buddy said hi: they wave back.
    func greet() {
        guard !napping else { return }
        for (i, m) in minis.enumerated() {
            let delay: TimeInterval = 0.15 + Double(i) * 0.1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                m.engine.triggerEmote(.wink, silent: true)
            }
        }
    }

    /// A click on one: it blushes and jumps (as on the banner).
    func poke(_ m: Mini) {
        m.engine.triggerEmote(.love, silent: true)
        m.engine.squash()
        m.restUntil = CACurrentMediaTime() + 2
    }

    // MARK: - Per frame (HubMochiTroupe's walk)

    func step() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(0.05, max(0, now - last)))
        last = now
        for m in minis {
            MochiFrameClock.advance(m.engine)
            if napping { continue }
            if now < m.restUntil {
                m.hop = max(0, m.hop - dt * 4)
                continue
            }
            let distance = m.target - m.x
            if abs(distance) < 0.004 {
                arrive(m, now: now)
                continue
            }
            let move = min(abs(distance), m.speed * dt * 2.2)   // a narrow strip: a bit quicker than the banner
            m.x += distance > 0 ? move : -move
            m.hop += dt * 9
        }
    }

    private func arrive(_ m: Mini, now: Double) {
        m.hop = 0
        m.restUntil = now + Double.random(in: 1.2...5)
        m.target = CGFloat.random(in: 0...1)
        m.speed = CGFloat.random(in: 0.035...0.08)
        switch Int.random(in: 0..<10) {
        case 0, 1: m.engine.triggerEmote(.happy, silent: true)
        case 2:    m.engine.triggerEmote(.wink, silent: true)
        case 3:    m.engine.doRoll(duration: 900, turns: 1)
        default:   break
        }
        for other in minis where other !== m && other.left == m.left && abs(other.x - m.x) < 0.18
            && now - m.lastHello > 12 {
            m.lastHello = now
            other.lastHello = now
            m.engine.triggerEmote(.love, silent: true)
            other.engine.triggerEmote(.happy, silent: true)
            break
        }
    }

    // MARK: - Where they are (canvas: the Buddy's window, y down)

    /// Each side's strip: the window's left or right `stripWidth`, standing on the Buddy's floor.
    func strip(left: Bool, canvas: CGSize, square: CGRect) -> CGRect {
        let floor = square.minY + square.height * BuddyCompanionLayout.floor
        let w = layout.stripWidth
        return CGRect(x: left ? 0 : canvas.width - w, y: floor - layout.stripHeight, width: w, height: layout.stripHeight)
    }

    private func centerX(_ m: Mini, strip: CGRect) -> CGFloat {
        let w = layout.size
        return strip.minX + w / 2 + m.x * max(0, strip.width - w)
    }

    func draw(_ ctx: GraphicsContext, canvas: CGSize, square: CGRect) {
        let w = layout.size
        for m in minis {
            let strip = strip(left: m.left, canvas: canvas, square: square)
            let cx = centerX(m, strip: strip)
            let lift = abs(sin(m.hop)) * w * 0.07
            let shadow = CGRect(x: cx - w * 0.26, y: strip.maxY - w * 0.12, width: w * 0.52, height: w * 0.09)
            ctx.fill(Path(ellipseIn: shadow), with: .color(.black.opacity(0.22 - Double(lift / w))))
            var c = ctx
            c.translateBy(x: cx - w / 2, y: strip.maxY - w * 0.92 - lift)
            m.engine.draw(context: c, size: CGSize(width: w, height: w))
        }
    }

    /// The companion under `p` (canvas, y down), if any.
    func hit(_ p: CGPoint, canvas: CGSize, square: CGRect) -> Mini? {
        let w = layout.size
        return minis.first { m in
            let strip = strip(left: m.left, canvas: canvas, square: square)
            // The body sits in the middle of its drawing, a little low (as HubMochiTroupe.poke).
            let center = CGPoint(x: centerX(m, strip: strip), y: strip.maxY - w * 0.45)
            return hypot(p.x - center.x, p.y - center.y) < w * 0.34
        }
    }
}
#endif
