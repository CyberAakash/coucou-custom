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

    // MARK: Turning a Focus on from Coucou (part 2)
    //
    // macOS lets only Shortcuts change a Focus. Each Focus here names two of the person's own
    // shortcuts (one "Set Focus … On" action, one "… Off"), run with `shortcuts run`.

    struct Entry: Codable, Equatable, Identifiable {
        var name: String
        var on: String = ""
        var off: String = ""
        /// Stable while the name is typed.
        var id = UUID().uuidString
    }

    @Published var entries: [Entry] = (UserDefaults.standard.data(forKey: "coucouFocusEntries")
        .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) }) ?? [Entry(name: "Work")] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: "coucouFocusEntries") }
    }
    /// The person's shortcuts, for the On and Off dropdowns.
    @Published private(set) var shortcuts: [String] = []
    @Published private(set) var running: String?

    /// Focuses that can be turned on from Coucou.
    var ready: [Entry] { entries.filter { !$0.on.isEmpty } }

    func loadShortcuts() {
        Task.detached(priority: .utility) {
            let names = Self.runShortcutsTool(["list"]).output
                .split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            await MainActor.run { MacFocus.shared.shortcuts = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } }
        }
    }

    /// Runs the Focus's On shortcut, or the current one's Off; the automations then confirm, and
    /// when there are none Coucou takes the shortcut's success as the answer.
    func turn(_ entry: Entry?, on: Bool) {
        let target = on ? entry : (entry ?? entries.first { $0.name.caseInsensitiveCompare(current ?? "") == .orderedSame })
        guard let target, running == nil else { return }
        let shortcut = on ? target.on : target.off
        guard !shortcut.isEmpty else {
            appendAppLog("nb.log", "[Focus] \(target.name): no \(on ? "On" : "Off") shortcut set")
            return
        }
        running = target.name
        Task.detached(priority: .userInitiated) {
            let result = Self.runShortcutsTool(["run", shortcut])
            await MainActor.run {
                let me = MacFocus.shared
                me.running = nil
                appendAppLog("nb.log", "[Focus] ran \"\(shortcut)\": \(result.ok ? "done" : "failed \(result.output.prefix(120))")")
                if result.ok { me.set(on ? target.name : nil) }
            }
        }
    }

    nonisolated private static func runShortcutsTool(_ args: [String]) -> (ok: Bool, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (false, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
    }

    /// The two links an automation opens for a Focus.
    static func links(for name: String) -> (on: String, off: String) {
        let q = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        return ("coucou://focus/on?name=\(q)", "coucou://focus/off?name=\(q)")
    }
}
#endif

#if !APPSTORE
/// The Controls page's Focus tile: the Focus that is on, and a list to turn one on or off or to
/// start a focus session.
struct ControlsFocusTile: View {
    var opener: Int = 0
    @ObservedObject private var focus = MacFocus.shared
    @ObservedObject private var routines = BuddyRoutineController.shared
    @State private var open = false

