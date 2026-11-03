#if !APPSTORE
import AppKit
import Darwin
import IOKit

// MARK: - System monitors for the Controls page (coucou-custom fork, roadmap phase 4)
//
// CPU, memory, disk and network, read once a second while the page shows (and never otherwise),
// with five minutes of history. The detail view also asks which apps are using it: helper
// processes are counted under the app they belong to (a browser's helpers are the browser).

enum MonitorKind: String, CaseIterable, Identifiable {
    case cpu, memory, disk, network
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .network: "Network"
        }
    }
}

/// One app's share of the kind shown, for "Using it now".
struct MonitorApp: Identifiable, Equatable {
    let id: String          // the .app's path, or the process name
    let name: String
    let path: String?
    let value: Double       // CPU: a fraction of one core × cores; memory: bytes; disk: bytes a second
}

@MainActor
final class ControlsMonitor: ObservableObject {
    static let shared = ControlsMonitor()
    static let historyLength = 300

    @Published private(set) var cpu: [Double] = []            // 0…1 of the whole Mac
    @Published private(set) var memory: [Double] = []         // 0…1
    @Published private(set) var disk: [Double] = []           // bytes a second, read + written
    @Published private(set) var netIn: [Double] = []          // bytes a second
    @Published private(set) var netOut: [Double] = []
    @Published private(set) var memoryUsed: UInt64 = 0
    @Published private(set) var memoryTotal: UInt64 = 0
    @Published private(set) var swapUsed: UInt64 = 0
    @Published private(set) var diskFree: UInt64?
    @Published private(set) var diskTotal: UInt64?
    @Published private(set) var diskRead: Double = 0
    @Published private(set) var diskWrite: Double = 0
    @Published private(set) var apps: [MonitorApp] = []
    /// The app list is read for this kind only, while its detail is open.
    var appsFor: MonitorKind? { didSet { lastProc = [:]; apps = [] } }

    private var timer: Timer?
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var lastNet: (rx: UInt64, tx: UInt64, at: TimeInterval)?
    private var lastDisk: (read: UInt64, written: UInt64, at: TimeInterval)?
    private var lastProc: [pid_t: (cpu: UInt64, disk: UInt64)] = [:]
    private var lastProcAt: TimeInterval = 0
    private var holders = 0

    private init() {}

