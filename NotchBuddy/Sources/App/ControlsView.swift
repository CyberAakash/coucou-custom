#if !APPSTORE
import AppKit
import CoreAudio
import SwiftUI

// MARK: - The Controls page (coucou-custom fork, roadmap phase 4)
//
// Three bands in one page: Control Center (volume with its output, brightness, four tiles),
// Connections (Wi-Fi and Bluetooth in one list) and System (four live graphs). Each band is
// the Mac's own setting, read and changed in place; nothing leaves the Mac.

@MainActor
final class ControlsSettings: ObservableObject {
    static let shared = ControlsSettings()
    static let enabledKey = "coucouControlsEnabled"
    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) } }
    private init() { enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
}

/// The page's height in the island: it grows as bands are added.
enum ControlsLayout {
    static let height: CGFloat = 232
}

struct ControlsView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var audio = ControlsAudio.shared
    @ObservedObject private var display = ControlsDisplay.shared
    @Environment(\.islandViewActive) private var active

    static let tint = Color(hex: "#34D399")

    var body: some View {
        ZStack {
            CardBackground(wash: nil)
            controlCenter
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
        }
        .onAppear {
            audio.start()
            display.watch(active)
        }
        .onChange(of: active) { _, on in
            display.watch(on)
            if on { audio.reload() }
        }
        .onDisappear { display.watch(false) }
        #if DEBUG
        // `debug.controls` "volume|awake|mic": a change and its undo, both logged (a terminal's check).
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("fr.louisraille.NotchBuddy.debug.controls"))) { note in
            switch note.object as? String {
            case "volume"?:
                let before = audio.volume ?? 0
                audio.setVolume(min(1, before + 0.0625))
                let after = audio.volume ?? -1
                audio.setVolume(before)
                appendAppLog("nb.log", "[Controls] test volume \(before) → \(after) → \(audio.volume ?? -1)")
            case "brightness"?:
                let before = display.brightness ?? 0
                display.setBrightness(min(1, before + 0.05))
                display.read()
                let after = display.brightness ?? -1
                display.setBrightness(before)
                display.read()
                appendAppLog("nb.log", "[Controls] test brightness \(before) → \(after) → \(display.brightness ?? -1)")
            case "awake"?:
                display.setKeepAwake(true)
                let on = display.keepAwake
                display.setKeepAwake(false)
                appendAppLog("nb.log", "[Controls] test keep awake on=\(on) off=\(!display.keepAwake)")
            case "mic"?:
                let before = audio.micMuted
                audio.setMicMuted(!before)
                let toggled = audio.micMuted
                audio.setMicMuted(before)
                appendAppLog("nb.log", "[Controls] test mic \(before) → \(toggled) → \(audio.micMuted)")
            default:
                appendAppLog("nb.log", "[Controls] outputs: \(audio.outputs.map(\.name)) current \(audio.outputs.first { $0.id == audio.current }?.name ?? "-") volume \(audio.volume ?? -1) brightness \(display.brightness ?? -1) night \(String(describing: display.nightShift)) dark \(display.dark)")
            }
        }
        #endif
    }

    // MARK: Control Center

    private var controlCenter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CONTROL CENTER").font(.system(size: 9, weight: .heavy)).tracking(1.1).foregroundColor(Color(hex: "#6B7079"))
            HStack(spacing: 10) {
                ControlSlider(value: audio.muted ? 0 : audio.volume, symbol: volumeSymbol, help: audio.muted ? "Unmute" : "Mute",
                              iconTap: { audio.setMuted(!audio.muted) }) { audio.setVolume($0) }
                outputMenu
            }
            if let b = display.brightness {
                HStack(spacing: 10) {
                    ControlSlider(value: b, symbol: "sun.max.fill", help: nil, iconTap: nil) { display.setBrightness($0) }
                    Text("Built-in display").font(.system(size: 10.5)).foregroundColor(Color(hex: "#8E939C"))
                        .frame(width: 170, alignment: .leading)
                }
            }
            HStack(spacing: 6) {
                tile("Dark", symbol: "moon.fill", on: display.dark) { display.setDark(!display.dark) }
                if let night = display.nightShift {
                    tile("Night Shift", symbol: "sun.haze.fill", on: night) { display.setNightShift(!night) }
                }
                tile("Keep awake", symbol: "cup.and.saucer.fill", on: display.keepAwake) { display.setKeepAwake(!display.keepAwake) }
                tile(audio.micMuted ? "Mic off" : "Mic on", symbol: audio.micMuted ? "mic.slash.fill" : "mic.fill", on: audio.micMuted,
                     help: audio.inputName.map { "Mute \($0)" }) { audio.setMicMuted(!audio.micMuted) }
            }
        }
    }

    private var volumeSymbol: String {
        guard let v = audio.volume, !audio.muted else { return "speaker.slash.fill" }
        return v < 0.01 ? "speaker.fill" : (v < 0.34 ? "speaker.wave.1.fill" : (v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"))
    }

    /// The output the volume belongs to: switched where the volume is changed. Drawn as a plain
    /// pill (a SwiftUI menu draws its own title and ignores truncation), opening a native menu.
    private var outputMenu: some View {
        let current = audio.outputs.first { $0.id == audio.current }
        return Button {
            PopupMenu.show(audio.outputs.map { o in (o.name, o.id == audio.current, { audio.use(o) }) })
        } label: {
            HStack(spacing: 6) {
                Image(systemName: Self.symbol(for: current)).font(.system(size: 10, weight: .semibold))
                Text(current?.name ?? "No output").font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 2)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundColor(Color(hex: "#8E939C"))
            }
            .foregroundColor(Color(hex: "#F5F6F8"))
            .padding(.horizontal, 11).frame(width: 170, height: 28)
            .background(Capsule().fill(Color.white.opacity(0.09)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).pointer().help("Sound output")
    }

    static func symbol(for output: AudioOutput?) -> String {
        guard let o = output else { return "speaker.fill" }
        let name = o.name.lowercased()
        if name.contains("airpods") { return "airpodspro" }
        switch o.transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeUSB: return name.contains("head") ? "headphones" : "hifispeaker.fill"
        default: return "laptopcomputer"
        }
    }

    private func tile(_ title: String, symbol: String, on: Bool, help: String? = nil, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
            }
            .foregroundColor(on ? Self.tint : Color(hex: "#C5C8CD"))
            .frame(maxWidth: .infinity).frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(on ? Self.tint.opacity(0.16) : Color.white.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointer().help(help ?? title)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: on)
    }
}

