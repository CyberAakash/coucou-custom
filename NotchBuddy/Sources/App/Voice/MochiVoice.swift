#if !APPSTORE
import AVFoundation
import FluidAudio
import Foundation

// MARK: - MochiCharacter (coucou-custom fork)

/// How Mochi sounds: a Kokoro base voice and the character chain applied to it. Kokoro has no
/// child or robot voices (no open model does), so the character is made the way studios make
/// one: a clear adult voice, its resonances scaled up so the speaker sounds smaller, the pitch
/// moved separately, then effects. Everything here is a slider in Settings → Voice.
struct MochiCharacter: Codable, Equatable {
    var base: String = "af_sky"
    /// Semitones, −6…+12. Moves the note only.
    var pitch: Double = 3
    /// Resonance scale, 1.0…1.45. Higher sounds like a smaller body.
    var body: Double = 1.19
    var speed: Double = 1.0
    /// 0…1: how much of the robot effect is mixed in.
    var robot: Double = 0
    /// 0…0.6: a short room echo.
    var echo: Double = 0
    /// Treble shelf in dB, −6…+8.
    var bright: Double = 0

    static let presets: [(name: String, character: MochiCharacter)] = [
        ("Cute 1", MochiCharacter(base: "af_sky", pitch: 3, body: 1.19)),
        ("Cute 2", MochiCharacter(base: "af_sky", pitch: 5, body: 1.33)),
        ("Cute 3", MochiCharacter(base: "af_heart", pitch: 4, body: 1.26, echo: 0.35)),
        ("Robot", MochiCharacter(base: "af_sky", pitch: 2, body: 1.12, robot: 0.8)),
        ("Plain", MochiCharacter(base: "af_heart", pitch: 0, body: 1.0)),
    ]

    static let key = "voiceMochiCharacter"
    static var current: MochiCharacter {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let c = try? JSONDecoder().decode(MochiCharacter.self, from: data) else { return presets[0].character }
            return c
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    /// Friendly names for the Kokoro voices worth offering as a base (clear English ones).
    static let bases: [(id: String, name: String)] = [
        ("af_sky", "Sky"), ("af_heart", "Heart"), ("af_bella", "Bella"), ("af_nicole", "Nicole"),
        ("af_nova", "Nova"), ("bf_emma", "Emma (British)"), ("bf_lily", "Lily (British)"),
        ("am_puck", "Puck"), ("am_michael", "Michael"), ("bm_george", "George (British)"),
    ]
}

// MARK: - MochiVoice

/// Mochi's own voice: Kokoro-82M (Apache-2.0) on the Neural Engine through FluidAudio, then the
/// character chain rendered offline with AVAudioEngine, all on this Mac. A sentence takes well
/// under a second; nothing leaves the machine.
@MainActor
final class MochiVoice: ObservableObject {
    static let shared = MochiVoice()

    enum State: Equatable { case missing, loading, ready, failed(String) }
    @Published private(set) var state: State = .missing

    static var isActive: Bool { VoiceSettings.ttsEngine == "mochi" }

    private var manager: KokoroAneManager?
    private var loading: Task<KokoroAneManager, Error>?

    private init() {
        if Self.installed { state = .ready }   // loads on first use
    }

