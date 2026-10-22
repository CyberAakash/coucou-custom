import Foundation
import CoreGraphics

@main
@MainActor
enum BuddyTests {
    static func main() {
        testSizes()
        testInsets()
        testPlacement()
        testEdges()
        testCompanions()
        testShadow()
        testClicks()
        testOpenTargets()
        testColors()
        testSpeech()
        testSettings()
        BuddyWardrobeTests.run()
        print("Buddy: all cases passed")
    }

    // MARK: - Sizes

    static func testSizes() {
        precondition(BuddySize.medium.side == 120, "Medium keeps the desktop Mochi's 120 pt")
        precondition(BuddySize.allCases.map(\.side) == [56, 80, 120, 160, 200], "OpenPets' 0.35…1.25, relative to Medium")
        precondition(BuddySize.allCases.map(\.short) == ["XS", "S", "M", "L", "XL"], "chip labels")
        precondition(BuddySize.from(stored: 1.5) == .huge, "OpenPets' old 1.5 → Huge")
        precondition(BuddySize.from(stored: 0.9) == .medium, "unknown → Medium")
        precondition(BuddySize.from(stored: 0.35) == .extraSmall, "stored XS")
    }

    // MARK: - Window margins

    static func testInsets() {
        let m = BuddyInsets.mochi
        // Mochi Huge (200 pt square): measured overflow 24 % top, 7 % right, 1 % left, plus 1.07 hover.
        let size = m.panelSize(side: 200)
        precondition(size == CGSize(width: 200 + 24 + 24, height: 200 + 84 + 8), "Mochi window: \(size)")
        precondition(m.innerOrigin(side: 200) == CGPoint(x: 24, y: 8), "square from the bottom-left (y up)")
        precondition(m.innerRectTopDown(side: 200) == CGRect(x: 24, y: 84, width: 200, height: 200), "square from the top-left (y down)")
        precondition(m.top >= 0.242 + 0.035 + 0.105, "room for the measured top, hover and a jump")
        // Room for the measured overflow and hover, in points, at the largest size
        let hover = (1.07 - 1) / 2   // grows this much past each side of the square
        precondition(m.top >= 0.242 + hover, "top room for proud / zZ / party hat")
        precondition(m.right >= 0.067 + hover && m.left >= 0.008 + hover, "side room for zZ / witch hat")
        // y-up and y-down placements agree: the square's bottom is `bottom` above the window's bottom
        for side in BuddySize.allCases.map(\.side) {
            let r = m.innerRectTopDown(side: side), sz = m.panelSize(side: side)
            precondition(sz.height - r.maxY == m.innerOrigin(side: side).y, "both spaces agree at \(side)")
        }
    }

    // MARK: - Placement

    static func testPlacement() {
        let vf = CGRect(x: 0, y: 80, width: 1512, height: 870)   // under the menu bar, above the Dock
        let foot = BuddyPlacement.defaultFoot(visibleFrame: vf, side: 156)
        precondition(foot == CGPoint(x: 1512 - 24 - 78, y: 104), "default: bottom right, 24 pt margin")
        let o = BuddyPlacement.origin(foot: foot, side: 156)
        precondition(BuddyPlacement.foot(origin: o, side: 156) == foot, "foot ↔ origin")
        // A size change keeps the foot: same centre x and bottom
        let big = BuddyPlacement.origin(foot: foot, side: 260)
        precondition(big.x + 130 == foot.x && big.y == foot.y, "bigger pet stands on the same spot")

        precondition(BuddyPlacement.clamp(origin: CGPoint(x: -50, y: 0), side: 100, visibleFrame: vf) == CGPoint(x: 0, y: 80), "clamp bottom-left")
        precondition(BuddyPlacement.clamp(origin: CGPoint(x: 2000, y: 2000), side: 100, visibleFrame: vf) == CGPoint(x: 1412, y: 850), "clamp top-right")
        precondition(BuddyPlacement.clamp(origin: CGPoint(x: 300, y: 300), side: 100, visibleFrame: vf) == CGPoint(x: 300, y: 300), "inside untouched")
        // Second display left of the main one (negative x)
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        precondition(BuddyPlacement.screenKey(left) == "-1920,0,1920x1080", "OpenPets key format")
        precondition(BuddyPlacement.clamp(origin: CGPoint(x: -10, y: 5), side: 100, visibleFrame: left) == CGPoint(x: -100, y: 5), "clamp on a left display")

        var spots: [BuddySpot] = []
        for i in 0..<10 { spots = BuddyPlacement.remembering(BuddySpot(screen: "s\(i)", x: Double(i), y: 0), in: spots) }
        precondition(spots.count == 8 && spots.first?.screen == "s9" && spots.last?.screen == "s2", "8 most recent displays")
        spots = BuddyPlacement.remembering(BuddySpot(screen: "s5", x: 99, y: 1), in: spots)
        precondition(spots.count == 8 && spots.first == BuddySpot(screen: "s5", x: 99, y: 1), "updated display moves first")
        precondition(spots.filter { $0.screen == "s5" }.count == 1, "one spot per display")
        precondition(BuddyPlacement.spot(for: "s5", in: spots)?.x == 99 && BuddyPlacement.spot(for: "zz", in: spots) == nil, "lookup")
    }

