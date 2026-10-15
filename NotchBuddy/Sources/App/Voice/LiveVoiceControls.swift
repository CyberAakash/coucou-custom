#if !APPSTORE
import AppKit

// MARK: - LiveMusicControl

final class LiveMusicControl: MusicControlling, @unchecked Sendable {
    var isMusicRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").count > 0
    }
    var isSpotifyRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").count > 0
    }
    /// With both apps open, commands go to the one playing (Spotify when neither is), not
    /// always to Apple Music. (coucou-custom fork)
    @MainActor private var useSpotify: Bool {
        isSpotifyRunning && (!isMusicRunning || SpotifyController.shared.isPlaying || !AppState.shared.musicPlaying)
    }

    @MainActor func play() {
        if !useSpotify      { MusicController.shared.play() }
        else                { SpotifyController.shared.play() }
    }
    @MainActor func pause() {
        if !useSpotify      { MusicController.shared.pause() }
        else                { SpotifyController.shared.pause() }
    }
    @MainActor func nextTrack() {
        if !useSpotify      { MusicController.shared.nextTrack() }
        else                { SpotifyController.shared.nextTrack() }
    }
    @MainActor func previousTrack() {
        if !useSpotify      { MusicController.shared.previousTrack() }
        else                { SpotifyController.shared.previousTrack() }
    }
    @MainActor func volumeUp() {
        if !useSpotify      { MusicController.shared.adjustVolume(by: +25) }
        else                { SpotifyController.shared.adjustVolume(by: +25) }
    }
    @MainActor func volumeDown() {
        if !useSpotify      { MusicController.shared.adjustVolume(by: -25) }
        else                { SpotifyController.shared.adjustVolume(by: -25) }
    }
    @MainActor func setVolume(_ pct: Int) {
        if !useSpotify      { MusicController.shared.setVolume(pct) }
        else                { SpotifyController.shared.setVolume(pct) }
    }
    @MainActor func playSearch(_ name: String) async -> Bool {
        guard isMusicRunning else { return false }
        return await MusicController.shared.playSearch(name)
    }
    @MainActor func playPlaylist(_ name: String) async -> Bool {
        guard isMusicRunning else { return false }
        return await MusicController.shared.playPlaylist(name)
    }
    @MainActor func launchAndPlay() async {
        if !isMusicRunning {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Music.app"))
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        if isMusicRunning { MusicController.shared.play() }
    }
    @MainActor func launchSpotify() async {
        guard !isSpotifyRunning else { SpotifyController.shared.play(); return }
        // Found by bundle id: Spotify also installs to ~/Applications. (coucou-custom fork)
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SpotifyController.bundleId) else { return }
        NSWorkspace.shared.open(url)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if isSpotifyRunning { SpotifyController.shared.play() }
    }
    @MainActor func openSearch(_ name: String) {
        // Spotify in use: search there instead of launching Apple Music next to it.
        if useSpotify, let q = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
           let url = URL(string: "spotify:search:\(q)") {
            NSWorkspace.shared.open(url)
            return
        }
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://music.apple.com/search?term=\(encoded)") else { return }
        // Open in Apple Music app, not the browser
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - LivePillControl

@MainActor
final class LivePillControl: PillControlling {
    func activeIds()  -> Set<String> { AppState.shared.activeIntegrations }
    func mainPillId() -> String      { AppState.shared.mainPillId }
    func activeCount() -> Int        { AppState.shared.activeIntegrations.count }
    func toggleIntegration(_ id: String) { AppState.shared.toggleIntegration(id) }
    func setMainPill(_ id: String)       { AppState.shared.setMainPill(id) }
}

// MARK: - Configuration

extension VoiceActionRunner {
    func configureLive() {
        music = LiveMusicControl()
        pills = LivePillControl()
        info  = LiveVoiceInfo.shared
        onLanguageSwitch = { lang in
            VoiceSettings.language = lang          // Settings picker follows (same key)
            VoiceBrain.shared.endConversation()    // next session gets the new instructions
        }
    }
}
#endif
