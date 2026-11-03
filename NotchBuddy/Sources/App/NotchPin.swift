import AppKit
import SwiftUI

// MARK: - The header's pin (coucou-custom fork)
//
// Keep open: the notch stops closing by itself (after a while, a click outside, Escape in another
// app) until let go. Stay on this screen: Follow the mouse leaves this notch where it is, open or
// closed. A click on the pin sets or clears both; a right-click or a long press shows the two.
// Neither is saved: a pin is for now, the lasting choice is Settings → General → Show Mochi on.

struct NotchPinButton: View {
    @ObservedObject var state: AppState
    @State private var hover = false
    @State private var choices = false

    private var on: Bool { state.pinOpen || state.pinScreen }

    var body: some View {
        Image(systemName: on ? "pin.fill" : "pin")
            .font(.system(size: 13))
            .foregroundColor(on ? Color(hex: "#FB923C") : (hover ? Color(hex: "#F5F6F8") : Color(hex: "#8E939C")))
            .frame(width: 22, height: 22)
            .background(Circle().fill(on ? Color(hex: "#FB923C").opacity(0.18) : Color.clear))
            .contentShape(Circle())
            .onTapGesture { NotchPin.toggle(state) }
            .onLongPressGesture(minimumDuration: 0.4) { choices = true }
            // View.pointer() is the GitHub build's; this file is in both.
            .onHover { h in hover = h; if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
            .help(on ? "Pinned: click to let go (⌘P)" : "Pin: keep open here (⌘P) · long press for choices")
            .popover(isPresented: $choices, arrowEdge: .bottom) { NotchPinChoices(state: state) }
            .background(RightClick { choices = true })
    }
}

private struct NotchPinChoices: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row("Keep open", "No closing after a while or on a click outside.", $state.pinOpen)
            row("Stay on this screen", "\(NotchPin.screenName), even when the pointer leaves.", $state.pinScreen)
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 6)
            Text("⌘P pins both · Esc or the pin again lets go")
                .font(.system(size: 11)).foregroundColor(Color(hex: "#6B7079")).padding(.horizontal, 10).padding(.vertical, 4)
        }
        .padding(8)
        .frame(width: 300)
    }

    private func row(_ title: String, _ detail: String, _ value: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundColor(Color(hex: "#8E939C")).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: value).toggleStyle(.switch).labelsHidden().controlSize(.small).tint(Color(hex: "#FB923C"))
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }
}

@MainActor
enum NotchPin {
    static func toggle(_ state: AppState) {
        let pin = !(state.pinOpen || state.pinScreen)
        state.pinOpen = pin
        state.pinScreen = pin
        appendAppLog("nb.log", "[Notch] pin \(pin ? "on" : "off")")
    }

    /// Closing on purpose (×, Escape in the notch, the shortcut) lets go of Keep open.
    static func letGo(_ state: AppState, reason: String) {
        guard state.pinOpen, explicit.contains(reason) else { return }
        state.pinOpen = false
        appendAppLog("nb.log", "[Notch] pin let go: \(reason)")
    }
    static let explicit: Set<String> = ["× in the header clicked", "Escape in the notch", "shortcut", "open terminal shortcut"]

    #if DEBUG
    /// `debug.pin` "toggle|close|x": pins, then asks the notch to close by the app or by ×, logging what happened.
    static func installDebug() {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("fr.louisraille.NotchBuddy.debug.pin"),
                                                            object: nil, queue: .main) { note in
            let what = note.object as? String ?? "toggle"
            MainActor.assumeIsolated {
                let s = AppState.shared
                switch what {
                case "close": NotificationCenter.default.post(name: .islandCollapse, object: nil)
                case "x": NotificationCenter.default.post(name: .islandCollapse, object: "× in the header" as NSString)
                default: toggle(s)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    appendAppLog("nb.log", "[Notch] pin test \(what): open \(s.pinOpen) screen \(s.pinScreen) mode \(s.mode.rawValue)")
                }
            }
        }
    }
    #endif

    static var screenName: String { IslandWindowController.currentScreen?.localizedName ?? "This screen" }
}

/// A right-click on a SwiftUI view, which has no gesture for it.
private struct RightClick: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> NSView { View(action: action) }
    func updateNSView(_ view: NSView, context: Context) { (view as? View)?.action = action }
    final class View: NSView {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func rightMouseDown(with event: NSEvent) { action() }
    }
}
