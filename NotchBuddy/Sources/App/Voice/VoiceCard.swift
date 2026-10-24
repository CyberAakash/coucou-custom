import SwiftUI

extension Notification.Name {
    /// Both builds know the name; only the GitHub build posts it (the voice card is Mac-only).
    static let islandVoiceFit = Notification.Name("coucou.islandVoiceFit")
}

#if !APPSTORE
// MARK: - VoiceCardLayout (coucou-custom fork)

/// The voice card is the island itself, sized to its answer (like the briefs' card and the chat):
/// one surface for listening, the answer and, later, the agent cards. Not actor-bound: the
/// island's size function runs wherever it is called, like the briefs' layout.
enum VoiceCardLayout {
    static let width: CGFloat = 560
    static let corner: CGFloat = 26
    static let minHeight: CGFloat = 132
    static let maxHeight: CGFloat = 340
    /// Top and bottom padding around the measured content.
    static let chrome: CGFloat = 30
    nonisolated(unsafe) static var height: CGFloat = 150

    static func applies(to view: IslandView) -> Bool {
        (view == .voiceResult || view == .listening) && VoiceSettings.replyInNotch
    }

    @MainActor static func update(contentHeight: CGFloat) {
        let target = min(max((contentHeight + chrome).rounded(.up), minHeight), maxHeight)
        guard abs(target - height) >= 4 else { return }
        height = target
        NotificationCenter.default.post(name: .islandVoiceFit, object: nil)
    }
}

struct VoiceCardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - VoiceCardView

/// What I said, Mochi's answer, and the waves while it listens or talks. Mochi himself is drawn
/// by BotCanvasView on the left (viewLayouts botX).
struct VoiceCardView: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var caption = VoiceCaptionManager.shared.state
    @ObservedObject private var engine = VoiceEngine.shared

    private var heard: String {
        if caption.isListening, !caption.liveLine.isEmpty { return caption.liveLine }
        return caption.userLine
    }
    private var answer: String {
        caption.responseLine.isEmpty ? (state.voiceResult?.message ?? "") : caption.responseLine
    }
    private var status: String {
        switch state.voiceSubState {
        case .listening: return heard.isEmpty || caption.isListening
            ? VoiceActionRunner.localizedString("voice.caption-listening", locale: VoiceSettings.answerLocale) : ""
        case .thinking: return String(localized: "voice.card.thinking", defaultValue: "Thinking…")
        case .speaking: return ""
        case .none: return ""
        }
    }

    var body: some View {
        ZStack {
            CardBackground(wash: state.voiceResult?.outcome == .failure ? .red : .cyan)
            VoiceGlowRim(cornerRadius: VoiceCardLayout.corner)

            HStack(spacing: 0) {
                Spacer().frame(width: 110)   // Mochi lives here (BotCanvasView)
                VStack(alignment: .leading, spacing: 8) {
                    if !heard.isEmpty {
                        Text(verbatim: heard)
                            .font(.system(size: 12.5))
                            .foregroundColor(Color.white.opacity(0.55))
                            .lineLimit(2)
                            .truncationMode(.head)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !answer.isEmpty { answerText }
                    HStack(spacing: 10) {
                        VoiceWaveView(compact: false).frame(height: 26)
                        if !status.isEmpty {
                            Text(verbatim: status)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(Color(hex: "#8E939C"))
                                .fixedSize()
                        }
                    }
                    .frame(height: 26)
                }
                .padding(.trailing, 20)
                .padding(.vertical, 2)
                .reportsHeight(VoiceCardHeightKey.self)
                Spacer(minLength: 0)
            }
        }
        .onPreferenceChange(VoiceCardHeightKey.self) { h in VoiceCardLayout.update(contentHeight: h) }
    }

    @ViewBuilder private var answerText: some View {
        let text = Text(verbatim: answer)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(Color(hex: "#F5F6F8"))
            .fixedSize(horizontal: false, vertical: true)
        if answer.count > 420 {
            ScrollView(.vertical, showsIndicators: false) { text }.frame(maxHeight: 200)
        } else {
            text
        }
    }
}
#endif