    // MARK: - Edges: up to half off any edge

    static func testEdges() {
        let f = CGRect(x: 0, y: 0, width: 1800, height: 1169)        // the whole display
        let s: CGFloat = 120
        // Every corner and edge is reachable; the centre stays on the display (half of it off at most)
        precondition(BuddyPlacement.clampLoose(origin: CGPoint(x: -500, y: -500), side: s, frame: f) == CGPoint(x: -60, y: -60), "bottom-left: half off")
        precondition(BuddyPlacement.clampLoose(origin: CGPoint(x: 5000, y: 5000), side: s, frame: f) == CGPoint(x: 1740, y: 1109), "top-right: half off")
        precondition(BuddyPlacement.clampLoose(origin: CGPoint(x: -30, y: 1000), side: s, frame: f) == CGPoint(x: -30, y: 1000), "a quarter off is fine")
        let edge = BuddyPlacement.clampLoose(origin: CGPoint(x: -500, y: 300), side: s, frame: f)
        precondition(edge.x + s / 2 == f.minX, "centre exactly on the left edge")
        // Second display to the right, lower
        let dell = CGRect(x: 1800, y: 89, width: 1920, height: 1080)
        precondition(BuddyPlacement.clampLoose(origin: CGPoint(x: 9999, y: 0), side: s, frame: dell) == CGPoint(x: 3660, y: 29), "on the other display")
        // Off every display (centre on none) is detected, so it can be put back
        precondition(BuddyPlacement.isOnScreen(origin: CGPoint(x: -60, y: -60), side: s, frames: [f, dell]), "centre on the corner counts")
        precondition(!BuddyPlacement.isOnScreen(origin: CGPoint(x: -61, y: 500), side: s, frames: [f, dell]), "centre past the edge")
        // Every loose-clamped spot counts as on the display, the top and right edges too
        for o in [CGPoint(x: 5000, y: 300), CGPoint(x: 300, y: 5000), CGPoint(x: 5000, y: 5000), CGPoint(x: -5000, y: -5000)] {
            let c = BuddyPlacement.clampLoose(origin: o, side: s, frame: f)
            precondition(BuddyPlacement.isOnScreen(origin: c, side: s, frames: [f]), "clamped \(o) → \(c) is on screen")
        }
        precondition(!BuddyPlacement.isOnScreen(origin: CGPoint(x: 1900, y: -50), side: s, frames: [f, dell]), "gap below the higher display")
        precondition(BuddyPlacement.isOnScreen(origin: CGPoint(x: 1800, y: 1100), side: s, frames: [f, dell]), "top of the other display")
    }

    // MARK: - Companions

