import Foundation

// MARK: - Custom wake phrase tests (coucou-custom fork)

@main
enum CustomWakePhraseTests {
    static var failures = 0

    static func check(_ label: String, _ raw: String, _ phrase: String, matched: Bool, cmd: String = "") {
        let r = WakePhrase.split(raw, customPhrase: phrase)
        if r.matched != matched || (matched && r.command != cmd) {
            failures += 1
            print("FAIL \(label): got matched=\(r.matched) cmd=\"\(r.command)\"")
        }
    }

    static func main() {
        check("basic", "hey jarvis add github", "Hey Jarvis", matched: true, cmd: "add github")
        check("punctuation and case", "Hey, Jarvis! What's on Stripe?", "hey jarvis", matched: true, cmd: "What's on Stripe?")
        check("okay = ok", "okay mochi play music", "OK Mochi", matched: true, cmd: "play music")
        check("recognizer splits a word", "hey jar vis pause", "hey jarvis", matched: true, cmd: "pause")
        check("recognizer merges words", "heymochi next song", "hey mochi", matched: true, cmd: "next song")
        check("single word", "computer open figma", "computer", matched: true, cmd: "open figma")
        check("anywhere, last occurrence", "um hey jarvis no hey jarvis stop", "hey jarvis", matched: true, cmd: "stop")
        check("phrase alone", "hey jarvis", "hey jarvis", matched: true, cmd: "")
        check("replaces ok coucou", "ok coucou add github", "hey jarvis", matched: false)
        check("not inside a word", "computers are great", "computer", matched: false)
        check("partial phrase", "hey there", "hey jarvis", matched: false)
        check("empty phrase keeps default", "ok coucou add github", "", matched: true, cmd: "add github")
        check("blank phrase keeps default", "ok coucou add github", "   ", matched: true, cmd: "add github")

        // Tolerant matching: a misheard letter still wakes, but only on phrases long enough.
        check("one edit, 8 letters", "hey siber what time is it", "Hey Cyber", matched: true, cmd: "what time is it")
        check("one edit after okay=ok", "ok task open spotify", "Okay Tusk", matched: true, cmd: "open spotify")
        check("extra letter heard", "hey moachi play music", "Hey Mochi", matched: true, cmd: "play music")
        check("two edits, 8 letters, rejected", "hey sibre play", "Hey Cyber", matched: false)
        check("plural of single word stays rejected", "hey computers rule", "Hey Jarvis", matched: false)
        check("recognizer spells the sound", "hey mochee next", "Hey Mochi", matched: true, cmd: "next")
        check("two edits, 10+ letters", "hey computor please stop", "Hey Computer", matched: true, cmd: "please stop")
        check("short phrase stays exact", "harvest the data", "jarvis", matched: false)
        check("short phrase exact still works", "jarvis the data", "jarvis", matched: true, cmd: "the data")
        check("unrelated phrase not accepted", "hey siri what time is it", "Hey Cyber", matched: false)
        check("tolerant match keeps last occurrence", "hey siber no hey cyber stop", "Hey Cyber", matched: true, cmd: "stop")
        check("command word not swallowed", "hey cyber cyberpunk", "Hey Cyber", matched: true, cmd: "cyberpunk")

        if WakePhrase.editDistance("kitten", "sitting") != 3 { failures += 1; print("FAIL editDistance kitten/sitting") }
        if WakePhrase.tolerance(for: ["computer"]) != 0 || WakePhrase.tolerance(for: ["ok", "tusk"]) != 1
            || WakePhrase.tolerance(for: ["hey", "cyber"]) != 1 || WakePhrase.tolerance(for: ["hey", "computer"]) != 2
            || WakePhrase.tolerance(for: ["hey", "mo"]) != 0 { failures += 1; print("FAIL tolerance") }
        if WakePhrase.phoneticFold("cyber") != WakePhrase.phoneticFold("siber")
            || WakePhrase.phoneticFold("mochi") != WakePhrase.phoneticFold("mochee") { failures += 1; print("FAIL phoneticFold") }
        if !WakePhrase.resembles("hey siber please", customPhrase: "Hey Cyber") { failures += 1; print("FAIL resembles near") }
        if WakePhrase.resembles("open the window", customPhrase: "Hey Cyber") { failures += 1; print("FAIL resembles far") }
        if WakePhrase.resembles("hey there", customPhrase: "Hey Cyber") { failures += 1; print("FAIL resembles ignores short words") }

        if failures == 0 { print("CustomWakePhraseTests: all passed") } else { exit(1) }
    }
}
