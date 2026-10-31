#if !APPSTORE
import SwiftUI
import AppKit

// coucou-custom fork: the Coucou window's Buddy page — the desktop Buddy's look and behaviour,
// in the window's own style (HubPageScaffold, HubCard, HubRow).

struct HubBuddyPage: View {
    /// The page's colour: its banner, tabs, switches and choices.
    static let tint = Color(hex: "#F472B6")

    /// One view, two pages (coucou-custom fork): the Buddy itself, and Routines (water, focus,
    /// reminders, timers, breathing), which used to be two of its tabs and are not about the pet.
    enum Kind { case buddy, routines }
    let kind: Kind

    init(_ kind: Kind = .buddy) {
        self.kind = kind
        _sectionRaw = AppStorage(wrappedValue: (kind == .buddy ? BuddySection.look : .routines).rawValue,
                                 kind == .buddy ? "buddySettingsSection" : "routinesSettingsSection")
    }

    @ObservedObject private var settings = BuddySettings.shared
    @ObservedObject private var routineSettings = BuddyRoutineSettings.shared
    /// The tab shown; a search shows what matches in every tab of this page.
    @AppStorage private var sectionRaw: String
    @State private var query = ""

    private var tabs: [BuddySection] { BuddySection.tabs(for: kind) }
    private var tab: BuddySection {
        let t = BuddySection(rawValue: sectionRaw) ?? tabs[0]
        return tabs.contains(t) ? t : tabs[0]
    }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private func shows(_ s: BuddySection) -> Bool {
        let onPage = tabs.contains(s) || (kind == .buddy && s == .moving)
        guard onPage else { return false }
        return searching ? s.matches(query) : (s == tab || (tab == .behaviour && s == .moving))
    }

