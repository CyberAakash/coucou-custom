import Foundation

// How a Mochi canvas capped at `cap` frames a second is drawn on a `display` Hz screen (see
// MochiFrameClock). Pure Foundation so the rule compiles into a standalone test.

struct MochiPacing: Equatable {
    /// TimelineView's minimumInterval; nil draws every display frame.
    let interval: TimeInterval?
    /// Engine steps to run in each drawn frame: the frames the interval skips.
    let steps: Int

    init(cap: Double, display: Double) {
        let ratio = (display / cap).rounded()
        // A display at or under the cap, or one that does not divide by it: every frame and
        // one step, exactly as before.
        guard ratio >= 2, abs(display / cap - ratio) < 0.1 else {
            interval = nil
            steps = 1
            return
        }
        // 3 % short of the cap's period. An interval of exactly 1/60 s skipped every other
        // display frame (30 fps on a 60 Hz screen), as frames come with jitter; on a
        // variable-refresh display a tick comes one interval after the last, so a longer
        // margin made Mochi's steps run faster than the display's rate (10 %: 133 a second
        // on 120 Hz). The steps are a whole number, never measured from the time between
        // renders (see MochiFrameClock.advance).
        interval = 0.97 / cap
        steps = Int(ratio)
    }
}
