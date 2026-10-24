#if !APPSTORE
import AVFoundation
import Foundation

// MARK: - CommandHearing (coucou-custom fork)
//
// Apple's streaming recognizer keeps doing what it is good at (the wake word, live partials,
// turn-end timing). The final text of a command comes from Parakeet, which heard short English
// commands clearly better in the fork's tests ("find me trekking shoes" right 3/3 against 1/3),
// run on the recorded command audio once the turn ends (40–150 ms). Falls back to Apple's text
// when Parakeet is not downloaded or fails.
enum CommandHearing {
    static var usesParakeet: Bool {
        VoiceSettings.commandRecognizer == "parakeet" && Parakeet.installed
    }

    /// Text for 16 kHz mono samples, or nil when Parakeet cannot answer.
    static func transcribe(_ samples: [Float]) async -> String? {
        let t0 = Date()
        do {
            let text = try await Parakeet.shared.transcribe(samples).trimmingCharacters(in: .whitespacesAndNewlines)
            appendAppLog("nb.log", "[Voice] parakeet heard \(text.split(separator: " ").count) words from \(samples.count / 16_000) s in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            return text
        } catch {
            appendAppLog("nb.log", "[Voice] parakeet failed: \(error.localizedDescription)")
            return nil
        }
    }
}

/// Keeps the command's audio for Parakeet: a rolling 3 s ring while idle (the wake fires a
/// moment after the words), then everything from `start` to `stop`. Fed from the audio tap
/// thread, read on the main actor; 16 kHz mono Float32, as `VoiceAudio` delivers it.
final class CommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var ring: [Float] = []
    private var taken: [Float] = []
    private var recording = false
    private static let ringSamples = 16_000 * 3
    private static let maxSamples  = 16_000 * 30

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        lock.withLock {
            if recording {
                if taken.count < Self.maxSamples { taken.append(contentsOf: samples) }
            } else {
                ring.append(contentsOf: samples)
                if ring.count > Self.ringSamples { ring.removeFirst(ring.count - Self.ringSamples) }
            }
        }
    }

    /// Begins a recording that already holds the last `keepingLast` seconds.
    func start(keepingLast seconds: Double) {
        lock.withLock {
            let keep = min(ring.count, Int(seconds * 16_000))
            taken = keep > 0 ? Array(ring.suffix(keep)) : []
            ring.removeAll(keepingCapacity: true)
            recording = true
        }
    }

    func stop() -> [Float] {
        lock.withLock {
            recording = false
            let out = taken
            taken = []
            return out
        }
    }
}
#endif
