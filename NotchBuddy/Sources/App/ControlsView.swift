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
    static let height: CGFloat = 318
}

struct ControlsView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var audio = ControlsAudio.shared
    @ObservedObject private var display = ControlsDisplay.shared
    @ObservedObject private var monitor = ControlsMonitor.shared
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
                controlCenter
                Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
                systemBand
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            if let kind = detail {
                monitorDetail(kind).transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: detail)
        .onAppear {
            audio.start()
            display.watch(active)
            hold(active)
            #if DEBUG
            if let d = KeepDebug.controlsDetail { detail = MonitorKind(rawValue: d) }
            #endif
        }
        .onChange(of: active) { _, on in
            display.watch(on)
            hold(on)
            if on { audio.reload() } else { detail = nil }
        }
        .onChange(of: detail) { _, kind in
            // Two copies of the page can be alive: only the one shown drives the shared monitor.
            if active { monitor.appsFor = kind }
            detailFocus = kind != nil
        }
        .onDisappear { display.watch(false); hold(false) }
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
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(detailHeadline(kind)).font(.system(size: 24, weight: .bold).monospacedDigit())
                Text(detailSubline(kind)).font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C")).lineLimit(1)
            }
            ZStack {
                if kind == .network {
                    Sparkline(values: monitor.netOut, color: Color(hex: "#A78BFA"), fixedMax: monitor.netIn.max(), filled: false)
                }
                Sparkline(values: series(kind), color: color(kind), fixedMax: kind == .cpu || kind == .memory ? 1 : nil, filled: true)
            }
            .frame(height: 92)
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
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(hex: "#141518")))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
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
