#if !APPSTORE
import AppKit
import ServiceManagement
import SwiftUI

// coucou-custom fork: the Coucou window's General page, in the window's own style (HubPageScaffold,
// HubGlowCard, HubCard, HubRow) like Settings and Buddy. Same settings as SettingsView's
// generalSection, which the App Store build still shows in its own Settings window: a toggle
// upstream adds there has to be added here too.

struct HubGeneralPage: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var demo = DemoEngine.shared
    @Environment(\.hubVisible) private var visible

    @AppStorage(NotchAlertRules.openOnFinishKey) private var openOnFinish = true
    @AppStorage(NotchAlertRules.openOnErrorKey) private var openOnError = true
    @AppStorage(NotchAlertRules.ambientKey) private var ambientPulse = true
    @AppStorage(IslandClickOutside.key) private var closesOnClickOutside = true   // coucou-custom fork
    #if !APPSTORE
    @AppStorage(FileShelf.enabledKey) private var shelfEnabled = true             // coucou-custom fork
    @AppStorage(FileShelf.dropModeKey) private var shelfDropMode = "ask"          // coucou-custom fork
    #endif
    @AppStorage(IslandPages.enabledKey) private var pageBar = true                 // coucou-custom fork
    #if !APPSTORE
    @AppStorage(EventPeeks.powerKey) private var peekPower = true                  // coucou-custom fork
    @AppStorage(EventPeeks.networkKey) private var peekNetwork = true              // coucou-custom fork
    @AppStorage(EventPeeks.audioKey) private var peekAudio = true                  // coucou-custom fork
    #endif
    @AppStorage(IslandPages.wheelKey) private var pageWheel = true                 // coucou-custom fork
    @AppStorage(NotchAlertRules.openWhenTerminalInFrontKey) private var openWhenTerminalInFront = true
    #if PHONE_LINK
    @AppStorage("iPhoneSyncEnabled") private var iPhoneSyncEnabled = false
    @AppStorage("iPhoneLiveActivityEnabled") private var iPhoneLiveActivityEnabled = false
    @AppStorage("iPhoneInstructionsEnabled") private var iPhoneInstructionsEnabled = false
    #endif

    @State private var hotkeyFlags: UInt = AppState.shared.hotkeyFlags
    @State private var hotkeyCode: UInt16 = AppState.shared.hotkeyCode
    @State private var launchAtStartup = SMAppService.mainApp.status == .enabled
    @State private var startupError = ""
    @State private var connectedScreens: [(uuid: String, name: String)] = []
    @State private var customSoundCount = SoundEngine.shared.customized.count

    var body: some View {
        HubPageScaffold(title: String(localized: "General"), subtitle: HubPage.notchSubtitle(.general)) {
            demoCard

            HubLabel(String(localized: "hub.general.notch", defaultValue: "Notch"))
            notchCard

            HubLabel(String(localized: "hub.general.alerts", defaultValue: "When it opens by itself"))
            alertsCard

            #if !APPSTORE
            // coucou-custom fork
            HubLabel("Peeks")
            peeksCard
            #endif

            HubLabel(String(localized: "spotlight.title", defaultValue: "Spotlight"))
            HubSpotlightCard(enabled: ambientPulse, animating: visible)

            HubLabel(String(localized: "Sound"))
            soundCard

            HubLabel(String(localized: "hub.general.mac", defaultValue: "This Mac"))
            macCard

            HubLabel(String(localized: "Weekly recap"))
            recapCard

            #if PHONE_LINK
            HubLabel("iPhone")
            iPhoneCard
            #endif

            HubLabel(String(localized: "update.settings.title"))
            updatesCard
        }
        .onAppear { refreshConnectedScreens() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            refreshConnectedScreens()
        }
    }

    #if !APPSTORE
    // MARK: - Peeks (coucou-custom fork)

    private var peeksCard: some View {
        HubCard {
            HubRow(title: "Charger",
                   detail: "The notch says for a moment when the Mac is plugged in or goes on battery.") {
                Toggle("", isOn: $peekPower).toggleStyle(.switch).labelsHidden()
            }
            HubDivider()
            HubRow(title: "Network",
                   detail: "When Wi‑Fi connects, the Mac goes offline or comes back online.") {
                Toggle("", isOn: $peekNetwork).toggleStyle(.switch).labelsHidden()
            }
            HubDivider()
            HubRow(title: "Sound output",
                   detail: "When headphones, AirPods or a speaker take over the sound.") {
                Toggle("", isOn: $peekAudio).toggleStyle(.switch).labelsHidden()
            }
        }
    }
    #endif

    // MARK: - Demo

    private var demoCard: some View {
        HubGlowCard(color: HubTheme.accent, padding: 22) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle().fill(demo.isActive ? HubTheme.green : HubTheme.muted).frame(width: 7, height: 7)
                        Text(demo.isActive ? String(localized: "hub.general.demo-on", defaultValue: "Demo running")
                                           : String(localized: "demo.groupbox.title"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(demo.isActive ? HubTheme.green : HubTheme.secondary)
                    }
                    Text(String(localized: "hub.general.demo-title", defaultValue: "See everything Mochi does"))
                        .font(.system(size: 21, weight: .bold))
                        .foregroundColor(HubTheme.text)
                    Text(String(localized: "demo.description"))
                        .font(.system(size: 13))
                        .foregroundColor(HubTheme.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(demo.isActive ? String(localized: "demo.stop") : String(localized: "demo.start")) {
                    if demo.isActive { DemoEngine.shared.stop() } else { DemoEngine.shared.start() }
                }
                .buttonStyle(HubButtonStyle(primary: !demo.isActive))
            }
        }
    }

    // MARK: - Notch

    private var notchCard: some View {
        HubCard {
            HubRow(title: String(localized: "Open on hover"),
                   detail: String(localized: "Hovering the island opens it; it folds again shortly after the pointer leaves. Click inside to keep it open.")) {
                hubSwitch($state.openOnHover)
            }
            HubDivider()
            HubRow(title: String(localized: "alerts.all-pills"), detail: String(localized: "alerts.all-pills.help")) {
                hubSwitch($state.alertsFromAllPills)
            }
            HubDivider()
            HubRow(title: String(localized: "Show Mochi on"),
                   detail: String(localized: "On a screen without a notch, Mochi sits in a small bar at the top. Follow the mouse moves it to your cursor's screen while it is closed.")) {
                Picker("", selection: $state.islandDisplay) {
                    Text("Screen with the notch").tag(IslandDisplayChoice.notch)
                    Text("Main screen (menu bar)").tag(IslandDisplayChoice.menuBar)
                    Text("Follow the mouse").tag(IslandDisplayChoice.followMouse)
                    Divider()
                    ForEach(connectedScreens, id: \.uuid) { screen in
                        Text(screen.name).tag(IslandDisplayChoice.display(uuid: screen.uuid))
                    }
                    if case .display(let uuid) = state.islandDisplay,
                       !connectedScreens.contains(where: { $0.uuid == uuid }) {
                        Text("Saved screen (not connected)").tag(state.islandDisplay)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            HubDivider()
            HubRow(title: String(localized: "Close after"),
                   detail: String(localized: "hub.general.close-detail", defaultValue: "Folds the open notch when nothing happens in it.")) {
                numberField($state.autoCloseInterval, unit: String(localized: "s inactive"))
            }
            HubDivider()
            // coucou-custom fork
            HubRow(title: "Close on a click outside",
                   detail: "Folds the open notch when you click anywhere else; never while a permission or a question waits.") {
                Toggle("", isOn: $closesOnClickOutside).toggleStyle(.switch).labelsHidden()
            }
            HubDivider()
            // coucou-custom fork: the page bar.
            HubRow(title: "Page bar",
                   detail: "Dots along the bottom of the open notch: home, chat, shelf, sessions. ← and → turn the page.") {
                Toggle("", isOn: $pageBar).toggleStyle(.switch).labelsHidden()
            }
            if pageBar {
                HubDivider()
                HubRow(title: "Swipe or scroll between pages",
                       detail: "A sideways swipe on the trackpad turns the page anywhere; the mouse wheel does on the home page.") {
                    Toggle("", isOn: $pageWheel).toggleStyle(.switch).labelsHidden()
                }
            }
            HubDivider()
            #if !APPSTORE
            // coucou-custom fork: the file shelf.
            HubRow(title: "File shelf",
                   detail: "Files dropped on the notch wait on a shelf (the tray tab) until you drag them out again.") {
                Toggle("", isOn: $shelfEnabled).toggleStyle(.switch).labelsHidden()
            }
            if shelfEnabled {
                HubDivider()
                HubRow(title: "After a drop",
                       detail: "Ask what to do with the file (chat, mail), or just keep it on the shelf.") {
                    Picker("", selection: $shelfDropMode) {
                        Text("Ask what to do").tag("ask")
                        Text("Keep on the shelf").tag("shelf")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            HubDivider()
            #endif
            HubRow(title: String(localized: "Hide after"),
                   detail: String(localized: "hub.general.hide-detail", defaultValue: "Hides Mochi while you are away from the Mac.")) {
                numberField(absenceMinutes, unit: String(localized: "min without movement"))
            }
            HubDivider()
            HubRow(title: String(localized: "Show island with shortcut")) {
                HStack(spacing: 10) {
                    if state.hotkeyEnabled {
                        ShortcutRecorderButton(flags: $hotkeyFlags, code: $hotkeyCode, hubStyle: true)
                            .onChange(of: hotkeyFlags) { _, v in
                                state.hotkeyFlags = v
                                HotKeyCenter.shared.reregister(.toggleIsland)
                            }
                            .onChange(of: hotkeyCode) { _, v in
                                state.hotkeyCode = v
                                HotKeyCenter.shared.reregister(.toggleIsland)
                            }
                    }
                    hubSwitch($state.hotkeyEnabled)
                        .onChange(of: state.hotkeyEnabled) { _, _ in HotKeyCenter.shared.reregister(.toggleIsland) }
                }
            }
        }
    }

    private var absenceMinutes: Binding<Double> {
        Binding(get: { state.absenceInterval / 60 }, set: { state.absenceInterval = max(1, $0) * 60 })
    }

    // MARK: - Alerts

    private var alertsCard: some View {
        HubCard {
            HubRow(title: String(localized: "alerts.open-finish", defaultValue: "Open when a session's work is done"),
                   detail: String(localized: "alerts.open-finish.help", defaultValue: "Not while its background agents still run. Permissions and questions always open the notch.")) {
                hubSwitch($openOnFinish)
            }
            HubRow(title: String(localized: "hub.general.terminal-front", defaultValue: "Even when its terminal is in front")) {
                hubSwitch($openWhenTerminalInFront).disabled(!openOnFinish)
            }
            .padding(.leading, 18)
            .opacity(openOnFinish ? 1 : 0.5)
            HubDivider()
            HubRow(title: String(localized: "alerts.open-error", defaultValue: "Open when a session stops on an error")) {
                hubSwitch($openOnError)
            }
            HubDivider()
            HubRow(title: String(localized: "hub.general.ambient", defaultValue: "For everything else: sound, wiggle and the spotlight"),
                   detail: String(localized: "alerts.ambient.help", defaultValue: "Session start, agents starting and finishing, a turn that left agents running.")) {
                hubSwitch($ambientPulse)
            }
        }
    }

    // MARK: - Sound

    private var soundCard: some View {
        HubCard {
            HubRow(title: String(localized: "Enable sounds")) { hubSwitch($state.soundEnabled) }
            HubDivider()
            HubRow(title: String(localized: "Volume")) {
                HStack(spacing: 10) {
                    Slider(value: $state.soundVolume, in: 0...0.2).frame(width: 200)
                    Text("\(Int(state.soundVolume / 0.2 * 100)) %")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(HubTheme.secondary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
            .disabled(!state.soundEnabled)
            HubDivider()
            HubRow(title: String(localized: "hub.general.custom-sounds", defaultValue: "Your own sounds"),
                   detail: String(localized: "Drop a file named like one of Mochi's sounds (finish.wav, approval.mp3, greet.m4a…) in the sounds folder to replace it, then Reload.")) {
                HStack(spacing: 8) {
                    if customSoundCount > 0 {
                        Text(String(format: String(localized: "%lld custom"), Int64(customSoundCount)))
                            .font(.system(size: 12))
                            .foregroundColor(HubTheme.secondary)
                    }
                    Button(String(localized: "Open sounds folder")) { SoundEngine.shared.revealCustomFolder() }
                        .buttonStyle(HubButtonStyle())
                    Button(String(localized: "Reload sounds")) {
                        SoundEngine.shared.reload()
                        customSoundCount = SoundEngine.shared.customized.count
                        SoundEngine.shared.play("pop")
                    }
                    .buttonStyle(HubButtonStyle())
                }
            }
            .disabled(!state.soundEnabled)
        }
    }

    // MARK: - This Mac

    private var macCard: some View {
        HubCard {
            HubRow(title: String(localized: "vitals.toggle"), detail: String(localized: "vitals.about")) {
                hubSwitch(Binding(get: { MachineVitals.shared.enabled }, set: { MachineVitals.shared.enabled = $0 }))
            }
            HubDivider()
            HubRow(title: String(localized: "Launch at Mac startup"), detail: startupError.isEmpty ? nil : startupError) {
                hubSwitch(Binding(get: { launchAtStartup }, set: { toggleStartup($0) }))
            }
            HubDivider()
            HubRow(title: String(localized: "Language"), detail: String(localized: "Applies on next launch")) {
                HStack(spacing: 8) {
                    Picker("", selection: $state.appLanguage) {
                        Text(String(localized: "System")).tag("")
                        ForEach(Self.languages, id: \.code) { Text(verbatim: $0.name).tag($0.code) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: state.appLanguage) { _, code in
                        if code.isEmpty { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
                        else { UserDefaults.standard.set([code], forKey: "AppleLanguages") }
                    }
                    Button(String(localized: "Restart Coucou")) { restart() }
                        .buttonStyle(HubButtonStyle())
                }
            }
        }
    }

    static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("hi", "हिन्दी"),
        ("es", "Español"), ("ar", "العربية"), ("fr", "Français"), ("bn", "বাংলা"),
        ("pt-BR", "Português (Brasil)"), ("ru", "Русский"), ("id", "Bahasa Indonesia"),
        ("de", "Deutsch"), ("tr", "Türkçe"), ("th", "ไทย"),
    ]

    private func toggleStartup(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtStartup = on
            startupError = ""
        } catch {
            startupError = "❌ \(error.localizedDescription)"
        }
    }

    /// Waits for this process to end, then opens the app again.
    private func restart() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$1\"",
                          "--", Bundle.main.bundleURL.path]
        try? task.run()
        BackgroundMode.quitCompletely()
    }

    // MARK: - Recap, iPhone, updates

    private var recapCard: some View {
        HubCard {
            HubRow(title: String(localized: "Keep a history of my coding sessions"),
                   detail: String(localized: "Stored locally on your Mac. Nothing leaves your Mac. Retained for 12 weeks.")) {
                hubSwitch($state.recapEnabled)
            }
            HubDivider()
            HubRow(title: String(localized: "Hide project names in shared images")) {
                hubSwitch($state.recapHideProjects).disabled(!state.recapEnabled)
            }
            HubDivider()
            HStack {
                Spacer()
                Button(String(localized: "Clear history")) { RecapStore.shared.clearHistory() }
                    .buttonStyle(HubButtonStyle())
            }
        }
    }

    #if PHONE_LINK
    private var iPhoneCard: some View {
        HubCard {
            HubRow(title: String(localized: "iphone.sync.toggle"), detail: String(localized: "iphone.sync.description")) {
                hubSwitch($iPhoneSyncEnabled)
                    .onChange(of: iPhoneSyncEnabled) { _, on in CloudProbe.shared.setEnabled(on) }
            }
            HubDivider()
            HubRow(title: String(localized: "iphone.live-activity.toggle"), detail: String(localized: "iphone.live-activity.description")) {
                hubSwitch($iPhoneLiveActivityEnabled)
                    .disabled(!iPhoneSyncEnabled)
                    .onChange(of: iPhoneLiveActivityEnabled) { _, on in LiveActivityRelay.shared.setEnabled(on) }
            }
            HubDivider()
            HubRow(title: String(localized: "iphone.instruction.toggle"), detail: String(localized: "iphone.instruction.description")) {
                hubSwitch($iPhoneInstructionsEnabled)
                    .disabled(!iPhoneSyncEnabled)
                    .onChange(of: iPhoneInstructionsEnabled) { _, on in InstructionRunner.shared.setEnabled(on) }
            }
        }
    }
    #endif

    @ViewBuilder private var updatesCard: some View {
        if MacUpdater.disabledInFork {
            HubCard {
                Text(String(localized: "update.settings.fork",
                            defaultValue: "Coucou Custom doesn't update itself: the official update would replace it and drop your customizations. Update from your fork: scripts/custom-sync-upstream.sh, then scripts/custom-install.sh."))
                    .font(.system(size: 12.5))
                    .foregroundColor(HubTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            UpdateSettingsSection()
        }
    }

    // MARK: - Pieces

    private func hubSwitch(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden()
    }

    private func numberField(_ value: Binding<Double>, unit: String) -> some View {
        HStack(spacing: 8) {
            TextField("", value: value, format: .number)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
                .frame(width: 52, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(HubTheme.field))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
            Text(unit)
                .font(.system(size: 12))
                .foregroundColor(HubTheme.secondary)
        }
    }

    private func refreshConnectedScreens() {
        connectedScreens = NSScreen.screens.compactMap { screen in
            IslandWindowController.displayUUID(screen).map { ($0, screen.localizedName) }
        }
    }
}

// MARK: - Spotlight

/// The spotlight's settings over a live preview: a notch on a wallpaper, lit by the chosen
/// event on a loop, following every slider as it moves.
private struct HubSpotlightCard: View {
    let enabled: Bool
    let animating: Bool

    @AppStorage(SpotlightSettings.brightnessKey) private var brightness = SpotlightSettings.defaultBrightness
    @AppStorage(SpotlightSettings.sizeKey) private var size = 1.0
    @AppStorage(SpotlightSettings.softnessKey) private var softness = 1.0
    @AppStorage(SpotlightSettings.colorModeKey) private var colorMode = SpotlightSettings.ColorMode.byEvent.rawValue
    @AppStorage(SpotlightSettings.colorKey) private var colorHex = SpotlightSettings.defaultColor
    @AppStorage(SpotlightSettings.motionKey) private var moving = true
    @AppStorage(SpotlightSettings.breatheKey) private var breathe = true
    @State private var event: NotchPulse.Kind = .sessionStart

    private static let events: [(kind: NotchPulse.Kind, label: String)] = [
        (.sessionStart, String(localized: "spotlight.preview.start", defaultValue: "Session start")),
        (.promptSent, String(localized: "spotlight.preview.prompt", defaultValue: "Prompt sent")),
        (.agentStart, String(localized: "spotlight.preview.agent", defaultValue: "Agent start")),
        (.finishedQuiet, String(localized: "spotlight.preview.done", defaultValue: "Done")),
        (.errorQuiet, String(localized: "spotlight.preview.error", defaultValue: "Error")),
    ]
    private static let swatches = ["#A78BFA", "#60A5FA", "#22D3EE", "#4ADE80", "#FBBF24", "#FB923C", "#F472B6"]

    var body: some View {
        HubCard(padding: 0) {
            stage
            VStack(alignment: .leading, spacing: 12) {
                eventChips
                HubDivider()
                slider(String(localized: "spotlight.brightness", defaultValue: "Brightness"), $brightness,
                       SpotlightSettings.brightnessRange, "\(Int(SpotlightSettings.clamped(brightness, SpotlightSettings.brightnessRange) * 100)) %")
                HubDivider()
                slider(String(localized: "spotlight.size", defaultValue: "Size"), $size, SpotlightSettings.sizeRange,
                       String(format: "%.1f×", SpotlightSettings.clamped(size, SpotlightSettings.sizeRange)))
                HubDivider()
                slider(String(localized: "spotlight.softness", defaultValue: "Softness"), $softness, SpotlightSettings.softnessRange,
                       softness < 0.7 ? String(localized: "Crisp") : softness > 1.25 ? String(localized: "Very soft") : String(localized: "Soft"))
                HubDivider()
                HubRow(title: String(localized: "spotlight.colors", defaultValue: "Colours")) {
                    Picker("", selection: $colorMode) {
                        Text(String(localized: "spotlight.colors.event", defaultValue: "By event")).tag(SpotlightSettings.ColorMode.byEvent.rawValue)
                        Text(String(localized: "spotlight.colors.single", defaultValue: "One colour")).tag(SpotlightSettings.ColorMode.single.rawValue)
                        Text(String(localized: "spotlight.colors.white", defaultValue: "White")).tag(SpotlightSettings.ColorMode.white.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if colorMode == SpotlightSettings.ColorMode.single.rawValue {
                    HStack(spacing: 8) {
                        Spacer()
                        ForEach(Self.swatches, id: \.self) { hex in swatch(hex) }
                        ColorPicker("", selection: Binding(
                            get: { Color(hex: colorHex) },
                            set: { colorHex = $0.hexString ?? SpotlightSettings.defaultColor }
                        ), supportsOpacity: false)
                        .labelsHidden()
                    }
                }
                HubDivider()
                HubRow(title: String(localized: "spotlight.motion", defaultValue: "Moving colours"),
                       detail: String(localized: "hub.spotlight.motion-detail", defaultValue: "Off: one still glow.")) {
                    Toggle("", isOn: $moving).toggleStyle(.switch).labelsHidden()
                }
                HubDivider()
                HubRow(title: String(localized: "spotlight.breathe", defaultValue: "Breathe while agents run"),
                       detail: String(localized: "hub.spotlight.breathe-detail", defaultValue: "A calm glow until the last background agent finishes.")) {
                    Toggle("", isOn: $breathe).toggleStyle(.switch).labelsHidden()
                }
                HubDivider()
                HStack(spacing: 8) {
                    Spacer()
                    Button(String(localized: "spotlight.reset", defaultValue: "Reset")) { reset() }
                        .buttonStyle(HubButtonStyle())
                    Button(String(localized: "hub.spotlight.try", defaultValue: "Try on the notch")) { NotchPulse.shared.preview(event) }
                        .buttonStyle(HubButtonStyle(primary: true))
                }
            }
            .padding(18)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
    }

    /// A wallpaper strip with a notch at its top, lit like the real one.
    private var stage: some View {
        let notchW: CGFloat = 190, notchH: CGFloat = 32
        return ZStack(alignment: .top) {
            LinearGradient(colors: [Color(hex: "#1B2A4A"), Color(hex: "#2A1F3D"), Color(hex: "#0F1A2B")],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            ZStack(alignment: .topLeading) {
                NotchHalo(width: notchW, height: notchH, cornerRadius: IslandConst.roundedCorner, topRadius: 0,
                          preview: enabled && animating ? event : nil)
                IslandShape(width: notchW, height: notchH, cornerRadius: IslandConst.roundedCorner, topRadius: 0)
                    .fill(Color.black)
            }
            .frame(width: notchW, height: notchH)
            if !enabled {
                Text(String(localized: "hub.spotlight.off", defaultValue: "Turned off above"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(HubTheme.secondary)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(height: 170)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(alignment: .bottom) { Rectangle().fill(HubTheme.line).frame(height: 1) }
    }

    private var eventChips: some View {
        HubRow(title: String(localized: "hub.spotlight.event", defaultValue: "Preview")) {
            HStack(spacing: 4) {
                ForEach(Self.events, id: \.kind) { e in
                    let on = event == e.kind
                    Button { event = e.kind } label: {
                        HStack(spacing: 5) {
                            Circle().fill(e.kind.palette[0]).frame(width: 6, height: 6)
                            Text(e.label).font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundColor(on ? HubTheme.onAccent : HubTheme.body)
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(on ? HubTheme.accent : Color.white.opacity(0.05)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(HubTheme.field))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ readout: String) -> some View {
        HubRow(title: title) {
            HStack(spacing: 10) {
                Slider(value: value, in: range).frame(width: 220)
                Text(readout)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(HubTheme.secondary)
                    .monospacedDigit()
                    .frame(width: 64, alignment: .trailing)
            }
        }
    }

    private func swatch(_ hex: String) -> some View {
        let on = colorHex.uppercased() == hex.uppercased()
        return Button { colorHex = hex } label: {
            Circle().fill(Color(hex: hex))
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(Color.white.opacity(on ? 0.95 : 0.12), lineWidth: on ? 2 : 1))
                .padding(3)
                .overlay(Circle().strokeBorder(on ? HubTheme.accent : .clear, lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func reset() {
        brightness = SpotlightSettings.defaultBrightness
        size = 1
        softness = 1
        colorMode = SpotlightSettings.ColorMode.byEvent.rawValue
        colorHex = SpotlightSettings.defaultColor
        moving = true
        breathe = true
    }
}
#endif
