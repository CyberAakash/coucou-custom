#if !APPSTORE
import SwiftUI

// MARK: - VoiceCardsView (coucou-custom fork)
// The cards under Mochi's answer in the voice card: results to open, a question's choices, a
// task to approve by click, a session's progress, an image.
struct VoiceCardsView: View {
    let cards: [VoiceCard]
    @ObservedObject private var live = LiveSessions.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(cards) { card in
                switch card.kind {
                case .answer:   answer(card)
                case .items:    items(card)
                case .confirm:  confirm(card)
                case .progress: progress(card)
                case .question: question(card)
                case .preview:  preview(card)
                }
            }
        }
    }

    // MARK: Kinds

    private func answer(_ c: VoiceCard) -> some View {
        box {
            if let t = c.title { Text(verbatim: t).font(.system(size: 12.5, weight: .semibold)).foregroundColor(Self.text) }
            if let body = c.text { Text(verbatim: body).font(.system(size: 12)).foregroundColor(Self.body).fixedSize(horizontal: false, vertical: true) }
            if let url = c.url { link(url, label: URL(string: url)?.host ?? url) }
        }
    }

    private func items(_ c: VoiceCard) -> some View {
        box {
            if let t = c.title { Text(verbatim: t).font(.system(size: 12.5, weight: .semibold)).foregroundColor(Self.text) }
            ForEach(Array(c.items.enumerated()), id: \.element.id) { i, item in
                HStack(alignment: .center, spacing: 10) {
                    Text(verbatim: "\(i + 1)").font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(Self.muted).frame(width: 14)
                    if let img = item.imageURL, let url = URL(string: img) {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image { image.resizable().scaledToFill() } else { Color.white.opacity(0.06) }
                        }
                        .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: item.title).font(.system(size: 12.5, weight: .medium)).foregroundColor(Self.text).lineLimit(2)
                        HStack(spacing: 6) {
                            if let d = item.detail { Text(verbatim: d).font(.system(size: 11.5)).foregroundColor(Self.accent) }
                            if let s = item.source { Text(verbatim: s).font(.system(size: 11)).foregroundColor(Self.muted) }
                        }
                    }
                    Spacer(minLength: 4)
                    if let url = item.url, let u = URL(string: url) {
                        Button { NSWorkspace.shared.open(u) } label: { Image(systemName: "arrow.up.right.square").font(.system(size: 13)) }
                            .buttonStyle(.plain).foregroundColor(Self.accent).help(url)
                    }
                }
            }
        }
    }

    private func confirm(_ c: VoiceCard) -> some View {
        box(stroke: Self.accent.opacity(0.6)) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").font(.system(size: 11)).foregroundColor(Self.accent)
                Text(verbatim: c.title ?? "Approve?").font(.system(size: 12.5, weight: .semibold)).foregroundColor(Self.text)
            }
            if let body = c.text { Text(verbatim: body).font(.system(size: 12)).foregroundColor(Self.body).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 8) {
                Button("Approve") { VoiceAgentTools.approve(c) }.buttonStyle(CardButton(primary: true))
                Button("Cancel") { AppState.shared.voiceCards.removeAll { $0.id == c.id } }.buttonStyle(CardButton(primary: false))
                Text(verbatim: "Click only; voice never approves.").font(.system(size: 10.5)).foregroundColor(Self.muted)
            }
        }
    }

    private func progress(_ c: VoiceCard) -> some View {
        let session = live.session(c.sessionID)
        return box {
            HStack(spacing: 6) {
                Circle().fill(Self.statusColor(session?.status)).frame(width: 7, height: 7)
                Text(verbatim: c.title ?? "Task").font(.system(size: 12.5, weight: .semibold)).foregroundColor(Self.text)
                Text(verbatim: Self.statusLabel(session?.status)).font(.system(size: 11.5)).foregroundColor(Self.muted)
                Spacer(minLength: 4)
                Button("Open terminal") {
                    TerminalFocus.open(session) { TerminalFocus.openDefaultTerminal() }
                }.buttonStyle(CardButton(primary: false))
            }
            if let step = session?.currentStep, !step.isEmpty, session?.status == .working {
                Text(verbatim: step).font(.system(size: 11.5)).foregroundColor(Self.body).lineLimit(2)
            } else if let final = session?.finalMessage, !final.isEmpty {
                Text(verbatim: final).font(.system(size: 11.5)).foregroundColor(Self.body).lineLimit(4).fixedSize(horizontal: false, vertical: true)
            } else if session == nil {
                Text(verbatim: "Starting… the session shows here once its first hook arrives.").font(.system(size: 11.5)).foregroundColor(Self.muted)
            }
            if let todos = session?.todos, !todos.isEmpty {
                let done = todos.filter { $0.status == "completed" }.count
                Text(verbatim: "\(done)/\(todos.count) steps").font(.system(size: 11)).foregroundColor(Self.muted)
            }
        }
    }

    private func question(_ c: VoiceCard) -> some View {
        box {
            if let t = c.title ?? c.text { Text(verbatim: t).font(.system(size: 12.5, weight: .semibold)).foregroundColor(Self.text).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 8) {
                ForEach(c.choices, id: \.self) { choice in
                    Button(choice) {
                        // Answers like a spoken reply: the controller runs it as the next turn.
                        AppState.shared.voiceCards.removeAll { $0.id == c.id }
                        VoiceEngine.shared.cancelListening()
                        NotificationCenter.default.post(name: .voiceFinished, object: choice as NSString)
                    }.buttonStyle(CardButton(primary: false))
                }
            }
        }
    }

    private func preview(_ c: VoiceCard) -> some View {
        box {
            if let t = c.title { Text(verbatim: t).font(.system(size: 12.5, weight: .semibold)).foregroundColor(Self.text) }
            if let img = c.imageURL, let url = URL(string: img) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFit() } else { Color.white.opacity(0.06) }
                }
                .frame(maxHeight: 140).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if let body = c.text { Text(verbatim: body).font(.system(size: 12)).foregroundColor(Self.body).fixedSize(horizontal: false, vertical: true) }
            if let url = c.url { link(url, label: URL(string: url)?.host ?? url) }
        }
    }

    // MARK: Pieces

    private static let text = Color(hex: "#F5F6F8"), body = Color(hex: "#C8CBD0"), muted = Color(hex: "#8E939C"), accent = Color(hex: "#F97316")

    private func box<Content: View>(stroke: Color = Color.white.opacity(0.07), @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(stroke))
    }

    private func link(_ url: String, label: String) -> some View {
        Button { if let u = URL(string: url) { NSWorkspace.shared.open(u) } } label: {
            Label(label, systemImage: "link").font(.system(size: 11.5)).foregroundColor(Self.accent)
        }.buttonStyle(.plain)
    }

    private static func statusColor(_ s: SessionTracker.Status?) -> Color {
        switch s {
        case .working, .background: return Color(hex: "#F5A524")
        case .waiting: return Color(hex: "#F472B6")
        case .finished: return Color(hex: "#34D399")
        case .failed: return Color(hex: "#F4505E")
        case .idle, nil: return muted
        }
    }
    private static func statusLabel(_ s: SessionTracker.Status?) -> String {
        switch s {
        case .working: return "working"
        case .background: return "finishing up"
        case .waiting: return "waiting for you in the notch"
        case .finished: return "done"
        case .failed: return "failed"
        case .idle: return "starting"
        case nil: return "starting"
        }
    }
}

struct CardButton: ButtonStyle {
    var primary: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundColor(primary ? Color(hex: "#170C04") : Color(hex: "#F5F6F8"))
            .padding(.horizontal, 10).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(primary ? Color(hex: "#F97316") : Color.white.opacity(0.1)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
#endif
