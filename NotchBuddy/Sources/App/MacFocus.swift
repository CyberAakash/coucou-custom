#if !APPSTORE
import AppKit
import SwiftUI

// MARK: - The Mac's Focus, told by Shortcuts (coucou-custom fork, phase 5)
//
// macOS gives the Focus state only to apps with Apple's Communication Notifications capability,
// and its Focus filters never reached this self-signed build (System Settings waited on it for
// ever). So the person's own Shortcuts automations tell Coucou: "When Work turns on → Open URLs
// coucou://focus/on?name=Work", and the same with /off. Coucou then shows the Focus by Mochi,
// peeks once on each change and keeps its other peeks quiet while one is on.

@MainActor
final class MacFocus: ObservableObject {
    static let shared = MacFocus()

    /// The Focus that is on, as the automation named it; nil when none.
    /// Kept across launches: the automation only speaks when the Focus changes.
    @Published private(set) var current: String? = UserDefaults.standard.string(forKey: "coucouFocusCurrent") {
        didSet { UserDefaults.standard.set(current, forKey: "coucouFocusCurrent") }
    }
    /// Settings → Routines → Focus → Quiet the notch.
    @AppStorage("coucouFocusQuiet") var quiet = true

    private init() {}

    static let tint = Color(hex: "#818CF8")

    /// Peeks other than the one saying so wait while a Focus is on (a key's level still shows).
    var quietsPeeks: Bool { quiet && current != nil }

    /// coucou://focus/on?name=Work, coucou://focus/off?name=Work (or /off alone).
    func handle(_ url: URL) -> Bool {
        guard url.scheme == "coucou", url.host == "focus" else { return false }
        let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "name" }?.value?.trimmingCharacters(in: .whitespaces)
        switch url.path {
        case "/on":
            set(name.flatMap { $0.isEmpty ? nil : $0 } ?? "Focus")
        case "/off":
            // An off for another Focus than the one shown (two automations racing) changes nothing.
            if let name, let current, name.caseInsensitiveCompare(current) != .orderedSame { break }
            set(nil)
        default:
            appendAppLog("nb.log", "[Focus] unknown link \(url.absoluteString)")
        }
        return true
    }

    func set(_ name: String?) {
        guard name != current else { return }
        let was = current
        current = name
        appendAppLog("nb.log", "[Focus] \(name.map { "\($0) on" } ?? "\(was ?? "Focus") off")")
        // Said once, past the quiet rule: it is the peek that explains the quiet.
        if let name {
            NotchPeek.shared.show(icon: Self.symbol(for: name), text: "\(name) Focus on", tint: Self.tint, force: true)
        } else if let was {
            NotchPeek.shared.show(icon: Self.symbol(for: was), text: "\(was) Focus off", tint: Color(hex: "#8E939C"), force: true)
        }
    }

    /// macOS's own symbols for its Focuses; any other name gets the moon.
    static func symbol(for name: String) -> String {
        switch name.lowercased() {
        case "work": "briefcase.fill"
        case "personal": "person.fill"
        case "sleep": "bed.double.fill"
        case "reading": "book.fill"
        case "fitness": "figure.run"
        case "gaming": "gamecontroller.fill"
        case "driving": "car.fill"
        case "mindfulness": "brain.head.profile"
        default: "moon.fill"
        }
    }

    /// The two links an automation opens for a Focus.
    static func links(for name: String) -> (on: String, off: String) {
        let q = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        return ("coucou://focus/on?name=\(q)", "coucou://focus/off?name=\(q)")
    }
}
#endif

#if !APPSTORE
/// Settings → Routines → Focus → Mac Focus: the automations to add, with their links to copy.
struct BuddyMacFocusCard: View {
    @ObservedObject private var focus = MacFocus.shared
    @State private var name = "Work"
    @State private var copied: String?

    var body: some View {
        let links = MacFocus.links(for: name.trimmingCharacters(in: .whitespaces).isEmpty ? "Work" : name.trimmingCharacters(in: .whitespaces))
        HubCard {
            HubRow(title: "Now", detail: "As your automations last told Coucou.") {
                HStack(spacing: 6) {
                    if let c = focus.current {
                        Image(systemName: MacFocus.symbol(for: c)).foregroundColor(MacFocus.tint)
                        Text("\(c) Focus on").font(.system(size: 13, weight: .semibold))
                    } else {
                        Text("No Focus").font(.system(size: 13)).foregroundColor(HubTheme.secondary)
                    }
                }
            }
            HubDivider()
            HubRow(title: "Tell Coucou from Shortcuts",
                   detail: "Shortcuts → Automation → New Automation → Focus → pick the Focus, When Turning On, Run Immediately → add Open URLs with the first link. Then one more for When Turning Off with the second. Once per Focus.") {
                Button("Open Shortcuts") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app"))
                }
                .buttonStyle(HubButtonStyle())
            }
            HubDivider()
            HubRow(title: "Focus name", detail: "As macOS names it: the peek and the symbol by Mochi use it.") {
                HubField(placeholder: "Work", text: $name, onSubmit: {}).frame(width: 180)
            }
            linkRow("When turning on", links.on)
            linkRow("When turning off", links.off)
            HubDivider()
            HubRow(title: "Quiet the notch", detail: "While a Focus is on, peeks (charger, network, sound, Caps Lock, devices) wait; a key's level and the Focus's own peek still show.") {
                Toggle("", isOn: $focus.quiet).toggleStyle(.switch).labelsHidden()
            }
        }
    }

    private func linkRow(_ title: String, _ link: String) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12)).foregroundColor(HubTheme.secondary).frame(width: 120, alignment: .leading)
            Text(link).font(.system(size: 12, design: .monospaced)).foregroundColor(HubTheme.body).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button(copied == link ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
                copied = link
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == link { copied = nil } }
            }
            .buttonStyle(HubButtonStyle())
            Button("Try") { if let url = URL(string: link) { _ = MacFocus.shared.handle(url) } }
                .buttonStyle(HubButtonStyle())
                .help("What Coucou does when the automation opens this link")
        }
        .padding(.vertical, 6)
    }
}
#endif