    var body: some View {
        // The page's one banner: its title and, for the Buddy, its switch.
        HubPageScaffold(title: kind == .buddy ? String(localized: "Buddy") : String(localized: "Routines"),
                        subtitle: kind == .buddy ? String(localized: "hub.notch.buddy")
                                                 : String(localized: "hub.notch.routines", defaultValue: "Water, focus sessions, reminders, timers and breathing: what they do and where they show."),
                        trailing: {
            if kind == .buddy {
                HubBannerSwitch(title: "Show on the desktop", tint: Color(hex: "#F472B6"), isOn: $settings.enabled)
            }
        }) {
            BuddySearchField(query: $query)
            BriefSegmented(options: tabs.map { BriefSegmentedOption(value: $0, title: $0.title, symbol: $0.symbol) },
                           selection: Binding(get: { tab }, set: { query = ""; sectionRaw = $0.rawValue }),
                           tint: Self.tint, height: 38)
                .opacity(searching ? 0.45 : 1)

            if kind == .buddy {
                HubLabel("Preview")
                BuddyHeroCard(settings: settings)
            }

            if !BuddySection.allCases.contains(where: shows) {
                HubEmptyState(text: "No \(kind == .buddy ? "Buddy" : "routine") setting matches “\(query)”.", state: .thinking)
            }

            if shows(.look) {
            HubLabel("Look")
            HubCard {
                BriefSettingRow(title: "Size", detail: "\(BuddySize.preset(scale: settings.sizeScale)?.label ?? "Custom") · \(Int(BuddySize.side(scale: settings.sizeScale))) pt") {
                    BuddySizeChips(scale: $settings.sizeScale)
                }
                if BuddySize.preset(scale: settings.sizeScale) == nil {
                    BuddyCustomSlider(value: $settings.sizeScale, range: BuddySize.customRange, step: 0.05,
                                      low: "40 pt", high: "320 pt") { "\(Int(BuddySize.side(scale: $0))) pt" }
                }
                HubDivider()
                HubRow(title: "Colour", detail: "Any colour, or Mochi's own.") {
                    BuddyColorPicker(hex: $settings.color)
                }
                HubDivider()
                BriefSettingRow(title: "Companions", detail: "Little Mochis around it, as on this window's banner. Click one to make it blush.") {
                    BuddyCountChips(selection: $settings.companions)
                }
                if settings.companions > 0 {
                    HubDivider()
                    BriefSettingRow(title: "Where they stay", detail: "On its left, its right, or both sides.") {
                        BuddySideChips(selection: $settings.companionSide)
                    }
                    HubDivider()
                    HubRow(title: "Same colour as the Buddy", detail: "Otherwise each wears one of this window's colours.") {
                        BriefSwitch(isOn: $settings.companionsMatch, tint: HubBuddyPage.tint)
                    }
                }
                HubDivider()
                BriefSettingRow(title: "Shadow", detail: "On the floor under it and its companions; lighter as they jump.") {
                    BuddyShadowChips(opacity: $settings.shadowOpacity)
                }
                if BuddyShadow.preset(opacity: settings.shadowOpacity) == nil {
                    BuddyCustomSlider(value: $settings.shadowOpacity, range: BuddyShadow.customRange, step: 0.01,
                                      low: "None", high: "Dark", live: true) { "\(Int(($0 * 100).rounded())) %" }
                }
            }

            }

            if shows(.wardrobe) {
                HubLabel("Wardrobe")
                BuddyWardrobeCard(settings: settings)
            }

            if shows(.assistant) {
                HubLabel("Assistant")
                BuddyAssistantCard(settings: routineSettings)
            }

            if shows(.routines) {
                HubLabel("Routines")
                BuddyRoutinesCard(settings: routineSettings)
                HubLabel("Alerts")
                BuddyFullScreenCard()
            }

            if shows(.water) {
                HubLabel("Water")
                BuddyWaterCard(settings: routineSettings)
            }

            if shows(.behaviour) {
            HubLabel("Behaviour")
            HubCard {
                HubRow(title: "React to my agents",
                       detail: "Thinks, works, waits and cheers with your Claude Code and other agent sessions.") {
                    BriefSwitch(isOn: $settings.reactToAgents, tint: HubBuddyPage.tint)
                }
                HubDivider()
                HubRow(title: "Speech bubbles",
                       detail: "A short line when a permission or a question waits, or something fails.") {
                    BriefSwitch(isOn: $settings.speechBubbles, tint: HubBuddyPage.tint)
                        .disabled(!settings.reactToAgents)
                }
                HubDivider()
                BriefSettingRow(title: "Bubble style",
                       detail: "Glass: dark, types its words. Comic: a white speech bubble that wobbles in. Sticker: a bold tag slapped on.") {
                    HStack(spacing: 10) {
                        BriefSegmented(options: BuddyBubbleStyle.allCases.map { BriefSegmentedOption(value: $0, title: $0.label) },
                                       selection: $settings.bubbleStyle, tint: HubBuddyPage.tint)
                        Button("Try") { BuddyController.shared.wave() }
                            .buttonStyle(HubButtonStyle())
                    }
                }
                HubDivider()
                HubRow(title: "Eyes follow the cursor") {
                    BriefSwitch(isOn: $settings.followCursor, tint: HubBuddyPage.tint)
                }
                HubDivider()
                HubRow(title: "Nap when idle", detail: "Only when you are away: two minutes without keyboard, mouse or trackpad, and your agents quiet. Any input wakes it.") {
                    BriefSwitch(isOn: $settings.napWhenIdle, tint: HubBuddyPage.tint)
                }
                HubDivider()
                BriefSettingRow(title: "Card while dragging",
                       detail: "The card of a focus session, a timer or an alert: it comes along, shrinks to its rings, or waits until you put the Buddy down.") {
                    BriefSegmented(options: BuddyHUDDrag.allCases.map { BriefSegmentedOption(value: $0, title: $0.label) },
                                   selection: $settings.hudWhileDragging, tint: HubBuddyPage.tint)
                }
                HubDivider()
                HubRow(title: "Card distance", detail: "Between the card and the top of its head or hat, when the card sits above it.") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.hudGap, in: BuddyHUDDrag.gapRange, step: 1).frame(width: 160)
                        Text("\(Int(settings.hudGap)) pt").font(.system(size: 12).monospacedDigit())
                            .foregroundColor(HubTheme.secondary).frame(width: 40, alignment: .trailing)
                    }
                }
            }

            }

            if shows(.clicks) {
                HubLabel("Clicks")
                BuddyClicksCard(settings: settings)
            }

            if shows(.moving) {
            HubLabel("Moving it around")
            HStack(spacing: 12) {
                BuddyTip(symbol: "hand.draw", title: "Drag", line: "Anywhere, right to the edges and even half off them. It remembers its spot on each display.")
                BuddyTip(symbol: "cursorarrow.click", title: "Click", line: "Once, twice, three times or more: each does what you set above. Click a companion to make it blush.")
                BuddyTip(symbol: "contextualmenu.and.cursorarrow", title: "Right-click",
                         line: "Ask Mochi, focus, timer, reminders, breathe, water; size, outfit, companions, bubbles, or hide it.")
            }
            }
        }
    }
}