    var body: some View {
        let on = focus.current != nil
        Button { open.toggle() } label: {
            VStack(spacing: 4) {
                if focus.running != nil {
                    ProgressView().controlSize(.small).frame(height: 15)
                } else {
                    Image(systemName: focus.current.map(MacFocus.symbol) ?? "moon").font(.system(size: 13, weight: .semibold))
                }
                Text(focus.current ?? "Focus").font(.system(size: 10, weight: .semibold)).lineLimit(1)
            }
            .foregroundColor(on ? Color(hex: "#A5B4FC") : Color(hex: "#C5C8CD"))
            .frame(maxWidth: .infinity).frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(on ? MacFocus.tint.opacity(0.16) : Color.white.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointer().help(on ? "\(focus.current ?? "") Focus is on" : "Turn a Focus on")
        .onChange(of: opener) { _, _ in open = true }
        .popover(isPresented: $open, arrowEdge: .bottom) { list }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            if focus.ready.isEmpty {
                row("gearshape", "Set up in Settings → Routines → Focus", on: false) {
                    FlowHubController.shared.show(.routines)
                }
            }
            ForEach(focus.ready) { e in
                let isOn = focus.current?.caseInsensitiveCompare(e.name) == .orderedSame
                row(MacFocus.symbol(for: e.name), e.name, on: isOn) { if !isOn { focus.turn(e, on: true) } }
            }
            if focus.current != nil {
                row("minus.circle", "Turn off", on: false) { focus.turn(nil, on: false) }
            }
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 6)
            HStack(spacing: 8) {
                Text(routines.focus != nil ? "A focus session is running" : "Focus session · \(BuddyRoutineSettings.shared.focusPlan.focus) min")
                    .font(.system(size: 12)).foregroundColor(Color(hex: "#C5C8CD"))
                Spacer(minLength: 8)
                Button("Start") { routines.startFocus(); open = false }
                    .buttonStyle(.plain).pointer()
                    .font(.system(size: 11.5, weight: .semibold)).foregroundColor(Color(hex: "#0B0C0E"))
                    .padding(.horizontal, 12).frame(height: 26).background(Capsule().fill(MacFocus.tint))
                    .disabled(routines.focus != nil).opacity(routines.focus != nil ? 0.4 : 1)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .padding(6)
        .frame(width: 270)
    }

    private func row(_ symbol: String, _ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button { action(); open = false } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                    .foregroundColor(on ? Color(hex: "#A5B4FC") : Color(hex: "#8E939C")).frame(width: 18)
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 6)
                if on { Text("on").font(.system(size: 11)).foregroundColor(Color(hex: "#A5B4FC")) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? MacFocus.tint.opacity(0.16) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointer()
    }
}

/// Settings → Routines → Focus → Mac Focus: each Focus with the two links its automations open
/// (how Coucou hears of it) and the two shortcuts Coucou runs (how it turns it on and off).
struct BuddyMacFocusCard: View {
    @ObservedObject private var focus = MacFocus.shared
    @State private var copied: String?

    var body: some View {
        HubCard {
            HubRow(title: "Now", detail: "As your automations, or Coucou's own shortcuts, last told it.") {
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
            HubRow(title: "How it works",
                   detail: "Hearing a Focus: Shortcuts → Automation → New Automation → Focus → the Focus, When Turning On, Run Immediately → Open URLs with its on link; one more When Turning Off with its off link. Turning one on from the notch: a shortcut with Set Focus → On, and one with Off.") {
                HStack(spacing: 8) {
                    Button("New shortcut") { NSWorkspace.shared.open(URL(string: "shortcuts://create-shortcut")!) }
                        .buttonStyle(HubButtonStyle())
                    Button("Open Shortcuts") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app")) }
                        .buttonStyle(HubButtonStyle())
                }
            }
            ForEach($focus.entries) { $entry in
                HubDivider()
                entryBlock($entry)
            }
            HubDivider()
            HStack {
                Button("Add a Focus") { focus.entries.append(MacFocus.Entry(name: nextName)) }
                    .buttonStyle(HubButtonStyle())
                Spacer()
                Button("Reload shortcuts") { focus.loadShortcuts() }.buttonStyle(HubButtonStyle())
            }
            .padding(.vertical, 8)
            HubDivider()
            HubRow(title: "Quiet the notch", detail: "While a Focus is on, peeks (charger, network, sound, Caps Lock, devices) wait; a key's level and the Focus's own peek still show.") {
                Toggle("", isOn: $focus.quiet).toggleStyle(.switch).labelsHidden()
            }
        }
        .onAppear { focus.loadShortcuts() }
    }

    private var nextName: String {
        ["Personal", "Do Not Disturb", "Sleep", "Reading"].first { n in !focus.entries.contains { $0.name == n } } ?? "Focus \(focus.entries.count + 1)"
    }

    private func entryBlock(_ entry: Binding<MacFocus.Entry>) -> some View {
        let name = entry.wrappedValue.name.trimmingCharacters(in: .whitespaces)
        let links = MacFocus.links(for: name.isEmpty ? "Focus" : name)
        let choices = [("", "Choose a shortcut")] + focus.shortcuts.map { ($0, $0) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: MacFocus.symbol(for: name)).foregroundColor(MacFocus.tint).frame(width: 18)
                HubField(placeholder: "Focus name, as macOS names it", text: entry.name).frame(width: 220)
                Spacer()
                Button {
                    focus.entries.removeAll { $0.id == entry.wrappedValue.id }
                } label: { Image(systemName: "trash") }
                .buttonStyle(HubButtonStyle()).help("Remove this Focus from Coucou")
            }
            HStack(spacing: 10) {
                Text("Turn on with").font(.system(size: 12)).foregroundColor(HubTheme.secondary).frame(width: 120, alignment: .leading)
                HubDropdown(entry.on, choices, tint: MacFocus.tint)
                Spacer(minLength: 8)
                Text("Turn off with").font(.system(size: 12)).foregroundColor(HubTheme.secondary)
                HubDropdown(entry.off, choices, tint: MacFocus.tint)
            }
            linkRow("Link when on", links.on)
            linkRow("Link when off", links.off)
        }
        .padding(.vertical, 8)
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
    }
}
#endif
