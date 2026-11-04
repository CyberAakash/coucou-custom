#if !APPSTORE
import AppKit

// MARK: - The Controls page from the keyboard (coucou-custom fork, design board 2)
//
// One focus ring walks the page's rows: volume, brightness, the tiles, Wi-Fi, each device shown,
// the four monitors. ↑↓ move it; ←→ change the slider it is on (⌥: a quarter step) or move along
// a row; Space or Return acts; M mute, O sound output, D dark, A keep awake, F Focus jump there.
// The ring shows only after a key and goes on a click. With no ring, ←→ still turn the page.

enum ControlsSpot: Hashable {
    case volume, brightness, tile(String), wifi, device(String), monitor(MonitorKind)
}

@MainActor
final class ControlsKeys: ObservableObject {
    static let shared = ControlsKeys()

    @Published var spot: ControlsSpot?
    /// Bumped to open the sound output's dropdown.
    @Published var openOutput = 0
    /// Bumped to open the Focus tile's list.
    @Published var openFocus = 0
    /// A monitor's detail to open (the page owns `detail`).
    @Published var openDetail: MonitorKind?
    /// The detail answers its own keys.
    var detailOpen = false

    private var clickMonitor: Any?
    private init() {}

    private var audio: ControlsAudio { .shared }
    private var display: ControlsDisplay { .shared }
    private var net: ControlsConnections { .shared }

    /// The tiles as the page shows them, by id.
    var tiles: [String] {
        let hidden = ControlsSettings.shared.hiddenTiles
        var t: [String] = []
        if !hidden.contains("dark") { t.append("dark") }
        if display.nightShift != nil, !hidden.contains("night") { t.append("night") }
        if !hidden.contains("awake") { t.append("awake") }
        if !hidden.contains("mic") { t.append("mic") }
        if !hidden.contains("focus") { t.append("focus") }
        return t
    }

    private var rows: [[ControlsSpot]] {
        var r: [[ControlsSpot]] = [[.volume]]
        if display.brightness != nil { r.append([.brightness]) }
        if !tiles.isEmpty { r.append(tiles.map { .tile($0) }) }
        if net.wifiOn != nil { r.append([.wifi]) }
        if net.bluetoothOn != false { r += net.devices.prefix(3).map { [.device($0.id)] } }
        r.append(MonitorKind.allCases.map { .monitor($0) })
        return r
    }

    /// What the arrows do where the ring is, for the hint line.
    var hint: String {
        switch spot {
        case .volume?: return "←→ volume · ⌥ finer · Space mute"
        case .brightness?: return "←→ brightness · ⌥ finer"
        case .tile?: return "←→ along · Space switch"
        case .wifi?: return "Space Wi-Fi on or off"
        case .device?: return "Space connect or disconnect"
        case .monitor?: return "←→ along · Return opens"
        case nil: return ""
        }
    }

    /// True when the key was the page's.
    func handle(_ event: NSEvent, state: AppState) -> Bool {
        guard state.mode == .expanded, state.view == .controls, !detailOpen else { return false }
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard mods.isEmpty || mods == .option else { return false }
        watchClicks()
        let fine = mods == .option
        switch event.keyCode {
        case 125, 126:   // ↓ ↑
            move(row: event.keyCode == 125 ? 1 : -1)
        case 123, 124:   // ← →
            guard let spot else { return false }
            let step = event.keyCode == 124 ? 1 : -1
            switch spot {
            case .volume: audio.setVolume(Self.stepped(audio.muted ? 0 : (audio.volume ?? 0), step, fine))
            case .brightness: display.setBrightness(Self.stepped(display.brightness ?? 0, step, fine))
            case .tile, .monitor: move(column: step)
            case .wifi, .device: break
            }
        case 49, 36, 76:   // Space, Return, Enter
            guard let spot else { return false }
            act(spot)
        case 53:   // Escape: the ring goes first, then the notch
            guard spot != nil else { return false }
            spot = nil
        default:
            guard mods.isEmpty else { return false }
            switch event.keyCode {
            case 46: spot = .volume; audio.setMuted(!audio.muted)                    // M
            case 31: spot = .volume; openOutput += 1                                 // O
            case 2: spot = .tile("dark"); display.setDark(!display.dark)             // D
            case 0: spot = .tile("awake"); display.setKeepAwake(!display.keepAwake)  // A
            case 3: spot = .tile("focus"); openFocus += 1                            // F
            default: return false
            }
        }
        #if DEBUG
        appendAppLog("nb.log", "[Controls] key \(event.keyCode)\(fine ? " ⌥" : ""): ring \(spot.map { "\($0)" } ?? "none"), volume \(audio.volume ?? -1)")
        #endif
        return true
    }

    /// One step up or down, landing on the steps (16, or 64 with ⌥) as the Mac's keys do.
    static func stepped(_ value: Float, _ step: Int, _ fine: Bool) -> Float {
        let steps: Float = fine ? 64 : 16
        return max(0, min(1, ((value * steps).rounded() + Float(step)) / steps))
    }

    private func position() -> (row: Int, column: Int)? {
        guard let spot else { return nil }
        for (r, row) in rows.enumerated() { if let c = row.firstIndex(of: spot) { return (r, c) } }
        return nil
    }

    private func move(row delta: Int) {
        let all = rows
        guard let at = position() else { spot = all.first?.first; return }
        let r = max(0, min(all.count - 1, at.row + delta))
        spot = all[r][min(at.column, all[r].count - 1)]
    }

    private func move(column delta: Int) {
        guard let at = position() else { return }
        let row = rows[at.row]
        spot = row[max(0, min(row.count - 1, at.column + delta))]
    }

    private func act(_ spot: ControlsSpot) {
        switch spot {
        case .volume: audio.setMuted(!audio.muted)
        case .brightness: break
        case .tile("dark"): display.setDark(!display.dark)
        case .tile("night"): if let n = display.nightShift { display.setNightShift(!n) }
        case .tile("awake"): display.setKeepAwake(!display.keepAwake)
        case .tile("mic"): audio.setMicMuted(!audio.micMuted)
        case .tile("focus"): openFocus += 1
        case .tile: break
        case .wifi: net.setWiFi(net.wifiOn != true)
        case .device(let id): if net.busy == nil, let d = net.devices.first(where: { $0.id == id }) { net.toggle(d) }
        case .monitor(let k): openDetail = k
        }
    }

    /// A click anywhere in Coucou hides the ring: it is for the keyboard only.
    private func watchClicks() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated { if ControlsKeys.shared.spot != nil { ControlsKeys.shared.spot = nil } }
            return event
        }
    }
}
#endif
