#if !APPSTORE
import SwiftUI

// coucou-custom fork: Settings → Briefs' own controls, so the page is not a wall of chips — a
// segmented control whose highlight slides, a time picker (hours, minutes, or type it), a weekday
// picker, and a combobox with search that also takes a value of your own.

// MARK: - Segmented, full width, the highlight sliding between its parts

struct BriefSegmentedOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var symbol: String? = nil
    var id: Value { value }
}

struct BriefSegmented<Value: Hashable>: View {
    let options: [BriefSegmentedOption<Value>]
    @Binding var selection: Value
    let tint: Color
    var height: CGFloat = 32
    @Namespace private var space

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { o in
                let on = o.value == selection
                Button {
                    withAnimation(BriefLayout.spring) { selection = o.value }
                } label: {
                    HStack(spacing: 7) {
                        if let symbol = o.symbol {
                            Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(on ? tint : HubTheme.muted)
                        }
                        Text(o.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    }
                    .foregroundColor(on ? HubTheme.text : HubTheme.secondary)
                    .frame(maxWidth: .infinity).frame(height: height)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.1))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tint.opacity(0.45)))
                                .shadow(color: tint.opacity(0.25), radius: 6)
                                .matchedGeometryEffect(id: "on", in: space)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(BriefPress())
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
    }
}

struct BriefPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(BriefLayout.pop, value: configuration.isPressed)
            .pointer()
    }
}

/// The face every popover control shows: what is chosen, and a chevron.
private struct BriefFieldFace: View {
    let symbol: String
    let text: String
    var detail: String? = nil
    let tint: Color
    let open: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundColor(tint)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.opacity(0.14)))
            Text(text).font(.system(size: 13, weight: .semibold).monospacedDigit()).lineLimit(1)
            if let detail {
                Text(detail).font(.system(size: 12)).foregroundColor(HubTheme.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9.5, weight: .bold))
                .foregroundColor(HubTheme.secondary)
                .rotationEffect(.degrees(open ? 180 : 0))
        }
        .padding(.leading, 5).padding(.trailing, 11)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(hover || open ? 0.08 : 0.045)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(open ? tint.opacity(0.6) : Color.white.opacity(0.08)))
        .shadow(color: open ? tint.opacity(0.25) : .clear, radius: 8)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .animation(BriefLayout.spring, value: open)
    }
}

// MARK: - Time: hours and minutes to pick, or typed

struct BriefTimePicker: View {
    @Binding var minuteOfDay: Int
    let tint: Color
    var width: CGFloat = 220
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            BriefFieldFace(symbol: "clock", text: MacDay.clock(minuteOfDay), detail: Self.partOfDay(minuteOfDay), tint: tint, open: open)
        }
        .buttonStyle(BriefPress())
        .frame(width: width)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            BriefTimePanel(minuteOfDay: $minuteOfDay, tint: tint) { open = false }
        }
    }

    static func partOfDay(_ m: Int) -> String {
        switch m / 60 {
        case 5..<12: "morning"
        case 12..<17: "afternoon"
        case 17..<22: "evening"
        default: "night"
        }
    }
}

struct BriefTimePanel: View {
    @Binding var minuteOfDay: Int
    let tint: Color
    let done: () -> Void
    @State private var typed = ""
    @FocusState private var typing: Bool

    private var hour: Int { minuteOfDay / 60 }
    private var minute: Int { minuteOfDay % 60 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(MacDay.clock(minuteOfDay)).font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(BriefLayout.spring, value: minuteOfDay)
                Spacer()
                stepButton("minus", -1)
                stepButton("plus", 1)
            }
            label("Hour")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
                ForEach(0..<24, id: \.self) { h in
                    cell(String(format: "%02d", h), on: h == hour) { set(h * 60 + minute) }
                }
            }
            label("Minute")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
                ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { m in
                    cell(String(format: ":%02d", m), on: m == minute) { set(hour * 60 + m) }
                }
            }
            HStack(spacing: 8) {
                TextField("Type a time: 7:45, 18.30, 9 pm", text: $typed)
                    .textFieldStyle(.plain).font(.system(size: 12.5))
                    .focused($typing)
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(typed.isEmpty || BriefInput.minuteOfDay(from: typed) != nil ? Color.white.opacity(0.08) : HubTheme.red.opacity(0.6)))
                    .onSubmit {
                        if let m = BriefInput.minuteOfDay(from: typed) { set(m); typed = ""; done() }
                    }
                Button("Done", action: done).buttonStyle(HubButtonStyle(primary: true))
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func set(_ m: Int) { withAnimation(BriefLayout.pop) { minuteOfDay = (m + 1440) % 1440 } }

    private func label(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 10.5, weight: .bold)).tracking(1.1).foregroundColor(HubTheme.muted)
    }

    private func stepButton(_ symbol: String, _ delta: Int) -> some View {
        Button { set(minuteOfDay + delta) } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                .frame(width: 28, height: 28).background(Circle().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(BriefPress())
        .help(delta > 0 ? "A minute later" : "A minute earlier")
    }

    private func cell(_ text: String, on: Bool, action: @escaping () -> Void) -> some View {
        BriefGridCell(text: text, on: on, tint: tint, action: action)
    }
}

