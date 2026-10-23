import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Runner tests (coucou-custom fork)
// The expectations come from RunCat Neo's source (RunnerService.updateRunnerSpeed, RunnerLayer,
// CustomRunnerEditor.appendFrameImage, docs/CustomMetricsSchema.md) and the Runner Gallery's
// CONTRIBUTING.md / validate_runners.py.

@main
enum RunnerTests {
    static var failures = 0

    static func check(_ label: String, _ ok: Bool) {
        print(ok ? "✓ \(label)" : "✗ \(label)")
        if !ok { failures += 1 }
    }

    static func main() throws {
        speedTests()
        frameTests()
        galleryTests()
        try zipTests()
        metricsTests()
        formatTests()
        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("All runner tests passed")
    }

    // MARK: - Speed

    static func speedTests() {
        check("idle CPU ambles at 1", RunnerSpeed.speed(load: 0, slowerUnderLoad: false) == 1)
        check("5 % is still 1", RunnerSpeed.speed(load: 0.05, slowerUnderLoad: false) == 1)
        check("50 % runs at 10", RunnerSpeed.speed(load: 0.5, slowerUnderLoad: false) == 10)
        check("100 % sprints at 20", RunnerSpeed.speed(load: 1, slowerUnderLoad: false) == 20)
        check("above 100 % stays 20", RunnerSpeed.speed(load: 3, slowerUnderLoad: false) == 20)
        check("slower under load: idle is 10", RunnerSpeed.speed(load: 0, slowerUnderLoad: true) == 10)
        check("slower under load: full is 0.5", RunnerSpeed.speed(load: 1, slowerUnderLoad: true) == 0.5)
        check("no agents, no load", RunnerSpeed.agentLoad(working: 0) == 0)
        check("one agent, half", RunnerSpeed.agentLoad(working: 1) == 0.5)
        check("two agents, three quarters", RunnerSpeed.agentLoad(working: 2) == 0.75)
        check("many agents stay under 1", RunnerSpeed.agentLoad(working: 30) <= 1)
    }

    // MARK: - Frames

    static func frameTests() {
        check("36 × 10 is fine", RunnerFrameRules.check(width: 10, height: 36) == nil)
        check("36 × 100 is fine", RunnerFrameRules.check(width: 100, height: 36) == nil)
        check("35 high is refused", RunnerFrameRules.check(width: 40, height: 35) == .height(35))
        check("72 high (an @2x export) is refused", RunnerFrameRules.check(width: 40, height: 72) == .height(72))
        check("9 wide is refused", RunnerFrameRules.check(width: 9, height: 36) == .width(9))
        check("101 wide is refused", RunnerFrameRules.check(width: 101, height: 36) == .width(101))
        check("frames sort numerically", RunnerFrameRules.sorted(["f-10.png", "f-2.png", "f-1.png"]) == ["f-1.png", "f-2.png", "f-10.png"])
        check("loop order", RunnerPlayback.loop.order(count: 4) == [0, 1, 2, 3])
        check("bounce order is RunCat's swing", RunnerPlayback.bounce.order(count: 5) == [0, 1, 2, 3, 4, 3, 2, 1])
        check("bounce of 2 is a loop", RunnerPlayback.bounce.order(count: 2) == [0, 1])
        check("no frames, no order", RunnerPlayback.loop.order(count: 0).isEmpty)
        check("detects bounce", RunnerPlayback.detect(order: [0, 1, 2, 1], count: 3) == .bounce)
        check("detects loop", RunnerPlayback.detect(order: [0, 1, 2], count: 3) == .loop)

        let runner = CustomRunner(id: "x", name: "X", isTemplate: true, frameOrder: [0, 7, 1], frameCount: 2)
        check("order skips missing frames", runner.playableOrder == [0, 1])
        let empty = CustomRunner(id: "y", name: "Y", isTemplate: true, frameOrder: [9], frameCount: 3)
        check("an order with no valid frame falls back to all", empty.playableOrder == [0, 1, 2])
        check("unique name kept", CustomRunner.uniqueName("Deer", existing: ["Cat"]) == "Deer")
        check("unique name numbered", CustomRunner.uniqueName("Deer", existing: ["deer", "Deer 2"]) == "Deer 3")
        check("blank name becomes Runner", CustomRunner.uniqueName("  ", existing: []) == "Runner")

        // RunCat Neo's custom-runners.json decodes as ours does (frameCount comes from disk there).
        let json = #"{"id":"A","name":"N","isTemplate":false,"frameOrder":[0,1],"frameCount":2}"#
        let decoded = try? JSONDecoder().decode(CustomRunner.self, from: Data(json.utf8))
        check("runner JSON round trip", decoded?.name == "N" && decoded?.isTemplate == false && decoded?.galleryName == nil)
    }

    // MARK: - Gallery

