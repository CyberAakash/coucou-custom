#if !APPSTORE && DEBUG
import AppKit
import SwiftUI

// MARK: - Debug: render the Keep pages to PNG (coucou-custom fork)
//
// `fr.louisraille.NotchBuddy.debug.snapshot` (object: "shelf", "clipboard", or empty for both)
// renders the notch page (the window's pages: `debug.hubSnapshot`, HubSnapshot.swift) in an off-screen window at 2× and writes
// `~/Library/Caches/NotchBuddy/snap-<name>.png`, so the look can be checked from a terminal
// without a screen. Thumbnails and Quick Look need a moment: the picture is taken after 2.5 s.

enum KeepSnapshots {
    static func install() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("fr.louisraille.NotchBuddy.debug.snapshot"), object: nil, queue: .main
        ) { note in
            let which = (note.object as? String ?? "").trimmingCharacters(in: .whitespaces)
            MainActor.assumeIsolated {
                // "shelf", "clipboard", "shelf:carousel", "shelf:filter", "clipboard:grid"…, or empty for both.
                let names = which.isEmpty ? ["shelf", "clipboard"] : [which]
                for (i, name) in names.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 3.2) { snapshot(name) }
                }
            }
        }
    }

    @MainActor
    private static func snapshot(_ spec: String) {
        let state = AppState.shared
        let parts = spec.split(separator: ":").map(String.init)
        let name = parts[0]
        let options = Set(parts.dropFirst())
        // Options change a setting for the picture and put it back after.
        let shelfLayout = ShelfSettings.shared.layout, clipLayout = ClipboardSettings.shared.layout
        if options.contains("carousel") { ShelfSettings.shared.layout = .carousel; ClipboardSettings.shared.layout = .carousel }
        if options.contains("grid") { ShelfSettings.shared.layout = .grid; ClipboardSettings.shared.layout = .grid }
        if options.contains("rows") { ShelfSettings.shared.layout = .rows; ClipboardSettings.shared.layout = .rows }
        KeepDebug.filterOpen = options.contains("filter")
        KeepDebug.forceHover = options.contains("hover")
        KeepDebug.selectFirstThree = options.contains("multi")
        if options.contains("multi") && parts[0] == "shelf" { FileShelf.shared.selected = Set(FileShelf.shared.items.prefix(3).map(\.id)) }
        let restore = { ShelfSettings.shared.layout = shelfLayout; ClipboardSettings.shared.layout = clipLayout }
        let view: AnyView
        let size: CGSize
        switch name {
        case "shelf":
            let h = KeepPanels.islandHeight(.shelf, layout: ShelfSettings.shared.layout) + (KeepDebug.filterOpen ? KeepPanels.filterRow : 0)
            size = CGSize(width: 640, height: h)
            view = AnyView(islandFrame(height: h) { ShelfView(state: state) })
        case "agenda":
            // agenda[:sample][:typing|:event|:hint|:slash|:hash|:when|:group|:help][:tasks]: sample data, a line being typed, a menu or the help open, the Tasks filter.
            if options.contains("sample") { TasksStore.shared.debugFill(); CalendarStore.shared.debugFill() }
            KeepDebug.tasksComposerText = options.contains("typing") ? "Call the bank tomorrow 6pm #personal"
                : (options.contains("event") ? "/e Lunch with Rita tomorrow 1pm for 45 min"
                : (options.contains("hint") ? "Review the PR today 5pm for 30 min"
                : (options.contains("slash") ? "Call mom /"
                : (options.contains("hash") ? "Send the build tomorrow 6pm #wo"
                : (options.contains("edetails") ? "/e Standup 9:30 for 15m every 2 weeks on mon and thu until 31 dec alert 5m, 1h @Room 4 #work"
                : (options.contains("full") || options.contains("repeat") || options.contains("details") ? "Pay rent every month on 1st alert 1d !! @Bank // bring the cheque"
                : (options.contains("when") || options.contains("group") ? "Call mom tomorrow 6pm #personal" : nil)))))))
            KeepDebug.agendaOpen = ["help", "when", "group", "repeat", "edetails", "details", "confirm", "editing"].first { options.contains($0) }
            KeepDebug.agendaTasksOnly = options.contains("tasks")
            KeepDebug.agendaHover = options.first { $0.hasPrefix("hover=") }.map { String($0.dropFirst(6)) }
            KeepDebug.agendaLater = options.first { $0.hasPrefix("later=") }.map { String($0.dropFirst(6)) }
            KeepDebug.agendaSwipe = options.first { $0.hasPrefix("swipe=") }.map { String($0.dropFirst(6)) }
            KeepDebug.agendaQuick = options.first { $0.hasPrefix("quick=") }.map { String($0.dropFirst(6)) }
            size = CGSize(width: IslandConst.openWidth, height: 420)
            view = AnyView(islandFrame(height: 420, width: IslandConst.openWidth) { AgendaView(state: state) })
        case "eventalert":
            // An event's alert set to the notch: the routine card with In 5 min / 10 min, Dismiss, Open.
            RoutineNotchModel.shared.moment = RoutineMoment(kind: .event, alert: BuddyAlert(kind: .event(id: "preview"),
                title: "Design review · in 10 min", detail: "10:00 – 11:00 AM · Room 4 · Work", isPreview: true))
            size = CGSize(width: IslandConst.openWidth, height: 160)
            view = AnyView(islandFrame(height: 160, width: IslandConst.openWidth) { RoutineNotchCard() })
        case "meeting":
            // The Join card for a sample meeting starting now (Mochi is the island's, not drawn here).
            CalendarStore.shared.debugFill()
            let now = Date.now
            MeetingWatcher.shared.debugShow(CalEvent(id: "m", title: "IM stand-up", start: now, end: now.addingTimeInterval(1800),
                                                     allDay: false, calendarID: "w", location: nil,
                                                     meeting: URL(string: "https://zoho.zoom.us/j/123456789"), attendees: 6))
            size = CGSize(width: IslandConst.openWidth, height: 150)
            view = AnyView(islandFrame(height: 150, width: IslandConst.openWidth) { MeetingCard() })
        case "wing":
            // The closed notch's right wing with the task due soon (or the clock).
            size = CGSize(width: 160, height: 37)
            view = AnyView(HStack {
                if let due = TaskDueSoon.shared.next { TaskDueWing(due: due) } else { CompactClock() }
            }.frame(width: 160, height: 37).background(Color.black))
        case "peek":
            // "peek:Keyboard: English (India)": the pill sized for that text, the notch in red.
            let text = parts.dropFirst().joined(separator: ":")
            NotchPeek.shared.debugSet(icon: "keyboard", text: text.isEmpty ? "Charging · 72 %" : text)
            let (w, h) = PeekLayout.size(for: .peek, nw: state.notchWidth, nh: state.notchHeight) ?? (400, 32)
            appendAppLog("nb.log", "[Snapshot] peek \(Int(w)) pt for a \(Int(state.notchWidth)) pt notch")
            size = CGSize(width: w, height: h)
            view = AnyView(ZStack {
                Color.black
                PeekStage(width: w, height: h)
                Self.housing(state.notchWidth, h)
            }.frame(width: w, height: h))
        case "compact":
            // The closed notch, the clock on ("compact:clock"), the notch in red.
            let clockWas = UserDefaults.standard.object(forKey: IslandClock.enabledKey)
            if options.contains("clock") { UserDefaults.standard.set(true, forKey: IslandClock.enabledKey) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { UserDefaults.standard.set(clockWas, forKey: IslandClock.enabledKey) }
            IslandRestingStyle.gridOnLeft = !state.gridSlots.isEmpty
            IslandRestingStyle.contentNeed = CompactSideContent.need(
                gridShown: false, clockOn: UserDefaults.standard.bool(forKey: IslandClock.enabledKey),
                seconds: UserDefaults.standard.bool(forKey: IslandClock.secondsKey), dueLabel: TaskDueSoon.shared.next.map { $0.label ?? "" })
            let (w, h) = IslandRestingStyle.compactSize(nw: state.notchWidth, nh: state.notchHeight)
            size = CGSize(width: w + 40, height: h)
            view = AnyView(ZStack {
                Color.gray.opacity(0.3)
                ZStack {
                    Color.black
                    CompactSideContent(state: state, islandWidth: w, islandHeight: h)
                    // Where Mochi is drawn (by the island, not here): his 20 pt body.
                    Circle().fill(Color.white).frame(width: 20, height: 20)
                        .position(x: IslandRestingStyle.mochiX, y: h / 2)
                    Self.housing(state.notchWidth, h)
                }.frame(width: w, height: h)
            }.frame(width: w + 40, height: h))
            appendAppLog("nb.log", "[Snapshot] compact \(Int(w)) pt: wing \(Int(IslandRestingStyle.wing)) (chosen \(Int(IslandRestingStyle.chosenWing)), content \(Int(IslandRestingStyle.contentNeed))), grid \(!state.gridSlots.isEmpty), mode \(state.mode.rawValue), corner \(state.islandPlacement.isCorner)")
        case "header":
            // The open notch's tabs, and the pages the dots and ← → go through, in nb.log.
            appendAppLog("nb.log", "[Snapshot] pages: " + IslandPages.pages(state).map(\.rawValue).joined(separator: ", "))
            appendAppLog("nb.log", "[Snapshot] notch \(Int(state.notchWidth)) pt wide: room for \(IslandHeader.tabRoom(notchWidth: state.notchWidth)) tabs")
            let w = IslandConst.openWidth
            appendAppLog("nb.log", "[Snapshot] open island \(Int(w)) pt")
            size = CGSize(width: w, height: 44)
            view = AnyView(ZStack {
                IslandHeader(state: state).frame(width: w, height: 44).background(Color.black)
                VStack { Self.housing(state.notchWidth, 32); Spacer(minLength: 0) }
            }.frame(width: w, height: 44))
        case "clipboard":
            let h = KeepPanels.islandHeight(.clipboard, layout: ClipboardSettings.shared.layout) + (KeepDebug.filterOpen ? KeepPanels.filterRow : 0)
            size = CGSize(width: 640, height: h)
            view = AnyView(islandFrame(height: h) { ClipboardView(state: state) })
        default:
            appendAppLog("nb.log", "[Snapshot] unknown page \(name)")
            restore()
            return
        }
        let hosting = NSHostingView(rootView: view.environment(\.islandViewActive, true).frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.alphaValue = 0
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("NotchBuddy")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("snap-\(spec.replacingOccurrences(of: ":", with: "-")).png")
            if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: file) }
            appendAppLog("nb.log", "[Snapshot] \(name) → \(file.path) (\(Int(size.width))×\(Int(size.height)))")
            window.orderOut(nil)
            restore()
            KeepDebug.filterOpen = false
            KeepDebug.forceHover = false
            KeepDebug.selectFirstThree = false
            if options.contains("multi") { FileShelf.shared.selected = [] }
        }
    }

    /// Where the camera housing is: what is drawn here cannot be seen on a MacBook.
    private static func housing(_ width: CGFloat, _ height: CGFloat) -> some View {
        Rectangle().fill(Color.red.opacity(0.45)).frame(width: width, height: height)
    }

    /// The island's black body, its header's height left empty, the card below it.
    @MainActor
    private static func islandFrame<V: View>(height: CGFloat, width: CGFloat = 640, @ViewBuilder content: () -> V) -> some View {
        ZStack(alignment: .top) {
            Color.black
            VStack(spacing: 0) {
                Color.clear.frame(height: 42)
                content().frame(height: height - 52)
                Color.clear.frame(height: 10)
            }
            .padding(.horizontal, 10)
        }
        .frame(width: width, height: height)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22))
    }
}
#endif
