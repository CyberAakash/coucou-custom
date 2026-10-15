import Foundation

// MARK: - WakePhrase
// Pure functions — no Speech or AVFoundation dependencies.
// Compiled into both the app and standalone test scripts.

enum WakePhrase {

    // MARK: - Public API

    struct SplitResult {
        let matched: Bool
        /// Words after the LAST wake phrase occurrence, extracted from the **original** transcript
        /// (original casing, apostrophes, hyphens, accents preserved).
        /// Leading punctuation on the first word is stripped.
        let command: String
    }

    /// Scans `raw` for a wake phrase at a word boundary (anywhere in the transcript,
    /// not just the start). Returns the text following the **last** occurrence as the command,
    /// preserving the original casing and punctuation of the command portion.
    ///
    /// Accepted patterns (case-insensitive, after phonetic normalisation):
    /// - "ok coucou" and variants: "okay coucou", "ok cuckoo", "ok kuku", "ok cou cou" …
    /// - "hey coucou"
    ///
    /// Word-boundary search means "euh ok coucou add" matches and returns "add".
    /// Standalone "coucou" never matches (no preceding "ok"/"hey").
    ///
    /// A non-empty `customPhrase` (coucou-custom fork) replaces the "OK Coucou" patterns.
    static func split(_ raw: String, customPhrase: String? = nil) -> SplitResult {
        // Split original into whitespace-separated tokens (punctuation stays attached to words)
        let originalWords = raw.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard !originalWords.isEmpty else { return SplitResult(matched: false, command: "") }

        // Normalise each word independently for wake-phrase matching only
        let normWords = originalWords.map(normWord)

        if let customPhrase, !normalise(customPhrase).isEmpty {
            guard let end = lastCustomMatchEnd(normWords, phrase: customPhrase) else {
                return SplitResult(matched: false, command: "")
            }
            return result(originalWords, after: end)
        }

        // Wake phrase patterns (normalised).
        // "ok cou cou" handled as a 3-token pattern in case the STT splits it.
        let patterns: [[String]] = [
            ["ok",  "coucou"],
            ["ok",  "cou", "cou"],
            ["hey", "coucou"],
            ["hey", "cou", "cou"],
        ]

        // Find LAST occurrence of any pattern
        var lastMatchEnd: Int? = nil   // word index immediately after the matched pattern

        for pattern in patterns {
            guard normWords.count >= pattern.count else { continue }
            var i = 0
            while i <= normWords.count - pattern.count {
                if Array(normWords[i ..< i + pattern.count]) == pattern {
                    let end = i + pattern.count
                    if lastMatchEnd == nil || end > lastMatchEnd! { lastMatchEnd = end }
                    i = end   // resume search after this match
                } else {
                    i += 1
                }
            }
        }

        guard let end = lastMatchEnd else { return SplitResult(matched: false, command: "") }
        return result(originalWords, after: end)
    }

    private static func result(_ originalWords: [String], after end: Int) -> SplitResult {
        let tail = Array(originalWords[end...])
        guard !tail.isEmpty else { return SplitResult(matched: true, command: "") }

        // Strip leading punctuation from the first command word
        var first = tail[0]
        while let c = first.first, !c.isLetter && !c.isNumber { first = String(first.dropFirst()) }

        let parts = ([first] + Array(tail.dropFirst())).filter { !$0.isEmpty }
        return SplitResult(matched: true, command: parts.joined(separator: " "))
    }

    /// Normalise a string for cancel-phrase comparison: lowercase + strip punctuation.
    static func normalise(_ s: String) -> String {
        s.lowercased()
         .components(separatedBy: .punctuationCharacters)
         .joined()
         .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Private

    /// Word index just after the last occurrence of `phrase`. Compared with spaces removed, so
    /// the recognizer splitting or merging words ("jar vis" / "jarvis", "heymochi") still matches.
    private static func lastCustomMatchEnd(_ normWords: [String], phrase: String) -> Int? {
        let target = normalise(phrase).split(separator: " ").map { normWord(String($0)) }
        let joined = target.joined()
        guard !joined.isEmpty else { return nil }
        var last: Int? = nil
        for start in normWords.indices {
            var concat = ""
            for end in start..<min(normWords.count, start + target.count + 2) {
                concat += normWords[end]
                if concat == joined { last = max(last ?? 0, end + 1); break }
                if concat.count >= joined.count { break }
            }
        }
        return last
    }

    /// Normalise a single word token for wake-phrase matching.
    private static func normWord(_ w: String) -> String {
        var t = normalise(w)
        t = t
            .replacingOccurrences(of: "cuckoo", with: "coucou")
            .replacingOccurrences(of: "kuku",   with: "coucou")
            .replacingOccurrences(of: "kucou",  with: "coucou")
            .replacingOccurrences(of: "okay",   with: "ok")
        return t
    }
}
