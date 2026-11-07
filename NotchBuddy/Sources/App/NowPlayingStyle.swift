#if !APPSTORE
import AppKit
import CoreImage
import SwiftUI

// MARK: - The song's look (coucou-custom fork, phase 6)
//
// The Home card's music player takes its look from the cover: the cover blurred and darkened
// behind the card, and a wave for a progress bar whose hills are the cover's own strongest
// colours. Shared by the Spotify and Apple Music cards.

/// The cover's strongest colours, most vivid first; computed once per image.
enum ArtworkPalette {
    nonisolated(unsafe) private static var cache: [ObjectIdentifier: [NSColor]] = [:]

    static func colors(_ image: NSImage?) -> [Color] {
        nsColors(image).map(Color.init(nsColor:))
    }

    static func nsColors(_ image: NSImage?) -> [NSColor] {
        guard let image else { return [] }
        let key = ObjectIdentifier(image)
        if let hit = cache[key] { return hit }
        let result = extract(image)
        if cache.count > 24 { cache.removeAll() }
        cache[key] = result
        return result
    }

    /// 32×32 pixels into 36 hue buckets; each bucket's weight is its pixels × their vividness.
    /// Greys and near-blacks are skipped, and every colour is lifted to read on the dark card.
    private static func extract(_ image: NSImage) -> [NSColor] {
        let side = 32
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return [] }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        var buckets = [(weight: Double, h: Double, s: Double, b: Double)](repeating: (0, 0, 0, 0), count: 36)
        for y in 0..<side {
            for x in 0..<side {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                guard s > 0.22, b > 0.22 else { continue }
                let i = min(35, Int(h * 36))
                let w = Double(s * b)
                buckets[i].weight += w
                buckets[i].h += Double(h) * w
                buckets[i].s += Double(s) * w
                buckets[i].b += Double(b) * w
            }
        }
        // Neighbouring buckets are one colour: keep a bucket only where it is the local peak.
        var picks: [(Double, NSColor)] = []
        for i in 0..<36 where buckets[i].weight > 0 {
            let l = buckets[(i + 35) % 36].weight, r = buckets[(i + 1) % 36].weight
            guard buckets[i].weight >= l, buckets[i].weight >= r else { continue }
            let w = buckets[i].weight
            let color = NSColor(hue: buckets[i].h / w, saturation: min(1, buckets[i].s / w * 1.05),
                                brightness: max(0.72, buckets[i].b / w), alpha: 1)
            picks.append((w, color))
        }
        let sorted = picks.sorted { $0.0 > $1.0 }.prefix(5).map(\.1)
        return Array(sorted)
    }

    /// Never fewer than three: a cover of one colour gets that colour lighter and darker.
    static func waveColors(_ image: NSImage?, fallback: Color) -> [Color] {
        var list = nsColors(image)
        if list.isEmpty { return [fallback, fallback.opacity(0.8), fallback.opacity(0.6)] }
        while list.count < 3, let first = list.first {
            list.append(first.blended(withFraction: list.count == 1 ? 0.35 : 0.3, of: list.count == 1 ? .white : .black) ?? first)
        }
        return list.map(Color.init(nsColor:))
    }
}

/// The cover, blurred and darkened, filling the card behind everything (Mochi included). The
/// blur is made once per cover with Core Image (a live blur filter costs every frame, and is
/// lost when the card is rendered to an image).
struct NowPlayingBackdrop: View {
    let image: NSImage

    var body: some View {
        GeometryReader { geo in
            Image(nsImage: Self.blurred(image))
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: geo.size.width, height: geo.size.height)
                .overlay(Color.black.opacity(0.55))
                .clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .allowsHitTesting(false)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.6), value: image)
    }
}

extension NowPlayingBackdrop {
    nonisolated(unsafe) private static var cache: (key: ObjectIdentifier, image: NSImage)?

    static func blurred(_ image: NSImage) -> NSImage {
        let key = ObjectIdentifier(image)
        if let cache, cache.key == key { return cache.image }
        guard let tiff = image.tiffRepresentation, let input = CIImage(data: tiff) else { return image }
        // Small first: the blur hides the detail anyway, and a 120 pt-wide image blurs in a moment.
        let scale = 160 / max(input.extent.width, 1)
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blurred = small.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 9])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.2])
            .cropped(to: small.extent)
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(blurred, from: small.extent) else { return image }
        let result = NSImage(cgImage: cg, size: NSSize(width: small.extent.width, height: small.extent.height))
        cache = (key, result)
        return result
    }
}

/// The progress bar as a wave: what has played carries layered hills in the cover's colours that
/// rise and fall with the music (a gentle motion while it plays, flat while paused), the rest a
/// thin line; the dot glows in the cover's strongest colour. Click or drag to seek.
struct WaveBar: View {
    let fraction: Double
    let colors: [Color]
    let playing: Bool
    let enabled: Bool
    /// The song's length: while it plays, the bar's end moves on every frame from the last known
    /// position instead of jumping each time the card re-reads it.
    var duration: Double = 0
    let onChange: (Double) -> Void
    let onCommit: (Double) -> Void

    @State private var dragging = false
    @State private var hovering = false
    @State private var width: CGFloat = 1
    @State private var anchor: (fraction: Double, at: Date) = (0, .now)

