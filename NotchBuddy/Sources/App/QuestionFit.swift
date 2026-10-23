import SwiftUI

// MARK: - QuestionFit (coucou-custom fork)
//
// The notch fits the question page on screen. Upstream sizes the island once, from a character
// count, for the tallest question of the set: shorter pages and the "Other…" field float in
// empty space, and a multi-select page with long options overflows and clips Send. Here the
// question card reports its real height and the island follows it as the user pages through.

struct QuestionContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension Notification.Name {
    /// QuestionLayout.height changed: the island animates to it.
    static let islandQuestionFit = Notification.Name("coucou.islandQuestionFit")
    /// BriefLayout changed: the island animates to it (coucou-custom fork, GitHub build).
    static let islandBriefFit = Notification.Name("coucou.islandBriefFit")
}

@MainActor
enum QuestionFit {
    /// Header row (34) + IslandContentView top and bottom padding (8 + 10) + room around the card.
    static let chrome: CGFloat = 34 + 8 + 10 + 14
    /// No card is shorter than home (the island's height law), none taller than its panel.
    static let minHeight: CGFloat = 160
    static let maxHeight: CGFloat = 560

    static func measured(_ contentHeight: CGFloat) {
        guard contentHeight > 0 else { return }
        let island = min(max((contentHeight + chrome).rounded(.up), minHeight), maxHeight)
        // Sub-point jitter while text lays out would restart the spring every frame.
        guard abs((QuestionLayout.height ?? 0) - island) >= 1 else { return }
        QuestionLayout.height = island
        appendAppLog("nb.log", "[Question] page fits in \(Int(island)) pt (content \(Int(contentHeight)) pt)")
        NotificationCenter.default.post(name: .islandQuestionFit, object: nil)
    }
}

extension View {
    /// Reports this view's own height (laid out at its natural size, not the island's) as the
    /// question page height.
    func reportsQuestionHeight() -> some View {
        fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { g in
                Color.clear.preference(key: QuestionContentHeightKey.self, value: g.size.height)
            })
            .onPreferenceChange(QuestionContentHeightKey.self) { h in
                Task { @MainActor in QuestionFit.measured(h) }
            }
    }
}
