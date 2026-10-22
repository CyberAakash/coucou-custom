import Foundation
import CoreGraphics
import ImageIO

@main
@MainActor
enum BuddyTests {
    static func main() {
        testManifest()
        testAnimationFrames()
        testAnimatorOneShots()
        testReactions()
        testOverrides()
        testGaze()
        testSizes()
        testGeometry()
        testPlacement()
        testSpeech()
        testAtlas()
        testStore()
        testSettings()
        testRealPets()
        print("Buddy: all cases passed")
    }

    static func json(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - pet.json

    static func testManifest() {
        let ok = try! BuddyPetManifest.parse(json("""
        {"id":"cheddar","displayName":"Cheddar","description":"A cat.","spritesheetPath":"spritesheet.webp",
         "kind":"animal","tags":["cute"]}
        """))
        precondition(ok.id == "cheddar" && ok.layout == .v1 && ok.gazeAnchor == nil, "v1 manifest, extra keys ignored")

        let v2 = try! BuddyPetManifest.parse(json("""
        {"id":"a","displayName":"A","description":"d","spritesheetPath":"spritesheet.webp",
         "spriteVersionNumber":2,"gazeAnchor":{"x":0.5,"y":0.25}}
        """))
        precondition(v2.layout == .v2 && v2.layout.hasGaze && v2.gazeAnchor == CGPoint(x: 0.5, y: 0.25), "v2 + anchor")

        func fails(_ s: String, _ why: String) {
            precondition((try? BuddyPetManifest.parse(json(s))) == nil, why)
        }
        fails("[]", "array is not a manifest")
        fails(#"{"id":"Bad","displayName":"A","description":"d","spritesheetPath":"spritesheet.webp"}"#, "uppercase id")
        fails(#"{"id":"-a","displayName":"A","description":"d","spritesheetPath":"spritesheet.webp"}"#, "id starts with -")
        fails(#"{"id":"a","displayName":"","description":"d","spritesheetPath":"spritesheet.webp"}"#, "empty name")
        fails(#"{"id":"a","displayName":"A","spritesheetPath":"spritesheet.webp"}"#, "missing description")
        fails(#"{"id":"a","displayName":"A","description":"d","spritesheetPath":"../x.webp"}"#, "other path")
        fails(#"{"id":"a","displayName":"A","description":"d","spritesheetPath":"spritesheet.webp","spriteVersionNumber":1}"#, "version 1 explicit")
        fails(#"{"id":"a","displayName":"A","description":"d","spritesheetPath":"spritesheet.webp","spriteVersionNumber":true}"#, "bool version")
        fails(#"{"id":"a","displayName":"A","description":"d","spritesheetPath":"spritesheet.webp","gazeAnchor":{"x":2,"y":0}}"#, "anchor out of range")
        do {
            _ = try BuddyPetManifest.parse(json(#"{"id":"a","displayName":"A","description":"d","spritesheetPath":"spritesheet.svg"}"#))
            preconditionFailure("svg must be refused")
        } catch let e as BuddyPetManifest.ParseError {
            precondition(e == .unsupportedSpritesheet("spritesheet.svg"), "svg reported as unsupported")
        } catch { preconditionFailure("unexpected error") }

        precondition(BuddyPetManifest.isValidId(String(repeating: "a", count: 64)), "64 chars ok")
        precondition(!BuddyPetManifest.isValidId(String(repeating: "a", count: 65)), "65 chars too long")
        precondition(BuddyPetManifest.isValidId("luffy-gear_5"), "- and _ allowed")
        precondition(!BuddyPetManifest.isValidId("ü"), "non-ascii refused")
    }

    // MARK: - Animation rows

    static func testAnimationFrames() {
        precondition(BuddyAnimation.allCases.map(\.row) == Array(0...8), "rows 0–8 in OpenPets order")
        precondition(BuddyAtlasLayout.v1.minimumPixelWidth == 1536 && BuddyAtlasLayout.v1.minimumPixelHeight == 1872, "v1 atlas")
        precondition(BuddyAtlasLayout.v2.minimumPixelHeight == 2288, "v2 atlas")
        precondition(BuddyAtlasLayout.cellRect(row: 2, column: 3) == CGRect(x: 576, y: 416, width: 192, height: 208), "cell rect")

        // idle: 6 frames over 5.5 s, loops
        precondition(BuddyAnimation.idle.frame(at: 0, relaxedWaiting: false) == 0, "idle start")
        precondition(BuddyAnimation.idle.frame(at: 5.4, relaxedWaiting: false) == 5, "idle last frame")
        precondition(BuddyAnimation.idle.frame(at: 5.6, relaxedWaiting: false) == 0, "idle loops")
        // waving: 4 frames × 0.7 s, 2 iterations, then over
        precondition(BuddyAnimation.waving.frame(at: 1.39, relaxedWaiting: false) == 3, "wave second pass")
        precondition(BuddyAnimation.waving.frame(at: 1.4, relaxedWaiting: false) == nil, "wave over after 2 passes")
        // waiting speeds
        precondition(BuddyAnimation.waiting.duration(relaxedWaiting: false) == 1.01, "waiting normal")
        precondition(BuddyAnimation.waiting.duration(relaxedWaiting: true) == 2.2, "waiting relaxed")
        precondition(BuddyAnimation.waiting.frame(at: 1.5, relaxedWaiting: true) == 4, "relaxed frame")
        precondition(BuddyAnimation.waiting.frame(at: 1.5, relaxedWaiting: false) == 2, "normal frame (loops)")
    }

    static func testAnimatorOneShots() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let a = BuddyAnimator()
        a.setReaction(.jumping, now: t0)
        precondition(a.cell(now: t0, gaze: nil) == (4, 0), "jumping starts")
        // Same reaction every frame must not restart it
        a.setReaction(.jumping, now: t0.addingTimeInterval(0.5))
        precondition(a.cell(now: t0.addingTimeInterval(0.5), gaze: nil).row == 4, "still jumping")
        // After 2 × 0.84 s it rests on idle, and re-sending jumping keeps it there
        precondition(a.cell(now: t0.addingTimeInterval(1.7), gaze: nil) == (0, 0), "jumping over → idle")
        a.setReaction(.jumping, now: t0.addingTimeInterval(2))
        precondition(a.cell(now: t0.addingTimeInterval(2), gaze: nil).row == 0, "no replay of a finished one-shot")
        // A new reaction plays
        a.setReaction(.running, now: t0.addingTimeInterval(3))
        precondition(a.cell(now: t0.addingTimeInterval(3), gaze: nil).row == 7, "running")
        // A click's wave plays over it, then back to running
        a.play(.waving, now: t0.addingTimeInterval(4))
        precondition(a.cell(now: t0.addingTimeInterval(4.1), gaze: nil).row == 3, "waving over running")
        precondition(a.cell(now: t0.addingTimeInterval(5.5), gaze: nil).row == 7, "back to running")
        // Gaze only while idle
        precondition(a.cell(now: t0.addingTimeInterval(5.6), gaze: 3).row == 7, "no gaze while running")
        a.setReaction(.idle, now: t0.addingTimeInterval(6))
        precondition(a.cell(now: t0.addingTimeInterval(6), gaze: 3) == (9, 3), "gaze cell while idle")
        precondition(a.cell(now: t0.addingTimeInterval(6), gaze: 12) == (10, 4), "gaze second row")
        // Drag motion wins, flipped pets swap left/right rows
        a.motion = .runningRight
        precondition(a.cell(now: t0.addingTimeInterval(6.1), gaze: 3).row == 1, "running right while dragged")
        a.flipped = true
        precondition(a.cell(now: t0.addingTimeInterval(6.1), gaze: nil).row == 2, "flipped: running-left row")
        a.motion = nil
        precondition(a.cell(now: t0.addingTimeInterval(6.1), gaze: 3) == (10, 5), "flipped gaze uses mirrored cell 13")
    }

    // MARK: - Reactions

    static func testReactions() {
        let expect: [BotState: BuddyReaction] = [
            .idle: .idle, .sleeping: .idle, .thinking: .thinking, .working: .working, .searching: .working,
            .approval: .waiting, .question: .waiting, .ratelimit: .waiting, .error: .error, .dizzy: .error,
            .finished: .success,
        ]
        for s in BotState.allCases {
            precondition(BuddyReaction.forState(s) == expect[s], "state \(s)")
        }
        precondition(BuddyReaction.thinking.defaultAnimation == .review, "thinking → review")
        precondition(BuddyReaction.success.defaultAnimation == .jumping, "success → jumping")
        precondition(BuddyReaction.error.defaultAnimation == .failed, "error → failed")
    }

    static func testOverrides() {
        let o = ["success": "waving", "thinking": "review", "error": "running-left", "bogus": "idle", "idle": "nope"]
        precondition(BuddyReaction.normalized(o) == ["success": "waving"], "normalized keeps real overrides only")
        precondition(BuddyReaction.success.animation(overrides: o) == .waving, "override applied")
        precondition(BuddyReaction.error.animation(overrides: o) == .failed, "non-selectable override ignored")
        precondition(BuddyReaction.idle.animation(overrides: o) == .idle, "unknown animation ignored")
    }

    // MARK: - Gaze

    static func testGaze() {
        let c = CGPoint(x: 100, y: 100)
        precondition(BuddyGaze.direction(cursor: CGPoint(x: 110, y: 110), anchor: c) == nil, "dead zone")
        precondition(BuddyGaze.direction(cursor: CGPoint(x: 100, y: 0), anchor: c) == 0, "up = 0")
        precondition(BuddyGaze.direction(cursor: CGPoint(x: 200, y: 100), anchor: c) == 4, "right = 4")
        precondition(BuddyGaze.direction(cursor: CGPoint(x: 100, y: 200), anchor: c) == 8, "down = 8")
        precondition(BuddyGaze.direction(cursor: CGPoint(x: 0, y: 100), anchor: c) == 12, "left = 12")
        precondition(BuddyGaze.direction(cursor: CGPoint(x: 200, y: 0), anchor: c) == 2, "up-right = 2")
        precondition(BuddyGaze.mirrored(0) == 0 && BuddyGaze.mirrored(4) == 12 && BuddyGaze.mirrored(2) == 14, "mirror")
        precondition(BuddyGaze.cell(direction: 16, flipped: false) == nil, "out of range")
        let now = Date()
        precondition(BuddyGaze.isActive(lastCursorMove: now.addingTimeInterval(-1.1), now: now), "moved 1.1 s ago")
        precondition(!BuddyGaze.isActive(lastCursorMove: now.addingTimeInterval(-1.2), now: now), "1.2 s → idle")
        precondition(!BuddyGaze.isActive(lastCursorMove: nil, now: now), "never moved")
    }

    // MARK: - Sizes

    static func testSizes() {
        precondition(BuddySize.medium.panelSide(isMochi: true) == 120, "Mochi Medium keeps 120 pt")
        precondition(BuddySize.large.panelSide(isMochi: true) == 160, "Mochi Large")
        precondition(BuddySize.medium.panelSide(isMochi: false) == 156, "pet Medium = 208 × 0.75")
        precondition(BuddySize.extraSmall.panelSide(isMochi: false) == 73, "pet XS")
        precondition(BuddySize.from(stored: 1.5) == .huge, "legacy 1.5 → huge")
        precondition(BuddySize.from(stored: 0.9) == .medium, "unknown → medium")
        precondition(BuddySize.from(stored: 0.35) == .extraSmall, "stored XS")
    }

    // MARK: - Geometry

    static func testGeometry() {
        let r = BuddySpriteGeometry.spriteRect(panelSide: 208)
        precondition(r == CGRect(x: 8, y: 0, width: 192, height: 208), "sprite fits height, centered")
        precondition(BuddySpriteGeometry.atlasPixel(localTopDown: CGPoint(x: 2, y: 100), panelSide: 208,
                                                    row: 0, column: 0, flipped: false) == nil, "left of sprite")
        let p = BuddySpriteGeometry.atlasPixel(localTopDown: CGPoint(x: 8, y: 0), panelSide: 208, row: 1, column: 2, flipped: false)
        precondition(p?.x == 384 && p?.y == 208, "top-left of cell (1,2)")
        let q = BuddySpriteGeometry.atlasPixel(localTopDown: CGPoint(x: 8, y: 0), panelSide: 208, row: 1, column: 2, flipped: true)
        precondition(q?.x == 384 + 191, "flipped reads the mirrored column")

        // One opaque pixel at (10,10): hit within radius 1, miss at 2
        let alpha: (Int, Int) -> UInt8? = { x, y in (x == 10 && y == 10) ? 255 : 0 }
        precondition(BuddySpriteGeometry.isOpaque(alphaAt: alpha, x: 11, y: 9), "within radius")
        precondition(!BuddySpriteGeometry.isOpaque(alphaAt: alpha, x: 12, y: 10), "outside radius")
        let faint: (Int, Int) -> UInt8? = { _, _ in 63 }
        precondition(!BuddySpriteGeometry.isOpaque(alphaAt: faint, x: 0, y: 0), "alpha 63 is below threshold")

        precondition(BuddySpriteGeometry.gazeAnchor(panelSide: 208, anchor: nil, flipped: false) == CGPoint(x: 104, y: 208), "default bottom centre")
        precondition(BuddySpriteGeometry.gazeAnchor(panelSide: 208, anchor: CGPoint(x: 0.25, y: 0.5), flipped: true) == CGPoint(x: 152, y: 104), "flipped anchor")
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

    // MARK: - Atlas

    /// A v1-sized transparent image with one opaque 4 × 4 block whose top-left is (x, y), y down.
    static func image(width: Int, height: Int, opaqueAt x: Int, _ y: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: x, y: height - y - 4, width: 4, height: 4))   // CG is y-up
        return ctx.makeImage()!
    }

    static func testAtlas() {
        let img = image(width: 1536, height: 1872, opaqueAt: 200, 10)
        let atlas = try! BuddyAtlas(image: img, layout: .v1)
        precondition(atlas.cells.count == 9 && atlas.cells.allSatisfy { $0.count == 8 }, "9 × 8 cells")
        precondition(atlas.cell(row: 0, column: 0)?.width == 192 && atlas.cell(row: 0, column: 0)?.height == 208, "cell size")
        precondition(atlas.cell(row: 9, column: 0) == nil, "no gaze rows on v1")
        precondition(atlas.alphaAt(201, 11) == 255, "alpha is read top-down")
        precondition(atlas.alphaAt(201, 1872 - 12) == 0, "not flipped")
        precondition(atlas.alphaAt(-1, 0) == nil && atlas.alphaAt(1536, 0) == nil, "outside atlas")

        // The pixel lands in cell (0, 1) at (8, 10): check the cropped cell has it at the top.
        let cell = atlas.cell(row: 0, column: 1)!
        let cctx = CGContext(data: nil, width: 192, height: 208, bitsPerComponent: 8, bytesPerRow: 192 * 4,
                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cctx.draw(cell, in: CGRect(x: 0, y: 0, width: 192, height: 208))
        let px = cctx.data!.assumingMemoryBound(to: UInt8.self)
        precondition(px[(11 * 192 + 9) * 4 + 3] == 255, "cell crop is top-down too")

        // V1 pet with a taller (V2-sized) image is fine; a short image is not; V2 needs 11 rows.
        precondition((try? BuddyAtlas(image: image(width: 1536, height: 2288, opaqueAt: 0, 0), layout: .v1)) != nil, "tall v1 ok")
        do {
            _ = try BuddyAtlas(image: image(width: 1536, height: 1872, opaqueAt: 0, 0), layout: .v2)
            preconditionFailure("v2 needs 2288")
        } catch let e as BuddyAtlas.LoadError {
            precondition(e == .tooSmall(width: 1536, height: 1872, needWidth: 1536, needHeight: 2288), "too small reported")
        } catch { preconditionFailure("unexpected") }
        precondition((try? BuddyAtlas(image: image(width: 1535, height: 1872, opaqueAt: 0, 0), layout: .v1)) == nil, "narrow refused")
    }

    // MARK: - Store (scan, import, remove) in a temporary folder

    static func writePet(_ dir: URL, id: String, folder: String? = nil, sheet: Bool = true) {
        let f = dir.appendingPathComponent(folder ?? id, isDirectory: true)
        try! FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        try! json(#"{"id":"\#(id)","displayName":"\#(id.uppercased())","description":"d","spritesheetPath":"spritesheet.webp"}"#)
            .write(to: f.appendingPathComponent("pet.json"))
        if sheet {
            // ImageIO reads by content: a PNG named .webp decodes the same way.
            let img = image(width: 1536, height: 1872, opaqueAt: 50, 50)
            let dst = CGImageDestinationCreateWithURL(f.appendingPathComponent("spritesheet.webp") as CFURL,
                                                      "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(dst, img, nil)
            precondition(CGImageDestinationFinalize(dst), "write test atlas")
        }
    }

    static func sh(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try! p.run(); p.waitUntilExit()
        return p.terminationStatus
    }

    static func testStore() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("buddy-store-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let install = root.appendingPathComponent("install")
        let codex = root.appendingPathComponent("codex")
        let incoming = root.appendingPathComponent("incoming")
        try! fm.createDirectory(at: incoming, withIntermediateDirectories: true)

        writePet(codex, id: "bravo")
        writePet(codex, id: "alpha")
        writePet(codex, id: "wrong", folder: "folder-name")   // id ≠ folder
        writePet(codex, id: "nosheet", sheet: false)
        let store = BuddyPetStore(installDir: install, searchDirs: [(codex, .codex)])
        precondition(store.pets.map(\.id) == ["alpha", "bravo"], "valid pets, sorted by name: \(store.pets.map(\.id))")
        precondition(store.skipped.count == 2, "two folders skipped with a reason")
        precondition(store.pets.allSatisfy { !$0.removable }, "codex pets are not removable")

        // Folder import
        writePet(incoming, id: "charlie")
        let c = try! store.importPackage(at: incoming.appendingPathComponent("charlie"))
        precondition(c.source == .coucou && c.removable, "imported into Coucou's folder")
        precondition(fm.fileExists(atPath: install.appendingPathComponent("charlie/pet.json").path), "pet.json copied")
        precondition(store.pets.map(\.id).contains("charlie"), "listed after import")
        do { try store.importPackage(at: incoming.appendingPathComponent("charlie")); preconditionFailure("dup") }
        catch let e as BuddyPetStore.ImportError { precondition(e == .alreadyInstalled("charlie"), "duplicate refused") }
        catch { preconditionFailure("unexpected \(error)") }
        precondition((try? store.importPackage(at: incoming.appendingPathComponent("charlie"), replace: true)) != nil, "replace")

        // An imported pet wins over the same id in another folder
        writePet(incoming, id: "alpha")
        _ = try! store.importPackage(at: incoming.appendingPathComponent("alpha"))
        precondition(store.pet(id: "alpha")?.source == .coucou, "imported copy wins")
        precondition(store.pets.filter { $0.id == "alpha" }.count == 1, "no duplicate ids")

        // Zip of a folder (ditto adds ._ AppleDouble files and the folder itself)
        writePet(incoming, id: "delta")
        extraFile(incoming.appendingPathComponent("delta/readme.txt"))
        let zip = root.appendingPathComponent("delta.zip")
        precondition(sh(["ditto", "-c", "-k", "--keepParent", incoming.appendingPathComponent("delta").path, zip.path]) == 0, "zip")
        let d = try! store.importPackage(at: zip)
        precondition(d.id == "delta", "zip import")
        let kept = try! fm.contentsOfDirectory(atPath: install.appendingPathComponent("delta").path).sorted()
        precondition(kept == ["pet.json", "spritesheet.webp"], "only the two pet files are kept: \(kept)")

        // Zip with a ../ entry is refused before anything is unpacked
        let evil = root.appendingPathComponent("evil.zip")
        precondition(sh(["python3", "-c", "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],'w'); z.writestr('../escape.txt','x'); z.close()", evil.path]) == 0, "evil zip")
        do { try store.importPackage(at: evil); preconditionFailure("evil zip imported") }
        catch let e as BuddyPetStore.ImportError { precondition(e == .unsafeZip("../escape.txt"), "unsafe entry: \(e)") }
        catch { preconditionFailure("unexpected \(error)") }
        precondition(!fm.fileExists(atPath: fm.temporaryDirectory.appendingPathComponent("escape.txt").path), "nothing escaped")

        // Not a pet
        let empty = incoming.appendingPathComponent("empty")
        try! fm.createDirectory(at: empty, withIntermediateDirectories: true)
        do { try store.importPackage(at: empty); preconditionFailure("empty imported") }
        catch let e as BuddyPetStore.ImportError { precondition(e == .notAPet, "not a pet") }
        catch { preconditionFailure("unexpected \(error)") }

        // Bad atlas: the folder is not copied
        writePet(incoming, id: "echo", sheet: false)
        try! Data("not an image".utf8).write(to: incoming.appendingPathComponent("echo/spritesheet.webp"))
        precondition((try? store.importPackage(at: incoming.appendingPathComponent("echo"))) == nil, "bad atlas refused")
        precondition(!fm.fileExists(atPath: install.appendingPathComponent("echo").path), "nothing installed")

        // Remove: only imported pets
        try! store.remove(id: "bravo")
        precondition(store.pet(id: "bravo") != nil, "codex pet untouched")
        try! store.remove(id: "charlie")
        precondition(store.pet(id: "charlie") == nil && !fm.fileExists(atPath: install.appendingPathComponent("charlie").path), "removed")

        precondition(BuddyPetStore.isSafeZipEntry("cat/pet.json"), "normal entry")
        for bad in ["/etc/passwd", "a/../../b", "..", "C:/x", "\\x"] {
            precondition(!BuddyPetStore.isSafeZipEntry(bad), "unsafe: \(bad)")
        }
    }

    static func extraFile(_ url: URL) { try! Data("hi".utf8).write(to: url) }

    // MARK: - Settings persistence

    static func testSettings() {
        let suite = "buddy-tests-\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suite)!
        defer { ud.removePersistentDomain(forName: suite) }
        let s = BuddySettings(defaults: ud)
        precondition(s.isMochi && s.size == .medium && s.cursorGaze && !s.relaxedWaiting, "defaults = Mochi, Medium")
        precondition(s.enabled && s.speechBubbles && s.spots.isEmpty, "on by default, bubbles on, no spot yet")
        s.enabled = false; s.speechBubbles = false
        s.spots = [BuddySpot(screen: "0,0,1512x982", x: 10, y: 20)]
        s.petId = "cheddar"; s.size = .large; s.setFlipped("cheddar", true); s.relaxedWaiting = true; s.cursorGaze = false
        s.setAnimation(.waving, for: .success)
        s.setAnimation(.review, for: .thinking)   // the default: not stored
        let t = BuddySettings(defaults: ud)
        precondition(t.petId == "cheddar" && t.size == .large && t.isFlipped("cheddar") && !t.isFlipped("mochi"), "persisted")
        precondition(t.relaxedWaiting && !t.cursorGaze, "toggles persisted")
        precondition(!t.enabled && !t.speechBubbles, "enabled / bubbles persisted")
        precondition(t.spots == [BuddySpot(screen: "0,0,1512x982", x: 10, y: 20)], "spots persisted")
        precondition(t.reactionOverrides == ["success": "waving"], "only real overrides stored: \(t.reactionOverrides)")
        precondition(t.animation(for: .success) == .waving && t.animation(for: .thinking) == .review, "lookup")
        t.resetReactions()
        precondition(BuddySettings(defaults: ud).reactionOverrides.isEmpty, "reset persisted")
    }

    // MARK: - The pets installed on this Mac (skipped when there are none)

    static func testRealPets() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/pets")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            print("  (no ~/.codex/pets — real-pet check skipped)")
            return
        }
        var parsed = 0
        for n in names where !n.hasPrefix(".") {
            guard let d = try? Data(contentsOf: dir.appendingPathComponent(n).appendingPathComponent("pet.json")) else { continue }
            do {
                let m = try BuddyPetManifest.parse(d)
                precondition(m.id == n, "\(n): id matches folder")
                let atlas = try BuddyAtlas.load(url: dir.appendingPathComponent(n).appendingPathComponent(m.spritesheetPath),
                                                layout: m.layout)
                // Something opaque in the first idle frame, or the pet could never be clicked.
                var opaque = 0
                for y in 0..<208 { for x in 0..<192 where (atlas.alphaAt(x, y) ?? 0) >= 64 { opaque += 1 } }
                precondition(opaque > 0, "\(n): idle frame 0 has opaque pixels")
                parsed += 1
            } catch {
                print("  \(n): \(error)")
            }
        }
        print("  parsed and decoded \(parsed) pets from ~/.codex/pets")
    }
}