    static func testCompanions() {
        // The window widens by the roaming room on each side; the square stays centred
        let m = BuddyInsets.mochi, lay = BuddyCompanionLayout(count: 4, side: 120)
        let size = m.panelSize(side: 120, strip: lay.roam)
        let sq = m.innerRectTopDown(side: 120, strip: lay.roam)
        precondition(size.width == m.panelSize(side: 120).width + 2 * lay.roam && size.height == m.panelSize(side: 120).height, "wider, same height")
        precondition(abs(sq.midX - size.width / 2) < 0.5, "square centred: \(sq.midX) of \(size.width)")
        precondition(m.innerOrigin(side: 120, strip: lay.roam).x == sq.minX, "both spaces agree in x")
        let floor = sq.minY + 120 * BuddyCompanionLayout.floor
        precondition(floor - lay.stripHeight >= 0 && floor <= size.height, "their jumps fit in the window")

        let none = BuddyCompanionLayout(count: 0, side: 120)
        precondition(none.roam == 0 && none.left == 0 && none.right == 0, "none: no room added")
        precondition(BuddyCompanionLayout(count: 9, side: 120).count == 6 && BuddyCompanionLayout(count: -1, side: 120).count == 0, "0…6")
        // More companions, more room to roam
        let rooms = (1...6).map { BuddyCompanionLayout(count: $0, side: 120).roam }
        precondition(rooms == rooms.sorted() && Set(rooms).count == 6, "room grows with the count: \(rooms)")
        let three = BuddyCompanionLayout(count: 3, side: 120)
        precondition(three.left == 2 && three.right == 1 && three.size == 50, "split and size")
        // They start right beside the Buddy's body, the first ones nearest, alternating sides
        let mid: CGFloat = 500, body = 120 * BuddyCompanionLayout.bodyHalfWidth
        let x0 = three.startX(0, squareMidX: mid), x1 = three.startX(1, squareMidX: mid), x2 = three.startX(2, squareMidX: mid)
        precondition(x0 < mid && x1 > mid && x2 < x0, "left, right, then further left")
        let gap0 = (mid - body) - (x0 + 50 * BuddyCompanionLayout.bodyHalfWidth)
        precondition(gap0 > 0 && gap0 < 10, "the first one stands just clear of the Buddy (gap \(gap0) pt)")
        precondition(abs((x1 - mid) - (mid - x0)) < 0.001, "symmetric")
        // Every start is inside the window the room makes
        let wide = BuddyCompanionLayout(count: 6, side: 200)
        let wsize = m.panelSize(side: 200, strip: wide.roam), wsq = m.innerRectTopDown(side: 200, strip: wide.roam)
        for i in 0..<6 {
            let x = wide.startX(i, squareMidX: wsq.midX)
            precondition(x - wide.size / 2 >= 0 && x + wide.size / 2 <= wsize.width, "start \(i) inside the stage")
        }
    }

    // MARK: - Shadow

    static func testShadow() {
        precondition(BuddyShadow.off.opacity == 0 && BuddyShadow.soft.opacity < BuddyShadow.medium.opacity && BuddyShadow.medium.opacity < BuddyShadow.strong.opacity, "levels")
        let sq = CGRect(x: 10, y: 50, width: 120, height: 120)
        let ground = BuddyShadow.ellipse(square: sq, lift: 0), up = BuddyShadow.ellipse(square: sq, lift: 0.1)
        precondition(abs(ground.rect.midX - sq.midX) < 0.001 && abs(ground.rect.midY - (50 + 96)) < 0.001, "under the body, on the floor")
        precondition(ground.rect.width == 72 && ground.fade == 1, "full size on the floor")
        precondition(up.rect.width < ground.rect.width && up.fade < 1, "smaller and lighter in a jump")
        precondition(BuddyShadow.ellipse(square: sq, lift: 5).rect.width == 72 * 0.45, "never vanishes")
    }

    // MARK: - Clicks

    static func testClicks() {
        precondition([1, 2, 3, 4, 7].map { BuddyGesture.from(count: $0) } == [.click, .double, .triple, .many, .many], "gestures")
        let d = BuddyClickBinding.defaults
        precondition(d[.click]?.action == .hello && d[.double]?.action == .spin && d[.triple]?.action == .hearts && d[.many]?.action == .dizzy, "defaults")
        // Wait for more clicks only when a longer gesture does something
        precondition(BuddyClicks.shouldWait(after: 1, bindings: d) && BuddyClicks.shouldWait(after: 3, bindings: d), "defaults wait")
        precondition(!BuddyClicks.shouldWait(after: 4, bindings: d), "4 is the last")
        var onlyClick = d; onlyClick[.double] = .init(action: .none); onlyClick[.triple] = .init(action: .none); onlyClick[.many] = .init(action: .none)
        precondition(!BuddyClicks.shouldWait(after: 1, bindings: onlyClick), "a lone click acts at once")
        var manyOnly = onlyClick; manyOnly[.many] = .init(action: .dizzy)
        precondition(BuddyClicks.shouldWait(after: 2, bindings: manyOnly), "still counting toward many")
        var noName = onlyClick; noName[.double] = .init(action: .shortcut, parameter: "  ")
        precondition(!BuddyClicks.shouldWait(after: 1, bindings: noName), "a Shortcut with no name does nothing")
        precondition(BuddyClickBinding(action: .shortcut, parameter: "Focus").isRunnable && !BuddyClickBinding(action: .none).isRunnable, "runnable")
        // Every action is offered once in the menu
        let listed = [BuddyAction.none] + BuddyAction.animations + BuddyAction.coucou + BuddyAction.yours
        precondition(listed.count == BuddyAction.allCases.count && Set(listed) == Set(BuddyAction.allCases), "each action listed once")
    }