    /// The pinned Kokoro bundle lives beside Parakeet's models, in Coucou's own folder.
    nonisolated static var directory: URL { Parakeet.modelsRoot.appendingPathComponent("kokoro-82m-coreml", isDirectory: true) }
    nonisolated static var installed: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("ANE-v3").path)
    }

    /// Downloads (first time, about 300 MB) and loads the model.
    func prepare() {
        Task { _ = try? await self.engine() }
    }

    func remove() {
        manager = nil
        loading = nil
        try? FileManager.default.removeItem(at: Self.directory)
        state = .missing
    }

    private func engine() async throws -> KokoroAneManager {
        if let manager { return manager }
        if let loading { return try await loading.value }
        state = Self.installed ? .loading : .missing
        let task = Task<KokoroAneManager, Error> {
            let m = KokoroAneManager(variant: .english, defaultVoice: MochiCharacter.current.base,
                                     directory: Parakeet.modelsRoot, version: .v3)
            try await m.initialize(preloadVoices: [MochiCharacter.current.base])
            // Core ML compiles each length bucket on its first use (measured 2.5–5 s), so a
            // short and a long phrase are spoken silently now rather than on the first answer.
            for warm in ["Hi.", "Hi, I'm Mochi! I found three things for you today, want me to open the first one?"] {
                _ = try? await m.synthesize(text: warm, voice: MochiCharacter.current.base)
            }
            return m
        }
        loading = task
        do {
            let m = try await task.value
            manager = m
            state = .ready
            appendAppLog("nb.log", "[Voice] Mochi voice ready")
            return m
        } catch {
            loading = nil
            state = .failed(error.localizedDescription)
            appendAppLog("nb.log", "[Voice] Mochi voice failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// WAV for one sentence in Mochi's character, or nil (model missing, error) → Mac voice.
    func audio(for text: String) async -> Data? {
        let character = MochiCharacter.current
        let t0 = Date()
        do {
            let engine = try await engine()
            let result = try await engine.synthesizeDetailed(text: text, voice: character.base, speed: Float(character.speed))
            let shaped = try await CharacterChain.render(samples: result.samples, sampleRate: Double(result.sampleRate), character: character)
            appendAppLog("nb.log", "[Voice] Mochi said \(text.split(separator: " ").count) words in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            return WAV.data(samples: shaped, sampleRate: Int(result.sampleRate))
        } catch {
            appendAppLog("nb.log", "[Voice] Mochi voice error, Mac voice used: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - CharacterChain

/// Offline AVAudioEngine render: varispeed scales pitch and resonances together (the "body"),
/// time-pitch then moves the pitch back to the wanted note and restores the tempo, a treble
/// shelf for brightness, a speech distortion preset for the robot, a short delay for the echo.
enum CharacterChain {
    static func render(samples: [Float], sampleRate: Double, character c: MochiCharacter) async throws -> [Float] {
        let neutral = c.body == 1 && c.pitch == 0 && c.robot == 0 && c.echo == 0 && c.bright == 0
        if neutral || samples.isEmpty { return samples }
        return try await Task.detached(priority: .userInitiated) {
            try renderSync(samples: samples, sampleRate: sampleRate, character: c)
        }.value
    }

    private static func renderSync(samples: [Float], sampleRate: Double, character c: MochiCharacter) throws -> [Float] {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return samples }
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let vari = AVAudioUnitVarispeed()
        let pitch = AVAudioUnitTimePitch()
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        let robot = AVAudioUnitDistortion()
        let echo = AVAudioUnitDelay()

        let body = max(1.0, min(1.45, c.body))
        vari.rate = Float(body)
        // Varispeed moved the pitch by 12·log2(body) semitones along with the resonances;
        // time-pitch takes the pitch the rest of the way and undoes the speed-up.
        pitch.pitch = Float((c.pitch - 12 * log2(body)) * 100)
        pitch.rate = Float(1 / body)
        pitch.overlap = 12
        eq.bands[0].filterType = .highShelf
        eq.bands[0].frequency = 3000
        eq.bands[0].gain = Float(c.bright)
        eq.bands[0].bypass = c.bright == 0
        robot.loadFactoryPreset(.speechCosmicInterference)
        robot.wetDryMix = Float(c.robot * 100)
        robot.preGain = -6
        robot.bypass = c.robot <= 0
        echo.delayTime = 0.085
        echo.feedback = 22
        echo.lowPassCutoff = 5000
        echo.wetDryMix = Float(c.echo * 100)
        echo.bypass = c.echo <= 0

        let nodes: [AVAudioNode] = [player, vari, pitch, eq, robot, echo]
        nodes.forEach { engine.attach($0) }
        for (a, b) in zip(nodes, nodes.dropFirst()) { engine.connect(a, to: b, format: format) }
        engine.connect(echo, to: engine.mainMixerNode, format: format)

        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        var finished = false
        player.scheduleBuffer(source, completionCallbackType: .dataRendered) { _ in finished = true }
        player.play()

        // Time-pitch keeps a little audio buffered after the player reports done.
        let tailSeconds = c.echo > 0 ? 0.6 : 0.3
        let expected = Int(Double(samples.count) / body / Double(pitch.rate)) + Int(sampleRate * tailSeconds)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { return samples }
        var rendered: [Float] = []
        rendered.reserveCapacity(expected)
        var tail = 0
        while rendered.count < expected + Int(sampleRate * 2) {
            let status = try engine.renderOffline(4096, to: out)
            guard status == .success, out.frameLength > 0 else { break }
            rendered.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
            if finished { tail += Int(out.frameLength); if tail > Int(sampleRate * tailSeconds) { break } }
        }
        engine.stop()
        // Trim trailing silence and normalise to the same loudness as the source.
        let threshold: Float = 0.002
        if let last = rendered.lastIndex(where: { abs($0) > threshold }) { rendered.removeSubrange(min(rendered.count, last + Int(sampleRate * 0.08))...) }
        let peakIn = samples.reduce(0) { max($0, abs($1)) }, peakOut = rendered.reduce(0) { max($0, abs($1)) }
        if peakOut > 0, peakIn > 0 { let g = min(peakIn / peakOut, 4); rendered = rendered.map { $0 * g } }
        return rendered
    }
}

/// 16-bit PCM WAV bytes for AVAudioPlayer.
enum WAV {
    static func data(samples: [Float], sampleRate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + byteCount); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(byteCount)
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, s) in samples.enumerated() { pcm[i] = Int16(max(-1, min(1, s)) * 32767) }
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }
}
#endif
