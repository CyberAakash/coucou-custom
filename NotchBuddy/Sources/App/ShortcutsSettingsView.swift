import SwiftUI
import AppKit

// MARK: - ShortcutsSettingsView

/// "Shortcuts" section inside SettingsView.
struct ShortcutsSettingsView: View {
    // Conflicts detected by HotKeyCenter (system already owns that combo)
    @State private var systemConflicts: Set<ShortcutAction> = []
    // Internal duplicates (two Coucou shortcuts share the same combo)
    @State private var internalDups: Set<ShortcutAction> = []

    // Per-action state (enabled flag + current spec)
    @State private var enabled:  [ShortcutAction: Bool]          = [:]
    @State private var closeTap = IslandCloseChord.enabled          // coucou-custom fork
    @State private var closeKey = IslandCloseChord.key
    @State private var closeInterval = IslandCloseChord.interval
    @State private var specs:    [ShortcutAction: ShortcutSpec]  = [:]
    /// coucou-custom fork: drawn as a page of the Coucou window (HubCard rows, keycaps).
    var hubStyle = false

    var body: some View {
        Group {
            #if !APPSTORE
            if hubStyle { hubBody } else { boxedBody }
            #else
            boxedBody
            #endif
        }
        .onAppear { reload() }
    }

    private var boxedBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            globalSection
            islandSection
        }
    }

    // MARK: - Global shortcuts

    private var globalSection: some View {
        GroupBox(String(localized: "shortcut.group.global")) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(globalActions, id: \.self) { action in
                    shortcutRow(action)
                    if action != globalActions.last {
                        Divider().padding(.leading, 24)
                    }
                }
                Divider().padding(.top, 8)
                HStack {
                    Spacer()
                    Button(String(localized: "shortcut.reset-defaults")) { resetAll() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.top, 6)
            }
            .padding(6)
        }
            .settingsAnchor("shortcuts.global")
    }

    /// Shortcuts listed here. The App Store build hides the ones it can't run.
    private var globalActions: [ShortcutAction] {
        #if APPSTORE
        ShortcutAction.allCases.filter { !$0.isNonAppStore }
        #else
        ShortcutAction.allCases
        #endif
    }

    @ViewBuilder
    private func shortcutRow(_ action: ShortcutAction) -> some View {
        let isEnabled    = enabled[action] ?? action.enabledByDefault
        let spec         = specs[action]   ?? ShortcutLogic.defaults[action]!
        let hasSysConf   = systemConflicts.contains(action)
        let hasIntConf   = internalDups.contains(action)

        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { v in toggleAction(action, enabled: v) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .frame(width: 18)

            Text(action.displayName)
                .font(.system(size: 12))
                .frame(minWidth: 160, alignment: .leading)

            Spacer(minLength: 4)

            ShortcutRecorderButton(flags: specFlagsBinding(action), code: specCodeBinding(action))
                .disabled(!isEnabled)
                .onChange(of: specs[action]) { _, _ in specChanged(action) }

            if hasSysConf {
                conflictTag(String(localized: "shortcut.conflict.system"), color: .orange)
            } else if hasIntConf {
                conflictTag(String(localized: "shortcut.conflict.duplicate"), color: .red)
            }
        }
        .padding(.vertical, 5)
        .opacity(isEnabled ? 1 : 0.5)
    }

    private func conflictTag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.1))
            .clipShape(Capsule())
    }

    // MARK: - Island-local shortcuts (read-only)

    private var islandSection: some View {
        GroupBox(String(localized: "shortcut.group.island")) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(ShortcutLogic.islandShortcuts.enumerated()), id: \.offset) { _, pair in
                    HStack(spacing: 10) {
                        Text(pair.key)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 90, alignment: .leading)
                        Text(pair.description)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    if pair.key != ShortcutLogic.islandShortcuts.last?.key {
                        Divider().padding(.leading, 100)
                    }
                }
            }
            .padding(6)
        }
            .settingsAnchor("shortcuts.island")
    }

    // MARK: - Bindings

    private func specFlagsBinding(_ action: ShortcutAction) -> Binding<UInt> {
        Binding(
            get: { (specs[action] ?? ShortcutLogic.defaults[action]!).nsFlags },
            set: { v in
                var s = specs[action] ?? ShortcutLogic.defaults[action]!
                s.nsFlags = v
                specs[action] = s
            }
        )
    }

    private func specCodeBinding(_ action: ShortcutAction) -> Binding<UInt16> {
        Binding(
            get: { (specs[action] ?? ShortcutLogic.defaults[action]!).keyCode },
            set: { v in
                var s = specs[action] ?? ShortcutLogic.defaults[action]!
                s.keyCode = v
                specs[action] = s
            }
        )
    }

    // MARK: - Actions

    private func reload() {
        for action in ShortcutAction.allCases {
            enabled[action] = ShortcutLogic.isEnabled(action)
            specs[action]   = ShortcutLogic.hotKey(for: action)
        }
        systemConflicts = HotKeyCenter.shared.conflicts
        updateInternalDups()
    }

    private func toggleAction(_ action: ShortcutAction, enabled v: Bool) {
        enabled[action] = v
        ShortcutLogic.setEnabled(v, for: action)
        HotKeyCenter.shared.reregister(action)
        systemConflicts = HotKeyCenter.shared.conflicts
    }

    private func specChanged(_ action: ShortcutAction) {
        guard let s = specs[action] else { return }
        ShortcutLogic.save(s, for: action)
        HotKeyCenter.shared.reregister(action)
        systemConflicts = HotKeyCenter.shared.conflicts
        updateInternalDups()
    }

    private func resetAll() {
        for action in ShortcutAction.allCases {
            ShortcutLogic.resetToDefault(action)
            HotKeyCenter.shared.reregister(action)
        }
        reload()
    }

    private func updateInternalDups() {
        var all: [ShortcutAction: ShortcutSpec] = [:]
        for action in ShortcutAction.allCases {
            if ShortcutLogic.isEnabled(action) {
                all[action] = ShortcutLogic.hotKey(for: action)
            }
        }
        internalDups = ShortcutLogic.duplicates(in: all)
    }
}