    // MARK: - Your own: links and apps to open

    static func testOpenTargets() {
        precondition(BuddyShortcuts.target("https://openpets.dev")?.absoluteString == "https://openpets.dev", "a link")
        precondition(BuddyShortcuts.target("mailto:me@example.com")?.scheme == "mailto", "any scheme")
        precondition(BuddyShortcuts.target("/System/Applications/Calculator.app")?.isFileURL == true, "an existing app")
        precondition(BuddyShortcuts.target("~")?.path == FileManager.default.homeDirectoryForCurrentUser.path, "~ expands")
        precondition(BuddyShortcuts.target("/no/such/app.app") == nil, "a missing path")
        for bad in ["", "   ", "just words", "openpets.dev"] { precondition(BuddyShortcuts.target(bad) == nil, "not a target: \(bad)") }
        precondition(FileManager.default.isExecutableFile(atPath: BuddyShortcuts.tool.path), "/usr/bin/shortcuts exists on this Mac")
    }

    // MARK: - Colours

    static func testColors() {
        precondition(BuddyColor.normalized("#f472b6") == "#F472B6", "lower case")
        precondition(BuddyColor.normalized(" 3b9eff ") == "#3B9EFF", "no # and spaces")
        for bad in ["", "#12345", "#1234567", "#GGGGGG", "red", "##123456"] {
            precondition(BuddyColor.normalized(bad) == nil, "refused: \(bad)")
        }
        precondition(BuddyColor.hex(red: 1, green: 0, blue: 0.5) == "#FF0080", "components → hex")
        precondition(BuddyColor.hex(red: 2, green: -1, blue: 0) == "#FF0000", "clamped")
        precondition(BuddyColor.companions.allSatisfy { BuddyColor.normalized($0) == $0 }, "palette is valid")
    }

    // MARK: - Speech

    static func testSpeech() {
        precondition(BuddySpeech.category(for: .approval) == .permission, "approval speaks")
        precondition(BuddySpeech.category(for: .question) == .question, "question speaks")
        precondition(BuddySpeech.category(for: .error) == .error, "error speaks")
        for s in [BotState.idle, .working, .thinking, .finished, .sleeping, .searching, .ratelimit, .dizzy] {
            precondition(BuddySpeech.category(for: s) == nil, "\(s) is silent (as OpenPets' hook)")
        }
        var sp = BuddySpeech()
        let t = Date(timeIntervalSince1970: 0)
        precondition(sp.shouldSpeak(.permission, now: t), "first permission speaks")
        precondition(!sp.shouldSpeak(.permission, now: t.addingTimeInterval(2.9)), "3 s cooldown")
        precondition(sp.shouldSpeak(.permission, now: t.addingTimeInterval(3)), "after 3 s")
        precondition(sp.shouldSpeak(.error, now: t), "categories are separate")
        precondition(!sp.shouldSpeak(.error, now: t.addingTimeInterval(19)), "20 s cooldown for errors")
        precondition(sp.shouldSpeak(.error, now: t.addingTimeInterval(20)), "after 20 s")
        for c in BuddySpeech.Category.allCases {
            precondition(!BuddySpeech.line(c, pick: -7).isEmpty && BuddySpeech.line(c, pick: 1000).count <= 40, "lines for \(c)")
        }
    }

    // MARK: - Settings: the Buddy's own, persisted

