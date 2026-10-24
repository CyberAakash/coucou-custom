#if !APPSTORE
import Combine
import Darwin
import Foundation

// coucou-custom fork: what the menu-bar Runner reads — the Mac's numbers every few seconds, and
// the Custom Metrics files (RunCat Neo's format) the moment a script rewrites them.

struct SystemSample: Equatable {
    var cpu: Double? = nil
    var memoryUsed: UInt64? = nil
    var memoryTotal: UInt64? = nil
    var storageUsed: UInt64? = nil
    var storageTotal: UInt64? = nil
    var batteryPercent: Int? = nil
    var batteryOnPower: Bool? = nil
    var networkIn: Double? = nil
    var networkOut: Double? = nil

    var memoryFraction: Double? {
        guard let u = memoryUsed, let t = memoryTotal, t > 0 else { return nil }
        return Double(u) / Double(t)
    }

    var storageFraction: Double? {
        guard let u = storageUsed, let t = storageTotal, t > 0 else { return nil }
        return Double(u) / Double(t)
    }

    /// The short text the menu bar shows for one number.
    func menuBarText(_ kind: SystemMetricKind) -> String? {
        switch kind {
        case .cpu: return cpu.map { "CPU " + MetricsFormat.percent($0) }
        case .memory: return memoryFraction.map { "MEM " + MetricsFormat.percent($0) }
        case .storage: return storageFraction.map { "SSD " + MetricsFormat.percent($0) }
        case .battery: return batteryPercent.map { "\($0)%" + (batteryOnPower == true ? "⚡︎" : "") }
        case .network:
            guard let i = networkIn, let o = networkOut else { return nil }
            return "↓\(MetricsFormat.rate(i)) ↑\(MetricsFormat.rate(o))"
        }
    }
}

/// Reads the Mac while the Runner shows, every 3, 5 or 10 seconds; nothing at all otherwise.
@MainActor
final class RunnerSampler: ObservableObject {
    static let shared = RunnerSampler()

    @Published private(set) var sample = SystemSample()
    @Published private(set) var cpuHistory = MetricsHistory()
    @Published private(set) var memoryHistory = MetricsHistory()

    private var timer: Timer?
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var lastNetwork: (rx: UInt64, tx: UInt64, at: TimeInterval)?
    private var lastStorageRead: TimeInterval = 0

    var running: Bool { timer != nil }

    func start(interval: Int) {
        stop()
        read()
        let t = Timer(timeInterval: TimeInterval(interval), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
        t.tolerance = TimeInterval(interval) * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastTicks = nil
        lastNetwork = nil
        // Rates and the load need two readings: a stale one would set the speed when it shows again.
        sample.cpu = nil
        sample.networkIn = nil
        sample.networkOut = nil
    }

    private func read() {
        var next = sample
        if let ticks = MachineVitals.cpuTicks() {
            if let last = lastTicks, ticks.total > last.total {
                next.cpu = Double(ticks.busy &- last.busy) / Double(ticks.total - last.total)
            }
            lastTicks = ticks
        }
        if let memory = Self.memory() {
            next.memoryUsed = memory.used
            next.memoryTotal = memory.total
        }
        let now = ProcessInfo.processInfo.systemUptime
        // The disk changes slowly; once a minute is enough.
        if now - lastStorageRead > 60 || next.storageTotal == nil, let disk = Self.storage() {
            next.storageUsed = disk.used
            next.storageTotal = disk.total
            lastStorageRead = now
        }
        if let battery = MachineVitals.readBattery() {
            next.batteryPercent = battery.percent
            next.batteryOnPower = battery.onPower
        } else {
            next.batteryPercent = nil
            next.batteryOnPower = nil
        }
        if let net = Self.networkBytes() {
            if let last = lastNetwork {
                let seconds = now - last.at
                next.networkIn = MetricsFormat.rate(from: last.rx, to: net.rx, seconds: seconds) ?? next.networkIn
                next.networkOut = MetricsFormat.rate(from: last.tx, to: net.tx, seconds: seconds) ?? next.networkOut
            }
            lastNetwork = (net.rx, net.tx, now)
        }
        if let cpu = next.cpu { cpuHistory.append(cpu) }
        if let mem = next.memoryFraction { memoryHistory.append(mem) }
        if next != sample { sample = next }
    }

    // MARK: - The Mac

    /// One send right, kept: each mach_host_self() call adds a reference that is never released.
    private static let host = mach_host_self()

    /// Used memory as Activity Monitor counts it: app memory + wired + compressed.
    static func memory() -> (used: UInt64, total: UInt64)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        host_page_size(host, &pageSize)
        let page = UInt64(pageSize)
        // The counters are not read atomically: purgeable can briefly exceed internal.
        let anonymous = UInt64(stats.internal_page_count), purgeable = UInt64(stats.purgeable_count)
        let app = anonymous > purgeable ? anonymous - purgeable : 0
        let pages = app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        let used = pages.multipliedReportingOverflow(by: page).partialValue
        let total = ProcessInfo.processInfo.physicalMemory
        return (min(used, total), total)
    }

