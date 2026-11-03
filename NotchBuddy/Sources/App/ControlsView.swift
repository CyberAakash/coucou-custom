#if !APPSTORE
import AppKit
import CoreAudio
import SwiftUI

// MARK: - The Controls page (coucou-custom fork, roadmap phase 4)
//
// Three bands in one page: Control Center (volume with its output, brightness, four tiles),
// Connections (Wi-Fi and Bluetooth in one list) and System (four live graphs). Each band is
// the Mac's own setting, read and changed in place; nothing leaves the Mac.

/// What the closed notch's right wing shows of the monitors, when nothing is due there.
enum ControlsWingMetric: String, CaseIterable, Identifiable {
    case off, cpu, network, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Off"
        case .cpu: "CPU"
        case .network: "Download speed"
        case .both: "CPU and download"
        }
    }
}

/// Settings → Controls.
@MainActor
final class ControlsSettings: ObservableObject {
    static let shared = ControlsSettings()
    static let enabledKey = "coucouControlsEnabled"
    private let ud = UserDefaults.standard
    @Published var enabled: Bool { didSet { ud.set(enabled, forKey: Self.enabledKey) } }
    /// A peek when a Bluetooth device connects or disconnects, with its battery.
    @Published var deviceAlerts: Bool { didSet { ud.set(deviceAlerts, forKey: "coucouControlsDeviceAlerts") } }
    /// A peek when a device's battery reaches 20%, and again at 10%.
    @Published var lowBattery: Bool { didSet { ud.set(lowBattery, forKey: "coucouControlsLowBattery") } }
    @Published var wingMetric: ControlsWingMetric { didSet { ud.set(wingMetric.rawValue, forKey: "coucouControlsWing") } }
    /// Speeds in Mbps (a speed test's unit) rather than MB/s (Activity Monitor's).
    @Published var bits: Bool { didSet { ud.set(bits, forKey: "coucouControlsBits") } }
    /// Control Center tiles left out: "dark", "night", "awake", "mic".
    @Published var hiddenTiles: Set<String> { didSet { ud.set(Array(hiddenTiles).sorted(), forKey: "coucouControlsHiddenTiles") } }
    /// The volume and brightness keys show their level in the notch instead of macOS's overlay (MediaKeys).
    @Published var keysInNotch: Bool { didSet { ud.set(keysInNotch, forKey: "coucouControlsKeysInNotch"); MediaKeys.shared.update() } }

    private init() {
        enabled = ud.object(forKey: Self.enabledKey) as? Bool ?? true
        deviceAlerts = ud.object(forKey: "coucouControlsDeviceAlerts") as? Bool ?? true
        lowBattery = ud.object(forKey: "coucouControlsLowBattery") as? Bool ?? true
        wingMetric = ud.string(forKey: "coucouControlsWing").flatMap(ControlsWingMetric.init(rawValue:)) ?? .off
        bits = ud.bool(forKey: "coucouControlsBits")
        hiddenTiles = Set(ud.stringArray(forKey: "coucouControlsHiddenTiles") ?? [])
        keysInNotch = ud.object(forKey: "coucouControlsKeysInNotch") as? Bool ?? true
    }
}

/// The page's height in the island: it grows as bands are added.
enum ControlsLayout {
    static let height: CGFloat = 318
}

