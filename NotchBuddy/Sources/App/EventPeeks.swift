#if !APPSTORE
import AppKit
import SwiftUI
import Network
import CoreAudio
import IOKit.ps

// MARK: - Peeks (coucou-custom fork)
//
// A peek (after Nusa's event peeks): the resting notch widens for a moment into a pill, a
// small Mochi on the left and an icon with a few words on the right, then folds again by
// itself. The charger, the network and the sound output say so when they change; nothing
// shows while a card is open.

struct NotchPeekContent: Equatable {
    let icon: String
    let text: String
    let tint: Color
}

/// Readable from the nonisolated `islandSize`, as BriefLayout is.
enum PeekLayout {
    /// The pill reaches this far past the notch on each side.
    static let wing: CGFloat = 100
    static let seconds: TimeInterval = 2.6

    static func size(for view: IslandView, nw: CGFloat, nh: CGFloat) -> (CGFloat, CGFloat)? {
        view == .peek ? (nw + wing * 2, nh) : nil
    }

    static func corner(for view: IslandView) -> CGFloat? { view == .peek ? 16 : nil }
}

@MainActor
final class NotchPeek: ObservableObject {
    static let shared = NotchPeek()

    @Published private(set) var content: NotchPeekContent?
    private var closer: DispatchWorkItem?

    private init() {}

    /// Shows the peek, unless a card is open (a peek replaces a peek).
    func show(icon: String, text: String, tint: Color) {
        let state = AppState.shared
        if state.mode == .expanded && state.view != .peek {
            appendAppLog("nb.log", "[Peek] \(text): \(state.view.rawValue) is open, not shown")
            return
        }
        appendAppLog("nb.log", "[Peek] \(text)")
        content = NotchPeekContent(icon: icon, text: text, tint: tint)
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.peek)
        closer?.cancel()
        let close = DispatchWorkItem {
            let state = AppState.shared
            guard state.mode == .expanded, state.view == .peek else { return }
            NotificationCenter.default.post(name: .islandCollapse, object: nil)
        }
        closer = close
        DispatchQueue.main.asyncAfter(deadline: .now() + PeekLayout.seconds, execute: close)
    }
}

/// What the island draws for a peek, in place of its header and card (the brief pill's layout).
struct PeekStage: View {
    let width: CGFloat
    let height: CGFloat
    @ObservedObject private var peek = NotchPeek.shared

    var body: some View {
        HStack(spacing: 0) {
            DesignMochi(size: 22, mode: .idle)
                .padding(.leading, 12)
            Spacer(minLength: 0)
            if let c = peek.content {
                HStack(spacing: 6) {
                    Image(systemName: c.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(c.tint)
                    Text(c.text)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(Color(hex: "#E1E3E6"))
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.trailing, 14)
                .id(c.text)
                .transition(.opacity)
            }
        }
        .frame(width: width, height: height)
        .animation(.easeOut(duration: 0.2), value: peek.content)
        .allowsHitTesting(false)
    }
}

// MARK: - What is watched

@MainActor
final class EventPeeks {
    static let shared = EventPeeks()

    /// Settings → General → Peeks (all on by default).
    static let powerKey = "coucouPeekPower"
    static let networkKey = "coucouPeekNetwork"
    static let audioKey = "coucouPeekAudio"

    static func on(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    private var onPower: Bool?
    private var powerDebounce: DispatchWorkItem?
    private var pathMonitor: NWPathMonitor?
    private var online: (up: Bool, wifi: Bool)?
    private var networkDebounce: DispatchWorkItem?
    private var outputDevice: AudioDeviceID = 0
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        // The charger: IOKit says when a power source changes; several times per plug.
        onPower = MachineVitals.readBattery()?.onPower
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            Task { @MainActor in EventPeeks.shared.powerChanged() }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }

        // The network: up or down, and whether it is Wi‑Fi.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let up = path.status == .satisfied
            let wifi = path.usesInterfaceType(.wifi)
            Task { @MainActor in EventPeeks.shared.pathChanged(up: up, wifi: wifi) }
        }
        monitor.start(queue: DispatchQueue(label: "coucou.peeks.network", qos: .utility))
        pathMonitor = monitor

        // The sound output: headphones, AirPods, a speaker.
        outputDevice = Self.defaultOutput()
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
            Task { @MainActor in EventPeeks.shared.outputChanged() }
        }
        appendAppLog("nb.log", "[Peek] watching: power \(onPower.map { $0 ? "ac" : "battery" } ?? "none"), network, sound output")
    }

    // MARK: Power

    private func powerChanged() {
        powerDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let battery = MachineVitals.readBattery(), battery.onPower != self.onPower else { return }
            let first = self.onPower == nil
            self.onPower = battery.onPower
            guard !first, Self.on(Self.powerKey) else { return }
            if battery.onPower {
                NotchPeek.shared.show(icon: "bolt.fill", text: "Charging · \(battery.percent) %", tint: Color(hex: "#34D399"))
            } else {
                NotchPeek.shared.show(icon: Self.batteryIcon(battery.percent), text: "On battery · \(battery.percent) %",
                                      tint: Color(hex: battery.percent <= 20 ? "#F87171" : "#F5A524"))
            }
        }
        powerDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    static func batteryIcon(_ percent: Int) -> String {
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    // MARK: Network

    private func pathChanged(up: Bool, wifi: Bool) {
        guard let previous = online else {
            online = (up, wifi)
            return
        }
        // Reconnections flap for a second or two: the settled state is what shows.
        networkDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, previous.up != up || previous.wifi != wifi else { return }
            self.online = (up, wifi)
            guard Self.on(Self.networkKey) else { return }
            if !up {
                NotchPeek.shared.show(icon: "wifi.slash", text: "Offline", tint: Color(hex: "#F87171"))
            } else if wifi {
                NotchPeek.shared.show(icon: "wifi", text: "Wi‑Fi connected", tint: Color(hex: "#60A5FA"))
            } else {
                NotchPeek.shared.show(icon: "network", text: "Back online", tint: Color(hex: "#60A5FA"))
            }
        }
        networkDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    // MARK: Sound output

    private func outputChanged() {
        let device = Self.defaultOutput()
        guard device != outputDevice else { return }
        outputDevice = device
        guard device != 0, Self.on(Self.audioKey), let name = Self.deviceName(device) else { return }
        let transport = Self.transportType(device)
        let bluetooth = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        let builtIn = transport == kAudioDeviceTransportTypeBuiltIn
        let icon = bluetooth ? "headphones" : (builtIn ? "speaker.wave.2.fill" : "hifispeaker.fill")
        NotchPeek.shared.show(icon: icon, text: bluetooth ? "\(name) connected" : "Sound: \(name)", tint: Color(hex: "#A78BFA"))
    }

    private static func defaultOutput() -> AudioDeviceID {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : 0
    }

    private static func deviceName(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        let s = (name as String).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    private static func transportType(_ device: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        return status == noErr ? transport : 0
    }
}
#endif
