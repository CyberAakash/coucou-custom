#if !APPSTORE
import SwiftUI

// coucou-custom fork: the Daily brief and the Weekly recap in the notch. Each card is as tall as
// what it has to say (BriefFit, as QuestionFit does for questions), up to a limit: a header, the
// greeting or the week in a line, the numbers as tiles, then its buttons.


/// Readable from the nonisolated `islandSize`, as QuestionLayout is; written on the main actor only.
enum BriefLayout {
    nonisolated(unsafe) private static var heights: [IslandView: CGFloat] = [:]

    static func height(for view: IslandView) -> CGFloat? { heights[view] }

    /// Header row (34) + IslandContentView padding (8 + 10) + room around the card, as QuestionFit.
    static let chrome: CGFloat = 34 + 8 + 10 + 14
    static let minHeight: CGFloat = 160
    static let maxHeight: CGFloat = 420

    @MainActor
    static func measured(_ contentHeight: CGFloat, for view: IslandView) {
        guard contentHeight > 0 else { return }
        let island = min(max((contentHeight + chrome).rounded(.up), minHeight), maxHeight)
        guard abs((heights[view] ?? 0) - island) >= 1 else { return }
        heights[view] = island
        NotificationCenter.default.post(name: .islandBriefFit, object: nil)
    }
}

private struct BriefHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private extension View {
    func reportsBriefHeight(_ view: IslandView) -> some View {
        fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { g in Color.clear.preference(key: BriefHeightKey.self, value: g.size.height) })
            .onPreferenceChange(BriefHeightKey.self) { h in
                Task { @MainActor in BriefLayout.measured(h, for: view) }
            }
    }
}

/// One number: its icon, the value, a label.
private struct NotchTile: View {
    let symbol: String
    let value: String
    let label: String
    var tint: Color = Color(hex: "#C9CBD1")

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundColor(tint)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.16)))
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.system(size: 13.5, weight: .bold).monospacedDigit()).foregroundColor(Color(hex: "#F1F2F4"))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(label).font(.system(size: 9.5)).foregroundColor(Color(hex: "#8E939C")).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.055)))
    }
}

private struct NotchTag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text.uppercased()).font(.system(size: 9.5, weight: .heavy)).tracking(0.8).foregroundColor(tint)
            .padding(.horizontal, 7).frame(height: 18)
            .background(Capsule().fill(tint.opacity(0.16)))
    }
}

private let notchColumns = [GridItem(.adaptive(minimum: 116), spacing: 6, alignment: .leading)]

// MARK: - Daily

struct DailyBriefNotchCard: View {
    @ObservedObject var state: AppState
    @ObservedObject private var model = BriefNotchModel.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            CardBackground(wash: .amber)
            content
                .padding(.leading, 116)
                .padding(.trailing, 16)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .reportsBriefHeight(.dailyBrief)
        }
    }

    @ViewBuilder private var content: some View {
        if let b = model.daily {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    NotchTag(text: "Daily brief", tint: Color(hex: "#F7B32B"))
                    Text(b.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.system(size: 10.5)).foregroundColor(Color(hex: "#8E939C"))
                    Spacer(minLength: 6)
                    if let w = b.weather {
                        HStack(spacing: 5) {
                            Image(systemName: DailyBriefWeather.symbol(w.code)).symbolRenderingMode(.multicolor)
                            Text("\(w.now)°").font(.system(size: 11, weight: .bold))
                            Text("\(w.high)° / \(w.low)°").font(.system(size: 10.5)).foregroundColor(Color(hex: "#8E939C"))
                        }
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#E1E3E6"))
                        .padding(.horizontal, 8).frame(height: 20)
                        .background(Capsule().fill(Color.white.opacity(0.07)))
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(b.greeting).font(.system(size: 17, weight: .bold)).foregroundColor(Color(hex: "#F5F6F8"))
                    Text(b.headline).font(.system(size: 12)).foregroundColor(Color(hex: "#B5B9C0"))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                LazyVGrid(columns: notchColumns, alignment: .leading, spacing: 6) {
                    if let w = b.work, !w.isEmpty {
                        NotchTile(symbol: "hammer.fill", value: DailyBriefText.duration(minutes: w.minutes), label: "with agents", tint: Color(hex: "#FB923C"))
                        NotchTile(symbol: "terminal.fill", value: "\(w.sessions)", label: w.sessions == 1 ? "session" : "sessions", tint: Color(hex: "#FB923C"))
                        NotchTile(symbol: "doc.text.fill", value: "\(w.filesChanged)", label: "files changed", tint: Color(hex: "#3B9EFF"))
                        NotchTile(symbol: "plus.forwardslash.minus", value: "+\(w.linesAdded.formatted())", label: "−\(w.linesRemoved.formatted()) lines", tint: Color(hex: "#34D399"))
                    }
                    if let water = b.water {
                        NotchTile(symbol: "drop.fill", value: "\(DailyBriefText.water(water.ml))", label: "of \(DailyBriefText.water(water.goal)) water", tint: Color(hex: "#22D3EE"))
                    }
                    if let d = b.diary, d.focusSessions > 0 {
                        NotchTile(symbol: "brain.head.profile", value: "\(d.focusSessions)", label: "focus · \(DailyBriefText.duration(minutes: d.focusMinutes))", tint: Color(hex: "#818CF8"))
                    }
                    if let s = b.plan?.session {
                        NotchTile(symbol: "staroflife.fill", value: "\(Int(s.percent.rounded()))%", label: "session used", tint: Color(hex: "#E07950"))
                    }
                    if let cpu = b.mac?.averageCPU {
                        NotchTile(symbol: "cpu", value: MetricsFormat.percent(cpu), label: "average CPU", tint: Color(hex: "#A78BFA"))
                    }
                    if let next = b.events.first(where: { $0.end > Date() }) {
                        NotchTile(symbol: "calendar", value: next.allDay ? "Today" : next.start.formatted(.dateTime.hour().minute()), label: next.title, tint: Color(hex: "#F472B6"))
                    }
                }
                HStack(spacing: 8) {
                    if b.readStreak > 1 {
                        Label("\(b.readStreak)-day streak", systemImage: "flame.fill")
                            .font(.system(size: 10.5, weight: .semibold)).foregroundColor(Color(hex: "#FB923C"))
                    }
                    Spacer()
                    SecondaryButton("OK") { NotificationCenter.default.post(name: .islandCollapse, object: nil) }
                    PrimaryButton(verbatim: "Full brief") {
                        NotificationCenter.default.post(name: .islandCollapse, object: nil)
                        DailyBriefController.shared.showFull(b, takeKeyboard: true)
                    }
                }
            }
        } else {
            Text("Your Daily brief is on its way.").font(.system(size: 14, weight: .semibold)).foregroundColor(Color(hex: "#F1F2F4"))
        }
    }
}

