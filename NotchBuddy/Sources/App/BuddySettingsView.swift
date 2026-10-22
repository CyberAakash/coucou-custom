#if !APPSTORE
import SwiftUI
import AppKit

// coucou-custom fork: the Coucou window's Buddy page — the desktop Buddy's look and behaviour,
// in the window's own style (HubPageScaffold, HubCard, HubRow).

struct HubBuddyPage: View {
    @ObservedObject private var settings = BuddySettings.shared

    var body: some View {
        HubPageScaffold(title: String(localized: "Buddy"), subtitle: String(localized: "hub.notch.buddy")) {
            BuddyHeroCard(settings: settings)

            HubLabel("Look")
            HubCard {
                HubRow(title: "Size", detail: "\(settings.size.label) · \(Int(settings.size.side)) pt") {
                    BuddySizeChips(selection: $settings.size)
                }
                HubDivider()
                VStack(alignment: .leading, spacing: 10) {
                    HubRow(title: "Outfit", detail: "Its own wardrobe: the notch's Mochi keeps its own.") { EmptyView() }
                    BuddyOutfitGrid(selection: $settings.outfit, color: settings.color)
                }
                HubDivider()
                HubRow(title: "Colour") {
                    BuddyColorSwatches(selection: $settings.color)
                }
            }

            HubLabel("Behaviour")
            HubCard {
                HubRow(title: "React to my agents",
                       detail: "Thinks, works, waits and cheers with your Claude Code and other agent sessions.") {
                    Toggle("", isOn: $settings.reactToAgents).toggleStyle(.switch).labelsHidden()
                }
                HubDivider()
                HubRow(title: "Speech bubbles",
                       detail: "A short line when a permission or a question waits, or something fails.") {
                    Toggle("", isOn: $settings.speechBubbles).toggleStyle(.switch).labelsHidden()
                        .disabled(!settings.reactToAgents)
                }
                HubDivider()
                HubRow(title: "Eyes follow the cursor") {
                    Toggle("", isOn: $settings.followCursor).toggleStyle(.switch).labelsHidden()
                }
                HubDivider()
                HubRow(title: "Nap when idle", detail: "After two quiet minutes with the cursor away.") {
                    Toggle("", isOn: $settings.napWhenIdle).toggleStyle(.switch).labelsHidden()
                }
            }

            HubLabel("Moving it around")
            HStack(spacing: 12) {
                BuddyTip(symbol: "hand.draw", title: "Drag", line: "Anywhere, on any display. It remembers its spot on each one.")
                BuddyTip(symbol: "cursorarrow.click", title: "Click", line: "It says hi.")
                BuddyTip(symbol: "contextualmenu.and.cursorarrow", title: "Right-click",
                         line: "Size, outfit, bubbles, or hide it.")
            }
        }
    }
}

// MARK: - Hero card: live preview, on/off, quick actions

private struct BuddyHeroCard: View {
    @ObservedObject var settings: BuddySettings
    @StateObject private var preview = BuddyPreview()

    var body: some View {
        HubGlowCard(color: Color(hex: "#F472B6"), padding: 22) {
            HStack(alignment: .center, spacing: 26) {
                preview.view
                    .frame(width: preview.canvas.width, height: preview.canvas.height)
                    .contentShape(Rectangle())
                    .onTapGesture { preview.hello() }
                    .onContinuousHover { phase in
                        if case .active(let p) = phase { preview.look(at: p) } else { preview.look(at: nil) }
                    }
                    .help("Click to say hi")

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Circle().fill(settings.enabled ? HubTheme.green : HubTheme.muted).frame(width: 7, height: 7)
                        Text(settings.enabled ? "On your desktop" : "Hidden")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(settings.enabled ? HubTheme.green : HubTheme.secondary)
                    }
                    Text("Your Mochi, on the desktop")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundColor(HubTheme.text)
                    Text("A Mochi of its own, apart from the notch's. It floats above your windows on every Space and keeps you company while your agents work.")
                        .font(.system(size: 13))
                        .foregroundColor(HubTheme.body)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Toggle(isOn: $settings.enabled) {
                            Text("Show on the desktop").font(.system(size: 13, weight: .semibold))
                        }
                        .toggleStyle(.switch)
                        Spacer(minLength: 8)
                        Button("Say hi") { BuddyController.shared.wave(); preview.hello() }
                            .buttonStyle(HubButtonStyle())
                            .disabled(!settings.enabled)
                        Button("Reset position") { BuddyController.shared.resetPosition() }
                            .buttonStyle(HubButtonStyle())
                            .disabled(!settings.enabled)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .onAppear { preview.dress(settings) }
        .onChange(of: settings.outfit) { _, _ in preview.dress(settings) }
        .onChange(of: settings.color) { _, _ in preview.dress(settings) }
    }
}

/// The hero card's Mochi: its own engine, dressed as the Buddy, looking at the cursor over the card.
@MainActor
private final class BuddyPreview: ObservableObject {
    let engine = BotEngine()
    let state = BuddyViewState()
    let side: CGFloat = 112
    var canvas: CGSize { BuddyInsets.mochi.panelSize(side: side) }
    var view: BuddyMochiView {
        BuddyMochiView(engine: engine, viewState: state, inner: BuddyInsets.mochi.innerRectTopDown(side: side), canvas: canvas)
    }

