import AppKit
import SwiftUI

// MARK: - Full screen and the clock (coucou-custom fork)
//
// Two things the resting notch can do (after Nusa): step aside while the front app runs
// full screen (a game, a film), and show the time on its right wing.

enum IslandFullScreen {
    /// Settings → General → "Hide in full screen" (default off).
    static let enabledKey = "coucouHideInFullScreen"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// True when the frontmost app (not Coucou) has a window covering the whole of `screen`:
    /// a full-screen Space, or a game drawing over the screen. Compared in CG coordinates
    /// (origin at the main display's top left), where a full-screen window is exactly the
    /// screen's frame.
    static func frontAppIsFullScreen(on screen: NSScreen?) -> Bool {
        guard let screen, let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier,
              front.activationPolicy == .regular,
              let main = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let frame = screen.frame
        let target = CGRect(x: frame.minX, y: main.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? Int32) == front.processIdentifier,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let b = window[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if abs(rect.minX - target.minX) <= 1, abs(rect.minY - target.minY) <= 1,
               rect.width >= target.width - 1, rect.height >= target.height - 1 {
                return true
            }
        }
        return false
    }
}

enum IslandClock {
    /// Settings → General → "Time in the notch" (default off) and "With seconds".
    static let enabledKey = "coucouNotchClock"
    static let secondsKey = "coucouNotchClockSeconds"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var seconds: Bool { UserDefaults.standard.bool(forKey: secondsKey) }

    /// The time as the Mac writes it (12 or 24 hours follow the system).
    static func text(_ date: Date, seconds: Bool) -> String {
        let style: Date.FormatStyle = seconds
            ? .init().hour(.defaultDigits(amPM: .abbreviated)).minute(.twoDigits).second(.twoDigits)
            : .init().hour(.defaultDigits(amPM: .abbreviated)).minute(.twoDigits)
        return date.formatted(style)
    }
}

/// The time on the resting notch's right wing, beside the mini Mochis when there are some.
struct CompactClock: View {
    @AppStorage(IslandClock.enabledKey) private var enabled = false
    @AppStorage(IslandClock.secondsKey) private var seconds = false

    var body: some View {
        if enabled {
            TimelineView(.periodic(from: .now, by: seconds ? 1 : 10)) { context in
                Text(IslandClock.text(context.date, seconds: seconds))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(Color(hex: "#E1E3E6"))
                    .lineLimit(1)
                    .fixedSize()
            }
            .transition(.opacity)
        }
    }
}
