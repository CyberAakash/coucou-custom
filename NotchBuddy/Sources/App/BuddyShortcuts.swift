#if !APPSTORE
import AppKit

// coucou-custom fork: the Buddy's "your own" click actions — run one of your Shortcuts (Apple's
// `shortcuts` command, /usr/bin/shortcuts, macOS 12+), or open an app, a file or a link. Only ever
// what you set in Settings → Buddy, on your click.

enum BuddyShortcuts {
    static let tool = URL(fileURLWithPath: "/usr/bin/shortcuts")

    /// Runs a Shortcut by name, in the background; its output is not used.
    static func run(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, FileManager.default.isExecutableFile(atPath: tool.path) else { return }
        let p = Process()
        p.executableURL = tool
        p.arguments = ["run", n]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            appendAppLog("buddy.log", "shortcut \(escapedForLog(n)) failed to start: \(escapedForLog("\(error)"))")
        }
    }

    /// Your Shortcuts' names (`shortcuts list`), for the picker; empty if there are none.
    static func list() async -> [String] {
        await Task.detached(priority: .utility) { () -> [String] in
            guard FileManager.default.isExecutableFile(atPath: tool.path) else { return [] }
            let p = Process()
            p.executableURL = tool
            p.arguments = ["list"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return [] }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
                .split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }.value
    }

    /// A link ("https://…", "mailto:…", any scheme) or a path to an app or a file.
    static func target(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("/") || t.hasPrefix("~") {
            let path = (t as NSString).expandingTildeInPath
            return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        guard let u = URL(string: t), let scheme = u.scheme, !scheme.isEmpty else { return nil }
        return u
    }

    static func open(_ text: String) {
        guard let url = target(text) else { return }
        NSWorkspace.shared.open(url)
    }
}
#endif
