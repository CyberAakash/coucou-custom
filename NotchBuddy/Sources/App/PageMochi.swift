#if !APPSTORE
import SwiftUI

// MARK: - Mochi on the notch's pages (coucou-custom fork, design board 3)
//
// One Mochi per page, the real one (HubLiveMochi), reacting to what that page shows: drowsy
// when muted or dim, busy under load, dizzy past 90%, pleased with a day done, asleep on an
// empty shelf. Drawn only on the page on screen, so the pages behind it cost nothing.
// Settings → Buddy → Mochi on the notch's pages turns them all off.

struct PageMochi: View {
    var state: BotState = .idle
    var size: CGFloat = 22
    @Environment(\.islandViewActive) private var active
    @AppStorage(PageMochi.key) private var on = true

    static let key = "coucouPageMochi"

    var body: some View {
        if on && active {
            HubLiveMochi(size: size, state: state)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    /// The mood for a load from 0 to 1.
    static func load(_ value: Double) -> BotState {
        value > 0.9 ? .dizzy : (value > 0.6 ? .working : .idle)
    }
}
#endif
