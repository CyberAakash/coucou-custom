#if !APPSTORE
import AppKit
import CoreLocation
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
#endif