    var body: some View {
        TimelineView(.animation(paused: !playing && !dragging)) { context in
            let now = context.date
            Canvas { ctx, size in
                draw(&ctx, size: size, t: now.timeIntervalSinceReferenceDate, f: shown(at: now))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                guard enabled else { return }
                dragging = true
                anchor = (fractionAt(v.location.x), .now)
                onChange(anchor.fraction)
            }
            .onEnded { v in
                guard enabled else { return }
                dragging = false
                anchor = (fractionAt(v.location.x), .now)
                onCommit(anchor.fraction)
            })
        .background(GeometryReader { geo in Color.clear.onAppear { width = geo.size.width }.onChange(of: geo.size.width) { _, w in width = w } })
        .onAppear { anchor = (fraction, .now) }
        .onChange(of: fraction) { _, f in if !dragging { anchor = (f, .now) } }
        .pointer()
    }

    /// The position now: the last known one, moved on by the time since, while playing.
    private func shown(at date: Date) -> Double {
        if dragging { return min(1, max(0, anchor.fraction)) }
        // Paused, or no update seen yet for this position: the position as given.
        guard playing, duration > 0, abs(anchor.fraction - fraction) < 0.000_1 else { return min(1, max(0, fraction)) }
        let moved = date.timeIntervalSince(anchor.at) / duration
        return min(1, max(0, anchor.fraction + min(moved, 2 / duration)))
    }

    private func fractionAt(_ x: CGFloat) -> Double { Double(min(1, max(0, x / max(1, width)))) }

    /// Hills on both sides of the line: each colour a few broad, slow swells, mirrored above and
    /// (a little shorter) below, drawn as smooth curves through points every 2 pt.
    private func draw(_ ctx: inout GraphicsContext, size: CGSize, t: Double, f: Double) {
        let mid = size.height / 2
        let xEnd = size.width * f
        let room = mid - 1.5
        var live = playing
        #if DEBUG
        if Self.debugPlaying { live = true }
        #endif
        let amp = live ? 1.0 : 0.45
        if xEnd > 8 {
            for (i, color) in colors.prefix(5).enumerated() {
                let k = Double(i)
                var tops: [CGPoint] = [], bottoms: [CGPoint] = []
                var x = 0.0
                while x <= xEnd {
                    let wave = sin(x / (52 + k * 15) + t * (0.45 + k * 0.1) + k * 2.1) * 0.6
                        + sin(x / (27 + k * 7) - t * (0.7 + k * 0.08) + k) * 0.4
                    let edge = min(1, x / 24) * min(1, max(0, (xEnd - x) / 28))
                    let h = (wave * 0.5 + 0.5) * room * (0.55 + 0.35 * (1 - k / 5)) * amp * edge
                    tops.append(CGPoint(x: x, y: mid - h))
                    bottoms.append(CGPoint(x: x, y: mid + h * 0.8))
                    x += 2
                }
                tops.append(CGPoint(x: xEnd, y: mid)); bottoms.append(CGPoint(x: xEnd, y: mid))
                var path = Path()
                path.move(to: CGPoint(x: 0, y: mid))
                Self.smooth(&path, tops)
                Self.smooth(&path, bottoms.reversed())
                path.closeSubpath()
                ctx.fill(path, with: .radialGradient(Gradient(colors: [color.opacity(0.85), color.opacity(0.3)]),
                                                     center: CGPoint(x: xEnd / 2, y: mid), startRadius: 0, endRadius: max(room * 2, 1)))
            }
        }
        let lineWidth: CGFloat = dragging || hovering ? 3.2 : 2.6
        var played = Path(); played.move(to: CGPoint(x: 0, y: mid)); played.addLine(to: CGPoint(x: xEnd, y: mid))
        ctx.stroke(played, with: .color(.white), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        var rest = Path(); rest.move(to: CGPoint(x: min(size.width, xEnd + 6), y: mid)); rest.addLine(to: CGPoint(x: size.width, y: mid))
        ctx.stroke(rest, with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        let dot = colors.first ?? .white
        let r: CGFloat = dragging || hovering ? 6.5 : 5
        ctx.fill(Path(ellipseIn: CGRect(x: xEnd - r * 2, y: mid - r * 2, width: r * 4, height: r * 4)), with: .color(dot.opacity(0.35)))
        ctx.fill(Path(ellipseIn: CGRect(x: xEnd - r, y: mid - r, width: r * 2, height: r * 2)), with: .color(dot))
        ctx.stroke(Path(ellipseIn: CGRect(x: xEnd - r, y: mid - r, width: r * 2, height: r * 2)), with: .color(.white), lineWidth: 2)
    }

    #if DEBUG
    /// Snapshots only: draw the hills as while a song plays.
    nonisolated(unsafe) static var debugPlaying = false
    #endif

    /// A curve through the points, each segment ending at the midpoint of the next pair.
    private static func smooth(_ path: inout Path, _ points: [CGPoint]) {
        guard let first = points.first else { return }
        path.addLine(to: first)
        for n in 1..<max(1, points.count) {
            let mid = CGPoint(x: (points[n - 1].x + points[n].x) / 2, y: (points[n - 1].y + points[n].y) / 2)
            path.addQuadCurve(to: mid, control: points[n - 1])
        }
        if let last = points.last { path.addLine(to: last) }
    }
}
#endif

#if !APPSTORE
/// The cover behind a focused music pill's card: Spotify's or Music's, while a song is loaded.
@MainActor
enum NowPlayingArt {
    static func image(for task: AgentTask?) -> NSImage? {
        switch task?.id {
        case SpotifyController.pillId?: return SpotifyController.shared.track != nil ? SpotifyController.shared.artwork : nil
        case "integration_music"?: return MusicController.shared.trackTitle != nil ? MusicController.shared.artwork : nil
        default: return nil
        }
    }
}
#endif
