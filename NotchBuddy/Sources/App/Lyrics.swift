#if !APPSTORE
import SwiftUI
import Combine
import CryptoKit

// MARK: - Synced lyrics (coucou-custom fork)
//
// The line being sung, under the track in the Spotify and Apple Music cards (after Nusa's
// lyrics). Words come from LRCLIB (https://lrclib.net, a free, open lyrics database) as LRC
// text, "[mm:ss.xx] line"; each track's answer, found or not, is kept on disk so a song asks
// once. The card's clock (the controller's extrapolated position) picks the line.

struct LyricLine: Equatable {
    let time: Double     // seconds from the start
    let text: String
}

enum LRC {
    /// "[01:02.34][01:40.00]text" → one line per tag; empty texts (instrumental gaps) are kept
    /// so the card goes blank between verses. Sorted by time.
    static func parse(_ lrc: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        for raw in lrc.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw)
            var times: [Double] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                rest = rest[rest.index(after: close)...]
                let parts = tag.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) else { continue }
                times.append(minutes * 60 + seconds)
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            for t in times { lines.append(LyricLine(time: t, text: text)) }
        }
        return lines.sorted { $0.time < $1.time }
    }

    /// The line sung at `position`, and the one after it.
    static func line(at position: Double, in lines: [LyricLine]) -> (current: LyricLine?, next: LyricLine?) {
        guard !lines.isEmpty else { return (nil, nil) }
        var lo = 0, hi = lines.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= position { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard found >= 0 else { return (nil, lines.first) }
        return (lines[found], found + 1 < lines.count ? lines[found + 1] : nil)
    }
}

/// What identifies a track for LRCLIB: names and the length in seconds.
struct LyricsKey: Hashable, Sendable {
    let artist: String
    let title: String
    let album: String
    let duration: Int

    var cacheName: String {
        let text = [artist, title, album, String(duration)].joined(separator: "\u{1}").lowercased()
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

/// LRCLIB, with a disk cache: found lyrics for good, a miss for a day.
enum LyricsStore {
    static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NotchBuddy/lyrics", isDirectory: true)
    static let userAgent = "CoucouCustom/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0") (https://github.com/CyberAakash/coucou-custom)"
    private static let missKeepFor: TimeInterval = 24 * 60 * 60

    private struct Cached: Codable {
        let synced: String?
        let at: Date
    }

    /// The track's synced lyrics (LRC), nil when none are known. `nil` is also the answer
    /// when the service could not be reached; that one is not cached, so it is asked again.
    static func lyrics(for key: LyricsKey) async -> String? {
        let file = folder.appendingPathComponent(key.cacheName + ".json")
        if let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode(Cached.self, from: data) {
            if cached.synced != nil || Date().timeIntervalSince(cached.at) < missKeepFor { return cached.synced }
        }
        guard let answer = await fetch(key) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Cached(synced: answer.synced, at: .now)) {
            try? data.write(to: file, options: .atomic)
        }
        return answer.synced
    }

    /// What LRCLIB said: the words, or that it knows none for this track.
    enum Answer: Equatable {
        case found(String)
        case none
        var synced: String? { if case .found(let s) = self { return s }; return nil }
    }

    /// nil: the service was not reached (asked again next time).
    static func fetch(_ key: LyricsKey) async -> Answer? {
        let session = URLSession(configuration: .ephemeral)
        func request(_ components: URLComponents) async -> (Int, Data)? {
            guard let url = components.url else { return nil }
            var req = URLRequest(url: url, timeoutInterval: 10)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await session.data(for: req),
                  let code = (response as? HTTPURLResponse)?.statusCode else { return nil }
            return (code, data)
        }
        // The exact match first: names and length (±2 s on their side).
        var get = URLComponents(string: "https://lrclib.net/api/get")!
        get.queryItems = [.init(name: "artist_name", value: key.artist), .init(name: "track_name", value: key.title),
                          .init(name: "duration", value: String(key.duration))]
        if !key.album.isEmpty { get.queryItems?.append(.init(name: "album_name", value: key.album)) }
        guard let (code, data) = await request(get) else { return nil }
        if code == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let synced = json["syncedLyrics"] as? String, !synced.isEmpty { return .found(synced) }
            return .none   // known track, plain words only or instrumental
        }
        guard code == 404 else { return nil }
        // Then a search: the same song on another album, or a length a few seconds off.
        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [.init(name: "track_name", value: key.title), .init(name: "artist_name", value: key.artist)]
        guard let (scode, sdata) = await request(search) else { return nil }
        guard scode == 200, let hits = try? JSONSerialization.jsonObject(with: sdata) as? [[String: Any]] else {
            return scode == 404 ? Answer.none : nil
        }
        let close = hits.filter { hit in
            guard let synced = hit["syncedLyrics"] as? String, !synced.isEmpty else { return false }
            let d = (hit["duration"] as? Double) ?? 0
            return key.duration == 0 || abs(d - Double(key.duration)) <= 4
        }
        if let synced = close.first?["syncedLyrics"] as? String { return .found(synced) }
        return Answer.none
    }
}