    init() { engine.setState(.idle, force: true) }

    func dress(_ settings: BuddySettings) {
        engine.setOutfit(settings.resolvedOutfit(), animated: true)
        engine.bodyColor = settings.color.isEmpty ? nil : cgColorFromHex(settings.color)
    }

    func hello() { engine.triggerEmote(.happy, duration: 1.2, silent: true) }

    /// `p` in the preview's own coordinates (y down), nil when the cursor leaves it.
    func look(at p: CGPoint?) {
        guard let p else { engine.lookX = 0; engine.lookY = 0; return }
        let r = BuddyInsets.mochi.innerRectTopDown(side: side)
        engine.lookX = tanh((p.x - r.midX) / 90)
        engine.lookY = -tanh((p.y - r.midY) / 70)
    }
}

// MARK: - Look

private struct BuddySizeChips: View {
    @Binding var selection: BuddySize

    var body: some View {
        HStack(spacing: 4) {
            ForEach(BuddySize.allCases) { size in
                let on = selection == size
                Button { selection = size } label: {
                    Text(size.short)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(on ? HubTheme.onAccent : HubTheme.body)
                        .frame(width: 36, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(on ? HubTheme.accent : Color.white.opacity(0.05)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(size.label)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(HubTheme.field))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }
}

private struct BuddyOutfitGrid: View {
    @Binding var selection: Outfit
    let color: String

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 86, maximum: 110), spacing: 10)], spacing: 10) {
            ForEach(Outfit.allCases, id: \.self) { outfit in
                let on = selection == outfit
                let shown = outfit == .auto ? Outfit.resolved(selection: .auto, date: .now, calendar: .current) : outfit
                Button { selection = outfit } label: {
                    VStack(spacing: 6) {
                        BuddyMochiThumb(outfit: shown, color: color)
                            .frame(width: 58, height: 62)
                        Text(outfit == .auto ? "Seasons" : outfit.displayName)
                            .font(.system(size: 11.5, weight: on ? .bold : .medium))
                            .foregroundColor(on ? HubTheme.text : HubTheme.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(on ? HubTheme.accent.opacity(0.12) : Color.white.opacity(0.03)))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(on ? HubTheme.accent : Color.white.opacity(0.07), lineWidth: on ? 1.5 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct BuddyColorSwatches: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(BuddySettings.colors, id: \.self) { hex in
                let on = selection == hex
                Button { selection = hex } label: {
                    ZStack {
                        if hex.isEmpty {
                            Circle().fill(LinearGradient(colors: [Color(hex: "#DCE6F5"), Color(hex: "#9DB4D8")],
                                                         startPoint: .top, endPoint: .bottom))
                        } else {
                            Circle().fill(Color(hex: hex))
                        }
                    }
                    .frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(Color.white.opacity(on ? 0.95 : 0.12), lineWidth: on ? 2 : 1))
                    .padding(3)
                    .overlay(Circle().strokeBorder(on ? HubTheme.accent : .clear, lineWidth: 1.5))
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(hex.isEmpty ? "Mochi's own" : hex)
            }
        }
    }
}

// MARK: - Tips

private struct BuddyTip: View {
    let symbol: String
    let title: String
    let line: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Color(hex: "#F472B6"))
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(hex: "#F472B6").opacity(0.12)))
            Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundColor(HubTheme.text)
            Text(line)
                .font(.system(size: 12))
                .foregroundColor(HubTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(HubTheme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(HubTheme.line))
    }
}
#endif
