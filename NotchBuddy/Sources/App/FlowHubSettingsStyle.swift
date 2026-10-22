#if !APPSTORE
import SwiftUI

// coucou-custom fork: the Settings sections the Coucou window embeds (Agents, Chat, Integrations,
// Voice, Shortcuts, Active pills) drawn in the window's style without rewriting them: each
// GroupBox becomes a small-caps label over a HubCard, each checkbox a row with a switch on the
// right, like the hand-built General, Settings and Buddy pages. The App Store build's own
// Settings window keeps the system look.

struct HubGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            configuration.label
                .font(.system(size: 11.5, weight: .bold))
                .textCase(.uppercase)
                .tracking(1.3)
                .foregroundColor(HubTheme.muted)
            VStack(alignment: .leading, spacing: 12) { configuration.content }
                .font(.system(size: 13))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(HubTheme.card))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(HubTheme.line))
        }
    }
}

struct HubSwitchRowStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { HubSwitchRow(configuration: configuration) }
}

private struct HubSwitchRow: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.labelsVisibility) private var labels

    var body: some View {
        // A toggle with its label hidden sits inside someone else's row: just the switch.
        if labels == .hidden {
            Toggle("", isOn: configuration.$isOn).toggleStyle(.switch).labelsHidden()
        } else {
            HStack(spacing: 16) {
                configuration.label
                    .font(.system(size: 13.5, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("", isOn: configuration.$isOn).toggleStyle(.switch).labelsHidden()
            }
        }
    }
}
#endif
