#if !APPSTORE
import SwiftUI

// coucou-custom fork: the full-screen frame the Daily brief and the Weekly recap share — progress
// ticks, a title and a date, one card at a time (click, ←/→, Space or Return to move, Esc to close),
// optional auto-advance.

@MainActor
final class BriefStory: ObservableObject {
    let count: Int
    let autoAdvance: Int
    @Published var index = 0
    @Published var cardStart = Date()
    private var timer: Timer?

    init(count: Int, autoAdvance: Int) {
        self.count = max(1, count)
        self.autoAdvance = autoAdvance
        arm()
    }

    /// False at the last card.
    @discardableResult
    func next() -> Bool {
        guard index + 1 < count else { return false }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { index += 1 }
        cardStart = Date()
        arm()
        return true
    }

    func previous() {
        guard index > 0 else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { index -= 1 }
        cardStart = Date()
        arm()
    }

    private func arm() {
        timer?.invalidate()
        timer = nil
        guard autoAdvance > 0, index + 1 < count else { return }
        let t = Timer(timeInterval: TimeInterval(autoAdvance), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// The overlay's keys: Esc closes, → Space Return go on (closing at the end), ← goes back.
    func handle(_ event: NSEvent, close: () -> Void) -> Bool {
        switch event.keyCode {
        case 53: close(); return true
        case 124, 49, 36: if !next() { close() }; return true
        case 123: previous(); return true
        default: return false
        }
    }
}

struct BriefStoryFrame<Card: View>: View {
    @ObservedObject var story: BriefStory
    let title: String
    let date: String
    let close: () -> Void
    @ViewBuilder let card: (Int) -> Card

    static var size: CGSize { CGSize(width: 720, height: 560) }

    var body: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                ticks
                HStack {
                    Text(title).font(.system(size: 12.5, weight: .bold))
                    Text(date).font(.system(size: 12.5)).foregroundColor(HubTheme.muted)
                    Spacer()
                    Text("\(story.index + 1) of \(story.count)").font(.system(size: 12).monospacedDigit()).foregroundColor(HubTheme.muted)
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundColor(HubTheme.secondary)
                            .frame(width: 22, height: 22).background(Circle().fill(Color.white.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 6)
                }
                ZStack {
                    ForEach(0..<story.count, id: \.self) { i in
                        if i == story.index {
                            card(i)
                                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 30)),
                                                        removal: .opacity.combined(with: .offset(x: -30))))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
                .onTapGesture { if !story.next() { close() } }
            }
            .padding(22)
            .frame(width: Self.size.width, height: Self.size.height)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(hex: "#0E0F11").opacity(0.96)))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 20)

            HStack(spacing: 14) {
                hint(["←", "→"], "Move")
                hint(["Esc"], "Close")
            }
        }
        .foregroundColor(HubTheme.text)
    }

    private var ticks: some View {
        HStack(spacing: 4) {
            ForEach(0..<story.count, id: \.self) { i in
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        if i < story.index {
                            Capsule().fill(Color.white.opacity(0.85))
                        } else if i == story.index {
                            if story.autoAdvance > 0 {
                                TimelineView(.animation) { ctx in
                                    let k = min(1, ctx.date.timeIntervalSince(story.cardStart) / Double(story.autoAdvance))
                                    Capsule().fill(Color.white.opacity(0.85)).frame(width: g.size.width * k)
                                }
                            } else {
                                Capsule().fill(Color.white.opacity(0.85))
                            }
                        }
                    }
                }
                .frame(height: 3)
            }
        }
    }

    private func hint(_ keys: [String], _ what: String) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                Text(k).font(.system(size: 10.5, weight: .bold)).padding(.horizontal, 6).frame(height: 18)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.12)))
            }
            Text(what).font(.system(size: 11.5)).foregroundColor(HubTheme.secondary)
        }
    }
}

/// Where a brief shows.
enum BriefPlace: String, CaseIterable, Identifiable {
    case notch, fullScreen
    var id: String { rawValue }
    var label: String { self == .notch ? "In the notch" : "Full screen" }
}
#endif
