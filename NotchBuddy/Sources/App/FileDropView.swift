import AppKit
import SwiftUI

// MARK: - NSView drag destination
// Wired at the AppKit level in IslandWindowController (not via SwiftUI NSViewRepresentable)
// so it never interferes with SwiftUI hit-testing.

final class FileDropNSView: NSView {
    var onDragEntered: ((CGPoint) -> Void)?
    var onDragUpdated: ((CGPoint) -> Void)?
    var onDragExited:  (() -> Void)?
    var onFilesDropped: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    // Pass all mouse events through — drag-drop uses NSDraggingDestination, not hitTest
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEntered?(sender.draggingLocation)
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragUpdated?(sender.draggingLocation)
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { onDragExited?() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else { return false }
        onFilesDropped?(urls)
        return true
    }
}

// MARK: - File drop handler

enum FileDropHandler {
    /// Removes inbox files older than 7 days, as on Windows/Linux. Hidden files too:
    /// a dropped `.env` is exactly the kind of copy that must not stay forever.
    static func sweepInbox(inbox: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) else { return }
        let keepFor: TimeInterval = 7 * 24 * 60 * 60
        let now = Date()
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate else { continue }
            if now.timeIntervalSince(modified) > keepFor {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    /// coucou-custom fork: each drop gets a number; a later drop makes the earlier handler's
    /// remaining steps (its ticks, its "done", its final view) stand down, so a second drop
    /// within a few seconds of the first keeps its canvas and Mochi's follow.
    @MainActor private static var generation = 0

    /// coucou-custom fork: the progress bar runs for about as long as the copy will take
    /// (120 MB/s on the SSD), between 0.4 s so the gulp reads and 1.5 s so nothing waits on
    /// a huge file. Folders and unknown sizes take the middle.
    static func progressDuration(for url: URL) -> Double {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true { return 0.8 }
        guard let bytes = values?.fileSize else { return 0.8 }
        return min(1.5, max(0.4, Double(bytes) / 120_000_000))
    }

    @MainActor
    static func handle(urls: [URL], state: AppState) async {
        guard let url = urls.first else { return }
        let name = url.lastPathComponent
        generation += 1
        let gen = generation

        #if !APPSTORE
        // coucou-custom fork: with the shelf on, every dropped file lands there (all of them,
        // not the first alone) and the shelf shows the newest, selected: Ask Claude, Email and
        // Open take over from upstream's "choose" step. While a permission or a question
        // waits, or a Finished/Error card is up, the file lands quietly and the tray tab fills.
        let landsOnShelf = FileShelf.enabled
        if landsOnShelf {
            FileShelf.shared.add(urls)
            if FileShelf.dropsQuietly(state) {
                state.fileDragOver = false
                UploadSequenceEngine.shared.deactivate()
                NotificationCenter.default.post(name: .botMorphTo, object: CGFloat(0))
                appendAppLog("nb.log", "[Shelf] landed quietly (\(state.view.rawValue) is up)")
                SoundEngine.shared.play("tick")
                return
            }
            // Otherwise the upload canvas plays through (gulp, progress, Mochi back) and the
            // sequence below ends on the shelf instead of the "choose" step.
        }
        #else
        let landsOnShelf = false
        #endif

        // Start animation immediately — do NOT block on file copy.
        // Use original URL first; swap to inbox copy once background copy finishes.
        state.droppedFile = DroppedFile(url: url, name: name)
        state.uploadProgress = 0
        state.fileDragOver = false
        state.promptContext = .file(name: name, fileURL: url)

        let dur = progressDuration(for: url)
        UploadSequenceEngine.shared.performDrop(uploadDuration: dur)

        // Copy to inbox in background — update state when done
        let inbox = HookServer.supportDir.appendingPathComponent("inbox")
        Task.detached {
            try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            let fm = FileManager.default
            let first = inbox.appendingPathComponent(name)
            // A file that already lives in the inbox is used where it is.
            let alreadyInInbox = first.standardizedFileURL.path == url.standardizedFileURL.path
            var target: URL? = alreadyInInbox || !fm.fileExists(atPath: first.path) ? first : nil
            if target == nil {
                // Never overwrite an earlier drop: "notes (2).txt", "notes (3).txt"…
                let stem = url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
                for i in 2..<1000 {
                    let candidate = inbox.appendingPathComponent("\(stem) (\(i))\(ext)")
                    if !fm.fileExists(atPath: candidate.path) { target = candidate; break }
                }
            }
            var landed: URL? = nil
            if let target, alreadyInInbox || (try? fm.copyItem(at: url, to: target)) != nil {
                // The copy ages from when it landed in the inbox, not from the original's
                // date — stamped before the sweep, or an old file would go at once.
                try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
                landed = target
            }
            Self.sweepInbox(inbox: inbox)
            // Copy failed: the drop keeps pointing at the original file, as before.
            guard let dest = landed else { return }
            await MainActor.run {
                state.droppedFile = DroppedFile(url: dest, name: name)
                state.promptContext = .file(name: name, fileURL: dest)
            }
        }

        // Drop feedback
        NotificationCenter.default.post(name: .botGulp, object: nil)
        SoundEngine.shared.play("approve")
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
        NotificationCenter.default.post(name: .botMorphTo, object: CGFloat(0))

        state.uploadDuration = dur
        state.uploadStartTime = Date()
        state.view = .uploading  // canvas stays active: uploadActive covers .uploading

        // Canvas timeline from drop:
        //   T_DROP → T_PROG_START : ≈1.30s  gulp + shrink + bar reveal
        //   T_PROG_START → progEnd: dur      progress bar fills
        //   progEnd → growEnd     : 0.70s    Mochi grows back to choose position
        let preProgress = USC.T_PROG_START - USC.T_DROP  // ≈1.30s

        // Tick sounds — delayed to sync with canvas progress start
        Task { @MainActor in
            var lastTens = 0
            let progStart = Date().addingTimeInterval(preProgress)
            while lastTens < 9 {
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard gen == generation else { return }
                let approxP = min(1.0, max(0, Date().timeIntervalSince(progStart) / dur))
                let tens = Int(approxP * 10)
                if tens > lastTens {
                    SoundEngine.shared.play("tick")
                    lastTens = tens
                }
            }
        }

        // Wait for canvas progress to complete (gulp/shrink phase + upload duration)
        try? await Task.sleep(nanoseconds: UInt64((preProgress + dur) * 1_000_000_000))
        guard gen == generation else { return }   // a newer drop took over

        // Canvas shows checkmark at this point
        SoundEngine.shared.play("approve")
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)

        // Wait for grow-back animation + choose overlay settle
        try? await Task.sleep(nanoseconds: UInt64(1_000_000_000))
        guard gen == generation else { return }

        // Clean up upload state
        state.uploadProgress = 0
        state.uploadStartTime = nil

        #if !APPSTORE
        if landsOnShelf {
            // coucou-custom fork: the file is on the shelf; its actions wait there. The chat
            // context set above for the choose step is not wanted until Ask Claude is chosen.
            state.promptContext = nil
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.view = .shelf }
            return
        }
        #endif
        // Switch to choose — canvas stays active (uploadActive covers .choose).
        // Engine deactivates when user clicks a canvas choose button or navigates away.
        state.view = .choose
    }
}
