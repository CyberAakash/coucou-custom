#if !APPSTORE
import SwiftUI

// MARK: - WakePhraseTestRows (coucou-custom fork)
//
// Settings → Voice → Wake word: "Test the wake phrase". For 20 seconds, shows what the live
// wake windows hear and whether each line would have woken Coucou. Apple's recognizer is
// speaker-independent, so there is nothing to enrol; the fix for a phrase that never wakes
// is to spell it the way the recognizer spells it, and this is where that spelling shows.
// The words stay in this view's memory and are never written to nb.log (docs/VOICE.md).
struct WakePhraseTestRows: View {
    @ObservedObject var engine: VoiceEngine
    let phrase: String

    @State private var now = Date()
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var running: Bool { engine.wakeTest.map { !$0.finished } ?? false }

    var body: some View {
        HubRow(title: String(localized: "hub.voice.test", defaultValue: "Test the wake phrase"),
               detail: String(localized: "hub.voice.test-detail",
                              defaultValue: "Say it a few times. Shows what Coucou hears for 20 seconds; nothing is saved.")) {
            Button(running ? String(localized: "hub.voice.test-stop", defaultValue: "Stop")
                           : String(localized: "hub.voice.test-start", defaultValue: "Listen")) {
                if running { engine.stopWakeTest() } else { engine.startWakeTest() }
            }
            .buttonStyle(HubButtonStyle(primary: !running))
            .disabled(!engine.isEnabled || engine.isPaused)
        }
        .onReceive(tick) { now = $0 }
        .onDisappear { engine.clearWakeTest() }

        if !engine.isEnabled {
            HubNote(text: String(localized: "hub.voice.test-off", defaultValue: "Turn voice on first."), warning: true)
        } else if engine.isPaused {
            HubNote(text: String(localized: "hub.voice.test-paused",
                                 defaultValue: "Voice is paused (screen locked, low power or dictation in progress)."), warning: true)
        }

        if let test = engine.wakeTest {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(test.heard.enumerated()), id: \.offset) { _, line in
                    heardLine(line)
                }
                if !test.current.isEmpty {
                    Text(test.current + " …")
                        .font(.system(size: 12.5).italic())
                        .foregroundColor(HubTheme.secondary)
                }
                if running {
                    Text(test.heard.isEmpty && test.current.isEmpty
                         ? String(localized: "hub.voice.test-listening", defaultValue: "Listening… say « \(phrase) »")
                         : String(format: String(localized: "hub.voice.test-left", defaultValue: "%d s left"),
                                  max(0, Int(test.endsAt.timeIntervalSince(now).rounded(.up)))))
                        .font(.system(size: 11.5))
                        .foregroundColor(HubTheme.muted)
                } else {
                    verdict(test)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func heardLine(_ line: String) -> some View {
        let woke = WakePhrase.split(line, customPhrase: phrase == "OK Coucou" ? nil : phrase).matched
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: woke ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11))
                .foregroundColor(woke ? HubTheme.green : HubTheme.muted)
            Text(line)
                .font(.system(size: 12.5))
                .foregroundColor(woke ? HubTheme.text : HubTheme.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func verdict(_ test: VoiceEngine.WakeTestState) -> some View {
        if test.heard.isEmpty {
            HubNote(text: String(localized: "hub.voice.test-nothing",
                                 defaultValue: "Nothing heard. Check the microphone, then try again closer to it."), warning: true)
        } else if test.matches > 0 {
            Text(String(format: String(localized: "hub.voice.test-woke", defaultValue: "Woke up %d time(s)."), test.matches))
                .font(.system(size: 12)).foregroundColor(HubTheme.green)
        } else {
            HubNote(text: String(localized: "hub.voice.test-missed",
                                 defaultValue: "Heard you, but not « \(phrase) ». If a line above is how you said it, set the wake phrase to that spelling."),
                    warning: true)
        }
    }
}
#endif
