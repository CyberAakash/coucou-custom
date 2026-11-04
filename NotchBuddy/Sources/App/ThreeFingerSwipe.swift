#if !APPSTORE
import Foundation

// MARK: - Three fingers on the trackpad, read raw (coucou-custom fork)
//
// macOS hands its "swipe between pages" gesture only to the app under the pointer, and only when
// System Settings uses three fingers for it, so the notch (never the app in front) rarely heard
// one. The trackpad's own touches come from MultitouchSupport, the private framework every
// gesture app uses (no permission needed), looked up at run time: they are read while the
// notch is open (swipes turn pages), and all the time when a three-finger double tap opens and
// closes the notch (Settings → General). Anywhere on the screen, with no click.

enum ThreeFingerSwipe {
    /// -1 previous page, +1 next one; called on the main actor.
    @MainActor static var onSwipe: ((Int) -> Void)?
    /// Two quick three-finger taps; called on the main actor.
    @MainActor static var onDoubleTap: (() -> Void)?
    @MainActor private(set) static var running = false
    /// The swipes are on (the notch is open and Swipe between pages on): the system's own swipe is
    /// then ignored for the page, so a page never turns twice.
    @MainActor static var swipes = false
    /// Settings → General → Double-tap with three fingers.
    static let doubleTapKey = "coucouThreeFingerDoubleTap"
    @MainActor static var doubleTapOn: Bool { UserDefaults.standard.object(forKey: doubleTapKey) as? Bool ?? true }

    /// Reads the trackpad while something needs it: open-notch swipes or the double tap.
    @MainActor static func update(swipes: Bool) {
        self.swipes = swipes
        if swipes || doubleTapOn { start() } else { stop() }
    }

    private typealias Frame = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias DeviceFn = @convention(c) (UnsafeMutableRawPointer) -> Void
    private typealias CallbackFn = @convention(c) (UnsafeMutableRawPointer, Frame) -> Void

    nonisolated(unsafe) private static let framework = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY)
    private static func symbol<T>(_ name: String, _: T.Type) -> T? {
        framework.flatMap { dlsym($0, name) }.map { unsafeBitCast($0, to: T.self) }
    }

    @MainActor private static var devices: [AnyObject] = []

    @MainActor static func start() {
        guard !running,
              let list = symbol("MTDeviceCreateList", (@convention(c) () -> Unmanaged<CFArray>?).self),
              let register = symbol("MTRegisterContactFrameCallback", CallbackFn.self),
              let begin = symbol("MTDeviceStart", (@convention(c) (UnsafeMutableRawPointer, Int32) -> Void).self),
              let found = list()?.takeRetainedValue() as? [AnyObject], !found.isEmpty else { return }
        devices = found
        for device in found {
            let d = Unmanaged.passUnretained(device).toOpaque()
            register(d, frame)
            begin(d, 0)
        }
        running = true
        appendAppLog("nb.log", "[Pages] three-finger touches on (\(found.count) trackpad\(found.count == 1 ? "" : "s"))")
    }

    @MainActor static func stop() {
        guard running else { return }
        let unregister = symbol("MTUnregisterContactFrameCallback", CallbackFn.self)
        let end = symbol("MTDeviceStop", DeviceFn.self)
        for device in devices {
            let d = Unmanaged.passUnretained(device).toOpaque()
            unregister?(d, frame)
            end?(d)
        }
        devices = []
        running = false
        Tracker.reset()
        Taps.reset()
    }

    /// One trackpad frame, on the framework's own thread. A touch is 96 bytes: its state at
    /// 20 (3 to 5 = on the surface), its position at 32 and 36 (0…1, x to the right).
    private static let frame: Frame = { _, touches, count, time, _ in
        var xs: [Float] = [], ys: [Float] = []
        if let touches {
            for i in 0..<Int(count) {
                let t = touches + i * 96
                let state = t.load(fromByteOffset: 20, as: Int32.self)
                guard (3...5).contains(state) else { continue }
                xs.append(t.load(fromByteOffset: 32, as: Float.self))
                ys.append(t.load(fromByteOffset: 36, as: Float.self))
            }
        }
        if let step = Tracker.feed(xs, ys) {
            DispatchQueue.main.async { MainActor.assumeIsolated { if swipes { onSwipe?(step) } } }
        }
        if Taps.feed(xs, ys, time: time) {
            DispatchQueue.main.async { MainActor.assumeIsolated { if doubleTapOn { onDoubleTap?() } } }
        }
        return 0
    }

    /// Two taps of three fingers: each down for under 0.3 s, barely moving, the second starting
    /// within 0.35 s of the first one's lift. Only on the framework's callback thread.
    enum Taps {
        nonisolated(unsafe) static var began: Double?
        nonisolated(unsafe) static var most = 0
        nonisolated(unsafe) static var origin: (x: Float, y: Float)?
        nonisolated(unsafe) static var moved = false
        nonisolated(unsafe) static var lastTap: Double?

        static func reset() { began = nil; most = 0; origin = nil; moved = false; lastTap = nil }

        /// True on the second tap of a pair.
        static func feed(_ xs: [Float], _ ys: [Float], time: Double) -> Bool {
            if xs.isEmpty {
                guard let b = began else { return false }
                let tap = most == 3 && !moved && time - b < 0.3
                began = nil; most = 0; origin = nil; moved = false
                guard tap else { lastTap = nil; return false }
                if let last = lastTap, b - last < 0.35 { lastTap = nil; return true }
                lastTap = time
                return false
            }
            if began == nil { began = time }
            most = max(most, xs.count)
            if xs.count == 3 {
                let x = xs.reduce(0, +) / 3, y = ys.reduce(0, +) / 3
                if let o = origin { if abs(x - o.x) > 0.03 || abs(y - o.y) > 0.03 { moved = true } } else { origin = (x, y) }
            }
            return false
        }
    }

    /// Only ever touched from the framework's callback thread (and reset while stopped).
    private enum Tracker {
        nonisolated(unsafe) static var start: (x: Float, y: Float)?
        nonisolated(unsafe) static var done = false

        static func reset() { start = nil; done = false }

        /// One step per gesture: three fingers that travel a tenth of the pad sideways, more
        /// sideways than up or down. Four or more (switching desktops) never count, until every
        /// finger is up.
        static func feed(_ xs: [Float], _ ys: [Float]) -> Int? {
            if xs.isEmpty { reset(); return nil }
            if xs.count > 3 { done = true; return nil }
            guard xs.count == 3, !done else { if !done { start = nil }; return nil }
            let x = xs.reduce(0, +) / 3, y = ys.reduce(0, +) / 3
            guard let s = start else { start = (x, y); return nil }
            let dx = x - s.x, dy = y - s.y
            guard abs(dx) > 0.1, abs(dx) > abs(dy) * 1.5 else { return nil }
            done = true
            // Fingers to the left go to the next page, as with the system's swipe.
            return dx < 0 ? 1 : -1
        }
    }
}
#endif
