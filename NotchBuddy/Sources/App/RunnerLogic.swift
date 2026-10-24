#if !APPSTORE
import Compression
import Foundation

// coucou-custom fork: the rules of the menu-bar Runner, after RunCat Neo (runcat-dev/RunCatNeo,
// Apache-2.0) — its speed curve, its frame rules, its Runner Gallery and its Custom Metrics files —
// kept free of AppKit so tests/RunnerTests.swift can run them.

// MARK: - Speed

enum RunnerSpeed {
    /// RunCat's curve: the load in percent / 5, held to 1…20, so 0–5 % ambles and 100 % sprints.
    /// "Slower under load" mirrors it (0.5 × (21 − v)), as RunCat's own switch does.
    static func speed(load: Double, slowerUnderLoad: Bool) -> Double {
        let value = max(1, min(20, load * 100 / 5))
        return slowerUnderLoad ? 0.5 * (21 - value) : value
    }

    /// At speed 1 a loop of n frames lasts n / 2 seconds (RunCat's keyframe duration).
    static let frameSeconds = 0.5

    /// The agents source: 0 working → 0, 1 → 0.5, 2 → 0.75, 3 → 0.875…
    static func agentLoad(working: Int) -> Double {
        working <= 0 ? 0 : 1 - pow(0.5, Double(working))
    }
}

/// What makes the Runner run faster.
enum RunnerSpeedSource: String, CaseIterable, Identifiable {
    case cpu, memory, agents
    var id: String { rawValue }
}

// MARK: - Frames

enum RunnerFrameRules {
    /// RunCat Neo's custom runner limits: PNG frames exactly 36 px high (18 pt in the menu bar),
    /// 10 to 100 px wide, at most 30 of them.
    static let height = 36
    static let widths = 10...100
    static let maxFrames = 30

    enum Problem: Equatable {
        case height(Int), width(Int), tooMany, notImage, empty
    }

    static func check(width: Int, height: Int) -> Problem? {
        if height != Self.height { return .height(height) }
        if !widths.contains(width) { return .width(width) }
        return nil
    }

    static func message(_ problem: Problem) -> String {
        switch problem {
        case .height(let h): "Frames must be exactly 36 px high (this one is \(h) px)."
        case .width(let w): "Frames must be 10 to 100 px wide (this one is \(w) px)."
        case .tooMany: "A runner has at most 30 frames."
        case .notImage: "Only PNG images can be frames."
        case .empty: "Add at least one frame."
        }
    }

    /// Files dropped or chosen, in frame order: "frame-2" before "frame-10", as RunCat sorts them.
    static func sorted(_ names: [String]) -> [String] {
        names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// How the frames play: straight through, or there and back (RunCat's swing).
enum RunnerPlayback: String, CaseIterable, Identifiable {
    case loop, bounce
    var id: String { rawValue }

    func order(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let forward = Array(0..<count)
        switch self {
        case .loop: return forward
        case .bounce: return count < 3 ? forward : forward + Array((1..<(count - 1)).reversed())
        }
    }

    static func detect(order: [Int], count: Int) -> RunnerPlayback {
        order == RunnerPlayback.bounce.order(count: count) && count >= 3 ? .bounce : .loop
    }
}

/// A runner made from PNG frames, stored in Application Support/NotchBuddy/Runners/<id>/frame-N.png.
/// The fields are RunCat Neo's (`id`, `name`, `isTemplate`, `frameOrder`) plus where it came from.
struct CustomRunner: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    /// Monochrome: drawn in the menu bar's own colour, from the frames' alpha only.
    var isTemplate: Bool
    var frameOrder: [Int]
    var frameCount: Int
    var author: String? = nil
    /// The Runner Gallery folder it was installed from ("border-collie").
    var galleryName: String? = nil

    /// Indices that point at a frame that exists; RunCat shows frame 0 for anything else.
    var playableOrder: [Int] {
        let valid = frameOrder.filter { (0..<frameCount).contains($0) }
        return valid.isEmpty ? Array(0..<max(frameCount, 0)) : valid
    }

    static func uniqueName(_ base: String, existing: [String]) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = trimmed.isEmpty ? "Runner" : trimmed
        let taken = Set(existing.map { $0.lowercased() })
        if !taken.contains(root.lowercased()) { return root }
        var n = 2
        while taken.contains("\(root) \(n)".lowercased()) { n += 1 }
        return "\(root) \(n)"
    }
}