    static func testSettings() {
        let suite = "buddy-tests-\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suite)!
        defer { ud.removePersistentDomain(forName: suite) }
        let s = BuddySettings(defaults: ud)
        precondition(s.enabled && s.size == .medium && s.alwaysWear == nil && s.userSchedule == nil && s.color.isEmpty, "defaults")
        precondition(s.reactToAgents && s.speechBubbles && s.followCursor && s.napWhenIdle && s.spots.isEmpty, "behaviour defaults")
        precondition(s.shadow == .soft && s.clicks == BuddyClickBinding.defaults && s.schedule == BuddyWardrobe.defaultSchedule, "shadow, clicks, schedule")

        s.enabled = false; s.size = .large; s.alwaysWear = .crown; s.color = "#F472B6"; s.shadow = .strong
        s.reactToAgents = false; s.speechBubbles = false; s.followCursor = false; s.napWhenIdle = false
        s.spots = [BuddySpot(screen: "0,0,1512x982", x: 10, y: 20)]
        s.setBinding(.init(action: .shortcut, parameter: "Focus"), for: .double)
        let t = BuddySettings(defaults: ud)
        precondition(!t.enabled && t.size == .large && t.alwaysWear == .crown && t.color == "#F472B6" && t.shadow == .strong, "look persisted")
        precondition(!t.reactToAgents && !t.speechBubbles && !t.followCursor && !t.napWhenIdle, "behaviour persisted")
        precondition(t.spots == [BuddySpot(screen: "0,0,1512x982", x: 10, y: 20)], "spots persisted")
        precondition(t.binding(.double) == .init(action: .shortcut, parameter: "Focus") && t.binding(.click).action == .hello, "clicks persisted, others default")

        // Its own wardrobe: the notch's key is never read or written
        ud.set("bunnyEars", forKey: "mochiOutfit")
        precondition(BuddySettings(defaults: ud).alwaysWear == .crown, "notch wardrobe does not dress the Buddy")
        precondition(ud.string(forKey: "mochiOutfit") == "bunnyEars", "the Buddy does not touch the notch's outfit")

        // Old stored values (before the wardrobe): "auto" → Automatic, an outfit → Always wear
        ud.set("auto", forKey: BuddySettings.outfitKey)
        precondition(BuddySettings(defaults: ud).alwaysWear == nil, "auto = Automatic")
        ud.set("witchHat", forKey: BuddySettings.outfitKey)
        precondition(BuddySettings(defaults: ud).alwaysWear == .witchHat, "an old outfit = Always wear")
        ud.set("none", forKey: BuddySettings.outfitKey)
        precondition(BuddySettings(defaults: ud).alwaysWear == BuddyOutfit.none, "none = always no outfit")

        // Schedule: Automatic follows it; editing copies the Buddy's own; Reset drops the copy
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let octNight = cal.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 23))!
        let w = BuddySettings(defaults: ud)
        w.alwaysWear = nil
        precondition(w.resolvedOutfit(on: octNight, calendar: cal) == .nightcap && w.activeRule(on: octNight, calendar: cal) == 3, "pajamas at night")
        w.editSchedule { $0.removeAll { $0.outfit == .nightcap } }
        precondition(w.userSchedule?.count == BuddyWardrobe.defaultSchedule.count - 1, "edited copy")
        precondition(BuddySettings(defaults: ud).resolvedOutfit(on: octNight, calendar: cal) == .none, "edit persisted")
        w.userSchedule = []
        precondition(BuddySettings(defaults: ud).userSchedule == [], "an empty schedule is kept (never change)")
        w.userSchedule = nil
        precondition(BuddySettings(defaults: ud).schedule == BuddyWardrobe.defaultSchedule, "reset to the Buddy's own")
        w.alwaysWear = .bow
        precondition(w.resolvedOutfit(on: octNight, calendar: cal) == .bow && w.activeRule(on: octNight, calendar: cal) == nil, "always wear pauses the schedule")

        // Any colour; bad stored values fall back
        t.color = "#123abc"
        precondition(t.color == "#123ABC" && BuddySettings(defaults: ud).color == "#123ABC", "any colour, normalized and stored")
        t.color = "not a colour"
        precondition(t.color.isEmpty && BuddySettings(defaults: ud).color.isEmpty, "a bad colour → Mochi's own")
        ud.set("zzz", forKey: BuddySettings.colorKey); ud.set("cape", forKey: BuddySettings.outfitKey)
        ud.set("neon", forKey: BuddySettings.shadowKey); ud.set(Data("x".utf8), forKey: BuddySettings.clicksKey)
        let u = BuddySettings(defaults: ud)
        precondition(u.color.isEmpty && u.alwaysWear == nil && u.shadow == .soft && u.clicks == BuddyClickBinding.defaults, "bad stored values → defaults")

        // Companions
        precondition(u.companions == 0 && !u.companionsMatch, "no companions by default")
        u.companions = 4
        precondition(BuddySettings(defaults: ud).companions == 4, "count persisted")
        u.companions = 10
        precondition(u.companions == 6, "at most 6")
        u.companions = -2
        precondition(u.companions == 0, "at least 0")
        ud.set(99, forKey: BuddySettings.companionsKey)
        precondition(BuddySettings(defaults: ud).companions == 6, "bad stored count clamped")
        precondition(u.companionColor(0) == BuddyColor.companions[0] && u.companionColor(9) == BuddyColor.companions[1], "palette, cycling")
        u.companionsMatch = true
        precondition(u.companionColor(3) == "", "match Mochi's own → Mochi's own")
        u.color = "#F472B6"
        precondition(u.companionColor(3) == "#F472B6" && BuddySettings(defaults: ud).companionsMatch, "match the Buddy's colour")
    }
}
