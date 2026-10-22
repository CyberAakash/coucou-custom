#if !APPSTORE
import Foundation
import Combine

// coucou-custom fork: the Buddy pets on this Mac. Coucou's own folder (pets imported in Settings
// → Buddy) plus the folders OpenPets and Codex read, so a pet installed there shows up here too.
// Foundation only, so `scripts/test-buddy.sh` builds it.

struct BuddyPetEntry: Identifiable, Equatable {
    enum Source: String { case coucou, codex, openPets }
    let manifest: BuddyPetManifest
    let folder: URL
    let source: Source

    var id: String { manifest.id }
    var spritesheetURL: URL { folder.appendingPathComponent(manifest.spritesheetPath) }
    /// Only pets Coucou installed can be removed from Coucou.
    var removable: Bool { source == .coucou }

    var sourceLabel: String {
        switch source {
        case .coucou: return "Imported"
        case .codex: return "~/.codex/pets"
        case .openPets: return "OpenPets"
        }
    }
}

@MainActor
final class BuddyPetStore: ObservableObject {
    static let shared = BuddyPetStore(
        installDir: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchBuddy/Pets", isDirectory: true),
        searchDirs: BuddyPetStore.externalDirs(home: FileManager.default.homeDirectoryForCurrentUser))

    /// Where imports go. Searched first, so an imported pet wins over one with the same id elsewhere.
    let installDir: URL
    let searchDirs: [(URL, BuddyPetEntry.Source)]

    @Published private(set) var pets: [BuddyPetEntry] = []
    /// Folders that hold something unreadable, with why, for Settings.
    @Published private(set) var skipped: [(name: String, reason: String)] = []

    init(installDir: URL, searchDirs: [(URL, BuddyPetEntry.Source)]) {
        self.installDir = installDir
        self.searchDirs = searchDirs
        refresh()
    }

    /// The folders OpenPets (native build, alterhq/openpets README) and Codex scan.
    nonisolated static func externalDirs(home: URL) -> [(URL, BuddyPetEntry.Source)] {
        [
            (home.appendingPathComponent(".codex/pets"), .codex),
            (home.appendingPathComponent("Library/Application Support/OpenPets/Pets"), .openPets),
            (home.appendingPathComponent(".local/share/openpets/pets"), .openPets),
            (home.appendingPathComponent(".config/openpets/pets"), .openPets),
        ]
    }