/// The lyrics of the track playing, for the cards. One model for both players: whichever
/// told it about a track last is the one shown.
@MainActor
final class LyricsModel: ObservableObject {
    static let shared = LyricsModel()

    /// Settings → General → "Lyrics while music plays" (default on).
    static let enabledKey = "coucouLyrics"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    enum Status: Equatable { case idle, loading, found, none }

    @Published private(set) var key: LyricsKey?
    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var status: Status = .idle
    private var task: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Spotify and Apple Music each say what they play; an empty track clears the words.
        SpotifyController.shared.$track
            .removeDuplicates { $0?.id == $1?.id }
            .sink { [weak self] track in
                guard let self else { return }
                guard let track, !track.isAd else { if self.key != nil, SpotifyController.shared.track == nil { self.track(nil) }; return }
                self.track(LyricsKey(artist: track.artist, title: track.title, album: track.album, duration: Int(track.duration.rounded())))
            }
            .store(in: &cancellables)
        MusicController.shared.$trackTitle.combineLatest(MusicController.shared.$artist, MusicController.shared.$duration)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] title, artist, duration in
                guard let self, let title, !title.isEmpty else { return }
                self.track(LyricsKey(artist: artist ?? "", title: title, album: MusicController.shared.album ?? "",
                                     duration: Int(duration.rounded())))
            }
            .store(in: &cancellables)
    }

    /// A new track: its words, from the cache or LRCLIB.
    func track(_ newKey: LyricsKey?) {
        guard newKey != key else { return }
        task?.cancel()
        key = newKey
        lines = []
        guard let newKey, Self.enabled, !newKey.title.isEmpty else { status = .idle; return }
        status = .loading
        task = Task { [weak self] in
            let lrc = await LyricsStore.lyrics(for: newKey)
            guard !Task.isCancelled, let self, self.key == newKey else { return }
            let parsed = lrc.map(LRC.parse) ?? []
            self.lines = parsed
            self.status = parsed.isEmpty ? .none : .found
            appendAppLog("nb.log", "[Lyrics] \(newKey.artist) – \(newKey.title): \(parsed.isEmpty ? "none" : "\(parsed.count) lines")")
        }
    }

    func line(at position: Double) -> LyricLine? { LRC.line(at: position, in: lines).current }
}

/// The line being sung, in place of the card's subtitle while the words are known.
struct LyricsLineView: View {
    let position: Double
    let accent: Color
    @ObservedObject private var model = LyricsModel.shared

    var body: some View {
        let line = model.line(at: position)
        let text = line?.text ?? ""
        Text(text.isEmpty ? "♪" : text)
            .font(.system(size: 11, weight: text.isEmpty ? .regular : .medium))
            .foregroundColor(text.isEmpty ? Color(hex: "#6B7079") : accent)
            .lineLimit(1).truncationMode(.tail)
            .id(line?.time ?? -1)
            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            .animation(.easeOut(duration: 0.25), value: line?.time)
    }
}
#endif
