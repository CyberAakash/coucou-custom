#if !APPSTORE
import SwiftUI
import UniformTypeIdentifiers

// coucou-custom fork: the fork's settings pages reorder lists the same way — drag a row by its
// handle (anywhere on it, in fact); the others make room as it passes and it lifts while carried.
// Rows that cannot move (a hidden card, say) can follow, their handle dimmed.

struct HubReorderList<Item: Identifiable, Row: View>: View {
    @Binding var items: [Item]
    var fixed: [Item] = []
    var tint: Color = HubTheme.accent
    var spacing: CGFloat = 6
    @ViewBuilder let row: (Item) -> Row
    @State private var dragging: Item.ID?

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(items) { item in
                cell(item, movable: true)
                    .onDrag {
                        dragging = item.id
                        watchRelease()
                        return NSItemProvider(object: "\(item.id)" as NSString)
                    }
                    .onDrop(of: [UTType.text], delegate: HubReorderDrop(target: item.id, items: $items, dragging: $dragging))
            }
            ForEach(fixed) { cell($0, movable: false) }
        }
    }

    private func cell(_ item: Item, movable: Bool) -> some View {
        let lifted = dragging == item.id
        return HStack(spacing: 10) {
            HubGrip().opacity(movable ? 1 : 0.3)
            row(item)
        }
        .contentShape(Rectangle())
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(lifted ? tint.opacity(0.55) : .clear).padding(-4))
        .shadow(color: .black.opacity(lifted ? 0.35 : 0), radius: lifted ? 12 : 0, y: lifted ? 6 : 0)
        .scaleEffect(lifted ? 1.02 : 1)
        .zIndex(lifted ? 1 : 0)
        .animation(BriefLayout.spring, value: lifted)
        .help(movable ? "Drag to move" : "")
    }

    /// A drop outside any row never reaches a delegate: the lift ends when the mouse comes up.
    private func watchRelease() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            while NSEvent.pressedMouseButtons & 1 != 0 { try? await Task.sleep(for: .milliseconds(150)) }
            dragging = nil
        }
    }
}

/// Moves the dragged row as it passes over another, so the list makes room live.
private struct HubReorderDrop<Item: Identifiable>: DropDelegate {
    let target: Item.ID
    @Binding var items: [Item]
    @Binding var dragging: Item.ID?

    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != target,
              let from = items.firstIndex(where: { $0.id == d }),
              let to = items.firstIndex(where: { $0.id == target }) else { return }
        var out = items
        let moving = out.remove(at: from)
        out.insert(moving, at: to)
        withAnimation(BriefLayout.spring) { items = out }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// The handle: two columns of three dots, as Claude Design drew it.
struct HubGrip: View {
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(HubTheme.muted).frame(width: 3, height: 3) }
                }
            }
        }
        .frame(width: 12)
    }
}

/// The fork's pages' one banner: the page's switches beside its title (HubPageScaffold's trailing).
struct HubBannerSwitch: View {
    let title: String
    let tint: Color
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(isOn ? tint : HubTheme.muted).frame(width: 7, height: 7)
                .shadow(color: isOn ? tint.opacity(0.9) : .clear, radius: isOn ? 5 : 0)
            Text(title).font(.system(size: 12.5, weight: .semibold)).fixedSize()
            BriefSwitch(isOn: $isOn, tint: tint).controlSize(.small)
        }
        .padding(.leading, 12).padding(.trailing, 6).frame(height: 32)
        .background(Capsule().fill(Color.black.opacity(0.35)))
        .overlay(Capsule().strokeBorder(isOn ? tint.opacity(0.35) : Color.white.opacity(0.08)))
        .animation(.easeOut(duration: 0.3), value: isOn)
    }
}
#endif