private struct BriefGridCell: View {
    let text: String
    let on: Bool
    let tint: Color
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(text).font(.system(size: 12, weight: on ? .bold : .medium).monospacedDigit())
                .foregroundColor(on ? HubTheme.onAccent : HubTheme.body)
                .frame(maxWidth: .infinity).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(on ? tint : Color.white.opacity(hover ? 0.1 : 0.04)))
                .scaleEffect(on ? 1.06 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(BriefPress())
        .onHover { hover = $0 }
        .animation(BriefLayout.pop, value: on)
    }
}

// MARK: - A day of the week

struct BriefWeekdayPicker: View {
    /// 1 Monday … 7 Sunday.
    @Binding var weekday: Int
    let tint: Color
    @Namespace private var space

    var body: some View {
        HStack(spacing: 8) {
            ForEach(1...7, id: \.self) { d in
                let on = d == weekday
                Button {
                    withAnimation(BriefLayout.pop) { weekday = d }
                } label: {
                    VStack(spacing: 4) {
                        Text(WeeklyBriefSchedule.weekdayNames[d - 1].prefix(3))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(on ? HubTheme.onAccent : (d >= 6 ? HubTheme.muted : HubTheme.body))
                            .frame(maxWidth: .infinity).frame(height: 38)
                            .background {
                                if on {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint)
                                        .shadow(color: tint.opacity(0.5), radius: 8)
                                        .matchedGeometryEffect(id: "day", in: space)
                                } else {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05))
                                }
                            }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(BriefPress())
                .help(WeeklyBriefSchedule.weekdayNames[d - 1])
            }
        }
    }
}

// MARK: - A combobox: the choices with their words, a search, your own value

struct BriefComboOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var detail: String? = nil
    var symbol: String? = nil
    var id: Value { value }
}

struct BriefComboBox<Value: Hashable>: View {
    let options: [BriefComboOption<Value>]
    @Binding var selection: Value
    let tint: Color
    var symbol = "list.bullet"
    var width: CGFloat = 320
    /// Turns what you type into a value of your own ("25" → 25 s); nil: only the listed choices.
    var custom: ((String) -> Value?)? = nil
    /// How a value of your own reads.
    var customTitle: ((Value) -> String)? = nil
    var placeholder = "Search"
    @State private var open = false

    private var current: (title: String, detail: String?) {
        if let o = options.first(where: { $0.value == selection }) { return (o.title, nil) }
        return (customTitle?(selection) ?? "\(selection)", "your own")
    }

    var body: some View {
        Button { open.toggle() } label: {
            BriefFieldFace(symbol: options.first(where: { $0.value == selection })?.symbol ?? symbol,
                           text: current.title, detail: current.detail, tint: tint, open: open)
        }
        .buttonStyle(BriefPress())
        .frame(width: width)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            BriefComboList(options: options, selection: $selection, tint: tint, custom: custom, customTitle: customTitle,
                           placeholder: placeholder) { open = false }
        }
    }
}

