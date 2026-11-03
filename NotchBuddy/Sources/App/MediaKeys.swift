#if !APPSTORE
import AppKit
import ApplicationServices
import SwiftUI

// MARK: - Volume and brightness keys in the notch (coucou-custom fork, design board 1)
//
// An event tap takes the keyboard's volume, mute and brightness keys before macOS draws its own
// overlay, changes the level itself (16 steps; ⌥⇧ for quarter steps, as macOS does) and shows it
// as a peek: the closed notch widens with the symbol, a bar and the number. A tap that changes
// events needs Accessibility; without it nothing is taken and macOS keeps its overlay. Keys the
// notch cannot do (an output with no volume of its own, an external display's brightness, the
// keyboard's backlight) pass through to macOS untouched.

@MainActor
final class MediaKeys {
    static let shared = MediaKeys()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var waitingForAccess: Timer?

    private init() {}

    var running: Bool { tap != nil }

    /// Started at launch and whenever Settings → Controls changes it.
    func update() {
        stop()
        guard ControlsSettings.shared.keysInNotch else { return }
        guard AXIsProcessTrusted() else {
            appendAppLog("nb.log", "[Keys] volume and brightness keys: no Accessibility, macOS keeps its overlay")
            return
        }
        ControlsAudio.shared.start()
        // NX_SYSDEFINED (14) carries the media keys.
        let mask = CGEventMask(1) << 14
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: mediaKeyTap, userInfo: nil) else {
            appendAppLog("nb.log", "[Keys] volume and brightness keys: the event tap was refused")
            return
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        appendAppLog("nb.log", "[Keys] volume and brightness keys in the notch")
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    /// After asking for Accessibility: starts as soon as it is given (checked each second, a minute at most).
    func waitForAccess() {
        waitingForAccess?.invalidate()
        accessChecks = 60
        waitingForAccess = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { MediaKeys.shared.checkAccess() }
        }
    }
    private var accessChecks = 0
    private func checkAccess() {
        accessChecks -= 1
        if AXIsProcessTrusted() { waitingForAccess?.invalidate(); update() } else if accessChecks <= 0 { waitingForAccess?.invalidate() }
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    enum Key { case volumeUp, volumeDown, mute, brightnessUp, brightnessDown }

    /// True when the notch did it (the key is then swallowed).
    func press(_ key: Key, fine: Bool) -> Bool {
        let audio = ControlsAudio.shared, display = ControlsDisplay.shared
        #if DEBUG
        defer { appendAppLog("nb.log", "[Keys] \(key)\(fine ? " fine" : ""): volume \(audio.volume ?? -1) muted \(audio.muted) brightness \(display.brightness ?? -1)") }
        #endif
        switch key {
        case .volumeUp, .volumeDown:
            guard let v = audio.volume else { return false }
            let from: Float = audio.muted ? 0 : v
            audio.setVolume(ControlsKeys.stepped(from, key == .volumeUp ? 1 : -1, fine))
            showVolume()
        case .mute:
            guard audio.volume != nil else { return false }
            audio.setMuted(!audio.muted)
            showVolume()
        case .brightnessUp, .brightnessDown:
            display.read()
            guard let b = display.brightness else { return false }
            display.setBrightness(ControlsKeys.stepped(b, key == .brightnessUp ? 1 : -1, fine))
            let level = Double(display.brightness ?? b)
            NotchPeek.shared.show(icon: "sun.max.fill", text: "\(Int((level * 100).rounded()))", tint: Color(hex: "#F7B32B"),
                                  level: level, seconds: 1.2)
        }
        return true
    }

    private func showVolume() {
        let audio = ControlsAudio.shared
        let v = Double(audio.volume ?? 0)
        if audio.muted || v < 0.005 {
            NotchPeek.shared.show(icon: "speaker.slash.fill", text: audio.muted ? "Muted" : "0", tint: Color(hex: "#F4505E"),
                                  level: 0, seconds: 1.2)
        } else {
            let icon = v < 0.34 ? "speaker.wave.1.fill" : (v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
            NotchPeek.shared.show(icon: icon, text: "\(Int((v * 100).rounded()))", tint: Color(hex: "#F5F6F8"), level: v, seconds: 1.2)
        }
    }
}

/// The tap's callback, on the main run loop. A media key's data1 holds its code in the top 16
/// bits and its state in the next 8 (0x0A down, 0x0B up).
private func mediaKeyTap(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { MediaKeys.shared.reenable() }
        return Unmanaged.passUnretained(event)
    }
    guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
        return Unmanaged.passUnretained(event)
    }
    let code = (ns.data1 & 0xFFFF_0000) >> 16
    let down = ((ns.data1 & 0xFF00) >> 8) == 0x0A
    let key: MediaKeys.Key? = switch code {
    case 0: .volumeUp
    case 1: .volumeDown
    case 7: .mute
    case 2: .brightnessUp
    case 3: .brightnessDown
    default: nil
    }
    guard let key else { return Unmanaged.passUnretained(event) }
    let flags = event.flags
    let fine = flags.contains(.maskAlternate) && flags.contains(.maskShift)
    let taken = MainActor.assumeIsolated { () -> Bool in
        // The key's release goes with its press: swallowed when the press was.
        if !down { return MediaKeys.lastTaken }
        let t = MediaKeys.shared.press(key, fine: fine)
        MediaKeys.lastTaken = t
        return t
    }
    return taken ? nil : Unmanaged.passUnretained(event)
}

extension MediaKeys {
    @MainActor static var lastTaken = false
}
#endif