// MARK: - The preview: the Buddy as it looks on the desktop, its quick actions

private struct BuddyHeroCard: View {
    @ObservedObject var settings: BuddySettings
    @StateObject private var preview = BuddyPreview()

    var body: some View {
        HubCard(padding: 20) {
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

                HStack(spacing: 10) {
                    Text(settings.enabled ? "On your desktop, above your windows on every Space. Click it here to say hi." : "Hidden: turn it on in the banner above.")
                        .font(.system(size: 12.5)).foregroundColor(HubTheme.secondary)
                    Spacer(minLength: 8)
                    Button("Say hi") { BuddyController.shared.wave(); preview.hello() }
                        .buttonStyle(HubButtonStyle())
                        .disabled(!settings.enabled)
                    Button("Reset position") { BuddyController.shared.resetPosition() }
                        .buttonStyle(HubButtonStyle())
                        .disabled(!settings.enabled)
                }
            }
        }
        .onAppear { preview.dress(settings) }
        .onChange(of: settings.alwaysWear) { _, _ in preview.dress(settings) }
        .onChange(of: settings.userSchedule) { _, _ in preview.dress(settings) }
        .onChange(of: settings.shadowOpacity) { _, _ in preview.dress(settings) }
        .onChange(of: settings.color) { _, _ in preview.dress(settings) }
        .onChange(of: settings.companions) { _, _ in preview.dress(settings) }
        .onChange(of: settings.companionsMatch) { _, _ in preview.dress(settings) }
        .onChange(of: settings.companionSide) { _, _ in preview.dress(settings) }
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
        state.shadow = settings.shadowOpacity
        engine.bodyColor = settings.color.isEmpty ? nil : cgColorFromHex(settings.color)
        if (companions?.layout.count ?? 0) != settings.companions || companions?.layout.placement != settings.companionSide {
            let layout = BuddyCompanionLayout(count: settings.companions, side: side, placement: settings.companionSide)
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
        engine.anim("oy", keys: [TweenKey(target: -0.35, duration: 190, ease: Ease.out),
                                 TweenKey(target: 0, duration: 260, ease: Ease.inOut)]) { [weak self] in
            self?.engine.squash()
        }
        engine.triggerEmote(.happy, duration: 1.4, silent: true)
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
    @Binding var scale: Double
    @State private var custom = false

    var body: some View {
        let preset = BuddySize.preset(scale: scale)
        BriefSegmented(options: BuddySize.allCases.map { BriefSegmentedOption(value: $0.rawValue, title: $0.label) }
                       + [BriefSegmentedOption(value: -1, title: "Custom", symbol: "slider.horizontal.3")],
                       selection: Binding(get: { custom || preset == nil ? -1 : scale }, set: { v in
                           if v < 0 {
                               // Nudge off the preset so the slider shows, starting where the Buddy is now.
                               if preset != nil { scale = min(scale + 0.05, BuddySize.customRange.upperBound) }
                               custom = true
                           } else {
                               custom = false
                               scale = v
                           }
                       }), tint: HubBuddyPage.tint)
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
                    .fill(hex.isEmpty ? HubBuddyPage.tint.opacity(0.14) : Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(hex.isEmpty ? HubBuddyPage.tint : Color.white.opacity(0.08)))
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

private struct BuddySideChips: View {
    @Binding var selection: BuddyCompanionSide

    var body: some View {
        BriefSegmented(options: BuddyCompanionSide.allCases.map { BriefSegmentedOption(value: $0, title: $0.label) },
                       selection: $selection, tint: HubBuddyPage.tint)
    }
}

/// None, 1…6.
private struct BuddyCountChips: View {
    @Binding var selection: Int

    var body: some View {
        BriefSegmented(options: (0...BuddyCompanionLayout.maxCount).map { BriefSegmentedOption(value: $0, title: $0 == 0 ? "None" : "\($0)") },
                       selection: $selection, tint: HubBuddyPage.tint)
    }
}

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

#if !APPSTORE
// MARK: - Filter (coucou-custom fork)

/// The Buddy page's sections, for its filter bar: a chip each, and the words a search matches
/// (the settings each one holds).
enum BuddySection: String, CaseIterable, Identifiable {
    case look, wardrobe, assistant, routines, water, behaviour, clicks, moving

    var id: String { rawValue }

    /// The tabs of each page: Moving it around shows under Behaviour; Routines and Water have
    /// their own page (coucou-custom fork).
    static func tabs(for kind: HubBuddyPage.Kind) -> [BuddySection] {
        switch kind {
        case .buddy: return [.look, .wardrobe, .assistant, .behaviour, .clicks]
        case .routines: return [.routines, .water]
        }
    }

    var title: String {
        switch self {
        case .look: "Look"
        case .wardrobe: "Wardrobe"
        case .assistant: "Assistant"
        case .routines: "Routines"
        case .water: "Water"
        case .behaviour: "Behaviour"
        case .clicks: "Clicks"
        case .moving: "Moving"
        }
    }

    var symbol: String {
        switch self {
        case .look: "paintpalette"
        case .wardrobe: "tshirt"
        case .assistant: "sparkles"
        case .routines: "timer"
        case .water: "drop"
        case .behaviour: "face.smiling"
        case .clicks: "cursorarrow.click"
        case .moving: "hand.draw"
        }
    }

    private var keywords: String {
        switch self {
        case .look: "size colour color companions side shadow look appearance scale"
        case .wardrobe: "wardrobe outfit clothes hat cap crown bow schedule seasons always wear nightcap"
        case .assistant: "assistant chat act tools ask mochi reminder timer slash commands"
        case .routines: "routines focus pomodoro session breaks long short breathing breathe calm launch greeting hello alert alerts sound start full screen fullscreen moment notch card popup where show"
        case .water: "water drink glass goal hydration nudge every between days ml litre"
        case .behaviour: "behaviour behavior react agents speech bubbles eyes cursor follow nap idle sleep card hud popup drag distance gap"
        case .clicks: "clicks click double triple many gesture action shortcut open app link"
        case .moving: "moving move drag right-click menu display position"
        }
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        let words = "\(title.lowercased()) \(keywords)"
        return q.split(separator: " ").allSatisfy { words.contains($0) }
    }
}

/// A search across every tab of the Buddy page.
private struct BuddySearchField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundColor(HubTheme.secondary)
            TextField("Search every Buddy setting: size, nap, water, focus…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(HubTheme.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(HubTheme.field))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
    }
}
#endif
