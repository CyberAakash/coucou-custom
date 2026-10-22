import Foundation
import CoreGraphics

@main
@MainActor
enum BuddyTests {
    static func main() {
        testSizes()
        testInsets()
        testPlacement()
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

        // Unknown stored values fall back
        ud.set("#123456", forKey: BuddySettings.colorKey); ud.set("cape", forKey: BuddySettings.outfitKey)
        let u = BuddySettings(defaults: ud)
        precondition(u.color.isEmpty && u.outfit == .auto, "colour outside the palette / unknown outfit → defaults")
        precondition(BuddySettings.colors.first == "" && BuddySettings.colors.allSatisfy { $0.isEmpty || $0.hasPrefix("#") }, "palette")
    }
}
