#if !APPSTORE
import SwiftUI

// coucou-custom fork: Mochi as Claude Design drew it for the briefs and the panel — a soft white
// blob (a gradient with two inner shadows), two dark eyes that blink, and one of the design's moves
// (mBreath, mHop, mJoy, mLook, mPeek, mBlink in design/…/Coucou.dc.html), played from the clock
// so it costs nothing once its view is gone.

struct DesignMochi: View {
    enum Mode { case idle, peek, hop, joy, calm, once }

    let size: CGFloat
    var mode: Mode = .idle

    @State private var start = Date()

    private var period: Double {
        switch mode {
        case .hop: 1.5
        case .joy: 1.1
        case .calm: 4.5
        case .once: 1.1
        case .idle, .peek: 3.6
        }
    }

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSince(start)
            let k = mode == .once ? min(1, t / period) : (t / period).truncatingRemainder(dividingBy: 1)
            let move = Self.body(mode, k)
            let blink = Self.blink((t / (mode == .calm ? 5.5 : 4.4)).truncatingRemainder(dividingBy: 1))
            let eyes = Self.eyes(mode, t)
            ZStack {
                if size >= 60 { shadow(mode == .hop || mode == .joy || mode == .once ? Self.shadow(k) : (1, 0.5)) }
                ZStack(alignment: .top) {
                    MochiBlobShape()
                        .fill(LinearGradient(stops: [.init(color: .white, location: 0),
                                                     .init(color: Color(hex: "#F3F4F6"), location: 0.42),
                                                     .init(color: Color(hex: "#C9CBD1"), location: 1)],
                                             startPoint: .top, endPoint: .bottom)
                            .shadow(.inner(color: Color(red: 110 / 255, green: 114 / 255, blue: 128 / 255).opacity(0.35), radius: size * 0.04, y: -size * 0.05))
                            .shadow(.inner(color: .white.opacity(0.95), radius: size * 0.02, y: size * 0.03)))
                    HStack(spacing: size * 0.2) {
                        eye.scaleEffect(x: 1, y: blink, anchor: .center)
                        eye.scaleEffect(x: 1, y: blink, anchor: .center)
                    }
                    .offset(x: eyes.x * size * 0.41, y: eyes.y * size * 0.2 + size * 0.86 * 0.3)
                }
                .frame(width: size, height: size * 0.86)
                .scaleEffect(x: move.sx, y: move.sy, anchor: .bottom)
                .rotationEffect(.degrees(move.rot), anchor: .bottom)
                .offset(y: move.dy * size * 0.86)
            }
            .frame(width: size, height: size * 0.86)
        }
        .onChange(of: mode) { start = Date() }
    }

    private var eye: some View {
        Capsule().fill(Color(hex: "#1A1412")).frame(width: size * 0.105, height: size * 0.2)
    }

    private func shadow(_ s: (scale: Double, opacity: Double)) -> some View {
        Ellipse().fill(Color.black.opacity(0.55))
            .frame(width: size * 0.64, height: size * 0.09)
            .blur(radius: size * 0.04)
            .scaleEffect(s.scale)
            .opacity(s.opacity / 0.5)
            .offset(y: size * 0.86 / 2 + size * 0.08 - size * 0.045)
    }

    // MARK: The design's keyframes

    struct Move { var dy = 0.0, sx = 1.0, sy = 1.0, rot = 0.0 }

    /// Linear between keyframes, eased in and out across each, as the CSS cubic-bezier roughly does.
    static func interpolate(_ frames: [(Double, [Double])], _ k: Double) -> [Double] {
        guard let first = frames.first else { return [] }
        if k <= first.0 { return first.1 }
        for (a, b) in zip(frames, frames.dropFirst()) where k <= b.0 {
            let u = (k - a.0) / max(0.0001, b.0 - a.0)
            let e = u * u * (3 - 2 * u)
            return zip(a.1, b.1).map { $0 + ($1 - $0) * e }
        }
        return frames.last!.1
    }

    static func body(_ mode: Mode, _ k: Double) -> Move {
        switch mode {
        case .hop, .once:
            let v = interpolate([(0, [0, 1.07, 0.92]), (0.2, [-0.26, 0.94, 1.07]), (0.36, [-0.32, 1, 1]),
                                 (0.54, [0, 1.12, 0.86]), (0.66, [0, 0.96, 1.04]), (0.76, [0, 1, 1]), (1, [0, 1, 1])], k)
            return Move(dy: v[0], sx: v[1], sy: v[2])
        case .joy:
            let v = interpolate([(0, [0, 1.08, 0.9, 0]), (0.24, [-0.34, 0.9, 1.1, -7]), (0.44, [-0.38, 1, 1, 6]),
                                 (0.62, [0, 1.14, 0.86, 0]), (0.76, [0, 0.96, 1.05, 0]), (0.88, [0, 1, 1, 0]), (1, [0, 1, 1, 0])], k)
            return Move(dy: v[0], sx: v[1], sy: v[2], rot: v[3])
        case .idle, .peek, .calm:
            let v = interpolate([(0, [1, 1]), (0.5, [1.03, 0.965]), (1, [1, 1])], k)
            return Move(sx: v[0], sy: v[1])
        }
    }

    static func shadow(_ k: Double) -> (scale: Double, opacity: Double) {
        let v = interpolate([(0, [1, 0.5]), (0.2, [0.62, 0.22]), (0.36, [0.62, 0.22]), (0.54, [1.08, 0.55]), (1, [1, 0.5])], k)
        return (v[0], v[1])
    }

    static func blink(_ k: Double) -> Double {
        interpolate([(0, [1]), (0.93, [1]), (0.96, [0.08]), (1, [1])], k)[0]
    }

    /// Where the eyes look, as a share of their pair's width (x) and height (y).
    static func eyes(_ mode: Mode, _ t: Double) -> (x: Double, y: Double) {
        switch mode {
        case .idle:
            let v = interpolate([(0, [0]), (0.18, [0]), (0.24, [-0.16]), (0.44, [-0.16]), (0.5, [0.15]), (0.7, [0.15]), (0.76, [0]), (1, [0])],
                                (t / 7).truncatingRemainder(dividingBy: 1))
            return (v[0], 0)
        case .peek:
            let v = interpolate([(0, [0, 0]), (0.3, [0, 0]), (0.4, [0.14, -0.1]), (0.8, [0.14, -0.1]), (0.9, [0, 0]), (1, [0, 0])],
                                (t / 4).truncatingRemainder(dividingBy: 1))
            return (v[0], v[1])
        default:
            return (0, 0)
        }
    }
}