    func refresh() {
        var seen = Set<String>()
        var found: [BuddyPetEntry] = []
        var bad: [(String, String)] = []
        let fm = FileManager.default
        for (dir, source) in [(installDir, BuddyPetEntry.Source.coucou)] + searchDirs {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") {
                let folder = dir.appendingPathComponent(name, isDirectory: true)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { continue }
                do {
                    let m = try Self.readManifest(in: folder)
                    guard m.id == name else { throw ImportError.idMismatch(id: m.id, folder: name) }
                    guard fm.fileExists(atPath: folder.appendingPathComponent(m.spritesheetPath).path) else {
                        throw ImportError.missingFile(m.spritesheetPath)
                    }
                    guard seen.insert(m.id).inserted else { continue }
                    found.append(BuddyPetEntry(manifest: m, folder: folder, source: source))
                } catch {
                    bad.append((name, "\(error)"))
                }
            }
        }
        pets = found.sorted { $0.manifest.displayName.localizedCaseInsensitiveCompare($1.manifest.displayName) == .orderedAscending }
        skipped = bad
    }

    func pet(id: String) -> BuddyPetEntry? { pets.first { $0.id == id } }

    // MARK: - Import

    enum ImportError: Error, Equatable, CustomStringConvertible {
        case notAPet
        case missingFile(String)
        case idMismatch(id: String, folder: String)
        case alreadyInstalled(String)
        case zipTooLarge
        case unsafeZip(String)
        case unzipFailed

        var description: String {
            switch self {
            case .notAPet: return "No pet.json found (at the top or in one folder)."
            case .missingFile(let f): return "\(f) is missing."
            case let .idMismatch(id, folder): return "pet.json id \"\(id)\" does not match its folder \"\(folder)\"."
            case .alreadyInstalled(let id): return "A pet \"\(id)\" is already imported."
            case .zipTooLarge: return "The zip is larger than OpenPets' limits (50 MB, 200 MB unpacked)."
            case .unsafeZip(let e): return "The zip has an unsafe entry: \(e)"
            case .unzipFailed: return "The zip could not be opened."
            }
        }
    }

    /// OpenPets' package limits (pet-installation.ts).
    nonisolated static let maxZipBytes = 50 * 1024 * 1024
    nonisolated static let maxUnpackedBytes = 200 * 1024 * 1024

    nonisolated static func readManifest(in folder: URL) throws -> BuddyPetManifest {
        let url = folder.appendingPathComponent("pet.json")
        guard let data = try? Data(contentsOf: url) else { throw ImportError.missingFile("pet.json") }
        return try BuddyPetManifest.parse(data)
    }

    /// The package's folder: `pet.json` at the top, or inside its only folder (a zipped folder).
    nonisolated static func packageRoot(in dir: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent("pet.json").path) { return dir }
        let subs = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        guard subs.count == 1, fm.fileExists(atPath: subs[0].appendingPathComponent("pet.json").path) else { return nil }
        return subs[0]
    }

    /// A zip entry is safe when it stays inside the folder it is unpacked to.
    nonisolated static func isSafeZipEntry(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("\\"), !path.contains("\0") else { return false }
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return !parts.contains("..") && !(parts.first?.contains(":") ?? false)
    }

    /// Checks a folder or a .zip is a pet, decodes its atlas, then copies only `pet.json` and its
    /// spritesheet into Coucou's folder. Nothing else from the package is kept.
    @discardableResult
    func importPackage(at url: URL, replace: Bool = false) throws -> BuddyPetEntry {
        let fm = FileManager.default
        var tempDir: URL?
        defer { if let t = tempDir { try? fm.removeItem(at: t) } }

        var source = url
        if url.pathExtension.lowercased() == "zip" {
            let t = fm.temporaryDirectory.appendingPathComponent("coucou-buddy-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: t, withIntermediateDirectories: true)
            tempDir = t
            try Self.unzip(url, into: t)
            source = t
        }
        guard let root = Self.packageRoot(in: source) else { throw ImportError.notAPet }
        let manifest = try Self.readManifest(in: root)
        let sheet = root.appendingPathComponent(manifest.spritesheetPath)
        guard fm.fileExists(atPath: sheet.path) else { throw ImportError.missingFile(manifest.spritesheetPath) }
        _ = try BuddyAtlas.load(url: sheet, layout: manifest.layout)

        let dest = installDir.appendingPathComponent(manifest.id, isDirectory: true)
        if fm.fileExists(atPath: dest.path) {
            guard replace else { throw ImportError.alreadyInstalled(manifest.id) }
            try fm.removeItem(at: dest)
        }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try fm.copyItem(at: root.appendingPathComponent("pet.json"), to: dest.appendingPathComponent("pet.json"))
        try fm.copyItem(at: sheet, to: dest.appendingPathComponent(manifest.spritesheetPath))
        refresh()
        return pet(id: manifest.id) ?? BuddyPetEntry(manifest: manifest, folder: dest, source: .coucou)
    }

    /// Removes an imported pet (never one in another app's folder).
    func remove(id: String) throws {
        guard let p = pet(id: id), p.removable else { return }
        try FileManager.default.removeItem(at: p.folder)
        refresh()
    }

    /// Lists the entries with `zipinfo` first: refuses absolute or `..` paths and an archive
    /// that unpacks beyond the limit, then unpacks with `ditto`.
    nonisolated static func unzip(_ zip: URL, into dir: URL) throws {
        let size = (try? zip.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxZipBytes else { throw ImportError.zipTooLarge }

        // zipinfo -l: one line per entry, the uncompressed size is the 4th column, name the last.
        guard let listing = run("/usr/bin/zipinfo", ["-1", zip.path]), let sizes = run("/usr/bin/zipinfo", ["-l", zip.path])
        else { throw ImportError.unzipFailed }
        for entry in listing.split(separator: "\n").map(String.init) where !entry.isEmpty {
            guard isSafeZipEntry(entry) else { throw ImportError.unsafeZip(entry) }
        }
        var total = 0
        for line in sizes.split(separator: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            // Entry lines start with a permission string such as "-rw-r--r--" or "drwxr-xr-x".
            guard cols.count >= 9, let first = cols.first, first.count == 10,
                  first.first == "-" || first.first == "d" || first.first == "l",
                  let n = Int(cols[3]) else { continue }
            if first.first == "l" { throw ImportError.unsafeZip(String(cols.last ?? "")) }
            total += n
        }
        guard total <= maxUnpackedBytes else { throw ImportError.zipTooLarge }
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path]) != nil else { throw ImportError.unzipFailed }
    }

    /// stdout of a tool, or nil when it fails.
    nonisolated private static func run(_ tool: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
