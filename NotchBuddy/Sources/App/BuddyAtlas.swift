import Foundation
import CoreGraphics
import ImageIO

// coucou-custom fork: a decoded Buddy pet atlas — one CGImage per cell to draw, and the alpha
// channel kept for click-through hit testing. ImageIO only, so `scripts/test-buddy.sh` builds it.

final class BuddyAtlas {
    let layout: BuddyAtlasLayout
    let pixelWidth: Int
    let pixelHeight: Int
    /// `cells[row][column]`, rows 0..<layout.rows.
    let cells: [[CGImage]]
    /// One byte per atlas pixel, rows top to bottom.
    private let alpha: [UInt8]

    /// OpenPets `MAX_SPRITE_SHEET_PIXELS`: a bigger decoded sheet is refused.
    static let maxPixels = 32 * 1024 * 1024

    enum LoadError: Error, Equatable, CustomStringConvertible {
        case unreadable
        case tooSmall(width: Int, height: Int, needWidth: Int, needHeight: Int)
        case tooLarge

        var description: String {
            switch self {
            case .unreadable: return "The spritesheet could not be decoded."
            case let .tooSmall(w, h, nw, nh):
                return "The spritesheet is \(w) × \(h) px; this pet needs at least \(nw) × \(nh)."
            case .tooLarge: return "The spritesheet is larger than 32 megapixels."
            }
        }
    }

    init(image: CGImage, layout: BuddyAtlasLayout) throws {
        let w = image.width, h = image.height
        guard w * h <= Self.maxPixels else { throw LoadError.tooLarge }
        guard w >= layout.minimumPixelWidth, h >= layout.minimumPixelHeight else {
            throw LoadError.tooSmall(width: w, height: h,
                                     needWidth: layout.minimumPixelWidth, needHeight: layout.minimumPixelHeight)
        }
        var rows: [[CGImage]] = []
        for r in 0..<layout.rows {
            var row: [CGImage] = []
            for c in 0..<BuddyAtlasLayout.columns {
                guard let cell = image.cropping(to: BuddyAtlasLayout.cellRect(row: r, column: c)) else {
                    throw LoadError.unreadable
                }
                row.append(cell)
            }
            rows.append(row)
        }

        // RGBA because a Swift CGContext needs a colour space (alpha-only takes none); only the
        // alpha byte is kept. A bitmap context's first memory row is the image's top row.
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw LoadError.unreadable }
        var a = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) { a[i] = rgba[i * 4 + 3] }

        self.layout = layout
        self.pixelWidth = w
        self.pixelHeight = h
        self.cells = rows
        self.alpha = a
    }

    static func load(url: URL, layout: BuddyAtlasLayout) throws -> BuddyAtlas {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw LoadError.unreadable }
        // Refuse a huge sheet from its header, before decoding it.
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
           w * h > maxPixels {
            throw LoadError.tooLarge
        }
        guard let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw LoadError.unreadable }
        return try BuddyAtlas(image: img, layout: layout)
    }

    /// Atlas pixel alpha, y down; nil outside the atlas.
    func alphaAt(_ x: Int, _ y: Int) -> UInt8? {
        guard x >= 0, y >= 0, x < pixelWidth, y < pixelHeight else { return nil }
        return alpha[y * pixelWidth + x]
    }

    func cell(row: Int, column: Int) -> CGImage? {
        guard cells.indices.contains(row), cells[row].indices.contains(column) else { return nil }
        return cells[row][column]
    }
}
