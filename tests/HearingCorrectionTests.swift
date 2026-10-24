import Foundation

@main
enum HearingCorrectionTests {
    static var failures = 0
    static func eq(_ label: String, _ got: String, _ want: String) {
        if got != want { failures += 1; print("FAIL \(label): got \"\(got)\" want \"\(want)\"") }
    }
    static func main() {
        let words = HearingCorrection.personalWords(from: "trekking, Zoho Cliq; Chennai\nMochi")
        if words != ["trekking", "Zoho Cliq", "Chennai", "Mochi"] { failures += 1; print("FAIL personalWords \(words)") }

        eq("one edit", HearingCorrection.correct("find me tracking shoes", personalWords: words), "find me trekking shoes")
        eq("keeps punctuation", HearingCorrection.correct("Tracking, shoe.", personalWords: words), "trekking, shoe.")
        eq("phrase of two words", HearingCorrection.correct("open zoho click now", personalWords: words), "open Zoho Cliq now")
        eq("already right keeps casing", HearingCorrection.correct("Open Zoho Cliq", personalWords: words), "Open Zoho Cliq")
        eq("unrelated untouched", HearingCorrection.correct("what time is it", personalWords: words), "what time is it")
        eq("sound-alike name", HearingCorrection.correct("hey muchi play music", personalWords: words), "hey Mochi play music")
        eq("two edits on a long word", HearingCorrection.correct("open my calinder", personalWords: ["calendar"]), "open my calendar")
        eq("short words stay exact", HearingCorrection.correct("the cat sat", personalWords: ["cot"]), "the cat sat")
        eq("no words no change", HearingCorrection.correct("find me tracking shoes", personalWords: []), "find me tracking shoes")

        eq("strip full wake", HearingCorrection.stripWake("hey mochi open spotify", customPhrase: "Hey Mochi"), "open spotify")
        eq("strip tail of wake", HearingCorrection.stripWake("Moachi open spotify", customPhrase: "Hey Mochi"), "open spotify")
        eq("strip nothing", HearingCorrection.stripWake("open spotify", customPhrase: "Hey Mochi"), "open spotify")
        eq("default wake", HearingCorrection.stripWake("Coucou add github", customPhrase: ""), "add github")
        eq("command that sounds like wake stays", HearingCorrection.stripWake("hey mochi hey there", customPhrase: "Hey Mochi"), "hey there")

        if failures == 0 { print("HearingCorrectionTests: all passed") } else { exit(1) }
    }
}
