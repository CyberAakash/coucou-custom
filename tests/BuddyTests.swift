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
        testColors()
        testSpeech()
        testSettings()
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
        precondition(size == CGSize(width: 200 + 24 + 24, height: 200 + 64 + 8), "Mochi window: \(size)")
        precondition(m.innerOrigin(side: 200) == CGPoint(x: 24, y: 8), "square from the bottom-left (y up)")
        precondition(m.innerRectTopDown(side: 200) == CGRect(x: 24, y: 64, width: 200, height: 200), "square from the top-left (y down)")
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
        // The window widens by a strip on each side; the square stays centred
        let m = BuddyInsets.mochi, lay = BuddyCompanionLayout(count: 4, side: 120)
        let size = m.panelSize(side: 120, strip: lay.stripWidth)
        let sq = m.innerRectTopDown(side: 120, strip: lay.stripWidth)
        precondition(size.width == m.panelSize(side: 120).width + 2 * lay.stripWidth && size.height == m.panelSize(side: 120).height, "wider, same height")
        precondition(abs(sq.midX - size.width / 2) < 0.5, "square centred: \(sq.midX) of \(size.width)")
        precondition(m.innerOrigin(side: 120, strip: lay.stripWidth).x == sq.minX, "both spaces agree in x")
        // The strip fits in the window above the floor
        let floor = sq.minY + 120 * BuddyCompanionLayout.floor
        precondition(floor - lay.stripHeight >= 0 && floor <= size.height, "strip inside the window")
        let none = BuddyCompanionLayout(count: 0, side: 120)
        precondition(none.stripWidth == 0 && none.left == 0 && none.right == 0, "none: no strip")
        precondition(BuddyCompanionLayout(count: 9, side: 120).count == 6 && BuddyCompanionLayout(count: -1, side: 120).count == 0, "0…6")
        let three = BuddyCompanionLayout(count: 3, side: 120)
        precondition(three.left == 2 && three.right == 1, "the extra one on the left")
        precondition(three.size == 50, "42 % of the square")
        precondition(three.stripWidth == (50 * (2 * 0.9 + 0.7)).rounded(), "strip sized for the fuller side")
        precondition(three.slot(0) == (true, 1.0) && three.slot(2) == (true, 0.0), "left: first nearest the Buddy (the strip's right end)")
        precondition(three.slot(1) == (false, 0.5), "a lone one in the middle of its strip")
        let six = BuddyCompanionLayout(count: 6, side: 200)
        precondition((0..<6).filter { six.slot($0).left }.count == 3, "3 a side")
        precondition(six.slot(1) == (false, 0.0) && six.slot(5) == (false, 1.0), "right: first nearest the Buddy")
        precondition(six.stripHeight == (six.size * 1.5).rounded() && BuddyCompanionLayout.floor == 0.8, "floor and height")
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
        precondition(s.enabled && s.size == .medium && s.outfit == .auto && s.color.isEmpty, "defaults")
        precondition(s.reactToAgents && s.speechBubbles && s.followCursor && s.napWhenIdle && s.spots.isEmpty, "behaviour defaults")

        s.enabled = false; s.size = .large; s.outfit = .crown; s.color = "#F472B6"
        s.reactToAgents = false; s.speechBubbles = false; s.followCursor = false; s.napWhenIdle = false
        s.spots = [BuddySpot(screen: "0,0,1512x982", x: 10, y: 20)]
        let t = BuddySettings(defaults: ud)
        precondition(!t.enabled && t.size == .large && t.outfit == .crown && t.color == "#F472B6", "look persisted")
        precondition(!t.reactToAgents && !t.speechBubbles && !t.followCursor && !t.napWhenIdle, "behaviour persisted")
        precondition(t.spots == [BuddySpot(screen: "0,0,1512x982", x: 10, y: 20)], "spots persisted")

        // Its own outfit: the notch's wardrobe key is not read or written
        ud.set("bunnyEars", forKey: "mochiOutfit")
        precondition(BuddySettings(defaults: ud).outfit == .crown, "notch wardrobe does not dress the Buddy")
        precondition(ud.string(forKey: "mochiOutfit") == "bunnyEars", "the Buddy does not touch the notch's outfit")

        // Auto follows the seasons, as the notch's does
        let cal = Calendar(identifier: .gregorian)
        let halloween = cal.date(from: DateComponents(year: 2026, month: 10, day: 31))!
        t.outfit = .auto
        precondition(t.resolvedOutfit(on: halloween) == .witchHat, "auto = seasonal")
        t.outfit = .bow
        precondition(t.resolvedOutfit(on: halloween) == .bow, "a chosen outfit stays")

        // Any colour; bad stored values fall back
        t.color = "#123abc"
        precondition(t.color == "#123ABC" && BuddySettings(defaults: ud).color == "#123ABC", "any colour, normalized and stored")
        t.color = "not a colour"
        precondition(t.color.isEmpty && BuddySettings(defaults: ud).color.isEmpty, "a bad colour → Mochi's own")
        ud.set("zzz", forKey: BuddySettings.colorKey); ud.set("cape", forKey: BuddySettings.outfitKey)
        let u = BuddySettings(defaults: ud)
        precondition(u.color.isEmpty && u.outfit == .auto, "bad stored colour / unknown outfit → defaults")

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
