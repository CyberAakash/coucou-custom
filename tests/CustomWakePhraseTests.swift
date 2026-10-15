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

        if failures == 0 { print("CustomWakePhraseTests: all passed") } else { exit(1) }
    }
}