/// `border-radius: 42% 42% 40% 40% / 46% 46% 42% 42%`: elliptical corners, rounder on top.
struct MochiBlobShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        let tx = w * 0.42, ty = h * 0.46, bx = w * 0.40, by = h * 0.42
        let c = 0.5523   // a quarter ellipse as one cubic
        var p = Path()
        p.move(to: CGPoint(x: r.minX + tx, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - tx, y: r.minY))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.minY + ty),
                   control1: CGPoint(x: r.maxX - tx + tx * c, y: r.minY), control2: CGPoint(x: r.maxX, y: r.minY + ty - ty * c))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - by))
        p.addCurve(to: CGPoint(x: r.maxX - bx, y: r.maxY),
                   control1: CGPoint(x: r.maxX, y: r.maxY - by + by * c), control2: CGPoint(x: r.maxX - bx + bx * c, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + bx, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.minX, y: r.maxY - by),
                   control1: CGPoint(x: r.minX + bx - bx * c, y: r.maxY), control2: CGPoint(x: r.minX, y: r.maxY - by + by * c))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + ty))
        p.addCurve(to: CGPoint(x: r.minX + tx, y: r.minY),
                   control1: CGPoint(x: r.minX, y: r.minY + ty - ty * c), control2: CGPoint(x: r.minX + tx - tx * c, y: r.minY))
        p.closeSubpath()
        return p
    }
}
#endif