// MARK: - Weekly

struct WeeklyBriefNotchCard: View {
    @ObservedObject var state: AppState
    @ObservedObject private var model = BriefNotchModel.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            CardBackground(wash: .indigo)
            content
                .padding(.leading, 116)
                .padding(.trailing, 16)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .reportsBriefHeight(.weeklyBrief)
        }
    }

    @ViewBuilder private var content: some View {
        if let b = model.weekly {
            let w = b.work
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    NotchTag(text: "Weekly recap", tint: Color(hex: "#818CF8"))
                    Text(b.rangeLabel).font(.system(size: 10.5)).foregroundColor(Color(hex: "#8E939C"))
                    Spacer(minLength: 6)
                    if let c = w.change {
                        Text(DailyBriefText.change(c)).font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(c >= 0 ? Color(hex: "#34D399") : Color(hex: "#F7B32B"))
                            .padding(.horizontal, 8).frame(height: 20)
                            .background(Capsule().fill((c >= 0 ? Color(hex: "#34D399") : Color(hex: "#F7B32B")).opacity(0.14)))
                    }
                }
                Text(b.headline).font(.system(size: 14.5, weight: .bold)).foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if !w.total.isEmpty { days(w) }
                LazyVGrid(columns: notchColumns, alignment: .leading, spacing: 6) {
                    NotchTile(symbol: "hammer.fill", value: DailyBriefText.duration(minutes: w.total.minutes), label: "with agents", tint: Color(hex: "#818CF8"))
                    NotchTile(symbol: "terminal.fill", value: "\(w.total.sessions)", label: "\(w.activeDays) of 7 days", tint: Color(hex: "#818CF8"))
                    NotchTile(symbol: "doc.text.fill", value: "\(w.total.filesChanged)", label: "files changed", tint: Color(hex: "#3B9EFF"))
                    NotchTile(symbol: "plus.forwardslash.minus", value: "+\(w.total.linesAdded.formatted())", label: "−\(w.total.linesRemoved.formatted()) lines", tint: Color(hex: "#34D399"))
                    if let p = w.projects.first {
                        NotchTile(symbol: "folder.fill", value: p.name, label: "top project", tint: Color(hex: "#FB923C"))
                    }
                    if let water = b.water {
                        NotchTile(symbol: "drop.fill", value: "\(water.days.filter { $0 >= water.goal }.count) of 7", label: "water goal days", tint: Color(hex: "#22D3EE"))
                    }
                    if b.routines.focusSessions > 0 {
                        NotchTile(symbol: "brain.head.profile", value: "\(b.routines.focusSessions)", label: "focus · \(DailyBriefText.duration(minutes: b.routines.focusMinutes))", tint: Color(hex: "#A5B4FC"))
                    }
                    if let all = b.plan?.weekly.first {
                        NotchTile(symbol: "staroflife.fill", value: "\(Int(all.percent.rounded()))%", label: "weekly plan used", tint: Color(hex: "#E07950"))
                    }
                }
                HStack(spacing: 8) {
                    Spacer()
                    SecondaryButton("OK") { NotificationCenter.default.post(name: .islandCollapse, object: nil) }
                    if !w.total.isEmpty {
                        SecondaryButton(verbatim: String(localized: "recap.share-image")) { WeeklyBriefController.shared.share(b) }
                    }
                    PrimaryButton(verbatim: "Full screen") {
                        NotificationCenter.default.post(name: .islandCollapse, object: nil)
                        WeeklyBriefController.shared.showFull(b, takeKeyboard: true)
                    }
                }
            }
        } else {
            Text(String(localized: "recap.no-activity")).font(.system(size: 14, weight: .semibold)).foregroundColor(Color(hex: "#F1F2F4"))
        }
    }

    /// The week as bars, each day's time on it.
    private func days(_ w: WeekWork) -> some View {
        let top = max(1, w.days.map(\.minutes).max() ?? 1)
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(0..<7, id: \.self) { i in
                let m = w.days[i].minutes
                VStack(spacing: 3) {
                    Text(m > 0 ? DailyBriefText.duration(minutes: m) : "").font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                        .foregroundColor(Color(hex: "#8E939C")).lineLimit(1).fixedSize()
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(i == w.busiestDay ? Color(hex: "#818CF8") : Color(hex: "#818CF8").opacity(m > 0 ? 0.45 : 0.1))
                        .frame(height: max(3, 34 * CGFloat(m) / CGFloat(top)))
                    Text(WeeklyBrief.dayLetters[i]).font(.system(size: 9, weight: .semibold)).foregroundColor(Color(hex: "#6B7079"))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 64, alignment: .bottom)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
    }
}
#endif
