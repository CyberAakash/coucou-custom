import AppKit
import SwiftUI

// MARK: - Page bar (coucou-custom fork)
//
// The open notch has pages (after Nusa's page bar): home, the chat, the shelf, the sessions.
// Dots along the bottom edge say which one is open; ← → and a sideways swipe (or the wheel
// on the home page, which has nothing to scroll) go to the next one.

/// The open notch's pages that can be moved and hidden (Settings → General → Pages); Home is
/// not one of them: the notch opens on it, so it is always first and always there.
enum NotchPage: String, CaseIterable, Identifiable, Codable {
    // Sessions last: it comes and goes with the agents, so the pages before it never move.
    case chat, shelf, clipboard, tasks, calendar, sessions
    var id: String { rawValue }

    var view: IslandView {
        switch self {
        case .chat: .prompt
        case .shelf: .shelf
        case .clipboard: .clipboard
        case .sessions: .sessions
        case .tasks: .tasks
        case .calendar: .calendar
        }
    }

    var title: String {
        switch self {
        case .chat: String(localized: "Chat")
        case .shelf: "Shelf"
        case .clipboard: "Clipboard"
        case .sessions: "Sessions"
        case .tasks: "Tasks"
        case .calendar: "Calendar"
        }
    }

    var symbol: String {
        switch self {
        case .chat: "bubble.left.fill"
        case .shelf: "tray.full.fill"
        case .clipboard: "list.clipboard.fill"
        case .sessions: "rectangle.stack.fill"
        case .tasks: "checklist"
        case .calendar: "calendar"
        }
    }

    var detail: String {
        switch self {
        case .chat: "Ask Claude about what is on screen."
        case .shelf: "Files dropped on the notch. Hidden, the + tab takes its place for uploads."
        case .clipboard: "What you copied. Hiding the page keeps recording; turn recording off on the Clipboard page."
        case .sessions: "Every agent session; shows only while one is running."
        case .tasks: "Your Reminders: add with a day, a time and #list, tick them off."
        case .calendar: "Your day and week from the Mac's calendars, with Join on meetings."
        }
    }
}

/// The pages' order and which are hidden, kept in UserDefaults and published so the header tabs,
/// the page dots and the settings list follow at once.
@MainActor
final class PageArrangement: ObservableObject {
    static let shared = PageArrangement()
    static let orderKey = "coucouPageOrder"
    static let hiddenKey = "coucouPagesHidden"

    @Published var order: [NotchPage] { didSet { UserDefaults.standard.set(order.map(\.rawValue), forKey: Self.orderKey) } }
    @Published var hidden: Set<NotchPage> { didSet { UserDefaults.standard.set(hidden.map(\.rawValue).sorted(), forKey: Self.hiddenKey) } }

    private init() {
        let stored = (UserDefaults.standard.stringArray(forKey: Self.orderKey) ?? []).compactMap(NotchPage.init(rawValue:))
        // A page added in a later version, or an order never set, lands in the default place at the end.
        var seen = Set<NotchPage>()
        order = stored.filter { seen.insert($0).inserted } + NotchPage.allCases.filter { !stored.contains($0) }
        hidden = Set((UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? []).compactMap(NotchPage.init(rawValue:)))
    }

    func isShown(_ page: NotchPage) -> Bool { !hidden.contains(page) }

    func set(_ page: NotchPage, shown: Bool) {
        if shown { hidden.remove(page) } else { hidden.insert(page) }
    }

    func reset() {
        order = NotchPage.allCases
        hidden = []
    }
}

enum IslandPages {
    /// Settings → General → "Page bar" (default on) and "Swipe or scroll between pages".
    static let enabledKey = "coucouPageBar"
    static let wheelKey = "coucouPageWheel"

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var wheelEnabled: Bool { UserDefaults.standard.object(forKey: wheelKey) as? Bool ?? true }

    /// The pages in order, as they can be reached right now.
    @MainActor
    static func pages(_ state: AppState) -> [IslandView] {
        let arrangement = PageArrangement.shared
        return [.overview] + arrangement.order.filter { arrangement.isShown($0) && available($0) }.map(\.view)
    }

    /// Whether a page can be reached at all right now, whatever the arrangement says.
    @MainActor
    static func available(_ page: NotchPage) -> Bool {
        switch page {
        case .chat: return true
        #if !APPSTORE
        case .shelf: return FileShelf.enabled
        case .clipboard: return ClipboardSettings.shared.enabled
        case .sessions: return !LiveSessions.shared.sessions.isEmpty
        case .tasks: return TasksSettings.shared.enabled
        case .calendar: return CalendarSettings.shared.enabled
        #else
        case .shelf, .clipboard, .sessions, .tasks, .calendar: return false
        #endif
        }
    }

    /// The page a view belongs to (the empty home is the home page); nil for cards and alerts.
    static func page(of view: IslandView) -> IslandView? {
        switch view {
        case .overview, .empty: return .overview
        case .prompt, .shelf, .clipboard, .sessions, .tasks, .calendar: return view
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

/// Page steps from the trackpad and the mouse (coucou-custom fork): a three-finger swipe turns the
/// page anywhere (macOS sends it when System Settings → Trackpad → More Gestures → Swipe between
/// pages uses three fingers); a two-finger scroll never does, it scrolls what is under it (the
/// shelf's and clipboard's carousels, lists); a mouse wheel turns it on the home page only.
@MainActor
final class PageWheel {
    /// True when the event was used for a page change (the caller swallows it).
    func handle(_ event: NSEvent, state: AppState) -> Bool {
        guard IslandPages.enabled, IslandPages.wheelEnabled, state.mode == .expanded,
              IslandPages.page(of: state.view) != nil else { return false }
        // A trackpad's scroll (precise deltas) is the content's.
        guard !event.hasPreciseScrollingDeltas,
              state.view == .overview || state.view == .empty,
              abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), event.scrollingDeltaY != 0,
              let next = IslandPages.step(event.scrollingDeltaY < 0 ? 1 : -1, from: state) else { return false }
        IslandPages.go(to: next, state: state, how: "wheel")
        return true
    }

    /// A three-finger swipe: fingers to the left go to the next page, to the right to the previous
    /// one (deltaX is +1 for a swipe to the left).
    func handleSwipe(_ event: NSEvent, state: AppState, from: String) -> Bool {
        // The gesture's in-between frames carry no direction: only the ones that do are noted.
        if event.deltaX != 0 {
            appendAppLog("nb.log", "[Pages] three-finger swipe from \(from): deltaX \(event.deltaX), \(state.mode.rawValue) \(state.view.rawValue)")
        }
        guard IslandPages.enabled, IslandPages.wheelEnabled, state.mode == .expanded,
              IslandPages.page(of: state.view) != nil, event.deltaX != 0 else { return false }
        guard let next = IslandPages.step(event.deltaX > 0 ? 1 : -1, from: state) else { return false }
        IslandPages.go(to: next, state: state, how: "swipe")
        return true
    }
}

/// The dots: the open page is a short bar, the others small circles. Click a dot to go there.
struct PageBar: View {
    @ObservedObject var state: AppState
    @ObservedObject private var arrangement = PageArrangement.shared
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
        case .clipboard: return "Clipboard"
        case .sessions: return "Sessions"
        case .tasks: return "Tasks"
        case .calendar: return "Calendar"
        default: return String(localized: "Home")
        }
    }
}
