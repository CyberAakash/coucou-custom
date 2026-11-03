#if !APPSTORE
import CoreBluetooth
import CoreLocation
import SwiftUI

// MARK: - Settings → Controls (coucou-custom fork, roadmap phase 4)
//
// The notch's Controls page on or off, which Control Center tiles it shows, the speed unit, what
// the closed notch says (a device connecting, a low battery, a monitor in the wing), and the
// permissions macOS asks for: Bluetooth to connect devices, Location for the Wi-Fi's name.

struct HubControlsPage: View {
    @ObservedObject private var settings = ControlsSettings.shared
    @ObservedObject private var net = ControlsConnections.shared

    static let tint = Color(hex: "#34D399")

    var body: some View {
        HubPageScaffold(title: "Controls",
                        subtitle: "Sound, brightness and quick switches, your Wi-Fi and Bluetooth devices, and the Mac's live graphs, in the notch.",
                        trailing: { HubBannerSwitch(title: "In the notch", tint: Self.tint, isOn: $settings.enabled) }) {
            HubLabel("Control Center")
            HubCard {
                HubRow(title: "Tiles", detail: "The switches under the sliders. Night Shift shows only where macOS offers it.") {
                    HStack(spacing: 12) {
                        tileToggle("Dark", "dark")
                        tileToggle("Night Shift", "night")
                        tileToggle("Keep awake", "awake")
                        tileToggle("Mic", "mic")
                    }
                }
                HubDivider()
                HubRow(title: "Speeds in", detail: "MB/s, as Activity Monitor counts; Mbps, as a speed test does.") {
                    HubDropdown($settings.bits, [(false, "MB/s"), (true, "Mbps")])
                }
            }

            HubLabel("On the closed notch")
            HubCard {
                HubRow(title: "A device connects or disconnects", detail: "Its name and battery for a moment, like the charger and sound output peeks.") {
                    Toggle("", isOn: $settings.deviceAlerts).toggleStyle(.switch).labelsHidden()
                }
                HubDivider()
                HubRow(title: "Low battery", detail: "When a Bluetooth device reaches 20%, and again at 10%.") {
                    Toggle("", isOn: $settings.lowBattery).toggleStyle(.switch).labelsHidden()
                }
                HubDivider()
                HubRow(title: "A live monitor in the wing", detail: "In the clock's place, when no task or meeting is due there. Off by default: a number that keeps changing pulls the eye.") {
                    HubDropdown($settings.wingMetric, ControlsWingMetric.allCases.map { ($0, $0.title) })
                }
            }

            HubLabel("Access")
            HubCard {
                HubRow(title: "Bluetooth", detail: bluetoothDetail) {
                    if CBManager.authorization == .denied || CBManager.authorization == .restricted {
                        Button("Open System Settings") { Self.openPrivacy("Privacy_Bluetooth") }.buttonStyle(HubButtonStyle())
                    } else {
                        status(CBManager.authorization == .allowedAlways ? "Allowed" : "Asked on first connect")
                    }
                }
                HubDivider()
                HubRow(title: "Location", detail: "Only for the Wi-Fi network's name: macOS gives it to an app with Location allowed.") {
                    if net.locationAllowed {
                        status("Allowed")
                    } else if net.locationAsked {
                        Button("Open System Settings") { ControlsView.openLocationSettings() }.buttonStyle(HubButtonStyle())
                    } else {
                        Button("Allow") { net.requestLocation() }.buttonStyle(HubButtonStyle(primary: true))
                    }
                }
                HubDivider()
                HubRow(title: "Sound, display and monitors", detail: "Need no permission. Dark mode asks once to control System Events.") {
                    status("—")
                }
            }
        }
    }

    private var bluetoothDetail: String {
        "The device list and batteries need nothing; connecting and disconnecting a device asks once."
    }

    private func tileToggle(_ title: String, _ key: String) -> some View {
        Toggle(title, isOn: Binding(get: { !settings.hiddenTiles.contains(key) },
                                    set: { on in if on { settings.hiddenTiles.remove(key) } else { settings.hiddenTiles.insert(key) } }))
            .toggleStyle(.checkbox)
    }

    private func status(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold))
            .foregroundColor(text == "Allowed" ? Self.tint : HubTheme.secondary)
            .padding(.horizontal, 9).frame(height: 22)
            .background(Capsule().fill((text == "Allowed" ? Self.tint : Color.white).opacity(text == "Allowed" ? 0.12 : 0.06)))
    }

    static func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
    }
}
#endif