// MARK: - Runner Gallery (runcat-dev/RunnerGallery)

enum RunnerGallery {
    static let site = URL(string: "https://runcat-dev.github.io/RunnerGallery/")!
    static let base = URL(string: "https://raw.githubusercontent.com/runcat-dev/RunnerGallery/main/runners/")!
    static let manifestURL = base.appendingPathComponent("manifest.json")
    /// The gallery's closed tag set (KNOWN_TAGS in its validator).
    static let tags = ["animal", "dog", "object", "mechanism", "fitness"]

    struct Manifest: Decodable { let runners: [String] }

    struct Metadata: Decodable, Equatable {
        let author: String
        let displayName: String
        let type: String
        let tags: [String]
        var isTemplate: Bool { type != "color" }
    }

    /// Lowercase words joined by hyphens, as the gallery requires. Anything else never becomes a URL.
    static func isValidName(_ name: String) -> Bool {
        name.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil && name.count <= 64
    }

    static func metadataURL(_ name: String) -> URL { base.appendingPathComponent("\(name)/metadata.json") }
    static func previewURL(_ name: String) -> URL { base.appendingPathComponent("\(name)/preview.png") }
    static func framesURL(_ name: String) -> URL { base.appendingPathComponent("\(name)/\(name)-frames.zip") }

    static func decodeManifest(_ data: Data) -> [String]? {
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
        return manifest.runners.filter(isValidName)
    }

    static func decodeMetadata(_ data: Data) -> Metadata? {
        guard data.count <= 4096 else { return nil }
        return try? JSONDecoder().decode(Metadata.self, from: data)
    }

    /// The gallery's validator makes every "dog" also an "animal", so the animal chip includes dogs.
    static func matches(_ metadata: Metadata, tag: String?, query: String) -> Bool {
        if let tag, !metadata.tags.contains(tag) { return false }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return metadata.displayName.lowercased().contains(q) || metadata.author.lowercased().contains(q)
            || metadata.tags.contains { $0.contains(q) }
    }
}

// MARK: - Zip archives (the gallery's <name>-frames.zip)

/// Reads the PNG files of a zip: stored or deflated entries, nothing else. The limits are the
/// gallery validator's own, so an archive it accepts always opens and nothing larger is inflated.
enum RunnerZip {
    static let maxArchiveBytes = 2 * 1024 * 1024
    static let maxEntries = 64
    static let maxEntryBytes = 1024 * 1024
    static let maxTotalBytes = 8 * 1024 * 1024
    static let maxRatio = 200

    enum Failure: Error, Equatable {
        case notZip, tooLarge, unsupported, corrupt, unsafeName, noFrames
    }

    struct Entry: Equatable {
        let name: String
        let data: Data
    }