/// A wide slider as Control Center draws one: a capsule track, a light fill, the symbol on it.
/// Drag or click anywhere on it; the symbol can be a button of its own (mute). Nil: greyed out.
struct ControlSlider: View {
    let value: Float?
    let symbol: String
    let help: String?
    let iconTap: (() -> Void)?
    let change: (Float) -> Void

    var body: some View {
        GeometryReader { geo in
            let v = CGFloat(value ?? 0)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.07))
                Capsule().fill(Color(hex: "#F5F6F8").opacity(value == nil ? 0.15 : 0.92))
                    .frame(width: max(28, geo.size.width * v))
                Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                    .foregroundColor(v * geo.size.width > 30 ? Color(hex: "#0B0C0E") : Color(hex: "#C5C8CD"))
                    .frame(width: 30, height: 28)
                    .contentShape(Rectangle())
                    .onTapGesture { iconTap?() }
                    .help(help ?? "")
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                guard value != nil, g.startLocation.x > 30 || iconTap == nil else { return }
                change(Float(max(0, min(1, g.location.x / geo.size.width))))
            })
            .pointer()
        }
        .frame(height: 28)
        .opacity(value == nil ? 0.5 : 1)
    }
}
/// A native menu at the pointer, from plain closures.
@MainActor
enum PopupMenu {
    private final class Target: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func run() { action() }
    }

    static func show(_ items: [(title: String, checked: Bool, action: () -> Void)]) {
        let menu = NSMenu()
        var targets: [Target] = []
        for item in items {
            let target = Target(item.action)
            targets.append(target)
            let mi = NSMenuItem(title: item.title, action: #selector(Target.run), keyEquivalent: "")
            mi.target = target
            mi.state = item.checked ? .on : .off
            menu.addItem(mi)
        }
        // The targets live as long as the menu is up: popUp returns when it closes.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        withExtendedLifetime(targets) {}
    }
}
#endif