struct ControlsView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var audio = ControlsAudio.shared
    @ObservedObject private var display = ControlsDisplay.shared
    @ObservedObject private var monitor = ControlsMonitor.shared
    @ObservedObject private var net = ControlsConnections.shared
    @ObservedObject private var settings = ControlsSettings.shared
    @ObservedObject private var keys = ControlsKeys.shared
    @Environment(\.islandViewActive) private var active
    /// The monitor whose graph and apps are open over the page.
    @State private var detail: MonitorKind?
    @FocusState private var detailFocus: Bool
    @State private var holding = false

    static let tint = Color(hex: "#34D399")

    var body: some View {
        ZStack {
            CardBackground(wash: nil)
            VStack(spacing: 10) {
                HStack(alignment: .top, spacing: 14) {
                    controlCenter.frame(maxWidth: .infinity)
                    Rectangle().fill(Color.white.opacity(0.05)).frame(width: 1)
                    connections.frame(maxWidth: .infinity)
                }
                .frame(height: 150)
                Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
                systemBand
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            // What the arrows do where the ring is (ControlsKeys); only while it shows.
            if keys.spot != nil {
                Text(keys.hint + " · Esc hides")
                    .font(.system(size: 9.5, weight: .medium)).foregroundColor(Color(hex: "#6B7079"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(.bottom, 1)
                    .allowsHitTesting(false).transition(.opacity)
            }
            if let kind = detail {
                monitorDetail(kind).transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: detail)
        .animation(.easeOut(duration: 0.12), value: keys.spot)
        .onChange(of: keys.openDetail) { _, k in
            guard active, let k else { return }
            detail = k
            keys.openDetail = nil
        }
        .onChange(of: detail) { _, d in if active { keys.detailOpen = d != nil } }
        .onAppear {
            audio.start()
            display.watch(active)
            net.watch(active)
            hold(active)
            #if DEBUG
            if let d = KeepDebug.controlsDetail { detail = MonitorKind(rawValue: d) }
            #endif
        }
        .onChange(of: active) { _, on in
            display.watch(on)
            net.watch(on)
            hold(on)
            if on { audio.reload() } else { detail = nil }
        }
        .onChange(of: detail) { _, kind in
            // Two copies of the page can be alive: only the one shown drives the shared monitor.
            if active { monitor.appsFor = kind }
            detailFocus = kind != nil
        }
        .onDisappear { display.watch(false); net.watch(false); hold(false) }
        #if DEBUG
        // `debug.controls` "volume|awake|mic": a change and its undo, both logged (a terminal's check).
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("fr.louisraille.NotchBuddy.debug.controls"))) { note in
            guard active else { return }
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
            case "cpu"?, "memory"?, "disk"?:
                detail = MonitorKind(rawValue: note.object as? String ?? "")
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    appendAppLog("nb.log", "[Controls] test \(detail?.rawValue ?? "-") apps: \(monitor.apps.map { "\($0.name)=\($0.value)" })")
                }
            case "watch"?:
                ControlsWatcher.shared.debugSequence()
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

    /// The monitors run only while the page shows.
    private func hold(_ on: Bool) {
        guard on != holding else { return }
        holding = on
        monitor.hold(on)
    }

    // MARK: Connections

    /// Wi-Fi first, then the Bluetooth devices (connected first): as many as fit, the rest in settings.
    private var connections: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("CONNECTIONS").font(.system(size: 9, weight: .heavy)).tracking(1.1).foregroundColor(Color(hex: "#6B7079"))
                Spacer()
                Button { ControlsConnections.openBluetoothSettings() } label: {
                    Image(systemName: "gearshape").font(.system(size: 10, weight: .semibold)).foregroundColor(Color(hex: "#6B7079"))
                }
                .buttonStyle(.plain).pointer().help("Bluetooth settings")
            }
            wifiRow
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1).padding(.vertical, 2)
            if net.bluetoothOn == false {
                HStack(spacing: 8) {
                    Text("Bluetooth is off").font(.system(size: 12)).foregroundColor(Color(hex: "#8E939C"))
                    Spacer()
                    smallButton("Bluetooth settings") { ControlsConnections.openBluetoothSettings() }
                }
                .frame(height: 26)
            } else if net.devices.isEmpty {
                Text(net.bluetoothOn == nil ? "Reading Bluetooth…" : "No Bluetooth devices paired")
                    .font(.system(size: 12)).foregroundColor(Color(hex: "#8E939C")).frame(height: 26)
            } else {
                let shown = Array(net.devices.prefix(3))
                ForEach(shown) { deviceRow($0) }
                if net.devices.count > shown.count {
                    Button { ControlsConnections.openBluetoothSettings() } label: {
                        Text("\(net.devices.count - shown.count) more in Bluetooth settings").font(.system(size: 10.5)).foregroundColor(Color(hex: "#6B7079"))
                    }
                    .buttonStyle(.plain).pointer()
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var wifiRow: some View {
        HStack(spacing: 8) {
            Image(systemName: net.wifiOn == true ? "wifi" : "wifi.slash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(net.wifiOn == true ? Color(hex: "#F5F6F8") : Color(hex: "#6B7079"))
                .frame(width: 22)
            if net.wifiOn == nil {
                Text("No Wi-Fi on this Mac").font(.system(size: 12)).foregroundColor(Color(hex: "#8E939C"))
            } else if net.wifiOn == false {
                Text("Wi-Fi is off").font(.system(size: 12)).foregroundColor(Color(hex: "#8E939C"))
            } else {
                if let name = net.wifiName {
                    Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                } else if !net.locationAllowed {
                    Button { if net.locationAsked { ControlsView.openLocationSettings() } else { net.requestLocation() } } label: {
                        Text("Show name").font(.system(size: 11.5, weight: .semibold)).foregroundColor(Color(hex: "#3B9EFF")).fixedSize()
                    }
                    .buttonStyle(.plain).pointer().help("macOS shows an app the network's name only with Location allowed")
                } else {
                    Text("Not connected").font(.system(size: 12)).foregroundColor(Color(hex: "#8E939C"))
                }
                if net.wifiRate > 0 {
                    Text("\(Int(net.wifiRate)) Mbps · \(net.wifiQuality)").font(.system(size: 10.5)).foregroundColor(Color(hex: "#8E939C")).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if net.wifiOn != nil {
                Toggle("", isOn: Binding(get: { net.wifiOn == true }, set: { net.setWiFi($0) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden().tint(Self.tint)
                    .help(net.wifiOn == true ? "Turn Wi-Fi off" : "Turn Wi-Fi on")
            }
        }
        .frame(height: 26)
        .contentShape(Rectangle())
        .overlay(ring(.wifi, radius: 8))
        .contextMenu { Button("Wi-Fi settings") { ControlsConnections.openWiFiSettings() } }
    }

    private func deviceRow(_ d: BluetoothDevice) -> some View {
        let isOutput = d.connected && audio.outputs.first { $0.id == audio.current }?.name == d.name
        let low = (d.battery ?? 100) <= 20
        return HStack(spacing: 8) {
            ZStack {
                if let b = d.battery, d.connected {
                    Circle().stroke(Color.white.opacity(0.1), lineWidth: 2.4)
                    Circle().trim(from: 0, to: CGFloat(b) / 100)
                        .stroke(low ? Color(hex: "#F4505E") : Self.tint, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Image(systemName: d.symbol).font(.system(size: d.battery != nil && d.connected ? 8 : 11, weight: .semibold))
                    .foregroundColor(d.connected ? Color(hex: "#F5F6F8") : Color(hex: "#6B7079"))
            }
            .frame(width: 22, height: 22)
            Text(d.name).font(.system(size: 12)).foregroundColor(d.connected ? Color(hex: "#F5F6F8") : Color(hex: "#8E939C")).lineLimit(1)
            if let b = d.battery, d.connected {
                Text("\(b)%").font(.system(size: 10.5).monospacedDigit()).foregroundColor(low ? Color(hex: "#F4505E") : Color(hex: "#8E939C"))
                    .help(d.batteryDetail ?? "Battery")
            }
            if isOutput {
                Text("sound").font(.system(size: 9.5, weight: .semibold)).foregroundColor(Self.tint)
                    .padding(.horizontal, 6).frame(height: 16).background(Capsule().fill(Self.tint.opacity(0.14)))
            }
            Spacer(minLength: 4)
            if net.busy == d.id {
                ProgressView().controlSize(.mini)
            } else {
                smallButton(d.connected ? "Disconnect" : "Connect") { net.toggle(d) }
                    .disabled(net.busy != nil)
            }
        }
        .frame(height: 26)
        .overlay(ring(.device(d.id), radius: 8))
    }

    private func smallButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundColor(Color(hex: "#F5F6F8"))
                .padding(.horizontal, 9).frame(height: 22)
                .background(Capsule().fill(Color.white.opacity(0.09)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).pointer()
    }

    static func openLocationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
    }

    // MARK: System

    private var systemBand: some View {
        HStack(spacing: 6) {
            ForEach(MonitorKind.allCases) { kind in
                Button { detail = kind } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title.uppercased()).font(.system(size: 8.5, weight: .heavy)).tracking(1).foregroundColor(Color(hex: "#6B7079"))
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(headline(kind)).font(.system(size: 13.5, weight: .bold).monospacedDigit()).lineLimit(1)
                            Text(subline(kind)).font(.system(size: 9.5)).foregroundColor(Color(hex: "#8E939C")).lineLimit(1)
                        }
                        Sparkline(values: Array(series(kind).suffix(60)), color: color(kind), fixedMax: kind == .cpu || kind == .memory ? 1 : nil)
                            .frame(height: 20)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointer().help("\(kind.title): its graph and what is using it")
                .overlay(ring(.monitor(kind)))
            }
        }
    }

    private func series(_ k: MonitorKind) -> [Double] {
        switch k {
        case .cpu: monitor.cpu
        case .memory: monitor.memory
        case .disk: monitor.disk
        case .network: monitor.netIn
        }
    }

    private func color(_ k: MonitorKind) -> Color {
        switch k {
        case .cpu: Self.tint
        case .memory: Color(hex: "#A78BFA")
        case .disk: Color(hex: "#F7B32B")
        case .network: Color(hex: "#22D3EE")
        }
    }

    private func headline(_ k: MonitorKind) -> String {
        switch k {
        case .cpu: return monitor.cpu.last.map(MonitorFormat.percent) ?? "–"
        // Gigabytes as Activity Monitor counts them (1024³), so 24 GB is 24, not 25.8.
        case .memory: return String(format: "%.1f", Double(monitor.memoryUsed) / 1_073_741_824)
        case .disk: return monitor.diskFree.map { "\(Int(Double($0) / 1e9))" } ?? "–"
        case .network: return monitor.netIn.last.map { "↓" + MonitorFormat.rate($0).replacingOccurrences(of: " ", with: "\u{2009}") } ?? "–"
        }
    }

    private func subline(_ k: MonitorKind) -> String {
        switch k {
        case .cpu: return ""
        case .memory: return "of \(Int((Double(monitor.memoryTotal) / 1_073_741_824).rounded())) GB"
        case .disk: return "GB free"
        case .network: return monitor.netOut.last.map { "↑" + MonitorFormat.rate($0) } ?? ""
        }
    }

    // MARK: A monitor's detail

    private func monitorDetail(_ kind: MonitorKind) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    ForEach(MonitorKind.allCases) { k in
                        Button { detail = k } label: {
                            Text(k.title).font(.system(size: 11, weight: .semibold))
                                .foregroundColor(k == kind ? Color(hex: "#F5F6F8") : Color(hex: "#8E939C"))
                                .padding(.horizontal, 12).frame(height: 24)
                                .background(Capsule().fill(k == kind ? Color(hex: "#1D1F23") : .clear))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain).pointer()
                    }
                }
                .padding(2)
                .background(Capsule().fill(Color.black.opacity(0.35)))
                Spacer(minLength: 6)
                Text("↑↓ between them · Esc back").font(.system(size: 10)).foregroundColor(Color(hex: "#6B7079"))
                Button { detail = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundColor(Color(hex: "#8E939C"))
                        .frame(width: 22, height: 22).background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain).pointer().help("Back to Controls")
            }
            // Taller than the page: the tabs stay, the rest scrolls (it used to push the notch's
            // header out of view).
            ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                PageMochi(state: detailMood(kind), size: 24)
                Text(detailHeadline(kind)).font(.system(size: 24, weight: .bold).monospacedDigit())
                Text(detailSubline(kind)).font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C")).lineLimit(1)
            }
            ZStack {
                if kind == .network {
                    Sparkline(values: monitor.netOut, color: Color(hex: "#A78BFA"), fixedMax: monitor.netIn.max(), filled: false)
                }
                Sparkline(values: series(kind), color: color(kind), fixedMax: kind == .cpu || kind == .memory ? 1 : nil, filled: true)
            }
            .frame(height: 52)
            Text("The last 5 minutes").font(.system(size: 9.5)).foregroundColor(Color(hex: "#6B7079"))
            if kind == .network {
                if let a = ControlsMonitor.primaryAddress() {
                    Text("\(a.interface) · \(a.address)").font(.system(size: 11.5)).foregroundColor(Color(hex: "#C5C8CD"))
                }
                Text("macOS does not tell apps which app the traffic is for.").font(.system(size: 10.5)).foregroundColor(Color(hex: "#6B7079"))
            } else {
                Text("USING IT NOW").font(.system(size: 8.5, weight: .heavy)).tracking(1).foregroundColor(Color(hex: "#6B7079"))
                if monitor.apps.isEmpty {
                    Text(kind == .memory ? "Reading…" : "Reading… (two seconds)").font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C"))
                }
                ForEach(monitor.apps) { app in appRow(app, kind) }
            }
            }
            .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(hex: "#141518")))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .focusable().focusEffectDisabled().focused($detailFocus)
        .onExitCommand { detail = nil }
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
            let all = MonitorKind.allCases
            guard let i = all.firstIndex(of: kind) else { return .ignored }
            let step = press.key == .upArrow || press.key == .leftArrow ? -1 : 1
            detail = all[(i + step + all.count) % all.count]
            return .handled
        }
    }

    /// Calm, busy, then dizzy as this monitor's load rises (network has none to read).
    private func detailMood(_ k: MonitorKind) -> BotState {
        switch k {
        case .cpu: return PageMochi.load(monitor.cpu.last ?? 0)
        case .memory: return PageMochi.load(monitor.memoryTotal > 0 ? Double(monitor.memoryUsed) / Double(monitor.memoryTotal) : 0)
        case .disk:
            guard let free = monitor.diskFree, let total = monitor.diskTotal, total > 0 else { return .idle }
            return PageMochi.load(1 - Double(free) / Double(total))
        case .network: return .idle
        }
    }

    private func detailHeadline(_ k: MonitorKind) -> String {
        switch k {
        case .cpu: return monitor.cpu.last.map(MonitorFormat.percent) ?? "–"
        case .memory: return MonitorFormat.bytes(Double(monitor.memoryUsed))
        case .disk: return MonitorFormat.rate(monitor.disk.last ?? 0)
        case .network: return "↓ " + MonitorFormat.rate(monitor.netIn.last ?? 0)
        }
    }

    private func detailSubline(_ k: MonitorKind) -> String {
        switch k {
        case .cpu: return "\(ProcessInfo.processInfo.activeProcessorCount) cores"
        case .memory:
            return "of \(MonitorFormat.bytes(Double(monitor.memoryTotal)))" + (monitor.swapUsed > 0 ? " · swap \(MonitorFormat.bytes(Double(monitor.swapUsed)))" : "")
        case .disk:
            let free = monitor.diskFree.map { MonitorFormat.bytes(Double($0)) + " free" } ?? ""
            return "read \(MonitorFormat.rate(monitor.diskRead)) · write \(MonitorFormat.rate(monitor.diskWrite))" + (free.isEmpty ? "" : " · \(free)")
        case .network: return "↑ " + MonitorFormat.rate(monitor.netOut.last ?? 0)
        }
    }

    private func appRow(_ app: MonitorApp, _ kind: MonitorKind) -> some View {
        let top = monitor.apps.first?.value ?? 1
        let label: String = switch kind {
        case .cpu: MonitorFormat.percent(app.value / Double(ProcessInfo.processInfo.activeProcessorCount))
        case .memory: MonitorFormat.bytes(app.value)
        default: MonitorFormat.rate(app.value)
        }
        return HStack(spacing: 10) {
            Group {
                if let path = app.path { Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable() }
                else { Image(systemName: "gearshape.fill").resizable().foregroundColor(Color(hex: "#6B7079")) }
            }
            .frame(width: 18, height: 18)
            Text(app.name).font(.system(size: 12)).lineLimit(1).frame(width: 170, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07))
                    Capsule().fill(color(kind)).frame(width: max(4, g.size.width * app.value / max(top, 0.0001)))
                }
            }
            .frame(height: 6)
            Text(label).font(.system(size: 11.5).monospacedDigit()).foregroundColor(Color(hex: "#C5C8CD")).frame(width: 70, alignment: .trailing)
        }
        .frame(height: 24)
    }

    // MARK: Control Center

    private var controlCenter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Text("CONTROL CENTER").font(.system(size: 9, weight: .heavy)).tracking(1.1).foregroundColor(Color(hex: "#6B7079"))
                Spacer(minLength: 0)
                // Laid over the label row's end, so the bands below keep their places.
                PageMochi(state: controlsMood, size: 18).frame(height: 10).offset(y: -3)
            }
            HStack(spacing: 10) {
                ControlSlider(value: audio.muted ? 0 : audio.volume, symbol: volumeSymbol, help: audio.muted ? "Unmute" : "Mute",
                              iconTap: { audio.setMuted(!audio.muted) }) { audio.setVolume($0) }
                    .overlay(ring(.volume))
                outputMenu
            }
            if let b = display.brightness {
                HStack(spacing: 10) {
                    ControlSlider(value: b, symbol: "sun.max.fill", help: nil, iconTap: nil) { display.setBrightness($0) }
                        .overlay(ring(.brightness))
                    Text("Built-in display").font(.system(size: 10.5)).foregroundColor(Color(hex: "#8E939C"))
                        .frame(width: 130, alignment: .leading)
                }
            }
            HStack(spacing: 6) {
                let hidden = settings.hiddenTiles
                if !hidden.contains("dark") {
                    tile("Dark", id: "dark", symbol: "moon.fill", on: display.dark) { display.setDark(!display.dark) }
                }
                if let night = display.nightShift, !hidden.contains("night") {
                    tile("Night Shift", id: "night", symbol: "sun.haze.fill", on: night) { display.setNightShift(!night) }
                }
                if !hidden.contains("awake") {
                    tile("Keep awake", id: "awake", symbol: "cup.and.saucer.fill", on: display.keepAwake) { display.setKeepAwake(!display.keepAwake) }
                }
                if !hidden.contains("mic") {
                    tile(audio.micMuted ? "Mic off" : "Mic on", id: "mic", symbol: audio.micMuted ? "mic.slash.fill" : "mic.fill", on: audio.micMuted,
                         help: audio.inputName.map { "Mute \($0)" }) { audio.setMicMuted(!audio.micMuted) }
                }
            }
        }
    }

    /// Drowsy when muted or the screen is dim, busy or dizzy as the CPU climbs.
    private var controlsMood: BotState {
        let cpu = monitor.cpu.last ?? 0
        if cpu > 0.6 { return PageMochi.load(cpu) }
        if audio.muted || (display.brightness ?? 1) < 0.15 { return .sleeping }
        return .idle
    }

    private var volumeSymbol: String {
        guard let v = audio.volume, !audio.muted else { return "speaker.slash.fill" }
        return v < 0.01 ? "speaker.fill" : (v < 0.34 ? "speaker.wave.1.fill" : (v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"))
    }

    /// The output the volume belongs to: switched where the volume is changed. A fixed width,
    /// so a long device name truncates instead of pushing the band.
    private var outputMenu: some View {
        let current = audio.outputs.first { $0.id == audio.current }
        return HubDropdown(Binding(get: { audio.current }, set: { id in audio.outputs.first { $0.id == id }.map(audio.use) }),
                           audio.outputs.map { ($0.id, $0.name) }, tint: Self.tint, listWidth: 240, width: 130,
                           symbol: Self.symbol(for: current), placeholder: "No output", opener: active ? keys.openOutput : 0)
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

    /// The keyboard's focus ring (ControlsKeys), drawn just outside what it is on.
    private func ring(_ spot: ControlsSpot, radius: CGFloat = 12) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(Color(hex: "#22D3EE"), lineWidth: 2)
            .padding(-3)
            .opacity(keys.spot == spot && active ? 1 : 0)
            .allowsHitTesting(false)
    }

    private func tile(_ title: String, id: String, symbol: String, on: Bool, help: String? = nil, _ action: @escaping () -> Void) -> some View {
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
        .overlay(ring(.tile(id), radius: 16))
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
/// A line graph of the values, newest on the right; scaled to `fixedMax`, else to its own peak.
struct Sparkline: View {
    let values: [Double]
    let color: Color
    var fixedMax: Double? = nil
    var filled = false

    var body: some View {
        GeometryReader { g in
            let peak = max(fixedMax ?? (values.max() ?? 1), 0.000001)
            let n = max(values.count, 2)
            let step = g.size.width / CGFloat(n - 1)
            let points = values.enumerated().map { i, v in
                CGPoint(x: CGFloat(i + (n - values.count)) * step,
                        y: g.size.height - CGFloat(min(1, v / peak)) * (g.size.height - 2) - 1)
            }
            ZStack {
                if filled, let first = points.first, let last = points.last {
                    Path { p in
                        p.move(to: CGPoint(x: first.x, y: g.size.height))
                        points.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: last.x, y: g.size.height))
                    }
                    .fill(color.opacity(0.13))
                }
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: first)
                    points.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: filled ? 2 : 1.6, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
#endif
