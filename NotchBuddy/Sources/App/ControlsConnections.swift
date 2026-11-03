#if !APPSTORE
import AppKit
import CoreLocation
import SwiftUI
import CoreWLAN
import IOBluetooth

// MARK: - Connections for the Controls page (coucou-custom fork, roadmap phase 4)
//
// Wi-Fi and Bluetooth in one list. Wi-Fi through CoreWLAN: on or off, signal, speed, and the
// network's name, which macOS gives an app only with Location allowed. Bluetooth: the paired
// devices, whether each is connected and its battery (one battery, or AirPods' left, right and
// case) come from the system profiler, which reads them for us without a permission; connecting
// and disconnecting go through IOBluetooth, which asks for Bluetooth access the first time.

struct BluetoothDevice: Identifiable, Equatable {
    let id: String            // its address
    let name: String
    let kind: String          // the profiler's minor type: Headset, Mouse, Keyboard…
    let connected: Bool
    /// The lowest battery it reports (one level, or the lowest of left, right and case), 0…100.
    let battery: Int?
    /// AirPods-style detail: "L 80% · R 75% · case 40%".
    let batteryDetail: String?

    var symbol: String {
        let n = name.lowercased(), k = kind.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods") { return "airpodspro" }
        if k.contains("mouse") { return "magicmouse.fill" }
        if k.contains("keyboard") { return "keyboard.fill" }
        if k.contains("trackpad") { return "rectangle.and.hand.point.up.left.fill" }
        if k.contains("game") { return "gamecontroller.fill" }
        if k.contains("headset") || k.contains("headphone") || k.contains("audio") { return "headphones" }
        if k.contains("speaker") { return "hifispeaker.fill" }
        return "dot.radiowaves.left.and.right"
    }
}

