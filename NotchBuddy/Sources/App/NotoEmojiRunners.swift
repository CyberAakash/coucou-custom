#if !APPSTORE
import AppKit
import ImageIO
import SwiftUI

// coucou-custom fork: Google's Noto Animated Emoji (CC BY 4.0, https://googlefonts.github.io/noto-emoji-files/)
// as menu-bar runners. The list is read from Google's own index only when you open it; an emoji is
// downloaded only when you install it, then kept as a runner of yours (12 frames, 36 px high).

@MainActor
final class NotoEmojiClient: ObservableObject {
    static let shared = NotoEmojiClient()

    static let indexURL = URL(string: "https://googlefonts.github.io/noto-emoji-animation/data/api.json")!
    static let credit = "Noto Animated Emoji by Google, CC BY 4.0"
    static let galleryPrefix = "noto:"

    struct Emoji: Identifiable, Hashable {
        let codepoint: String      // "1f415", or "1f468_200d_1f4bb"
        let name: String
        let category: String
        var id: String { codepoint }

        /// The character itself, drawn by the system: no download for the list.
        var character: String {
            String(String.UnicodeScalarView(codepoint.split(separator: "_").compactMap { UInt32($0, radix: 16).flatMap(Unicode.Scalar.init) }))
        }

        var animationURL: URL? {
            // Only hex and underscores ever reach the URL.
            guard codepoint.range(of: "^[0-9a-f]+(_[0-9a-f]+)*$", options: .regularExpression) != nil else { return nil }
            return URL(string: "https://fonts.gstatic.com/s/e/notoemoji/latest/\(codepoint)/512.webp")
        }
    }

    enum Phase: Equatable { case idle, loading, loaded, failed(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var emoji: [Emoji] = []
    @Published private(set) var installing: Set<String> = []

    var categories: [String] { Array(Set(emoji.map(\.category))).sorted() }

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.httpCookieStorage = nil
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    func load() {
        guard phase != .loading else { return }
        phase = .loading
        Task {
            do {
                let (data, response) = try await session.data(from: Self.indexURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2_000_000,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let icons = json["icons"] as? [[String: Any]] else {
                    phase = .failed("Google's list could not be read.")
                    return
                }
                emoji = icons.compactMap { i in
                    guard let cp = i["codepoint"] as? String else { return nil }
                    let tag = ((i["tags"] as? [String])?.first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                    let name = tag.replacingOccurrences(of: "-", with: " ").capitalized
                    return Emoji(codepoint: cp, name: name.isEmpty ? cp : name,
                                 category: (i["categories"] as? [String])?.first ?? "Other")
                }
                phase = emoji.isEmpty ? .failed("Google's list is empty.") : .loaded
            } catch {
                phase = .failed("Google's list could not be reached.")
            }
        }
    }

    /// Downloads the animation, takes 12 frames through its loop, and adds it as a colour runner.
    func install(_ e: Emoji) async -> String? {
        guard !installing.contains(e.codepoint), let url = e.animationURL else { return "This emoji has no animation." }
        installing.insert(e.codepoint)
        defer { installing.remove(e.codepoint) }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return "Google has no animation for this one." }
            guard data.count <= 3_000_000 else { return "The animation is too large." }
            let frames = Self.frames(from: data, count: 12)
            guard !frames.isEmpty else { return "The animation could not be read." }
            try RunnerLibrary.shared.add(name: e.name, isTemplate: false, frames: frames, playback: .loop,
                                         author: Self.credit, galleryName: Self.galleryPrefix + e.codepoint)
            return nil
        } catch {
            return "The animation could not be downloaded."
        }
    }

    /// `count` frames spread evenly through the animation, each 36 × 36 px, as PNG.
    nonisolated static func frames(from data: Data, count: Int) -> [Data] {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return [] }
        let total = CGImageSourceGetCount(src)
        guard total > 0 else { return [] }
        let picks = total <= count ? Array(0..<total) : (0..<count).map { $0 * total / count }
        return picks.compactMap { i -> Data? in
            guard let image = CGImageSourceCreateImageAtIndex(src, i, nil),
                  let ctx = CGContext(data: nil, width: 36, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 36, height: 36))
            return ctx.makeImage().flatMap(RunnerImages.png)
        }
    }
}

struct NotoEmojiCard: View {
    @ObservedObject var library: RunnerLibrary
    @Binding var toast: String
    @ObservedObject private var client = NotoEmojiClient.shared
    @State private var category = "Animals and nature"
    @State private var query = ""

    var body: some View {
        HubCard {
            switch client.phase {
            case .idle:
                HubRow(title: "Google's animated emoji",
                       detail: "Hundreds of Noto emoji that move, under CC BY 4.0. Opening the list reads Google's index; an emoji is downloaded only when you install it.") {
                    Button("Browse emoji") { client.load() }.buttonStyle(HubButtonStyle(primary: true))
                }
            case .loading:
                HStack { ProgressView().controlSize(.small); Text("Loading Google's list…").foregroundColor(HubTheme.secondary) }
            case .failed(let message):
                HubRow(title: "The emoji could not be loaded", detail: message) {
                    Button("Try again") { client.load() }.buttonStyle(HubButtonStyle())
                }
            case .loaded:
                let installed = library.installedGalleryNames()
                let q = query.trimmingCharacters(in: .whitespaces).lowercased()
                let shown = client.emoji.filter { (q.isEmpty ? $0.category == category : $0.name.lowercased().contains(q)) }
                HStack(spacing: 8) {
                    HubField(placeholder: "Search every emoji", text: $query).frame(maxWidth: 220)
                    Picker("", selection: $category) {
                        ForEach(client.categories, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 200).disabled(!q.isEmpty)
                    Spacer()
                    Text("\(shown.count) emoji").font(.system(size: 11.5)).foregroundColor(HubTheme.muted)
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                        ForEach(shown) { e in
                            let has = installed.contains(NotoEmojiClient.galleryPrefix + e.codepoint)
                            let busy = client.installing.contains(e.codepoint)
                            Button {
                                guard !has, !busy else { return }
                                Task {
                                    if let problem = await client.install(e) { toast = "❌ \(e.name): \(problem)" }
                                    else { toast = "“\(e.name)” added. Pick it above." }
                                }
                            } label: {
                                VStack(spacing: 4) {
                                    Text(e.character).font(.system(size: 30))
                                    Text(e.name).font(.system(size: 10.5)).foregroundColor(HubTheme.secondary).lineLimit(1)
                                    Group {
                                        if has { Label("Added", systemImage: "checkmark").foregroundColor(HubTheme.green) }
                                        else if busy { ProgressView().controlSize(.mini) }
                                        else { Text("Add").foregroundColor(HubTheme.accent) }
                                    }
                                    .font(.system(size: 10.5, weight: .bold)).frame(height: 14)
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
                            }
                            .buttonStyle(.plain)
                            .help(e.name)
                        }
                    }
                }
                .frame(height: 300)
                HubNote(text: "\(NotoEmojiClient.credit). They play in their own colours; the menu bar's tint does not apply.")
            }
        }
    }
}
#endif