    func hold(_ on: Bool) {
        holders = max(0, holders + (on ? 1 : -1))
        if holders > 0, timer == nil {
            read()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { ControlsMonitor.shared.read() }
            }
            timer?.tolerance = 0.2
        } else if holders == 0 {
            timer?.invalidate()
            timer = nil
            // Rates need two readings: a stale one would make the first point a spike.
            lastTicks = nil
            lastNet = nil
            lastDisk = nil
        }
    }

    private func push(_ value: Double, into list: inout [Double]) {
        list.append(value)
        if list.count > Self.historyLength { list.removeFirst(list.count - Self.historyLength) }
    }

    private func read() {
        let now = ProcessInfo.processInfo.systemUptime
        if let ticks = MachineVitals.cpuTicks() {
            if let last = lastTicks, ticks.total > last.total {
                push(Double(ticks.busy &- last.busy) / Double(ticks.total - last.total), into: &cpu)
            }
            lastTicks = ticks
        }
        if let m = RunnerSampler.memory() {
            memoryUsed = m.used
            memoryTotal = m.total
            push(Double(m.used) / Double(max(1, m.total)), into: &memory)
        }
        swapUsed = Self.swap()
        if let net = RunnerSampler.networkBytes() {
            if let last = lastNet, now > last.at {
                push(Double(net.rx &- last.rx) / (now - last.at), into: &netIn)
                push(Double(net.tx &- last.tx) / (now - last.at), into: &netOut)
            }
            lastNet = (net.rx, net.tx, now)
        }
        if let d = Self.diskBytes() {
            if let last = lastDisk, now > last.at {
                diskRead = Double(d.read &- last.read) / (now - last.at)
                diskWrite = Double(d.written &- last.written) / (now - last.at)
                push(diskRead + diskWrite, into: &disk)
            }
            lastDisk = (d.read, d.written, now)
        }
        if diskTotal == nil || Int(now) % 30 == 0, let s = RunnerSampler.storage() {
            diskTotal = s.total
            diskFree = s.total - s.used
        }
        if let kind = appsFor, kind != .network, now - lastProcAt >= 2 {
            readApps(kind, now: now)
        }
    }

    // MARK: Apps using it

    /// Every process's CPU time and disk bytes, summed per app; the top three by the kind's measure.
    private func readApps(_ kind: MonitorKind, now: TimeInterval) {
        let seconds = lastProcAt == 0 ? 0 : now - lastProcAt
        lastProcAt = now
        var count = proc_listallpids(nil, 0)
        guard count > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var byApp: [String: (name: String, path: String?, value: Double)] = [:]
        var next: [pid_t: (cpu: UInt64, disk: UInt64)] = [:]
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        for pid in pids.prefix(Int(max(0, count))) where pid > 0 {
            var usage = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard ok == 0 else { continue }
            let cpuNs = (usage.ri_user_time + usage.ri_system_time) * UInt64(timebase.numer) / UInt64(max(1, timebase.denom))
            let diskBytes = usage.ri_diskio_bytesread + usage.ri_diskio_byteswritten
            next[pid] = (cpuNs, diskBytes)
            let value: Double
            switch kind {
            case .cpu:
                guard seconds > 0, let last = lastProc[pid], cpuNs >= last.cpu else { continue }
                value = Double(cpuNs - last.cpu) / 1e9 / seconds
            case .memory:
                value = Double(usage.ri_phys_footprint)
            case .disk:
                guard seconds > 0, let last = lastProc[pid], diskBytes >= last.disk else { continue }
                value = Double(diskBytes - last.disk) / seconds
            case .network:
                continue
            }
            guard value > 0 else { continue }
            let owner = Self.owner(pid)
            byApp[owner.id, default: (owner.name, owner.path, 0)].value += value
        }
        lastProc = next
        apps = byApp.map { MonitorApp(id: $0.key, name: $0.value.name, path: $0.value.path, value: $0.value.value) }
            .sorted { $0.value > $1.value }.prefix(3).map { $0 }
    }

    /// The app a process belongs to: the outermost .app in its path, else its own name.
    private static func owner(_ pid: pid_t) -> (id: String, name: String, path: String?) {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = length > 0 ? String(cString: buffer) : ""
        if let r = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app") : nil) {
            let app = String(path[..<r.upperBound]).replacingOccurrences(of: ".app/", with: ".app")
            let name = FileManager.default.displayName(atPath: app).replacingOccurrences(of: ".app", with: "")
            return (app, name, app)
        }
        var nameBuffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let name = String(cString: nameBuffer)
        return (name.isEmpty ? "pid \(pid)" : name, name.isEmpty ? "Process \(pid)" : name, nil)
    }

    // MARK: The Mac

    private static func swap() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        return sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 ? usage.xsu_used : 0
    }

    /// Bytes read and written by every disk since boot, from the storage drivers' statistics.
    private static func diskBytes() -> (read: UInt64, written: UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, written: UInt64 = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                read &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                written &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return (read, written)
    }

    /// The interface carrying traffic and its address, for the network detail ("en0 · 192.168.1.24").
    static func primaryAddress() -> (interface: String, address: String)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: (String, String)?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), a.ifa_flags & UInt32(IFF_UP) != 0,
                  a.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: a.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let address = String(cString: host)
            // en0 first (Wi-Fi or the built-in Ethernet), then whichever is up.
            if name == "en0" { return (name, address) }
            if found == nil, name.hasPrefix("en") { found = (name, address) }
        }
        return found
    }

    #if DEBUG
    /// Snapshots only: five minutes of plausible history, as if the page had been open.
    func debugFill() {
        func wave(_ base: Double, _ amp: Double, _ seed: Double) -> [Double] {
            (0..<Self.historyLength).map { i in max(0, base + amp * sin(Double(i) / 9 + seed) + amp * 0.4 * sin(Double(i) / 3.1 + seed * 2)) }
        }
        cpu = wave(0.22, 0.12, 0.3); memory = wave(0.62, 0.02, 1); disk = wave(3e6, 3e6, 2)
        netIn = wave(6e6, 5e6, 0.7); netOut = wave(6e5, 4e5, 1.4)
        memoryUsed = 11_200_000_000; memoryTotal = 18_000_000_000; swapUsed = 1_100_000_000
        diskFree = 412_000_000_000; diskTotal = 994_000_000_000; diskRead = 2.1e6; diskWrite = 0.8e6
        apps = [MonitorApp(id: "/Applications/Xcode.app", name: "Xcode", path: "/Applications/Xcode.app", value: 1.4),
                MonitorApp(id: "/Applications/Safari.app", name: "Safari", path: "/Applications/Safari.app", value: 0.6),
                MonitorApp(id: "/System/Applications/Mail.app", name: "Mail", path: "/System/Applications/Mail.app", value: 0.2)]
    }
    #endif
}

enum MonitorFormat {
    static func bytes(_ b: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory)
    }

    /// MB/s, or Mbps when Settings → Controls says so (a speed test's unit).
    @MainActor static func rate(_ bytesPerSecond: Double) -> String {
        if ControlsSettings.shared.bits {
            let b = bytesPerSecond * 8
            if b >= 1e9 { return String(format: "%.1f Gbps", b / 1e9) }
            if b >= 1e6 { return String(format: "%.1f Mbps", b / 1e6) }
            if b >= 1e3 { return String(format: "%.0f Kbps", b / 1e3) }
            return "0 Kbps"
        }
        let v = bytesPerSecond
        if v >= 1e9 { return String(format: "%.1f GB/s", v / 1e9) }
        if v >= 1e6 { return String(format: "%.1f MB/s", v / 1e6) }
        if v >= 1e3 { return String(format: "%.0f KB/s", v / 1e3) }
        return "0 KB/s"
    }

    static func percent(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }
}
#endif