    static func storage() -> (used: UInt64, total: UInt64)? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0,
              let free = values.volumeAvailableCapacityForImportantUsage else { return nil }
        let t = UInt64(total), f = UInt64(max(0, free))
        return (t > f ? t - f : 0, t)
    }

    /// Bytes in and out over every interface but loopback, from the 64-bit counters
    /// (NET_RT_IFLIST2; getifaddrs' if_data wraps at 4 GB).
    static func networkBytes() -> (rx: UInt64, tx: UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return nil }
        var rx: UInt64 = 0, tx: UInt64 = 0
        var offset = 0
        buffer.withUnsafeBytes { raw in
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.load(fromByteOffset: offset, as: if_msghdr.self)
                let size = Int(header.ifm_msglen)
                guard size > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if info.ifm_flags & IFF_LOOPBACK == 0 {
                        rx &+= info.ifm_data.ifi_ibytes
                        tx &+= info.ifm_data.ifi_obytes
                    }
                }
                offset += size
            }
        }
        return (rx, tx)
    }
}

// MARK: - Custom Metrics files

struct MetricsSourceState: Equatable {
    var snapshot: MetricsSnapshot? = nil
    /// The file could not be read or held invalid JSON: the last good snapshot stays, flagged.
    var failed = false
    var error: String? = nil
}

/// Watches each source's file while the Runner shows or its settings page is open.
@MainActor
final class RunnerMetricsCenter: ObservableObject {
    static let shared = RunnerMetricsCenter()

    @Published private(set) var states: [UUID: MetricsSourceState] = [:]

    private var watchers: [UUID: MetricsFileWatcher] = [:]
    private var holders = 0
    private var runnerShowing = false
    private var subscription: AnyCancellable?

    private init() {
        subscription = RunnerSettings.shared.$sources.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] list in
            MainActor.assumeIsolated { self?.reconcile(list) }
        }
    }

    /// The settings page holds the watch open while it is on screen.
    func hold() { holders += 1; reconcile(RunnerSettings.shared.sources) }
    func release() { holders = max(0, holders - 1); reconcile(RunnerSettings.shared.sources) }

    func setRunnerShowing(_ showing: Bool) {
        runnerShowing = showing
        reconcile(RunnerSettings.shared.sources)
    }

    private var active: Bool { runnerShowing || holders > 0 }

    private func reconcile(_ sources: [MetricsSourceConfig]) {
        let wanted = active ? Dictionary(sources.map { ($0.id, $0.path) }, uniquingKeysWith: { first, _ in first }) : [:]
        for (id, watcher) in watchers where wanted[id] != watcher.path {
            watcher.cancel()
            watchers[id] = nil
        }
        for (id, path) in wanted where watchers[id] == nil {
            let watcher = MetricsFileWatcher(path: path) { [weak self] result in
                MainActor.assumeIsolated { self?.apply(result, to: id) }
            }
            watchers[id] = watcher
            watcher.start()
        }
        let ids = Set(sources.map(\.id))
        states = states.filter { ids.contains($0.key) }
    }

    private func apply(_ result: Result<MetricsSnapshot, MetricsReadError>, to id: UUID) {
        var state = states[id] ?? MetricsSourceState()
        switch result {
        case .success(let snapshot):
            state.snapshot = snapshot
            state.failed = false
            state.error = nil
        case .failure(let error):
            state.failed = true
            state.error = error.message
        }
        if states[id] != state { states[id] = state }
    }

    /// Reads a file once, to check it before it is added.
    static func readOnce(_ path: String) -> Result<MetricsSnapshot, MetricsReadError> {
        MetricsFileWatcher.read(path)
    }
}