struct BriefComboList<Value: Hashable>: View {
    let options: [BriefComboOption<Value>]
    @Binding var selection: Value
    let tint: Color
    let custom: ((String) -> Value?)?
    let customTitle: ((Value) -> String)?
    let placeholder: String
    var width: CGFloat = 320
    let done: () -> Void
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var shown: [BriefComboOption<Value>] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var list = q.isEmpty ? options : options.filter {
            $0.title.localizedCaseInsensitiveContains(q) || ($0.detail?.localizedCaseInsensitiveContains(q) ?? false)
        }
        if let custom, let v = custom(q), !list.contains(where: { $0.value == v }) {
            list.append(BriefComboOption(value: v, title: "Use \(customTitle?(v) ?? "\(v)")", detail: "Your own value", symbol: "plus.circle"))
        }
        return list
    }

    /// A short list needs no search: the field shows past seven choices, or to type a value.
    private var searchable: Bool { options.count > 7 || custom != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if searchable {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundColor(HubTheme.muted)
                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .focused($focused)
                    .onSubmit { pick(highlighted) }
                    .onChange(of: query) { highlighted = 0 }
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { i, o in
                        row(o, index: i)
                    }
                    if shown.isEmpty {
                        Text(custom == nil ? "Nothing matches." : "Nothing matches. Type a value, such as 25.")
                            .font(.system(size: 12)).foregroundColor(HubTheme.muted).padding(12)
                    }
                }
            }
            .frame(maxHeight: 280)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(searchable ? 10 : 6)
        .frame(width: width)
        .focusable(!searchable).focusEffectDisabled().focused($focused)
        .onKeyPress(.return) { searchable ? .ignored : { pick(highlighted); return .handled }() }
        .onAppear { focused = true; highlighted = shown.firstIndex { $0.value == selection } ?? 0 }
        .onKeyPress(.downArrow) { highlighted = min(shown.count - 1, highlighted + 1); return .handled }
        .onKeyPress(.upArrow) { highlighted = max(0, highlighted - 1); return .handled }
        .onKeyPress(.escape) { done(); return .handled }
    }

    private func row(_ o: BriefComboOption<Value>, index: Int) -> some View {
        let on = o.value == selection
        let lit = index == highlighted
        return Button { pick(index) } label: {
            HStack(spacing: 10) {
                Image(systemName: o.symbol ?? "circle").font(.system(size: 12, weight: .semibold))
                    .foregroundColor(on ? tint : HubTheme.secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(o.title).font(.system(size: 13, weight: .semibold))
                    if let d = o.detail {
                        Text(d).font(.system(size: 11.5)).foregroundColor(HubTheme.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 6)
                if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundColor(tint) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(lit ? tint.opacity(0.16) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointer()
        .onHover { if $0 { highlighted = index } }
    }

    private func pick(_ index: Int) {
        guard shown.indices.contains(index) else { return }
        withAnimation(BriefLayout.spring) { selection = shown[index].value }
        done()
    }
}
// MARK: - The dropdown every choice list uses (coucou-custom fork)
//
// FORK.md, "Dropdowns": no native Picker menus or NSMenus for a choice. A compact face sized to
// its longest choice, BriefComboList in a popover (search past seven choices), ↑↓ Return Esc.

struct HubDropdown<Value: Hashable>: View {
    let options: [BriefComboOption<Value>]
    @Binding var selection: Value
    var tint: Color = HubTheme.accent
    /// The popover's width; nil sizes it to the face (at least 200).
    var listWidth: CGFloat? = nil
    /// A fixed face that truncates (a device name in a narrow band); nil: as wide as the longest choice.
    var width: CGFloat? = nil
    var symbol: String? = nil
    /// Shown when the selection is none of the choices.
    var placeholder: String? = nil
    /// Changing it opens the list (a key that opens the dropdown).
    var opener: Int = 0
    @State private var open = false
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    init(_ selection: Binding<Value>, _ choices: [(Value, String)], tint: Color = HubTheme.accent, listWidth: CGFloat? = nil,
         width: CGFloat? = nil, symbol: String? = nil, placeholder: String? = nil, opener: Int = 0) {
        self.init(options: choices.map { BriefComboOption(value: $0.0, title: $0.1) }, selection: selection, tint: tint,
                  listWidth: listWidth, width: width, symbol: symbol, placeholder: placeholder, opener: opener)
    }

    init(options: [BriefComboOption<Value>], selection: Binding<Value>, tint: Color = HubTheme.accent, listWidth: CGFloat? = nil,
         width: CGFloat? = nil, symbol: String? = nil, placeholder: String? = nil, opener: Int = 0) {
        self.opener = opener
        self.options = options
        self._selection = selection
        self.tint = tint
        self.listWidth = listWidth
        self.width = width
        self.symbol = symbol
        self.placeholder = placeholder
    }

    private var known: Bool { options.contains { $0.value == selection } }
    private var title: String { options.first { $0.value == selection }?.title ?? placeholder ?? "\(selection)" }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 7) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundColor(HubTheme.text) }
                if width != nil {
                    Text(title).truncationMode(.tail)
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(HubTheme.text).lineLimit(1)
                    Spacer(minLength: 0)
                } else {
                    // Every title laid over the others, hidden but one: the face keeps the width of the longest.
                    ZStack(alignment: .leading) {
                        ForEach(options) { o in
                            Text(o.title).opacity(o.value == selection ? 1 : 0)
                        }
                        if !known { Text(title) }
                    }
                    .font(.system(size: 12.5, weight: .medium)).foregroundColor(HubTheme.text).lineLimit(1)
                }
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(HubTheme.secondary)
            }
            .padding(.leading, 10).padding(.trailing, 9)
            .frame(width: width, height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(hover || open ? 0.09 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(open ? tint.opacity(0.6) : Color.white.opacity(0.08)))
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.45)
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        }
        .buttonStyle(BriefPress())
        .fixedSize(horizontal: width == nil, vertical: true)
        .background(GeometryReader { g in Color.clear.preference(key: HubDropdownWidth.self, value: g.size.width) })
        .onPreferenceChange(HubDropdownWidth.self) { faceWidth = $0 }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            BriefComboList(options: options, selection: $selection, tint: tint, custom: nil, customTitle: nil,
                           placeholder: "Search", width: listWidth ?? max(200, faceWidth + 40)) { open = false }
        }
        .onChange(of: opener) { _, _ in open = true }
        #if DEBUG
        // `debug.dropdown` "<text in the shown choice>" opens it, "close" closes them all (a terminal's check).
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("fr.louisraille.NotchBuddy.debug.dropdown"))) { note in
            guard let text = note.object as? String else { return }
            if text == "close" { open = false } else if title.localizedCaseInsensitiveContains(text) { open = true }
        }
        #endif
    }
    @State private var faceWidth: CGFloat = 0
}

private struct HubDropdownWidth: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
#endif
