import SwiftUI

// MARK: - ChatFit (coucou-custom fork)
//
// The notch chat's height follows the conversation instead of upstream's guess
// (min(300, 240 + 40 per message), which also grew for an empty streaming placeholder and left
// ~140 pt for messages). The message list and the composer report their real heights; the island
// is header + paddings + both, clamped to 180…520 pt (the panel is 560). One value, read by every
// place that used to repeat the formula (hit test, hover frame, Mochi's eyes, voice caption).

/// Readable from nonisolated code (islandSize, hit tests). Written on the main actor only.
enum ChatLayout {
    nonisolated(unsafe) static var height: CGFloat = 200
    /// The chat is wider than the other expanded views (panel is 720).
    static let width: CGFloat = 700
}

struct ChatMessagesHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct ChatComposerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension Notification.Name {
    static let islandChatFit = Notification.Name("coucou.islandChatFit")
}

@MainActor
enum ChatFit {
    static let minHeight: CGFloat = 180
    static let maxHeight: CGFloat = 520
    /// Header (34) + IslandContentView padding (8 + 10) + card padding (10 + 12) + outer bottom
    /// padding (10) + the gap between the list and the composer (8).
    static let chrome: CGFloat = 34 + 18 + 22 + 10 + 8

    private static var messages: CGFloat = 0
    private static var composer: CGFloat = 70

    static func update(messages m: CGFloat? = nil, composer c: CGFloat? = nil) {
        if let m { messages = m }
        if let c, c > 0 { composer = c }
        let target = min(max((chrome + messages + composer).rounded(.up), minHeight), maxHeight)
        // Streaming text changes the height every few characters: move in steps, not per glyph.
        let atLimit = target == maxHeight || target == minHeight
        guard abs(target - ChatLayout.height) >= (atLimit ? 1 : 8) else { return }
        ChatLayout.height = target
        NotificationCenter.default.post(name: .islandChatFit, object: nil)
    }
}

extension View {
    func reportsHeight<K: PreferenceKey>(_ key: K.Type) -> some View where K.Value == CGFloat {
        background(GeometryReader { g in Color.clear.preference(key: key, value: g.size.height) })
    }
}

// MARK: - Sources

enum ChatSources {
    /// Splits a reply ending in a "Sources:" list (the CLI's web search adds one) so the list can
    /// collapse. Same marker ClaudeCodeVoice strips before speaking.
    static func split(_ text: String) -> (body: String, sources: String, count: Int)? {
        guard let r = text.range(of: #"\n\s*\**Sources\**:?\**\s*\n"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let sources = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let count = sources.split(separator: "\n").filter { $0.contains("http") || $0.contains("](") }.count
        guard count > 0 else { return nil }
        return (String(text[..<r.lowerBound]), sources, count)
    }
}
