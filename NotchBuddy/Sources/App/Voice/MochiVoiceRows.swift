#if !APPSTORE
import SwiftUI

// MARK: - MochiVoiceRows (coucou-custom fork)
// Settings → Voice → Coucou's voice → Mochi: the base voice, presets, and the character sliders,
// each change heard right away.
struct MochiVoiceRows: View {
    @ObservedObject private var voice = MochiVoice.shared
    @State private var character = MochiCharacter.current

    @AppStorage(VoiceSettings.wakePhraseKey) private var wakePhrase: String = ""
    private var busy: Bool {
        switch voice.state { case .downloading, .loading: return true; default: return false }
    }

    var body: some View {
        switch voice.state {
        case .missing:
            HStack(spacing: 12) {
                HubNote(text: String(localized: "hub.mochi.missing", defaultValue: "Mochi's voice (Kokoro, about 400 MB) is not downloaded yet. The Mac voice is used until then."), warning: true)
                Button(String(localized: "hub.mochi.download", defaultValue: "Download")) { voice.prepare() }
                    .buttonStyle(HubButtonStyle(primary: true))
            }
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: fraction).tint(HubTheme.accent).frame(width: 260)
                HubNote(text: String(format: String(localized: "hub.mochi.downloading", defaultValue: "Downloading Mochi's voice… %d%% of 395 MB"), Int(fraction * 100)))
            }
        case .loading:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                HubNote(text: String(localized: "hub.mochi.loading", defaultValue: "Preparing Mochi's voice for the Neural Engine… about a minute and a half the first time, a few seconds after."))
            }
        case .failed(let why):
            HStack(spacing: 12) {
                HubNote(text: "\(String(localized: "hub.mochi.failed", defaultValue: "Mochi's voice could not load")): \(why)", warning: true)
                Button(String(localized: "hub.mochi.retry", defaultValue: "Retry")) { voice.prepare() }.buttonStyle(HubButtonStyle())
            }
        case .ready:
            HStack(spacing: 12) {
                HubStatusPill(text: String(localized: "hub.mochi.ready", defaultValue: "On this Mac"), tone: .on)
                Spacer()
                Button(String(localized: "hub.mochi.remove", defaultValue: "Remove (395 MB)")) { voice.remove() }.buttonStyle(HubButtonStyle())
            }
        }
        HubRow(title: String(localized: "hub.mochi.preset", defaultValue: "Character")) {
            Picker("", selection: Binding(
                get: { MochiCharacter.presets.firstIndex { $0.character == character } ?? -1 },
                set: { i in if i >= 0 { apply(MochiCharacter.presets[i].character); sayHi() } })) {
                ForEach(Array(MochiCharacter.presets.enumerated()), id: \.offset) { i, p in Text(verbatim: p.name).tag(i) }
                if !MochiCharacter.presets.contains(where: { $0.character == character }) {
                    Text(String(localized: "hub.mochi.custom", defaultValue: "Custom")).tag(-1)
                }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        HubDivider()
        HubRow(title: String(localized: "hub.mochi.base", defaultValue: "Base voice")) {
            Picker("", selection: Binding(get: { character.base }, set: { character.base = $0; save(); sayHi() })) {
                ForEach(MochiCharacter.bases, id: \.id) { b in Text(verbatim: b.name).tag(b.id) }
            }
            .labelsHidden().frame(width: 180)
        }
        HubDivider()
        slider(String(localized: "hub.mochi.pitch", defaultValue: "Pitch"), $character.pitch, -6...12, 0.5, unit: " st")
        slider(String(localized: "hub.mochi.body", defaultValue: "Body size"), $character.body, 1.0...1.45, 0.01, unit: "×", detail: String(localized: "hub.mochi.body-detail", defaultValue: "Higher sounds smaller"))
        slider(String(localized: "hub.mochi.speed", defaultValue: "Speed"), $character.speed, 0.8...1.3, 0.02, unit: "×")
        slider(String(localized: "hub.mochi.robot", defaultValue: "Robot"), $character.robot, 0...1, 0.05, unit: "")
        slider(String(localized: "hub.mochi.echo", defaultValue: "Echo"), $character.echo, 0...0.6, 0.05, unit: "")
        slider(String(localized: "hub.mochi.bright", defaultValue: "Brightness"), $character.bright, -6...8, 0.5, unit: " dB")
        HubRow(title: "") {
            Button {
                sayHi()
            } label: {
                Label(busy ? String(localized: "hub.mochi.preparing", defaultValue: "Preparing…")
                           : String(localized: "hub.mochi.say-hi", defaultValue: "Say hi"),
                      systemImage: "speaker.wave.2.fill")
            }
            .buttonStyle(HubButtonStyle(primary: !busy))
            .disabled(busy)
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ step: Double, unit: String, detail: String? = nil) -> some View {
        Group {
            HubRow(title: title, detail: detail) {
                HStack(spacing: 10) {
                    Slider(value: value, in: range, step: step, onEditingChanged: { editing in if !editing { save(); sayHi() } })
                        .frame(width: 200)
                    Text(String(format: step < 0.1 ? "%.2f%@" : "%.1f%@", value.wrappedValue, unit))
                        .font(.system(size: 12, design: .monospaced)).foregroundColor(HubTheme.secondary)
                        .frame(width: 64, alignment: .trailing)
                }
            }
            HubDivider()
        }
    }

    private func apply(_ c: MochiCharacter) { character = c; save() }
    private func save() { MochiCharacter.current = character }
    /// One sample, in the wake phrase you chose; while the voice downloads or warms up it plays
    /// once it is ready instead of once per click.
    private func sayHi() {
        voice.speakSample(VoiceSettings.sampleSentence(wakePhrase: wakePhrase), locale: Locale(identifier: "en-US"))
    }
}
#endif
