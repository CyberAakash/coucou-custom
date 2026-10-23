#if !APPSTORE
import CoreGraphics
import Foundation

// coucou-custom fork: the Runner Gallery (runcat-dev/RunnerGallery, Apache-2.0), read from its
// GitHub repository only when you open it in Settings → Runner. No account, no key, nothing sent.

@MainActor
final class RunnerGalleryClient: ObservableObject {
    static let shared = RunnerGalleryClient()

    struct Entry: Identifiable, Equatable {
        let name: String
        let metadata: RunnerGallery.Metadata
        var preview: [CGImage] = []
        var delay: Double = 0.1
        var id: String { name }

        static func == (a: Entry, b: Entry) -> Bool {
            a.name == b.name && a.metadata == b.metadata && a.preview.count == b.preview.count
        }
    }

    enum Phase: Equatable { case idle, loading, loaded, failed(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var entries: [Entry] = []
    /// Gallery names being installed right now.
    @Published private(set) var installing: Set<String> = []

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    func load() {
        guard phase != .loading else { return }
        phase = .loading
        Task {
            do {
                let data = try await fetch(RunnerGallery.manifestURL, limit: 64 * 1024)
                guard let names = RunnerGallery.decodeManifest(data), !names.isEmpty else {
                    phase = .failed("The gallery’s list could not be read.")
                    return
                }
                var loaded: [Entry] = []
                // A few at a time: 40-odd runners, two small files each.
                for chunk in stride(from: 0, to: names.count, by: 6).map({ Array(names[$0..<min($0 + 6, names.count)]) }) {
                    let batch = await withTaskGroup(of: Entry?.self) { group in
                        for name in chunk { group.addTask { await self.entry(name) } }
                        var out: [Entry] = []
                        for await e in group { if let e { out.append(e) } }
                        return out
                    }
                    loaded.append(contentsOf: batch)
                    entries = names.compactMap { n in loaded.first { $0.name == n } }
                }
                phase = entries.isEmpty ? .failed("No runner could be read from the gallery.") : .loaded
            } catch {
                phase = .failed(Self.describe(error))
            }
        }
    }

    private nonisolated func entry(_ name: String) async -> Entry? {
        guard let data = try? await fetch(RunnerGallery.metadataURL(name), limit: 4096),
              let metadata = RunnerGallery.decodeMetadata(data) else { return nil }
        var entry = Entry(name: name, metadata: metadata)
        if let png = try? await fetch(RunnerGallery.previewURL(name), limit: 512 * 1024),
           let anim = RunnerImages.animation(from: png) {
            entry.preview = anim.frames
            entry.delay = anim.delay
        }
        return entry
    }

    /// Downloads the runner's frames, checks them as a manual import is checked, and adds it.
    func install(_ entry: Entry) async -> String? {
        guard !installing.contains(entry.name) else { return nil }
        installing.insert(entry.name)
        defer { installing.remove(entry.name) }
        do {
            let zip = try await fetch(RunnerGallery.framesURL(entry.name), limit: RunnerZip.maxArchiveBytes)
            let frames = try RunnerZip.pngEntries(zip)
            if let problem = RunnerImages.validate(frames.map { ($0.name, $0.data) }) { return problem }
            try RunnerLibrary.shared.add(name: entry.metadata.displayName, isTemplate: entry.metadata.isTemplate,
                                         frames: frames.map(\.data), playback: .loop,
                                         author: entry.metadata.author, galleryName: entry.name)
            return nil
        } catch let failure as RunnerZip.Failure {
            return "The frames archive was refused (\(failure))."
        } catch {
            return Self.describe(error)
        }
    }

    private nonisolated func fetch(_ url: URL, limit: Int) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard data.count <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost: return "No internet connection."
            case .timedOut: return "GitHub took too long to answer."
            default: break
            }
        }
        return "The gallery could not be reached."
    }
}
#endif
