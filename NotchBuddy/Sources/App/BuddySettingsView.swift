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
                HubRow(title: "Colour", detail: "Any colour, or Mochi's own.") {
                    BuddyColorPicker(hex: $settings.color)
                }
                HubDivider()
                HubRow(title: "Companions", detail: "Little Mochis around it, as on this window's banner. Click one to make it blush.") {
                    BuddyCountChips(selection: $settings.companions)
                }
                if settings.companions > 0 {
                    HubDivider()
                    HubRow(title: "Same colour as the Buddy", detail: "Otherwise each wears one of this window's colours.") {
                        Toggle("", isOn: $settings.companionsMatch).toggleStyle(.switch).labelsHidden()
                    }
                }
                HubDivider()
                HubRow(title: "Shadow", detail: "On the floor under it and its companions; lighter as they jump.") {
                    BuddyShadowChips(selection: $settings.shadow)
                }
            }

            HubLabel("Wardrobe")
            BuddyWardrobeCard(settings: settings)

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

            HubLabel("Clicks")
            BuddyClicksCard(settings: settings)

            HubLabel("Moving it around")
            HStack(spacing: 12) {
                BuddyTip(symbol: "hand.draw", title: "Drag", line: "Anywhere, right to the edges and even half off them. It remembers its spot on each display.")
                BuddyTip(symbol: "cursorarrow.click", title: "Click", line: "Once, twice, three times or more: each does what you set above. Click a companion to make it blush.")
                BuddyTip(symbol: "contextualmenu.and.cursorarrow", title: "Right-click",
                         line: "Size, outfit (or back to the schedule), companions, bubbles, or hide it.")
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
            VStack(alignment: .leading, spacing: 16) {
                // The stage: the Buddy and its companions, as they look on the desktop.
                preview.view
                    .frame(width: preview.canvas.width, height: preview.canvas.height)
                    .id(preview.revision)
                    .contentShape(Rectangle())
                    .onTapGesture { preview.hello() }
                    .onContinuousHover { phase in
                        if case .active(let p) = phase { preview.look(at: p) } else { preview.look(at: nil) }
                    }
                    .help("Click to say hi")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.25)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.06)))

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
        .onChange(of: settings.alwaysWear) { _, _ in preview.dress(settings) }
        .onChange(of: settings.userSchedule) { _, _ in preview.dress(settings) }
        .onChange(of: settings.shadow) { _, _ in preview.dress(settings) }
        .onChange(of: settings.color) { _, _ in preview.dress(settings) }
        .onChange(of: settings.companions) { _, _ in preview.dress(settings) }
        .onChange(of: settings.companionsMatch) { _, _ in preview.dress(settings) }
    }
}

/// The hero card's Mochi: its own engine, dressed as the Buddy, looking at the cursor over the card.
@MainActor
private final class BuddyPreview: ObservableObject {
    let engine = BotEngine()
    let state = BuddyViewState()
    let side: CGFloat = 112
    /// A new set of companions: the stage is rebuilt.
    @Published private(set) var revision = 0
    private(set) var companions: BuddyCompanions?
    private var strip: CGFloat { companions?.layout.roam ?? 0 }
    var canvas: CGSize { BuddyInsets.mochi.panelSize(side: side, strip: strip) }
    private var square: CGRect { BuddyInsets.mochi.innerRectTopDown(side: side, strip: strip) }
    var view: BuddyMochiView {
        BuddyMochiView(engine: engine, viewState: state, inner: square, canvas: canvas, companions: companions)
    }

    init() { engine.setState(.idle, force: true) }

    func dress(_ settings: BuddySettings) {
        let worn = settings.resolvedOutfit()
        engine.setOutfit(worn.engineOutfit ?? .none, animated: true)
        state.nightcap = worn == .nightcap
        state.shadow = settings.shadow.opacity
        engine.bodyColor = settings.color.isEmpty ? nil : cgColorFromHex(settings.color)
        if (companions?.layout.count ?? 0) != settings.companions {
            let layout = BuddyCompanionLayout(count: settings.companions, side: side)
            let size = BuddyInsets.mochi.panelSize(side: side, strip: layout.roam)
            let mid = BuddyInsets.mochi.innerRectTopDown(side: side, strip: layout.roam).midX
            companions = layout.count > 0
                ? BuddyCompanions(layout: layout, stageWidth: size.width, buddyMidX: mid, colors: { settings.companionColor($0) })
                : nil
            revision += 1
        } else {
            companions?.recolor { settings.companionColor($0) }
        }
    }

    func hello() {
        engine.triggerEmote(.happy, duration: 1.2, silent: true)
        companions?.greet()
    }

    /// `p` in the preview's own coordinates (y down), nil when the cursor leaves it.
    func look(at p: CGPoint?) {
        guard let p else { engine.lookX = 0; engine.lookY = 0; return }
        engine.lookX = tanh((p.x - square.midX) / 90)
        engine.lookY = -tanh((p.y - square.midY) / 70)
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

/// Any colour: Mochi's own, the system colour picker, or a hex code.
private struct BuddyColorPicker: View {
    @Binding var hex: String
    @State private var text = ""

    var body: some View {
        HStack(spacing: 8) {
            Button { hex = "" } label: {
                HStack(spacing: 6) {
                    Circle().fill(LinearGradient(colors: [Color(hex: "#DCE6F5"), Color(hex: "#9DB4D8")],
                                                 startPoint: .top, endPoint: .bottom))
                        .frame(width: 16, height: 16)
                    Text("Mochi's own").font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(hex.isEmpty ? HubTheme.text : HubTheme.secondary)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hex.isEmpty ? HubTheme.accent.opacity(0.14) : Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(hex.isEmpty ? HubTheme.accent : Color.white.opacity(0.08)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ColorPicker("", selection: Binding(
                get: { Color(hex: hex.isEmpty ? "#C9D6EA" : hex) },
                set: { hex = BuddyColorPicker.hex(of: $0) ?? hex }), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 44, height: 30)
                .help("Pick any colour")

            TextField("#RRGGBB", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .monospaced))
                .padding(.horizontal, 10)
                .frame(width: 96, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(HubTheme.field))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(BuddyColor.normalized(text) == nil && !text.isEmpty ? HubTheme.red : Color.white.opacity(0.1)))
                .onSubmit { if let n = BuddyColor.normalized(text) { hex = n } }
        }
        .onAppear { text = hex }
        .onChange(of: hex) { _, new in text = new }
    }

    /// A SwiftUI colour as "#RRGGBB" in sRGB.
    static func hex(of color: Color) -> String? {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return BuddyColor.hex(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent))
    }
}

/// None, 1…6.
private struct BuddyCountChips: View {
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0...BuddyCompanionLayout.maxCount, id: \.self) { n in
                let on = selection == n
                Button { selection = n } label: {
                    Text(n == 0 ? "None" : "\(n)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(on ? HubTheme.onAccent : HubTheme.body)
                        .frame(width: n == 0 ? 46 : 30, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(on ? HubTheme.accent : Color.white.opacity(0.05)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(HubTheme.field))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
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