    /// The PNG entries, Finder junk (__MACOSX, ._*, .DS_Store) and folders left out.
    static func pngEntries(_ archive: Data) throws -> [Entry] {
        guard archive.count <= maxArchiveBytes else { throw Failure.tooLarge }
        let bytes = [UInt8](archive)
        guard let eocd = findEOCD(bytes) else { throw Failure.notZip }
        let count = Int(u16(bytes, eocd + 10))
        let cdOffset = Int(u32(bytes, eocd + 16))
        guard count <= maxEntries else { throw Failure.tooLarge }
        var entries: [Entry] = []
        var total = 0
        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= bytes.count, u32(bytes, p) == 0x0201_4b50 else { throw Failure.corrupt }
            let flags = u16(bytes, p + 8)
            let method = u16(bytes, p + 10)
            let compressed = Int(u32(bytes, p + 20))
            let size = Int(u32(bytes, p + 24))
            let nameLength = Int(u16(bytes, p + 28))
            let extraLength = Int(u16(bytes, p + 30))
            let commentLength = Int(u16(bytes, p + 32))
            let localOffset = Int(u32(bytes, p + 42))
            guard p + 46 + nameLength <= bytes.count else { throw Failure.corrupt }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            p += 46 + nameLength + extraLength + commentLength

            if name.hasSuffix("/") || isJunk(name) { continue }
            guard isSafe(name) else { throw Failure.unsafeName }
            guard name.lowercased().hasSuffix(".png") else { continue }
            // Encrypted, or ZIP64 sizes: not something the gallery ships.
            guard flags & 0x1 == 0, compressed != 0xFFFF_FFFF, size != 0xFFFF_FFFF else { throw Failure.unsupported }
            guard size <= maxEntryBytes else { throw Failure.tooLarge }
            total += size
            guard total <= maxTotalBytes else { throw Failure.tooLarge }
            if compressed > 0, size / compressed > maxRatio { throw Failure.tooLarge }

            guard localOffset + 30 <= bytes.count, u32(bytes, localOffset) == 0x0403_4b50 else { throw Failure.corrupt }
            let start = localOffset + 30 + Int(u16(bytes, localOffset + 26)) + Int(u16(bytes, localOffset + 28))
            guard start + compressed <= bytes.count else { throw Failure.corrupt }
            let raw = Array(bytes[start..<(start + compressed)])
            let data: Data
            switch method {
            case 0:
                guard compressed == size else { throw Failure.corrupt }
                data = Data(raw)
            case 8:
                guard compressed > 0 || size == 0 else { throw Failure.corrupt }
                data = try inflate(raw, size: size)
            default:
                throw Failure.unsupported
            }
            entries.append(Entry(name: (name as NSString).lastPathComponent, data: data))
        }
        guard !entries.isEmpty else { throw Failure.noFrames }
        // Sorted as they are, so two files with one name (in two folders) both stay.
        return entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func isJunk(_ name: String) -> Bool {
        let parts = name.split(separator: "/").map(String.init)
        guard let last = parts.last else { return true }
        return parts.contains("__MACOSX") || last == ".DS_Store" || last.hasPrefix("._")
            || last == "Thumbs.db" || last == "desktop.ini"
    }

    static func isSafe(_ name: String) -> Bool {
        guard !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0") else { return false }
        return !name.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." }
    }

    private static func inflate(_ raw: [UInt8], size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var out = [UInt8](repeating: 0, count: size)
        // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), which is what zip's method 8 stores.
        let written = raw.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(dst.baseAddress!, size, src.baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw Failure.corrupt }
        return Data(out)
    }

    private static func findEOCD(_ b: [UInt8]) -> Int? {
        guard b.count >= 22 else { return nil }
        var i = b.count - 22
        let floor = max(0, b.count - 22 - 65_535)
        while i >= floor {
            if u32(b, i) == 0x0605_4b50 { return i }
            i -= 1
        }
        return nil
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        guard i + 1 < b.count else { return 0 }
        return UInt16(b[i]) | UInt16(b[i + 1]) << 8
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i + 3 < b.count else { return 0 }
        return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}

// MARK: - Custom Metrics (RunCat Neo's docs/CustomMetricsSchema.md)

/// One file a script keeps up to date. The format is RunCat Neo's, unchanged, so a file made for
/// RunCat (its Claude Code statusLine, Codex and Bitcoin samples) shows in Coucou as it is.
struct MetricsSnapshot: Codable, Equatable {
    struct Metric: Codable, Equatable {
        var title: String
        var formattedValue: String
        var normalizedValue: Double? = nil

        /// The bar's fill, held to 0…1 as RunCat clamps it.
        var bar: Double? { normalizedValue.map { max(0, min(1, $0.isFinite ? $0 : 0)) } }
    }

    var title: String
    var symbol: String? = nil
    var metricsBarValue: String? = nil
    var metrics: [Metric]
    var lastUpdatedDate: Date

    static let defaultSymbol = "chart.bar.horizontal.page.fill"
    /// RunCat asks for files "well under a megabyte".
    static let maxBytes = 1024 * 1024

    enum Failure: Error, Equatable { case tooLarge, invalid(String) }

    static func decode(_ data: Data) throws -> MetricsSnapshot {
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let c = try d.singleValueContainer()
            let text = try c.decode(String.self)
            if let date = parseDate(text) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "lastUpdatedDate is not an ISO 8601 date")
        }
        do {
            return try decoder.decode(MetricsSnapshot.self, from: data)
        } catch let error as DecodingError {
            throw Failure.invalid(describe(error))
        } catch {
            throw Failure.invalid("Not valid JSON.")
        }
    }

    /// RunCat reads plain ISO 8601 ("2026-06-05T04:50:40Z"); fractional seconds are accepted too.
    static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: text) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _): return "Missing “\(key.stringValue)”."
        case .typeMismatch(_, let c), .valueNotFound(_, let c):
            let path = c.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
            return "Wrong type at “\(path)”."
        case .dataCorrupted(let c):
            return c.codingPath.isEmpty ? "Not valid JSON." : c.debugDescription
        @unknown default: return "Not valid JSON."
        }
    }

    /// What the menu bar shows for it: its metricsBarValue, or "---" (RunCat's placeholder).
    var menuBarText: String {
        let v = metricsBarValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return v.isEmpty ? "---" : v
    }
}

