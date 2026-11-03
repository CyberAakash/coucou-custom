#if !APPSTORE
import AudioToolbox
import CoreAudio
import Foundation

// MARK: - Sound for the Controls page (coucou-custom fork, roadmap phase 4)
//
// The Mac's outputs, the default one, its volume and mute, and the default input's mute, all
// through CoreAudio, with listeners so the page follows changes made anywhere (the menu bar,
// the keyboard's volume keys, a headset plugged in).

struct AudioOutput: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    /// Bluetooth, built-in, HDMI…: the symbol beside its name.
    let transport: UInt32
}

@MainActor
final class ControlsAudio: ObservableObject {
    static let shared = ControlsAudio()

    @Published private(set) var outputs: [AudioOutput] = []
    @Published private(set) var current: AudioDeviceID = 0
    /// 0…1; nil when this output has no volume of its own (an HDMI display).
    @Published private(set) var volume: Float?
    @Published private(set) var muted = false
    @Published private(set) var micMuted = false
    @Published private(set) var inputName: String?

    private var started = false
    /// The input's volume before Coucou muted it, for inputs that have no mute switch.
    private var micVolumeBefore: Float?

    private init() {}

    /// Listeners on the system object (devices, defaults) and on the current output (volume,
    /// mute); called once when the Controls page first shows.
    func start() {
        guard !started else { return }
        started = true
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice] {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(system, &address, .main) { _, _ in
                MainActor.assumeIsolated { ControlsAudio.shared.reload() }
            }
        }
        reload()
    }

    func reload() {
        outputs = Self.allDevices().compactMap { id in
            guard Self.channels(id, scope: kAudioObjectPropertyScopeOutput) > 0 else { return nil }
            let transport = Self.uint32(id, kAudioDevicePropertyTransportType)
            // Virtual devices are other apps' plumbing (Zoom, Teams, recorders), not speakers.
            guard transport != kAudioDeviceTransportTypeVirtual, transport != kAudioDeviceTransportTypeAggregate else { return nil }
            return AudioOutput(id: id, name: Self.name(id) ?? "Output", transport: transport)
        }
        let old = current
        current = Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        if old != current { watch(current, previous: old) }
        readLevels()
    }

    private func readLevels() {
        volume = Self.volume(current, scope: kAudioObjectPropertyScopeOutput)
        muted = Self.uint32(current, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput) == 1
        let input = Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        inputName = input == 0 ? nil : Self.name(input)
        let inputMute = Self.uint32(input, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput) == 1
        micMuted = inputMute || (micVolumeBefore != nil && (Self.volume(input, scope: kAudioObjectPropertyScopeInput) ?? 1) == 0)
    }

    /// The current output's volume and mute: the keyboard's keys and the menu bar change them too.
    private var watched: AudioDeviceID = 0
    private func watch(_ device: AudioDeviceID, previous: AudioDeviceID) {
        guard device != 0, device != watched else { return }
        watched = device
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var address = Self.address(selector, scope: kAudioObjectPropertyScopeOutput)
            AudioObjectAddPropertyListenerBlock(device, &address, .main) { _, _ in
                MainActor.assumeIsolated {
                    // A listener of an earlier output still fires: only the current one counts.
                    guard ControlsAudio.shared.current == device else { return }
                    ControlsAudio.shared.readLevels()
                }
            }
        }
    }

    // MARK: Changing

    func use(_ output: AudioOutput) {
        var id = output.id
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                                UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        appendAppLog("nb.log", "[Controls] output \(output.name)\(status == noErr ? "" : " failed (\(status))")")
        reload()
    }

    func setVolume(_ value: Float) {
        var v = max(0, min(1, value))
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
        guard AudioObjectSetPropertyData(current, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &v) == noErr else { return }
        volume = v
        // Turning it up from silence unmutes, as the volume keys do.
        if muted && v > 0 { setMuted(false) }
    }

    func setMuted(_ on: Bool) {
        var value: UInt32 = on ? 1 : 0
        var address = Self.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
        if AudioObjectSetPropertyData(current, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr { muted = on }
    }

    /// The default input muted: its mute switch when it has one, else its volume at 0 (and back).
    func setMicMuted(_ on: Bool) {
        let input = Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        guard input != 0 else { return }
        var value: UInt32 = on ? 1 : 0
        var address = Self.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput)
        var settable: DarwinBoolean = false
        if AudioObjectIsPropertySettable(input, &address, &settable) == noErr, settable.boolValue,
           AudioObjectSetPropertyData(input, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr {
            micMuted = on
            appendAppLog("nb.log", "[Controls] mic \(on ? "muted" : "on")")
            return
        }
        var volume: Float
        if on {
            micVolumeBefore = Self.volume(input, scope: kAudioObjectPropertyScopeInput) ?? 1
            volume = 0
        } else {
            volume = micVolumeBefore ?? 0.75
            micVolumeBefore = nil
        }
        var vAddress = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeInput)
        if AudioObjectSetPropertyData(input, &vAddress, 0, nil, UInt32(MemoryLayout<Float>.size), &volume) == noErr {
            micMuted = on
            appendAppLog("nb.log", "[Controls] mic \(on ? "muted (volume 0)" : "on")")
        }
    }

    // MARK: CoreAudio reads

    private nonisolated static func address(_ selector: AudioObjectPropertySelector,
                                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private nonisolated static func allDevices() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private nonisolated static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = address(selector)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr ? id : 0
    }

    private nonisolated static func name(_ id: AudioDeviceID) -> String? {
        var address = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private nonisolated static func uint32(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                                           scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32 {
        guard id != 0 else { return 0 }
        var address = address(selector, scope: scope)
        guard AudioObjectHasProperty(id, &address) else { return 0 }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : 0
    }

    private nonisolated static func volume(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Float? {
        guard id != 0 else { return nil }
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private nonisolated static func channels(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
#endif