#if !APPSTORE
// MARK: - coucou-custom fork: the Coucou window's Shortcuts page

extension ShortcutsSettingsView {
    @ViewBuilder fileprivate var hubBody: some View {
        let conflicts = systemConflicts.count + internalDups.count
        HubGlowCard(color: Color(hex: "#6366F1"), padding: 22) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    HubStatusPill(text: conflicts == 0
                                      ? String(localized: "hub.shortcuts.ok", defaultValue: "No conflicts")
                                      : String(format: String(localized: "hub.shortcuts.conflicts %lld", defaultValue: "%lld in conflict"), Int64(conflicts)),
                                  tone: conflicts == 0 ? .on : .warn)
                    Text(String(localized: "hub.shortcuts.title", defaultValue: "Your keys for Mochi"))
                        .font(.system(size: 21, weight: .bold))
                        .foregroundColor(HubTheme.text)
                    Text(String(localized: "hub.shortcuts.detail", defaultValue: "Click a shortcut, then press the new keys. Switch one off to give its keys back to other apps."))
                        .font(.system(size: 13))
                        .foregroundColor(HubTheme.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(String(localized: "shortcut.reset-defaults")) { resetAll() }
                    .buttonStyle(HubButtonStyle())
            }
        }

        // coucou-custom fork: close the open notch from the keyboard while busy elsewhere.
        HubLabel(String(localized: "hub.shortcuts.close", defaultValue: "Close the notch"))
        HubCard {
            HubRow(title: String(localized: "hub.shortcuts.close-tap", defaultValue: "Tap a key twice"),
                   detail: String(localized: "hub.shortcuts.close-tap-detail",
                                  defaultValue: "Two quick taps of this key, in any app, fold the open notch, a finished card included. A tap counts only when the key goes down and up on its own, so ⌃C is not one. Permissions and questions stay.")) {
                HStack(spacing: 10) {
                    Picker("", selection: Binding(get: { closeKey }, set: { closeKey = $0; IslandCloseChord.key = $0 })) {
                        ForEach(IslandCloseChord.Key.allCases) { Text(verbatim: $0.label).tag($0) }
                    }
                    .labelsHidden().frame(width: 170)
                    .disabled(!closeTap)
                    Toggle("", isOn: Binding(get: { closeTap }, set: { closeTap = $0; IslandCloseChord.enabled = $0 }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }
            if let note = closeKey.note, closeTap {
                HubNote(text: note, warning: true)
            }
            HubDivider()
            HubRow(title: String(localized: "hub.shortcuts.close-speed", defaultValue: "How quick"),
                   detail: String(format: String(localized: "hub.shortcuts.close-speed-detail", defaultValue: "Within %.2f s of each other."), closeInterval)) {
                Picker("", selection: Binding(get: { IslandCloseChord.Speed(rawValue: closeInterval) ?? .normal },
                                              set: { closeInterval = $0.interval; IslandCloseChord.interval = $0.interval })) {
                    ForEach(IslandCloseChord.Speed.allCases) { Text(verbatim: $0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .disabled(!closeTap)
            }
            HubDivider()
            hubRow(.closeIsland)
        }

        HubLabel(String(localized: "hub.shortcuts.global", defaultValue: "Everywhere"))
        HubCard {
            ForEach(globalActions.filter { $0 != .closeIsland }, id: \.self) { action in
                hubRow(action)
                if action != globalActions.last { HubDivider() }
            }
        }

        HubLabel(String(localized: "hub.shortcuts.island", defaultValue: "While the notch is open"))
        HubCard {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 18, alignment: .leading)], alignment: .leading, spacing: 12) {
                ForEach(Array(ShortcutLogic.islandShortcuts.enumerated()), id: \.offset) { _, pair in
                    HStack(spacing: 12) {
                        HubKeyCap(text: pair.key)
                            .frame(minWidth: 64, alignment: .leading)
                        Text(pair.description)
                            .font(.system(size: 12.5))
                            .foregroundColor(HubTheme.body)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func hubRow(_ action: ShortcutAction) -> some View {
        let isEnabled = enabled[action] ?? action.enabledByDefault
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(action.displayName).font(.system(size: 13.5, weight: .medium))
                if systemConflicts.contains(action) {
                    HubStatusPill(text: String(localized: "shortcut.conflict.system"), tone: .warn)
                } else if internalDups.contains(action) {
                    HubStatusPill(text: String(localized: "shortcut.conflict.duplicate"), tone: .warn)
                }
            }
            Spacer(minLength: 8)
            ShortcutRecorderButton(flags: specFlagsBinding(action), code: specCodeBinding(action), hubStyle: true)
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.45)
                .onChange(of: specs[action]) { _, _ in specChanged(action) }
            Toggle("", isOn: Binding(get: { isEnabled }, set: { toggleAction(action, enabled: $0) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.vertical, 2)
    }
}
#endif
