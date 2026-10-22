#if !APPSTORE
import SwiftUI
import QuartzCore

// coucou-custom fork: the little Mochis around the Buddy — the Coucou window banner's mini Mochis
// (HubMochiTroupe: they walk, stop, do a little something, say hello when they meet). They start
// right beside the Buddy and roam the whole stage (BuddyCompanionLayout.roam on each side),
// crossing behind it, running, jumping, visiting it. They nap and cheer with it.

@MainActor
final class BuddyCompanions {
    @MainActor final class Mini {
        let engine = BotEngine()
        /// Its centre's x in the window, in points.
        var x: CGFloat
        var target: CGFloat
        /// Points per second.
        var speed: CGFloat = 40
        var restUntil: Double
        var hop: CGFloat = 0
        var lastHello: Double = 0
        /// A jump in progress: when it started and how long it lasts.
        var jumpStart: Double = 0
        var jumpLength: Double = 0
        var jumpHeight: CGFloat = 0

        init(x: CGFloat, color: String) {
            self.x = x
            target = x
            restUntil = CACurrentMediaTime() + Double.random(in: 0.8...3)
            engine.isMini = true
            engine.bodyColor = color.isEmpty ? nil : cgColorFromHex(color)
        }

        func lift(now: Double, size: CGFloat) -> CGFloat {
            var l = abs(sin(hop)) * size * 0.07
            if now < jumpStart + jumpLength {
                let t = CGFloat((now - jumpStart) / jumpLength)
                l += 4 * t * (1 - t) * jumpHeight   // a parabola
            }
            return l
        }
    }

    let layout: BuddyCompanionLayout
    private(set) var minis: [Mini] = []
    private(set) var napping = false
    private var last = CACurrentMediaTime()
    /// The stage: the window's width, and the Buddy's body (they cross behind it).
    private let stageWidth: CGFloat
    private let buddyMidX: CGFloat

    init(layout: BuddyCompanionLayout, stageWidth: CGFloat, buddyMidX: CGFloat, colors: (Int) -> String) {
        self.layout = layout
        self.stageWidth = stageWidth
        self.buddyMidX = buddyMidX
        minis = (0..<layout.count).map { Mini(x: layout.startX($0, squareMidX: buddyMidX), color: colors($0)) }
    }

    private var minX: CGFloat { layout.size / 2 }
    private var maxX: CGFloat { stageWidth - layout.size / 2 }

    func recolor(_ colors: (Int) -> String) {
        for (i, m) in minis.enumerated() {
            let c = colors(i)
            m.engine.bodyColor = c.isEmpty ? nil : cgColorFromHex(c)
        }
    }

    /// Asleep with the Buddy: they stop where they are and close their eyes.
    func setNapping(_ on: Bool) {
        guard on != napping else { return }
        napping = on
        for m in minis {
            m.engine.setState(on ? .sleeping : .idle)
            m.hop = 0
            m.target = m.x
        }
    }

    /// What the agents just did: they jump for a finish, look up at a question, grumble at an error.
    func react(to state: BotState) {
        guard !napping else { return }
        for (i, m) in minis.enumerated() {
            let delay: TimeInterval = Double(i) * 0.12
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                switch state {
                case .finished: self.jump(m, height: 0.7); m.engine.triggerEmote(.happy, silent: true)
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
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { m.engine.triggerEmote(.wink, silent: true) }
        }
    }

    /// A party: everyone jumps and blushes, one after the other.
    func party() {
        for (i, m) in minis.enumerated() {
            let delay: TimeInterval = Double(i) * 0.15
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                if self.napping { m.engine.setState(.idle) }
                self.jump(m, height: 0.8)
                m.engine.triggerEmote(.love, silent: true)
            }
        }
    }

    /// A click on one: it blushes and jumps (as on the banner).
    func poke(_ m: Mini) {
        m.engine.triggerEmote(.love, silent: true)
        m.engine.squash()
        jump(m, height: 0.45)
        m.restUntil = CACurrentMediaTime() + 2
    }

