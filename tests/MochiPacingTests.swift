import Foundation

// MARK: - Mochi pacing tests (coucou-custom fork)

@main
enum MochiPacingTests {
    static var failures = 0

    static func check(_ label: String, cap: Double, display: Double, interval: TimeInterval?, steps: Int) {
        let p = MochiPacing(cap: cap, display: display)
        if p.steps != steps || p.interval != interval {
            failures += 1
            print("FAIL \(label): got interval=\(String(describing: p.interval)) steps=\(p.steps)")
        }
    }

    static func main() {
        // A display at the cap or under it is drawn every frame, one step each: as before.
        check("60 Hz, cap 60", cap: 60, display: 60, interval: nil, steps: 1)
        check("30 Hz, cap 60", cap: 60, display: 30, interval: nil, steps: 1)
        // ProMotion: a frame in two, two steps, so 120 steps a second as before.
        check("120 Hz, cap 60", cap: 60, display: 120, interval: 0.97 / 60, steps: 2)
        check("120 Hz, cap 30", cap: 30, display: 120, interval: 0.97 / 30, steps: 4)
        check("60 Hz, cap 30", cap: 30, display: 60, interval: 0.97 / 30, steps: 2)
        // A display the cap does not divide into: every frame, nothing guessed.
        check("90 Hz, cap 60", cap: 60, display: 90, interval: nil, steps: 1)
        check("144 Hz, cap 60", cap: 60, display: 144, interval: nil, steps: 1)
        check("100 Hz, cap 30", cap: 30, display: 100, interval: nil, steps: 1)
        // 240 Hz does divide: 4 steps in a frame in four.
        check("240 Hz, cap 60", cap: 60, display: 240, interval: 0.97 / 60, steps: 4)

        // What matters: the steps a second stay the display's rate (within the 3 % margin), and
        // the interval is never longer than the frames it skips (or a frame in two turns into one
        // in three).
        for (cap, display) in [(60.0, 120.0), (30.0, 120.0), (30.0, 60.0), (60.0, 240.0)] {
            let p = MochiPacing(cap: cap, display: display)
            guard let interval = p.interval else { failures += 1; print("FAIL \(cap)/\(display): no interval"); continue }
            let stepsPerSecond = Double(p.steps) / interval
            if stepsPerSecond < display || stepsPerSecond > display * 1.04 {
                failures += 1
                print("FAIL \(cap)/\(display): \(stepsPerSecond) steps a second")
            }
            if interval >= Double(p.steps) / display {
                failures += 1
                print("FAIL \(cap)/\(display): interval \(interval) is not shorter than \(p.steps) frames")
            }
        }

        if failures == 0 { print("MochiPacing: all checks passed") }
        exit(failures == 0 ? 0 : 1)
    }
}