    static func galleryTests() {
        check("gallery names", RunnerGallery.isValidName("border-collie") && RunnerGallery.isValidName("dots"))
        check("no traversal in names", !RunnerGallery.isValidName("../etc") && !RunnerGallery.isValidName("a/b"))
        check("no capitals or trailing hyphen", !RunnerGallery.isValidName("Deer") && !RunnerGallery.isValidName("deer-"))
        check("frames URL", RunnerGallery.framesURL("deer").absoluteString
              == "https://raw.githubusercontent.com/runcat-dev/RunnerGallery/main/runners/deer/deer-frames.zip")
        let manifest = #"{"runners":["beagle","../x","deer"]}"#
        check("manifest drops bad names", RunnerGallery.decodeManifest(Data(manifest.utf8)) == ["beagle", "deer"])
        let meta = #"{"author":"Takuto Nakamura (Kyome22)","displayName":"Deer","type":"monochrome","tags":["animal"]}"#
        let m = RunnerGallery.decodeMetadata(Data(meta.utf8))
        check("metadata decodes", m?.displayName == "Deer" && m?.isTemplate == true)
        if let m {
            check("tag filter", RunnerGallery.matches(m, tag: "animal", query: "") && !RunnerGallery.matches(m, tag: "dog", query: ""))
            check("search by author", RunnerGallery.matches(m, tag: nil, query: "kyome"))
            check("search misses", !RunnerGallery.matches(m, tag: nil, query: "robot"))
        }
        let color = #"{"author":"a","displayName":"b","type":"color","tags":[]}"#
        check("color runners are not templates", RunnerGallery.decodeMetadata(Data(color.utf8))?.isTemplate == false)
        check("oversized metadata refused", RunnerGallery.decodeMetadata(Data(repeating: 32, count: 5000)) == nil)
    }

    // MARK: - Zip