@MainActor
final class ControlsConnections: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = ControlsConnections()

    // Wi-Fi
    @Published private(set) var wifiOn: Bool?
    @Published private(set) var wifiName: String?
    @Published private(set) var wifiRSSI: Int = 0
    @Published private(set) var wifiRate: Double = 0
    @Published private(set) var locationAllowed = false
    @Published private(set) var locationAsked = false

    // Bluetooth
    @Published private(set) var bluetoothOn: Bool?
    @Published private(set) var devices: [BluetoothDevice] = []
    /// The device being connected or disconnected (its row says so and waits).
    @Published private(set) var busy: String?

    private let location = CLLocationManager()
    private var timer: Timer?
    private var profilerRunning = false

    private override init() {
        super.init()
        location.delegate = self
        updateLocation()
    }

    /// While the page shows: Wi-Fi every 3 s, Bluetooth every 6 s (the profiler takes ~0.1 s,
    /// off the main thread).
    func watch(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else { return }
        readWiFi()
        readBluetooth()
        var tick = 0
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated {
                let c = ControlsConnections.shared
                c.readWiFi()
                tick += 1
                if tick % 2 == 0 { c.readBluetooth() }
            }
        }
        timer?.tolerance = 0.5
    }

    // MARK: Wi-Fi

    func readWiFi() {
        #if DEBUG
        if debugFrozen { return }
        #endif
        guard let iface = CWWiFiClient.shared().interface() else { wifiOn = nil; return }
        wifiOn = iface.powerOn()
        wifiName = iface.ssid()
        wifiRSSI = iface.rssiValue()
        wifiRate = iface.transmitRate()
    }

    func setWiFi(_ on: Bool) {
        guard let iface = CWWiFiClient.shared().interface() else { return }
        do {
            try iface.setPower(on)
            appendAppLog("nb.log", "[Controls] Wi-Fi \(on ? "on" : "off")")
        } catch {
            appendAppLog("nb.log", "[Controls] Wi-Fi \(on ? "on" : "off") failed: \(error.localizedDescription)")
        }
        readWiFi()
    }

    /// "strong", "good", "weak" from the signal, as the menu bar's bars read it.
    var wifiQuality: String {
        switch wifiRSSI {
        case -60...0: "strong"
        case -70 ..< -60: "good"
        default: "weak"
        }
    }

    var wifiBars: Int {
        switch wifiRSSI {
        case -55...0: 3
        case -67 ..< -55: 2
        default: 1
        }
    }

    func requestLocation() {
        locationAsked = true
        location.requestWhenInUseAuthorization()
    }

    private func updateLocation() {
        let status = location.authorizationStatus
        locationAllowed = status == .authorizedAlways || status == .authorized
        locationAsked = status != .notDetermined
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            ControlsConnections.shared.updateLocation()
            ControlsConnections.shared.readWiFi()
        }
    }

    // MARK: Bluetooth

    func readBluetooth() {
        #if DEBUG
        if debugFrozen { return }
        #endif
        guard !profilerRunning else { return }
        profilerRunning = true
        Task.detached(priority: .utility) {
            let read = Self.profiler()
            await MainActor.run {
                let c = ControlsConnections.shared
                c.profilerRunning = false
                guard let read else { return }
                c.bluetoothOn = read.on
                if c.devices != read.devices { c.devices = read.devices }
            }
        }
    }

    /// Connects or disconnects a paired device; macOS asks for Bluetooth access the first time.
    func toggle(_ device: BluetoothDevice) {
        guard busy == nil else { return }
        busy = device.id
        let connect = !device.connected
        let address = device.id
        DispatchQueue.global(qos: .userInitiated).async {
            let result: IOReturn
            if let d = IOBluetoothDevice(addressString: address) {
                result = connect ? d.openConnection() : d.closeConnection()
            } else {
                result = kIOReturnNotFound
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let c = ControlsConnections.shared
                    appendAppLog("nb.log", "[Controls] Bluetooth \(connect ? "connect" : "disconnect") \(device.name): \(result == kIOReturnSuccess ? "ok" : "failed \(result)")")
                    c.busy = nil
                    c.readBluetooth()
                }
            }
        }
    }

    /// The system profiler's Bluetooth report: the controller's state and every paired device.
    nonisolated static func profiler() -> (on: Bool, devices: [BluetoothDevice])? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        task.arguments = ["-json", "-detailLevel", "basic", "SPBluetoothDataType"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return parse(data)
    }

    nonisolated static func parse(_ data: Data) -> (on: Bool, devices: [BluetoothDevice])? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = (json["SPBluetoothDataType"] as? [[String: Any]])?.first else { return nil }
        let state = (root["controller_properties"] as? [String: Any])?["controller_state"] as? String
        var out: [BluetoothDevice] = []
        for (key, connected) in [("device_connected", true), ("device_not_connected", false)] {
            for entry in root[key] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let p = value as? [String: Any], let address = p["device_address"] as? String else { continue }
                    func level(_ k: String) -> Int? { (p[k] as? String).flatMap { Int($0.filter(\.isNumber)) } }
                    let main = level("device_batteryLevelMain") ?? level("device_batteryLevel")
                    let left = level("device_batteryLevelLeft"), right = level("device_batteryLevelRight"), box = level("device_batteryLevelCase")
                    let parts = [left.map { "L \($0)%" }, right.map { "R \($0)%" }, box.map { "case \($0)%" }].compactMap { $0 }
                    let levels = [main, left, right].compactMap { $0 }
                    out.append(BluetoothDevice(id: address, name: name, kind: p["device_minorType"] as? String ?? "",
                                               connected: connected, battery: levels.min(),
                                               batteryDetail: parts.isEmpty ? nil : parts.joined(separator: " · ")))
                }
            }
        }
        // Connected first, then by name: the ones in use at the top.
        out.sort { ($0.connected ? 0 : 1, $0.name.lowercased()) < ($1.connected ? 0 : 1, $1.name.lowercased()) }
        return (state == "attrib_on", out)
    }

    static func openBluetoothSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
    }

    static func openWiFiSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")!)
    }

    #if DEBUG
    private var debugFrozen = false

    /// Snapshots only: a connected AirPods, a keyboard, a low mouse and one not connected.
    func debugFill() {
        debugFrozen = true
        wifiOn = true; wifiName = "Zoho-Corp"; wifiRSSI = -52; wifiRate = 866; locationAllowed = true
        bluetoothOn = true
        devices = [
            BluetoothDevice(id: "a", name: "AirPods Pro", kind: "Headphones", connected: true, battery: 75, batteryDetail: "L 80% · R 75% · case 40%"),
            BluetoothDevice(id: "k", name: "Magic Keyboard", kind: "Keyboard", connected: true, battery: 62, batteryDetail: nil),
            BluetoothDevice(id: "m", name: "MX Master 3", kind: "Mouse", connected: true, battery: 14, batteryDetail: nil),
            BluetoothDevice(id: "j", name: "JBL Live 770NC", kind: "Headset", connected: false, battery: nil, batteryDetail: nil),
        ]
    }
    #endif
}
// MARK: - Device alerts on the closed notch

/// Always on while its alerts are: every 10 s the profiler's report (no permission, ~0.1 s off the
/// main thread) against the last one. A device that connects or disconnects gets a peek with its
/// battery; one that reaches 20%, and then 10%, gets a low-battery peek, again after a charge.
/// Also keeps the monitors running while the closed notch's wing shows one.
@MainActor
final class ControlsWatcher {
    static let shared = ControlsWatcher()

