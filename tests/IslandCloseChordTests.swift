import Foundation

@main
enum IslandCloseChordTests {
    static var failures = 0
    static func check(_ label: String, _ ok: Bool) { if !ok { failures += 1; print("FAIL \(label)") } }

    static func main() {
        var d = DoubleTapDetector(interval: 0.45)
        check("first tap alone", d.tap(at: 10.0) == false)
        check("second tap within the gap", d.tap(at: 10.3) == true)
        check("pair consumed: third tap starts over", d.tap(at: 10.5) == false)
        check("too slow", d.tap(at: 11.5) == false)
        check("exactly at the limit counts", d.tap(at: 11.95) == true)
        var q = DoubleTapDetector(interval: 0.3)
        _ = q.tap(at: 0); check("quick: 0.4 s is too slow", q.tap(at: 0.4) == false)
        check("quick: then 0.2 s later", q.tap(at: 0.6) == true)
        var c = DoubleTapDetector(interval: 0.45)
        _ = c.tap(at: 5); check("clock going backwards is not a double tap", c.tap(at: 4.9) == false)
        check("speeds keep their order", IslandCloseChord.Speed.quick.interval < IslandCloseChord.Speed.normal.interval
              && IslandCloseChord.Speed.normal.interval < IslandCloseChord.Speed.relaxed.interval)
        if failures == 0 { print("IslandCloseChordTests: all passed") } else { exit(1) }
    }
}
