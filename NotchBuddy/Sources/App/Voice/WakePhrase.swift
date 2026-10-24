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
    /// the recognizer splitting or merging words ("jar vis" / "jarvis", "heymochi") still matches,
    /// after a phonetic fold and within `tolerance(for:)` edits, so a misheard letter
    /// ("hey siber", "ok task") still wakes.
    private static func lastCustomMatchEnd(_ normWords: [String], phrase: String) -> Int? {
        let target = normalise(phrase).split(separator: " ").map { normWord(String($0)) }
        let joined = phoneticFold(target.joined())
        guard !joined.isEmpty else { return nil }
        let tol = tolerance(for: target)
        var last: Int? = nil
        for start in normWords.indices {
            var concat = ""
            for end in start..<min(normWords.count, start + target.count + 2) {
                concat += normWords[end]
                let heard = phoneticFold(concat)
                if heard.count > joined.count + tol { break }
                if heard.count + tol >= joined.count, editDistance(heard, joined) <= tol {
                    last = max(last ?? 0, end + 1); break
                }
            }
        }
        return last
    }

    /// Edits allowed between the phrase and what was heard. A single word gets none ("computer"
    /// must not wake on "computers"); the lead-in word of a longer phrase is what guards it.
    static func tolerance(for phraseWords: [String]) -> Int {
        guard phraseWords.count >= 2 else { return 0 }
        switch phraseWords.joined().count {
        case ..<6:  return 0
        case 6...9: return 1
        default:    return 2
        }
    }

    /// Collapses spellings the recognizer swaps for the same sound (cyber/siber, phil/fil,
    /// mochi/mochee), applied to both sides before comparing.
    static func phoneticFold(_ s: String) -> String {
        var t = s
        for (from, to) in [("ph", "f"), ("ck", "k"), ("ce", "se"), ("ci", "si"), ("cy", "si"),
                           ("c", "k"), ("q", "k"), ("z", "s"), ("y", "i"), ("ee", "i"), ("ea", "i")] {
            t = t.replacingOccurrences(of: from, with: to)
        }
        var out = ""
        for ch in t where ch != out.last { out.append(ch) }   // "tt" → "t"
        return out
    }

    /// Levenshtein distance; both strings are a handful of letters.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur  = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let sub = prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, sub)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// True when a word of `raw` sounds one edit away from a word (4+ letters) of the custom
    /// phrase: the "heard something close but not the phrase" diagnostic of the wake-window log.
    static func resembles(_ raw: String, customPhrase: String) -> Bool {
        let targets = normalise(customPhrase).split(separator: " ")
            .map { phoneticFold(normWord(String($0))) }.filter { $0.count >= 4 }
        guard !targets.isEmpty else { return false }
        let words = raw.components(separatedBy: .whitespaces).map { phoneticFold(normWord($0)) }
        return words.contains { w in !w.isEmpty && targets.contains { editDistance(w, $0) <= 1 } }
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
