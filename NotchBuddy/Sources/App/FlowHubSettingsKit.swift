#if !APPSTORE
import SwiftUI

// coucou-custom fork: pieces the Coucou window's settings pages share (Agents, Chat, Integrations,
// Voice), next to FlowHub's HubCard / HubRow / HubField.

/// Connected / needs attention / off, as a small coloured pill.
struct HubStatusPill: View {
    enum Tone { case on, warn, off }
    let text: String
    let tone: Tone

    private var color: Color {
        switch tone {
        case .on: HubTheme.green
        case .warn: Color(hex: "#F5B83D")
        case .off: HubTheme.muted
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(tone == .off ? HubTheme.secondary : color)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(color.opacity(tone == .off ? 0.08 : 0.12)))
    }
}

/// A service or agent: icon, name and status on top, its fields and actions below.
struct HubTile<Content: View>: View {
    let name: String
    let symbol: String
    let color: Color
    var status: HubStatusPill? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(color)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.opacity(0.14)))
                Text(name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(HubTheme.text)
                    .lineLimit(1)
                Spacer(minLength: 6)
                status
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(HubTheme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(HubTheme.line))
    }
}

/// Tiles two (or more) to a row, as wide as the window allows.
struct HubTileGrid<Content: View>: View {
    var minWidth: CGFloat = 300
    @ViewBuilder var content: () -> Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: 14, alignment: .top)],
                  alignment: .leading, spacing: 14) { content() }
    }
}

/// A key or token field drawn like HubField.
struct HubSecureField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        SecureField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(HubTheme.field))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
            .onSubmit(onSubmit)
    }
}

/// What an install is about to write, to read before saying yes.
struct HubDiffPanel: View {
    let text: String
    var height: CGFloat = 150
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "hub.diff.title", defaultValue: "This will be written:"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(HubTheme.secondary)
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(HubTheme.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
            HStack(spacing: 8) {
                Spacer()
                Button(String(localized: "Cancel"), action: onCancel).buttonStyle(HubButtonStyle())
                Button(String(localized: "hooks.confirm-write"), action: onConfirm).buttonStyle(HubButtonStyle(primary: true))
            }
        }
    }
}

/// A line under a field: a hint, or a warning with its icon.
struct HubNote: View {
    let text: String
    var warning = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#F5B83D"))
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(warning ? Color(hex: "#F5D58A") : HubTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The settings' status line ("Key saved", "❌ …") as a toast at the bottom of the page.
struct HubToast: View {
    @Binding var message: String

    private var isError: Bool { message.hasPrefix("❌") }

    var body: some View {
        if !message.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundColor(isError ? HubTheme.red : HubTheme.green)
                Text(isError ? String(message.dropFirst(1)).trimmingCharacters(in: .whitespaces) : message)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(HubTheme.text)
                    .lineLimit(2)
                Button { withAnimation { message = "" } } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundColor(HubTheme.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(Color(hex: "#1D1E22")))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
            .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: message) {
                try? await Task.sleep(for: .seconds(isError ? 8 : 3.5))
                withAnimation { message = "" }
            }
        }
    }
}
#endif