    private func jump(_ m: Mini, height: CGFloat) {
        let now = CACurrentMediaTime()
        guard now >= m.jumpStart + m.jumpLength else { return }
        m.jumpStart = now
        m.jumpLength = 0.45 + Double(height) * 0.3
        m.jumpHeight = layout.size * height
        m.engine.squash()
    }

    // MARK: - Per frame

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
            if abs(distance) < 0.6 {
                arrive(m, now: now)
                continue
            }
            let move = min(abs(distance), m.speed * dt)
            m.x += distance > 0 ? move : -move
            m.hop += dt * (m.speed > layout.size * 2 ? 16 : 9)   // runners bob faster
        }
    }

    private func arrive(_ m: Mini, now: Double) {
        m.hop = 0
        m.restUntil = now + Double.random(in: 0.8...4)
        let w = layout.size
        switch Int.random(in: 0..<20) {
        case 0..<9:     // stroll anywhere, even to the other side
            m.target = CGFloat.random(in: minX...maxX)
            m.speed = w * CGFloat.random(in: 0.7...1.3)
        case 9..<12:    // run to a far spot
            m.target = m.x < buddyMidX ? CGFloat.random(in: max(minX, buddyMidX)...maxX)
                                       : CGFloat.random(in: minX...min(maxX, buddyMidX))
            m.speed = w * CGFloat.random(in: 2.4...3.2)
            m.restUntil = now + 0.3
        case 12..<15:   // visit the Buddy, either side of it
            let edge = layout.side * BuddyCompanionLayout.bodyHalfWidth + w * 0.45
            m.target = min(maxX, max(minX, buddyMidX + (Bool.random() ? edge : -edge)))
            m.speed = w * 1.1
        case 15..<17:   // a jump where it stands
            jump(m, height: CGFloat.random(in: 0.35...0.75))
        case 17:        m.engine.triggerEmote(.happy, silent: true)
        case 18:        m.engine.triggerEmote(.wink, silent: true)
        default:        m.engine.doRoll(duration: 900, turns: 1)
        }
        // Two meeting say hello.
        for other in minis where other !== m && abs(other.x - m.x) < w * 0.9 && now - m.lastHello > 12 {
            m.lastHello = now
            other.lastHello = now
            m.engine.triggerEmote(.love, silent: true)
            other.engine.triggerEmote(.happy, silent: true)
            break
        }
    }

    // MARK: - Drawing and hit testing (the window, y down)

    private func floorY(square: CGRect) -> CGFloat { square.minY + square.height * BuddyCompanionLayout.floor }

    /// Drawn before the Buddy: behind it when they cross.
    func draw(_ ctx: GraphicsContext, canvas: CGSize, square: CGRect, shadow: Double) {
        let w = layout.size, floor = floorY(square: square), now = CACurrentMediaTime()
        for m in minis {
            let lift = m.lift(now: now, size: w)
            if shadow > 0 {
                let k = max(0.5, 1 - lift / w)
                let sw = w * 0.52 * k, sh = w * 0.09 * k
                ctx.fill(Path(ellipseIn: CGRect(x: m.x - sw / 2, y: floor - sh / 2, width: sw, height: sh)),
                         with: .color(.black.opacity(shadow * 1.1 * Double(k))))
            }
            var c = ctx
            c.translateBy(x: m.x - w / 2, y: floor + w * 0.04 - w * 0.92 - lift)
            m.engine.draw(context: c, size: CGSize(width: w, height: w))
        }
    }

    /// The companion under `p` (the window, y down), if any.
    func hit(_ p: CGPoint, square: CGRect) -> Mini? {
        let w = layout.size, floor = floorY(square: square), now = CACurrentMediaTime()
        return minis.first { m in
            let center = CGPoint(x: m.x, y: floor - w * 0.41 - m.lift(now: now, size: w))
            return hypot(p.x - center.x, p.y - center.y) < w * 0.34
        }
    }
}
#endif
