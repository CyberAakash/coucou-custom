#if !APPSTORE
import SwiftUI

// coucou-custom fork: how high the Buddy really reaches — its head, or the top of its hat — so
// what sits over it (the HUD) can sit just above, whatever it wears.

@MainActor
enum BuddyHeadroom {
    private static var cache: [BuddyOutfit: CGFloat] = [:]

    /// The top of Mochi and his outfit, standing still, in sides above the square's bottom
    /// (about 0.75 bare; a crown or a party hat reaches past 1). Measured once per outfit by
    /// drawing him and finding the first row that is not transparent.
    static func top(_ outfit: BuddyOutfit) -> CGFloat {
        if let hit = cache[outfit] { return hit }
        let side: CGFloat = 200
        let room = side * BuddyInsets.mochi.top
        let view = Canvas { ctx, size in
            let engine = BotEngine()
            engine.state = .idle
            engine.cfg = BotStates[.idle]!
            engine.open = 1
            engine.setOutfit(outfit.engineOutfit ?? .none, animated: false)
            BuddyMochiView.draw(engine, in: ctx, square: CGRect(x: 0, y: room, width: side, height: side),
                                nightcap: outfit == .nightcap)
        }
        .frame(width: side, height: side + room)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        var value: CGFloat = 0.78
        if let image = renderer.cgImage, let row = firstOpaqueRow(image) {
            value = (CGFloat(image.height) - CGFloat(row)) / side
        }
        cache[outfit] = value
        return value
    }

    private static func firstOpaqueRow(_ image: CGImage) -> Int? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let base = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = base.bindMemory(to: UInt8.self, capacity: w * h * 4)
        // The bitmap's first row in memory is the image's top row.
        for y in 0..<h {
            for x in 0..<w where px[(y * w + x) * 4 + 3] > 24 { return y }
        }
        return nil
    }
}
#endif
