#if !APPSTORE
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// coucou-custom fork: a brief as an image to share — the Daily brief or the Weekly recap on one
// card in the design's look (its name and date, the greeting and the day in a line, the numbers,
// Mochi peeking up), made on this Mac and given to you to copy, save or pass to the Share menu.
// Projects and event names stay out unless you want them.

struct BriefShareCard: View {
    let title: String
    let date: String
    let headline: String
    let line: (lead: String, value: String, tail: String)
    let chips: [BriefChip]
    let accent: Color

    static let size = CGSize(width: 640, height: 400)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(hex: "#0E0F11")
            RadialGradient(colors: [accent.opacity(0.22), .clear], center: .topLeading, startRadius: 0, endRadius: 420)
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    Circle().fill(accent).frame(width: 7, height: 7)
                    Text(title).font(.system(size: 13, weight: .bold)).foregroundColor(Color(hex: "#F5F6F8"))
                    Text(date).font(.system(size: 13)).foregroundColor(Color(hex: "#6B7079"))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(headline).font(.system(size: 30, weight: .bold)).tracking(-0.6).foregroundColor(Color(hex: "#F5F6F8"))
                        .lineLimit(1).minimumScaleFactor(0.6)
                    (Text(line.lead) + Text(line.value).foregroundColor(accent).fontWeight(.semibold) + Text(line.tail))
                        .font(.system(size: 17)).foregroundColor(Color(hex: "#E1E3E6")).lineLimit(2)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(chips.prefix(6)) { c in
                        HStack(spacing: 10) {
                            Circle().fill(c.color).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.value).font(.system(size: 19, weight: .bold).monospacedDigit()).foregroundColor(Color(hex: "#F5F6F8")).lineLimit(1)
                                Text(c.label).font(.system(size: 12)).foregroundColor(Color(hex: "#8E939C")).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14).frame(height: 52)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(hex: "#18191C")))
                    }
                }
                .padding(.trailing, 110)
                Spacer(minLength: 0)
                Text("Coucou · Mochi lives in the notch").font(.system(size: 11.5, weight: .medium)).foregroundColor(Color(hex: "#6B7079"))
            }
            .padding(32)
            DesignMochi(size: 112, mode: .idle)
                .position(x: Self.size.width - 86, y: Self.size.height - 30)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
        .environment(\.colorScheme, .dark)
    }

    static func daily(_ b: DailyBrief, hidePrivate: Bool) -> BriefShareCard {
        BriefShareCard(title: "Daily brief", date: b.date.formatted(.dateTime.weekday(.wide).day().month(.wide)),
                       headline: DailyBriefText.greeting(at: b.date, name: nil) + ".",
                       line: DailyBriefText.notchLine(work: b.work, isToday: b.isToday),
                       chips: BriefNotchStage.chips(b).filter { !(hidePrivate && $0.isPrivate) },
                       accent: Color(hex: "#FB923C"))
    }

    static func weekly(_ b: WeeklyBrief, hidePrivate: Bool) -> BriefShareCard {
        BriefShareCard(title: "Weekly recap", date: b.rangeLabel,
                       headline: b.isThisWeek ? "My week so far." : "My week.",
                       line: DailyBriefText.weekNotchLine(b.work, isThisWeek: b.isThisWeek),
                       chips: BriefNotchStage.chips(b).filter { !(hidePrivate && $0.isPrivate) },
                       accent: Color(hex: "#818CF8"))
    }
}

/// The window to copy, save or share the image; over a full-screen brief when one shows.
@MainActor
enum BriefSharePanel {
    private static var window: NSPanel?

    static func show(name: String, card: @escaping (Bool) -> BriefShareCard) {
        window?.close()
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 470),
                        styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        p.title = "Share"
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .statusBar
        p.isReleasedWhenClosed = false
        p.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: BriefSharePanelView(name: name, card: card))
        host.sizingOptions = [.minSize]
        p.contentView = host
        p.center()
        window = p
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    static func render(_ card: BriefShareCard) -> NSImage? {
        let r = ImageRenderer(content: card)
        r.scale = 2
        return r.nsImage
    }

    static var panelView: NSView? { window?.contentView }
}

private struct BriefSharePanelView: View {
    let name: String
    let card: (Bool) -> BriefShareCard
    @State private var hidePrivate = AppState.shared.recapHideProjects
    @State private var image: NSImage?
    @State private var copied = false

    var body: some View {
        VStack(spacing: 16) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                } else {
                    RoundedRectangle(cornerRadius: 14).fill(Color(hex: "#141518")).overlay(ProgressView())
                }
            }
            .frame(width: 480, height: 300)
            Toggle("Leave out project and event names", isOn: $hidePrivate)
                .toggleStyle(.switch).font(.system(size: 12.5))
            HStack(spacing: 10) {
                Button(copied ? "Copied" : "Copy image") {
                    guard let image else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                Button("Save…") { save() }
                Button("Share…") {
                    guard let image, let view = BriefSharePanel.panelView else { return }
                    let picker = NSSharingServicePicker(items: [image])
                    picker.show(relativeTo: NSRect(x: view.bounds.midX, y: 20, width: 1, height: 1), of: view, preferredEdge: .minY)
                }
                .keyboardShortcut(.defaultAction)
            }
            .disabled(image == nil)
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: render)
        .onChange(of: hidePrivate) { render() }
    }

    private func render() { image = BriefSharePanel.render(card(hidePrivate)) }

    private func save() {
        guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = name + ".png"
        panel.level = .statusBar
        if panel.runModal() == .OK, let url = panel.url { try? png.write(to: url) }
    }
}
#endif
