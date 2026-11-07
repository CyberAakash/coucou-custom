#if !APPSTORE
import AppKit
import SwiftUI

// MARK: - The expanded music player (coucou-custom fork, phase 6 part 2; design board F2)
//
// The Home card's ↗ grows the player in place: an island view of its own (`.player`), not a
// page or a tab; ↙ or Esc goes back to Home. Mochi on a spotlight in the cover's colour, the
// title and Up next on the right, the wave bar and big frosted buttons at the bottom, the
// cover blurred behind it all. Spotify or Apple Music, whichever the card showed.

enum PlayerLayout {
    static let height: CGFloat = 330
}

struct MusicPlayerView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var spotify = SpotifyController.shared
    @ObservedObject private var music = MusicController.shared
    @ObservedObject private var audio = ControlsAudio.shared
    @Environment(\.islandViewActive) private var active
    @FocusState private var focused: Bool

    private var isSpotify: Bool {
        if let source = state.playerSource { return source == SpotifyController.pillId }
        return spotify.track != nil
    }
    private var appColor: Color { isSpotify ? Color(hex: SpotifyController.green) : Color(hex: "#FA2D48") }

    private var artwork: NSImage? { isSpotify ? spotify.artwork : music.artwork }
    private var title: String { (isSpotify ? spotify.track?.title : music.trackTitle) ?? "" }
    private var subtitle: String {
        let parts = isSpotify ? [spotify.track?.artist, spotify.track?.album] : [music.artist, music.album]
        return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private var playing: Bool { isSpotify ? spotify.isPlaying : state.musicPlaying }
    private var duration: Double { isSpotify ? (spotify.track?.duration ?? 0) : music.duration }
    private func position(_ date: Date) -> Double { isSpotify ? spotify.position(at: date) : music.position(at: date) }
    private var shuffling: Bool { isSpotify ? spotify.shuffling : music.shuffling }
    private var repeating: Bool { isSpotify ? spotify.repeating : music.repeating }

    var body: some View {
        ZStack {
            CardBackground(wash: nil)
            if let artwork { NowPlayingBackdrop(image: artwork) }
            VStack(spacing: 8) {
                topRow
                HStack(spacing: 22) {
                    stage.frame(width: 210)
                    details
                }
                .frame(maxHeight: .infinity)
                bottom
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 12)
        }
        .focusable().focusEffectDisabled().focused($focused)
        .onExitCommand { back() }
        .onAppear {
            focused = active
            audio.start()
            if !isSpotify { music.loadUpNext() }
        }
        .onChange(of: music.trackTitle) { _, _ in if !isSpotify { music.loadUpNext() } }
    }

    private func back() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { state.view = .overview }
    }

    // MARK: Top

    private var topRow: some View {
        HStack(spacing: 10) {
            Button { isSpotify ? spotify.openSpotify() : music.openMusic() } label: {
                Image(nsImage: Self.appIcon(isSpotify ? "com.spotify.client" : "com.apple.Music"))
                    .resizable().interpolation(.high).frame(width: 30, height: 30)
            }
            .buttonStyle(.plain).pointer().help(isSpotify ? "Open Spotify" : "Open Music")
            if !audio.outputs.isEmpty {
                HubDropdown(Binding(get: { audio.current }, set: { id in audio.outputs.first { $0.id == id }.map(audio.use) }),
                            audio.outputs.map { ($0.id, $0.name) }, tint: appColor, listWidth: 240, width: 150,
                            symbol: ControlsView.symbol(for: audio.outputs.first { $0.id == audio.current }), placeholder: "Output")
            }
            Spacer(minLength: 8)
            frostButton("arrow.down.left", size: 30, help: "Back to Home (Esc)") { back() }
        }
    }

    // MARK: Middle

    /// Mochi, in the cover's colour, on a spotlight.
    private var stage: some View {
        let colors = ArtworkPalette.nsColors(artwork)
        let main = colors.first ?? NSColor(appColor)
        return ZStack(alignment: .bottom) {
            Ellipse().fill(RadialGradient(colors: [Color(nsColor: main).opacity(0.55), .clear], center: .center, startRadius: 0, endRadius: 90))
                .frame(width: 170, height: 28)
            HubLiveMochi(color: Self.hex(main), size: 96, state: playing ? .working : .idle)
                .padding(.bottom, 10)
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private var details: some View {
        let queue = !isSpotify && !music.upNext.isEmpty
        return VStack(alignment: .leading, spacing: 3) {
            if !queue { Spacer(minLength: 0) }
            Text(title).font(.system(size: queue ? 21 : 26, weight: .heavy)).lineLimit(queue ? 1 : 2).truncationMode(.tail)
            Text(subtitle).font(.system(size: queue ? 12.5 : 14)).foregroundColor(.white.opacity(0.7)).lineLimit(1).truncationMode(.tail)
            if queue {
                upNext.padding(.top, 10)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var upNext: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("UP NEXT").font(.system(size: 9.5, weight: .heavy)).tracking(1.1).foregroundColor(.white.opacity(0.5))
                .padding(.horizontal, 8).padding(.top, 4)
            ForEach(music.upNext) { song in
                Button { music.playUpNext(song) } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(song.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                            Text(song.artist).font(.system(size: 10.5)).foregroundColor(.white.opacity(0.6)).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Text(NowPlayingProgress.format(song.duration)).font(.system(size: 10.5).monospacedDigit()).foregroundColor(.white.opacity(0.55))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowHoverStyle()).pointer()
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }

    // MARK: Bottom

    private var bottom: some View {
        VStack(spacing: 4) {
            TimelineView(.animation(minimumInterval: 0.5, paused: !playing)) { context in
                let p = position(context.date)
                VStack(spacing: 2) {
                    WaveBar(fraction: duration > 0 ? p / duration : 0, colors: ArtworkPalette.waveColors(artwork, fallback: appColor),
                            playing: playing, enabled: duration > 0, duration: duration, onChange: { _ in },
                            onCommit: { f in isSpotify ? spotify.seek(to: f * duration) : music.seek(to: f * duration) })
                        .frame(height: 36)
                    HStack {
                        Text(NowPlayingProgress.format(p))
                        Spacer()
                        Text(duration > 0 ? NowPlayingProgress.format(duration) : "")
                    }
                    .font(.system(size: 10.5).monospacedDigit()).foregroundColor(.white.opacity(0.65))
                }
            }
            HStack(spacing: 26) {
                iconToggle("shuffle", on: shuffling, help: "Shuffle") { isSpotify ? spotify.setShuffling(!shuffling) : music.setShuffling(!shuffling) }
                frostButton("backward.fill", size: 40, help: "Previous") { isSpotify ? spotify.previousTrack() : music.previousTrack() }
                frostButton(playing ? "pause.fill" : "play.fill", size: 48, help: playing ? "Pause" : "Play") {
                    isSpotify ? spotify.playPause() : music.playPause()
                }
                frostButton("forward.fill", size: 40, help: "Next") { isSpotify ? spotify.nextTrack() : music.nextTrack() }
                iconToggle("repeat", on: repeating, help: "Repeat") { isSpotify ? spotify.setRepeating(!repeating) : music.setRepeating(!repeating) }
            }
        }
    }

    private func frostButton(_ icon: String, size: CGFloat, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size * 0.32, weight: .bold)).foregroundColor(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(0.16)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.12)))
        }
        .buttonStyle(NowPlayingPressStyle()).pointer().help(help)
    }

    private func iconToggle(_ icon: String, on: Bool, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .bold))
                .foregroundColor(on ? appColor : .white.opacity(0.6)).frame(width: 30, height: 30)
        }
        .buttonStyle(.plain).pointer().help("\(help) \(on ? "on" : "off")")
    }

    static func appIcon(_ bundleId: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSImage(systemSymbolName: "music.note", accessibilityDescription: nil) ?? NSImage()
    }

    static func hex(_ c: NSColor) -> String {
        let rgb = c.usingColorSpace(.sRGB) ?? c
        return String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }
}

/// A row that lights up under the pointer.
private struct RowHoverStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }
    private struct Row: View {
        let configuration: ButtonStyle.Configuration
        @State private var hover = false
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.14 : (hover ? 0.08 : 0))))
                .onHover { hover = $0 }
        }
    }
}
#endif
