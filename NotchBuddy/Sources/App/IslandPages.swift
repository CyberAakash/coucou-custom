import AppKit
import SwiftUI

// MARK: - Page bar (coucou-custom fork)
//
// The open notch has pages (after Nusa's page bar): home, the chat, the shelf, the sessions.
// Dots along the bottom edge say which one is open; ← → and a sideways swipe (or the wheel
// on the home page, which has nothing to scroll) go to the next one.

enum IslandPages {
    /// Settings → General → "Page bar" (default on) and "Swipe or scroll between pages".
    static let enabledKey = "coucouPageBar"
    static let wheelKey = "coucouPageWheel"

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var wheelEnabled: Bool { UserDefaults.standard.object(forKey: wheelKey) as? Bool ?? true }

    /// The pages in order, as they can be reached right now.
    @MainActor
    static func pages(_ state: AppState) -> [IslandView] {
        var pages: [IslandView] = [.overview, .prompt]
        #if !APPSTORE
        if FileShelf.enabled { pages.append(.shelf) }
        if !LiveSessions.shared.sessions.isEmpty { pages.append(.sessions) }
        #endif
        return pages
    }

    /// The page a view belongs to (the empty home is the home page); nil for cards and alerts.
    static func page(of view: IslandView) -> IslandView? {
        switch view {
        case .overview, .empty: return .overview
        case .prompt, .shelf, .sessions: return view
        default: return nil
        }
    }

    @MainActor
    static func showsBar(_ state: AppState) -> Bool {
        enabled && state.mode == .expanded && page(of: state.view) != nil && pages(state).count > 1
    }

    /// The page `delta` steps away from the current one, wrapping around; nil when the current
    /// view is not a page.
    @MainActor
    static func step(_ delta: Int, from state: AppState) -> IslandView? {
        guard let current = page(of: state.view) else { return nil }
        let all = pages(state)
        guard all.count > 1, let i = all.firstIndex(of: current) else { return nil }
        return all[(i + delta + all.count) % all.count]
    }

    @MainActor
    static func go(to page: IslandView, state: AppState, how: String) {
        guard page != state.view else { return }
        appendAppLog("nb.log", "[Pages] \(state.view.rawValue) → \(page.rawValue) (\(how))")
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.view = page }
        state.lastActivity = .now
    }

    /// Bare ← → switch pages, unless a text field has the keyboard (the chat, a session's message box).
    @MainActor
    static func handleKey(_ event: NSEvent, state: AppState) -> Bool {
        guard enabled, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              event.keyCode == 123 || event.keyCode == 124,
              !(NSApp.keyWindow?.firstResponder is NSTextView),
              let next = step(event.keyCode == 124 ? 1 : -1, from: state) else { return false }
        go(to: next, state: state, how: event.keyCode == 124 ? "→" : "←")
        return true
    }
}

/// Turns scroll events into page steps: one step per gesture, after enough sideways travel.
/// The wheel (vertical) counts only on the home page, where nothing scrolls.
@MainActor
final class PageWheel {
    private var travel: CGFloat = 0
    private var stepped = false
    private static let threshold: CGFloat = 36

    /// True when the event was used for a page change (the caller swallows it).
    func handle(_ event: NSEvent, state: AppState) -> Bool {
        guard IslandPages.enabled, IslandPages.wheelEnabled, state.mode == .expanded,
              IslandPages.page(of: state.view) != nil else { return false }
        // A new gesture starts the count again; momentum after a step is ignored.
        if event.phase == .began { travel = 0; stepped = false }
        if event.phase == .ended || event.phase == .cancelled { travel = 0; stepped = false; return false }
        if event.momentumPhase != [] { return false }
        guard !stepped else { return true }
        var dx = event.scrollingDeltaX
        if abs(dx) < abs(event.scrollingDeltaY) {
            // Vertical: the wheel on the home page; elsewhere the content scrolls.
            guard state.view == .overview || state.view == .empty else { return false }
            dx = event.scrollingDeltaY
        }
        travel += dx
        guard abs(travel) >= Self.threshold, let next = IslandPages.step(travel < 0 ? 1 : -1, from: state) else {
            return false
        }
        stepped = event.hasPreciseScrollingDeltas   // a trackpad gesture steps once; wheel clicks step each
        travel = 0
        IslandPages.go(to: next, state: state, how: event.hasPreciseScrollingDeltas ? "swipe" : "wheel")
        return true
    }
}

/// The dots: the open page is a short bar, the others small circles. Click a dot to go there.
struct PageBar: View {
    @ObservedObject var state: AppState
    #if !APPSTORE
    @ObservedObject private var live = LiveSessions.shared
    @ObservedObject private var shelf = FileShelf.shared
    #endif

    var body: some View {
        let pages = IslandPages.pages(state)
        let current = IslandPages.page(of: state.view)
        HStack(spacing: 5) {
            ForEach(pages, id: \.self) { page in
                Capsule()
                    .fill(page == current ? Color(hex: "#F5F6F8") : Color.white.opacity(0.28))
                    .frame(width: page == current ? 14 : 5, height: 5)
                    .contentShape(Rectangle().inset(by: -4))
                    .onTapGesture { IslandPages.go(to: page, state: state, how: "dot") }
                    .help(Self.name(page))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: current)
    }

    static func name(_ page: IslandView) -> String {
        switch page {
        case .prompt: return String(localized: "Chat")
        case .shelf: return "Shelf"
        case .sessions: return "Sessions"
        default: return String(localized: "Home")
        }
    }
}