    static func png(width: Int, height: Int) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 2, y: 2, width: width - 4, height: height - 4))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    static func run(_ tool: String, _ args: [String], in dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.currentDirectoryURL = dir
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
    }

    static func zipTests() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("runner-zip-\(UUID().uuidString)")
        let frames = dir.appendingPathComponent("toy-frames")
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in [0, 1, 2, 10] {
            try png(width: 30, height: 36).write(to: frames.appendingPathComponent("toy-frame-\(i).png"))
        }
        try Data("junk".utf8).write(to: frames.appendingPathComponent(".DS_Store"))
        try Data("notes".utf8).write(to: frames.appendingPathComponent("readme.txt"))
        // Deflated, as `zip -r` makes the gallery's archives.
        try run("/usr/bin/zip", ["-qr", "deflate.zip", "toy-frames"], in: dir)
        try run("/usr/bin/zip", ["-qr0", "store.zip", "toy-frames"], in: dir)

        for kind in ["deflate", "store"] {
            let data = try Data(contentsOf: dir.appendingPathComponent("\(kind).zip"))
            let entries = try RunnerZip.pngEntries(data)
            check("\(kind): only the 4 PNGs", entries.count == 4)
            check("\(kind): numeric order", entries.map(\.name) == ["toy-frame-0.png", "toy-frame-1.png", "toy-frame-2.png", "toy-frame-10.png"])
            check("\(kind): bytes intact", entries.first?.data == (try? Data(contentsOf: frames.appendingPathComponent("toy-frame-0.png"))))
        }

        // Two folders, one file name in each: both frames stay (not the first one twice).
        for sub in ["a", "b"] {
            let folder = dir.appendingPathComponent("twins/\(sub)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png(width: sub == "a" ? 20 : 40, height: 36).write(to: folder.appendingPathComponent("x-frame-1.png"))
        }
        try run("/usr/bin/zip", ["-qr", "twins.zip", "twins"], in: dir)
        let twins = try RunnerZip.pngEntries(try Data(contentsOf: dir.appendingPathComponent("twins.zip")))
        check("same name in two folders: both kept", twins.count == 2 && twins[0].data != twins[1].data)

        check("not a zip", (try? RunnerZip.pngEntries(Data("hello".utf8))) == nil)
        check("oversized archive refused", throwsFailure(.tooLarge) { try RunnerZip.pngEntries(Data(count: RunnerZip.maxArchiveBytes + 1)) })
        check("traversal is unsafe", !RunnerZip.isSafe("../x.png") && !RunnerZip.isSafe("/abs.png") && RunnerZip.isSafe("a/b.png"))
        check("Finder junk", RunnerZip.isJunk("__MACOSX/a/._x.png") && RunnerZip.isJunk("a/.DS_Store") && !RunnerZip.isJunk("a/x.png"))

        // A real gallery archive, when the test script was given one.
        if let path = ProcessInfo.processInfo.environment["RUNNER_GALLERY_ZIP"],
           let data = FileManager.default.contents(atPath: path) {
            let entries = (try? RunnerZip.pngEntries(data)) ?? []
            check("gallery zip opens (\(entries.count) frames)", !entries.isEmpty)
            let sizes = entries.compactMap { e -> (Int, Int)? in
                guard let src = CGImageSourceCreateWithData(e.data as CFData, nil),
                      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
                return (img.width, img.height)
            }
            check("gallery frames all decode", sizes.count == entries.count)
            check("gallery frames pass the rules", sizes.allSatisfy { RunnerFrameRules.check(width: $0.0, height: $0.1) == nil })
        }
    }

    static func throwsFailure(_ expected: RunnerZip.Failure, _ body: () throws -> Any) -> Bool {
        do { _ = try body(); return false } catch let f as RunnerZip.Failure { return f == expected } catch { return false }
    }

    // MARK: - Custom Metrics

    static func metricsTests() {
        // The schema document's own example.
        let example = """
        {"title":"Claude Code","symbol":"staroflife","metricsBarValue":"5.4%","metrics":[
          {"title":"Model","formattedValue":"Opus 4.7"},
          {"title":"Context","formattedValue":"5.4%","normalizedValue":0.054},
          {"title":"5h","formattedValue":"16.4%","normalizedValue":0.164},
          {"title":"7d","formattedValue":"1.0%","normalizedValue":0.01}],
         "lastUpdatedDate":"2026-06-05T04:50:40Z"}
        """
        let s = try? MetricsSnapshot.decode(Data(example.utf8))
        check("schema example decodes", s?.title == "Claude Code" && s?.metrics.count == 4)
        check("text-only row has no bar", s?.metrics.first?.bar == nil)
        check("bar value kept", s?.metrics[1].bar == 0.054)
        check("menu bar value", s?.menuBarText == "5.4%")
        check("date parsed", s?.lastUpdatedDate == Date(timeIntervalSince1970: 1_780_635_040))

        let minimal = #"{"title":"T","metrics":[],"lastUpdatedDate":"2026-06-05T04:50:40.250Z"}"#
        let m = try? MetricsSnapshot.decode(Data(minimal.utf8))
        check("fractional seconds accepted", m != nil)
        check("empty metrics allowed", m?.metrics.isEmpty == true)
        check("missing metricsBarValue shows ---", m?.menuBarText == "---")
        check("missing symbol is nil (default drawn)", m?.symbol == nil)

        let clamp = #"{"title":"T","metrics":[{"title":"a","formattedValue":"x","normalizedValue":1.7},{"title":"b","formattedValue":"y","normalizedValue":-2}],"lastUpdatedDate":"2026-06-05T04:50:40Z"}"#
        let c = try? MetricsSnapshot.decode(Data(clamp.utf8))
        check("bars clamp to 0…1", c?.metrics[0].bar == 1 && c?.metrics[1].bar == 0)

        func failure(_ json: String) -> MetricsSnapshot.Failure? {
            do { _ = try MetricsSnapshot.decode(Data(json.utf8)); return nil } catch let f as MetricsSnapshot.Failure { return f } catch { return nil }
        }
        check("missing title named", failure(#"{"metrics":[],"lastUpdatedDate":"2026-06-05T04:50:40Z"}"#) == .invalid("Missing “title”."))
        check("missing date named", failure(#"{"title":"T","metrics":[]}"#) == .invalid("Missing “lastUpdatedDate”."))
        check("comments are not JSON", failure("{\"title\":\"T\", // no\n\"metrics\":[],\"lastUpdatedDate\":\"2026-06-05T04:50:40Z\"}") != nil)
        // A trailing comma is not checked: Foundation's JSONDecoder accepts one, in RunCat Neo too.
        check("bad date refused", failure(#"{"title":"T","metrics":[],"lastUpdatedDate":"yesterday"}"#) != nil)
        check("wrong type named", failure(#"{"title":"T","metrics":[{"title":"a","formattedValue":3}],"lastUpdatedDate":"2026-06-05T04:50:40Z"}"#)
              == .invalid("Wrong type at “metrics.[0].formattedValue”."))
        check("too large refused", failure(String(repeating: " ", count: MetricsSnapshot.maxBytes + 1)) == .tooLarge)
    }

    // MARK: - Formatting

    static func formatTests() {
        check("percent", MetricsFormat.percent(0.424) == "42%" && MetricsFormat.percent(1.5) == "100%")
        check("rate B/s", MetricsFormat.rate(512) == "512 B/s")
        check("rate KB/s", MetricsFormat.rate(12_400) == "12 KB/s")
        check("rate MB/s", MetricsFormat.rate(3_250_000) == "3.2 MB/s" || MetricsFormat.rate(3_250_000) == "3.3 MB/s")
        check("counter reset gives no rate", MetricsFormat.rate(from: 100, to: 50, seconds: 3) == nil)
        check("rate from counters", MetricsFormat.rate(from: 0, to: 3000, seconds: 3) == 1000)
        let now = Date(timeIntervalSince1970: 10_000)
        check("ago: just now", MetricsFormat.ago(now.addingTimeInterval(-20), now: now) == "just now")
        check("ago: minutes", MetricsFormat.ago(now.addingTimeInterval(-180), now: now) == "3 min ago")
        check("ago: hours", MetricsFormat.ago(now.addingTimeInterval(-7300), now: now) == "2 h ago")
        var h = MetricsHistory(length: 3)
        [1, 2, 3, 4].forEach { h.append($0) }
        check("history keeps the last ones", h.values == [2, 3, 4])
    }
}