/// A file Coucou watches, and whether its value goes in the menu bar.
struct MetricsSourceConfig: Codable, Equatable, Identifiable {
    var id: UUID
    var path: String
    var displayName: String
    var symbol: String? = nil
    var showsInMenuBar: Bool = false
}

// MARK: - The Mac's own numbers

enum MetricsFormat {
    static func percent(_ fraction: Double) -> String {
        "\(Int((max(0, min(1, fraction)) * 100).rounded()))%"
    }

    static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .memory)
    }

    /// Disk sizes in decimal units, as Finder counts them (memory is counted in binary ones).
    static func diskBytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        let v = max(0, bytesPerSecond)
        if v < 1000 { return "\(Int(v)) B/s" }
        if v < 1_000_000 { return String(format: "%.0f KB/s", v / 1000) }
        if v < 1_000_000_000 { return String(format: "%.1f MB/s", v / 1_000_000) }
        return String(format: "%.1f GB/s", v / 1_000_000_000)
    }

    /// Bytes per second between two readings of the interface counters; nil when a counter went
    /// backwards (an interface reset) or no time passed.
    static func rate(from old: UInt64, to new: UInt64, seconds: Double) -> Double? {
        guard seconds > 0, new >= old else { return nil }
        return Double(new - old) / seconds
    }

    /// "3 min ago", from the file's lastUpdatedDate.
    static func ago(_ date: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 86_400 { return "\(s / 3600) h ago" }
        return "\(s / 86_400) d ago"
    }
}

/// The last readings of one value, for a sparkline (RunCat keeps 61).
struct MetricsHistory: Equatable {
    let length: Int
    private(set) var values: [Double] = []

    init(length: Int = 61) { self.length = max(1, length) }

    mutating func append(_ value: Double) {
        values.append(value)
        if values.count > length { values.removeFirst(values.count - length) }
    }
}

/// The Mac's numbers the menu bar can show next to the Runner.
enum SystemMetricKind: String, CaseIterable, Identifiable {
    case cpu, memory, storage, battery, network
    var id: String { rawValue }
}

/// The panel's tiles as a bento: two by two, and with an odd count one tile across the whole width
/// at the bottom — the one that reads best as a strip (network), else the last.
enum PanelBento {
    static func rows<T: Equatable>(_ tiles: [T], preferWide: T? = nil) -> [[T]] {
        var rest = tiles
        var wide: T?
        if rest.count % 2 == 1 {
            let i = preferWide.flatMap { p in rest.firstIndex(of: p) } ?? rest.count - 1
            wide = rest.remove(at: i)
        }
        var rows = stride(from: 0, to: rest.count, by: 2).map { Array(rest[$0..<min($0 + 2, rest.count)]) }
        if let wide { rows.append([wide]) }
        return rows
    }
}

/// What Coucou already knows, shown the same way without any script: the Claude plan's windows
/// (from Coucou's status-line relay) and the agents at work.
enum RunnerCoucouMetric: String, CaseIterable, Identifiable {
    case claudePlan, agents
    var id: String { rawValue }

    /// "5h 34% · 7d 12%"; a window whose reset has passed counts as 0, as the notch's gauge does.
    static func planText(fiveHour: (pct: Double, resetsAt: Date)?, sevenDay: (pct: Double, resetsAt: Date)?, now: Date) -> String? {
        func pct(_ w: (pct: Double, resetsAt: Date)) -> Int { w.resetsAt <= now ? 0 : Int(w.pct.rounded()) }
        var parts: [String] = []
        if let f = fiveHour { parts.append("5h \(pct(f))%") }
        if let s = sevenDay { parts.append("7d \(pct(s))%") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func agentsText(working: Int) -> String {
        working == 1 ? "1 agent" : "\(working) agents"
    }
}
#endif
