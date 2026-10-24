#if !APPSTORE
import SwiftUI

// MARK: - HearingSettingsRows (coucou-custom fork)
// Settings → Voice → Hearing: which recognizer gives the command's final text, the personal
// words it must get right, and a six-second recording heard by both so the choice is made on
// your own voice, not on a benchmark.
struct HearingSettingsRows: View {
    @ObservedObject var engine: VoiceEngine
    @ObservedObject private var parakeet = Parakeet.shared
    @AppStorage(VoiceSettings.commandRecognizerKey) private var recognizer: String = "parakeet"
    @AppStorage(VoiceSettings.personalWordsKey) private var personalWords: String = ""

    private var running: Bool { engine.hearingTest?.running == true }

    var body: some View {
        HubRow(title: String(localized: "hub.hearing.recognizer", defaultValue: "Hears commands with"),
               detail: String(localized: "hub.hearing.recognizer-detail",
                              defaultValue: "Parakeet (NVIDIA, on the Neural Engine) hears short English commands more reliably than Apple's recognizer. Apple's still spots the wake word and shows live words.")) {
            Picker("", selection: $recognizer) {
                Text(verbatim: "Apple").tag("apple")
                Text(verbatim: "Parakeet").tag("parakeet")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        if recognizer == "parakeet" {
            switch parakeet.state {
            case .ready:
                EmptyView()
            case .downloading(let fraction):
                HubNote(text: String(format: String(localized: "hub.hearing.downloading", defaultValue: "Downloading Parakeet… %d%%"), Int(fraction * 100)))
            case .unsupported:
                HubNote(text: String(localized: "hub.hearing.unsupported", defaultValue: "Parakeet needs an Apple silicon Mac. Apple's recognizer is used."), warning: true)
            case .missing, .failed:
                HStack(spacing: 12) {
                    HubNote(text: String(localized: "hub.hearing.missing", defaultValue: "Parakeet is not downloaded (about 650 MB, shared with Coucou Flow). Apple's recognizer is used until then."), warning: true)
                    Button(String(localized: "hub.hearing.download", defaultValue: "Download")) { parakeet.download() }
                        .buttonStyle(HubButtonStyle(primary: true))
                }
            }
        }
        HubDivider()
        HubRow(title: String(localized: "hub.hearing.words", defaultValue: "Words to get right"),
               detail: String(localized: "hub.hearing.words-detail",
                              defaultValue: "Brands, names, places, separated by commas. A word heard almost like one of these is corrected to it.")) {
            HubField(placeholder: String(localized: "hub.hearing.words-placeholder", defaultValue: "trekking, Zoho Cliq, Chennai"), text: $personalWords)
                .frame(width: 280)
        }
        HubDivider()
        HubRow(title: String(localized: "hub.hearing.test", defaultValue: "Record and compare"),
               detail: String(localized: "hub.hearing.test-detail",
                              defaultValue: "Say a command; both recognizers write what they heard. Nothing is saved.")) {
            Button(running ? String(localized: "hub.hearing.listening", defaultValue: "Listening…")
                           : String(localized: "hub.hearing.record", defaultValue: "Record 6 s")) {
                engine.startHearingTest()
            }
            .buttonStyle(HubButtonStyle(primary: !running))
            .disabled(running || !engine.isEnabled || engine.isPaused)
        }
        .onDisappear { engine.clearHearingTest() }
        if let test = engine.hearingTest, !test.running {
            VStack(alignment: .leading, spacing: 6) {
                heard(String(localized: "hub.hearing.apple", defaultValue: "Apple"), test.apple)
                heard(String(localized: "hub.hearing.parakeet", defaultValue: "Parakeet"), test.parakeet)
            }
            .padding(.vertical, 2)
        }
    }

    private func heard(_ who: String, _ text: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(who).font(.system(size: 12, weight: .semibold)).foregroundColor(HubTheme.muted).frame(width: 64, alignment: .leading)
            Text(text.map { $0.isEmpty ? "—" : $0 } ?? String(localized: "hub.hearing.not-run", defaultValue: "(not downloaded)"))
                .font(.system(size: 12.5)).foregroundColor(HubTheme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