struct MetricsReadError: Error, Equatable {
    let message: String
}

/// One file: a DispatchSource on it, reopened when a script replaces it (the atomic `mv`
/// RunCat's samples use), retried every 5 seconds while it is missing.
final class MetricsFileWatcher: @unchecked Sendable {
    let path: String
    private let onResult: @Sendable (Result<MetricsSnapshot, MetricsReadError>) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var retry: DispatchSourceTimer?
    private var cancelled = false

    init(path: String, onResult: @escaping @Sendable (Result<MetricsSnapshot, MetricsReadError>) -> Void) {
        self.path = path
        self.onResult = onResult
    }

    /// Everything happens on the main queue: events are rare and the files small.
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        open()
    }

    func cancel() {
        cancelled = true
        source?.cancel()
        source = nil
        retry?.cancel()
        retry = nil
    }

    private func open() {
        guard !cancelled else { return }
        let fd = Darwin.open(path, O_EVTONLY | O_NONBLOCK)
        guard fd >= 0 else {
            onResult(.failure(MetricsReadError(message: "The file is missing or can’t be read.")))
            scheduleRetry(after: 5)
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete, .revoke], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = src.data
            if flags.contains(.rename) || flags.contains(.delete) || flags.contains(.revoke) {
                src.cancel()
                self.source = nil
                // The new file is in place a moment after the rename.
                self.scheduleRetry(after: 0.2)
            } else {
                self.onResult(Self.read(self.path))
            }
        }
        src.setCancelHandler { Darwin.close(fd) }
        source = src
        src.resume()
        onResult(Self.read(path))
    }

    private func scheduleRetry(after seconds: Double) {
        retry?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + seconds, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.retry?.cancel()
            self?.retry = nil
            self?.open()
        }
        retry = timer
        timer.resume()
    }

    static func read(_ path: String) -> Result<MetricsSnapshot, MetricsReadError> {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return .failure(MetricsReadError(message: "The file is missing or can’t be read."))
        }
        // A FIFO or a device would block the main thread or never end.
        guard values.isRegularFile == true else {
            return .failure(MetricsReadError(message: "Not a regular file."))
        }
        guard (values.fileSize ?? 0) <= MetricsSnapshot.maxBytes else {
            return .failure(MetricsReadError(message: "The file is larger than 1 MB."))
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .failure(MetricsReadError(message: "The file can’t be read."))
        }
        defer { try? handle.close() }
        // Capped, in case it grew since the size was read.
        guard let data = try? handle.read(upToCount: MetricsSnapshot.maxBytes + 1) ?? Data() else {
            return .failure(MetricsReadError(message: "The file can’t be read."))
        }
        do {
            return .success(try MetricsSnapshot.decode(data))
        } catch MetricsSnapshot.Failure.invalid(let why) {
            return .failure(MetricsReadError(message: why))
        } catch {
            return .failure(MetricsReadError(message: "The file is larger than 1 MB."))
        }
    }
}
#endif