    private var last: [String: BluetoothDevice]?
    /// The lowest threshold already announced per device (20 or 10).
    private var warned: [String: Int] = [:]
    private var timer: Timer?
    private var reading = false
    private var holdingMonitor = false
    /// A test sequence is running: the real reads wait, so they do not interleave with it.
    private var testing = false

    private init() {}

    func start() {
        guard timer == nil else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { ControlsWatcher.shared.tick() }
        }
        timer?.tolerance = 2
    }

    private func tick() {
        let settings = ControlsSettings.shared
        let wantMonitor = settings.wingMetric != .off
        if wantMonitor != holdingMonitor {
            holdingMonitor = wantMonitor
            ControlsMonitor.shared.hold(wantMonitor)
        }
        guard settings.deviceAlerts || settings.lowBattery, !reading else { if !(settings.deviceAlerts || settings.lowBattery) { last = nil }; return }
        reading = true
        Task.detached(priority: .utility) {
            let read = ControlsConnections.profiler()
            await MainActor.run {
                let w = ControlsWatcher.shared
                w.reading = false
                if let read, !w.testing { w.compare(read.devices) }
            }
        }
    }

    #if DEBUG
    /// `debug.controlsWatch`: a made-up sequence through the same comparison, peeks logged.
    func debugSequence() {
        func dev(_ connected: Bool, _ battery: Int?) -> [BluetoothDevice] {
            [BluetoothDevice(id: "t", name: "Test Buds", kind: "Headphones", connected: connected, battery: battery, batteryDetail: nil)]
        }
        last = nil
        warned = [:]
        testing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { ControlsWatcher.shared.testing = false; ControlsWatcher.shared.last = nil }
        let steps: [[BluetoothDevice]] = [dev(false, nil), dev(true, 80), dev(true, 19), dev(true, 18), dev(true, 9), dev(true, 50), dev(true, 15), dev(false, nil)]
        for (i, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8 * Double(i)) {
                appendAppLog("nb.log", "[Controls] watch step \(i): \(step[0].connected ? "connected" : "not connected") \(step[0].battery.map { "\($0)%" } ?? "")")
                ControlsWatcher.shared.compare(step)
            }
        }
    }
    #endif

    func compare(_ devices: [BluetoothDevice]) {
        let settings = ControlsSettings.shared
        let now = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        defer { last = now }
        // The first report is the baseline: nothing is announced at launch.
        guard let last else { return }
        for d in devices {
            let was = last[d.id]?.connected ?? false
            if settings.deviceAlerts, d.connected, !was {
                let battery = d.battery.map { " · \($0)%" } ?? ""
                NotchPeek.shared.show(icon: d.symbol, text: d.name + battery, tint: Color(hex: "#34D399"))
            } else if settings.deviceAlerts, !d.connected, was {
                NotchPeek.shared.show(icon: d.symbol, text: "\(d.name) disconnected", tint: Color(hex: "#8E939C"))
            }
            guard settings.lowBattery, d.connected, let b = d.battery else { continue }
            if b > 30 { warned[d.id] = nil; continue }
            let threshold = b <= 10 ? 10 : (b <= 20 ? 20 : nil)
            if let threshold, (warned[d.id] ?? 100) > threshold {
                warned[d.id] = threshold
                NotchPeek.shared.show(icon: "battery.25", text: "\(d.name) · \(b)% left", tint: Color(hex: "#F4505E"))
            }
        }
    }
}

/// The closed notch's right wing showing a monitor (Settings → Controls), in the clock's place.
struct ControlsWingText: View {
    @ObservedObject private var monitor = ControlsMonitor.shared
    @ObservedObject private var settings = ControlsSettings.shared

    var body: some View {
        HStack(spacing: 5) {
            if settings.wingMetric == .cpu || settings.wingMetric == .both {
                Text("CPU " + (monitor.cpu.last.map(MonitorFormat.percent) ?? "–")).foregroundColor(Color(hex: "#34D399"))
            }
            if settings.wingMetric == .both { Text("·").foregroundColor(Color(hex: "#6B7079")) }
            if settings.wingMetric == .network || settings.wingMetric == .both {
                Text("↓" + MonitorFormat.rate(monitor.netIn.last ?? 0)).foregroundColor(Color(hex: "#22D3EE"))
            }
        }
        .font(.system(size: 11, weight: .semibold).monospacedDigit())
        .lineLimit(1).fixedSize()
    }

    /// The widest the text gets, for the wing's width.
    @MainActor static func widest(_ metric: ControlsWingMetric) -> String? {
        let speed = ControlsSettings.shared.bits ? "↓999.9 Mbps" : "↓999.9 MB/s"
        switch metric {
        case .off: return nil
        case .cpu: return "CPU 100%"
        case .network: return speed
        case .both: return "CPU 100% · " + speed
        }
    }
}
#endif
