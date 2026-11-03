#if !APPSTORE
import AppKit
import CoreGraphics
import IOKit.pwr_mgt

// MARK: - Display and theme for the Controls page (coucou-custom fork, roadmap phase 4)
//
// Brightness of the built-in display and Night Shift have no public API: they go through the
// frameworks every brightness app uses (DisplayServices, CoreBrightness), looked up at run time.
// Whatever is missing on this Mac (a later macOS, no built-in display) is reported as missing and
// the page hides it, rather than failing. Dark mode goes through System Events (asks once);
// keeping the Mac awake is an ordinary power assertion.

@MainActor
final class ControlsDisplay: ObservableObject {
    static let shared = ControlsDisplay()

    /// 0…1; nil when there is no built-in display or the framework did not answer.
    @Published private(set) var brightness: Float?
    @Published private(set) var nightShift: Bool?
    @Published private(set) var dark = false
    @Published private(set) var keepAwake = false

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private let getBrightness: GetBrightness?
    private let setBrightnessFn: SetBrightness?
    private let blueLight: NSObject?
    private var assertion: IOPMAssertionID = 0
    private var poll: Timer?

    private init() {
        let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        getBrightness = ds.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: GetBrightness.self) }
        setBrightnessFn = ds.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: SetBrightness.self) }
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        blueLight = (NSClassFromString("CBBlueLightClient") as? NSObject.Type)?.init()
        read()
    }

    /// While the page shows: brightness and Night Shift change from the keyboard and Control
    /// Center without telling anyone, so they are read every second.
    func watch(_ on: Bool) {
        poll?.invalidate()
        poll = nil
        guard on else { return }
        read()
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { ControlsDisplay.shared.read() }
        }
        poll?.tolerance = 0.3
    }

    func read() {
        if let display = Self.builtIn, let getBrightness {
            var value: Float = 0
            brightness = getBrightness(display, &value) == 0 ? value : nil
        } else {
            brightness = nil
        }
        nightShift = blueLightStatus()
        dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
            || NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static var builtIn: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    func setBrightness(_ value: Float) {
        guard let display = Self.builtIn, let setBrightnessFn else { return }
        let v = max(0, min(1, value))
        if setBrightnessFn(display, v) == 0 { brightness = v }
    }

    // MARK: Night Shift

    /// CBBlueLightClient's status: the first bytes are `active` then `enabled` (BOOLs); the
    /// rest (schedule, mode) is not read, so a longer struct on a later macOS does no harm.
    private func blueLightStatus() -> Bool? {
        guard let client = blueLight else { return nil }
        let selector = NSSelectorFromString("getBlueLightStatus:")
        guard client.responds(to: selector), let imp = client.method(for: selector) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 128, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 128)
        guard unsafeBitCast(imp, to: Fn.self)(client, selector, buffer) else { return nil }
        return buffer.load(fromByteOffset: 1, as: Bool.self)
    }

    func setNightShift(_ on: Bool) {
        guard let client = blueLight else { return }
        let selector = NSSelectorFromString("setEnabled:")
        guard client.responds(to: selector), let imp = client.method(for: selector) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Bool
        if unsafeBitCast(imp, to: Fn.self)(client, selector, on) { nightShift = on }
        appendAppLog("nb.log", "[Controls] Night Shift \(on ? "on" : "off")")
    }

    // MARK: Dark mode

    /// Through System Events: macOS asks once whether Coucou may control it.
    func setDark(_ on: Bool) {
        let source = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)"
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            let failed = error != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    appendAppLog("nb.log", "[Controls] dark \(on)\(failed ? " failed (System Events not allowed?)" : "")")
                    ControlsDisplay.shared.read()
                    if !failed { ControlsDisplay.shared.dark = on }
                }
            }
        }
    }

    // MARK: Keep awake

    /// The display stays on and the Mac awake until turned off or Coucou quits (the assertion
    /// goes with the process).
    func setKeepAwake(_ on: Bool) {
        if on, assertion == 0 {
            let ok = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Coucou: Keep awake" as CFString, &assertion)
            keepAwake = ok == kIOReturnSuccess
        } else if !on, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
            keepAwake = false
        }
        appendAppLog("nb.log", "[Controls] keep awake \(keepAwake)")
    }
}
#endif
