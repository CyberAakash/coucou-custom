import Foundation

// MARK: - HearingCorrection (coucou-custom fork)
// Pure functions: no Speech or FluidAudio, compiled into the app and the test script.

/// Fixes what the recognizer almost heard. The user's personal words (brands, places, names)
/// replace a transcript word that sounds within one edit of them: "tracking shoe" with
/// "trekking" in the list becomes "trekking shoe". Also strips a wake phrase Parakeet heard
/// at the start of the recorded command.
enum HearingCorrection {

    /// Splits "trekking, Zoho Cliq; Mochi" into its words and phrases.
    static func personalWords(from text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func correct(_ text: String, personalWords: [String]) -> String {
        let phrases = personalWords.map { word in
            (word, word.split(separator: " ").map { WakePhrase.phoneticFold(WakePhrase.normalise(String($0))) },
             word.split(separator: " ").map { WakePhrase.normalise(String($0)) }.joined())
        }.filter { !$0.1.isEmpty && $0.1.joined().count >= 3 }
        guard !phrases.isEmpty else { return text }
        var words = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        var i = 0
        while i < words.count {
            var replaced = false
            // Longest phrase first so "zoho cliq" wins over "zoho".
            for (spelling, target, plain) in phrases.sorted(by: { $0.1.count > $1.1.count }) where i + target.count <= words.count {
                let slice = words[i..<i + target.count]
                // Already spelled right (any casing): leave it alone.
                if slice.map({ WakePhrase.normalise($0) }).joined() == plain { break }
                let joined = slice.map { WakePhrase.phoneticFold(WakePhrase.normalise($0)) }.joined()
                let want = target.joined()
                let tol = want.count >= 8 ? 2 : want.count >= 5 ? 1 : 0
                guard WakePhrase.editDistance(joined, want) <= tol else { continue }
                // Keep the punctuation that followed the last heard word ("tracking," → "trekking,").
                let last = words[i + target.count - 1]
                let trailing = String(last.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
                words.replaceSubrange(i..<i + target.count, with: [spelling + trailing])
                i += 1; replaced = true
                break
            }
            if !replaced { i += 1 }
        }
        return words.joined(separator: " ")
    }

    /// The command Parakeet heard, without the wake phrase the recording started on. A full match
    /// uses `WakePhrase.split`; otherwise leading words that sound like the wake words are dropped
    /// (the recording starts a little before the wake fired, so it may hold "…mochi open spotify").
    static func stripWake(_ text: String, customPhrase: String) -> String {
        let r = WakePhrase.split(text, customPhrase: customPhrase.isEmpty ? nil : customPhrase)
        if r.matched { return r.command }
        let wakeWords = (customPhrase.isEmpty ? "ok coucou hey coucou" : customPhrase)
            .split(separator: " ").map { WakePhrase.phoneticFold(WakePhrase.normalise(String($0))) }
        var words = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        while let first = words.first {
            let f = WakePhrase.phoneticFold(WakePhrase.normalise(first))
            guard !f.isEmpty, wakeWords.contains(where: { WakePhrase.editDistance(f, $0) <= (f.count >= 4 ? 1 : 0) }) else { break }
            words.removeFirst()
        }
        return words.joined(separator: " ")
    }
}
