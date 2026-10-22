import SwiftUI

// coucou-custom fork: the notch chat's agentic bits, after OpenPets v4's assistant — a line for
// each Buddy tool call with its status, and suggested prompts on an empty chat. In the chat's own
// style (ChatBubble, the model chip).

struct ChatToolRow: View {
    let run: ChatToolRun

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(hex: "#8E939C"))
            Text(run.title)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(hex: "#D5D8DD"))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            status
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.white.opacity(0.06))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .help(run.title)
    }

    @ViewBuilder private var status: some View {
        switch run.status {
        case .running:
            ProgressView().controlSize(.mini)
        case .completed:
            chip("COMPLETED", "#34C759")
        case .failed:
            chip("FAILED", "#F4505E")
        }
    }

    private func chip(_ text: String, _ hex: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .foregroundColor(Color(hex: hex))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color(hex: hex).opacity(0.14))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(hex: hex).opacity(0.35)))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

extension Notification.Name {
    /// "Ask Mochi…": the chat's text field takes the cursor.
    static let buddyFocusChat = Notification.Name("coucou.buddy.focusChat")
}

#if !APPSTORE
/// Slash commands in the chat: the list while typing one, and running it.
@MainActor
enum ChatSlash {
    /// Runs a slash command in the chat, without the model: the command, its tool line, the
    /// result. False when `query` is not one.
    static func run(_ query: String, state: AppState) -> Bool {
        guard BuddyToolRunner.enabled, let parsed = BuddySlash.parse(query) else { return false }
        switch parsed {
        case .success(.clear):
            NotificationCenter.default.post(name: .islandNewConversation, object: nil)
        case .success(.help):
            state.chatHistory.append(ChatMessage(role: .user, content: query))
            state.chatHistory.append(ChatMessage(role: .assistant, content: BuddySlash.helpText))
        case .failure(let usage):
            state.chatHistory.append(ChatMessage(role: .user, content: query))
            state.chatHistory.append(ChatMessage(role: .assistant, content: usage.text))
        case .success(.tool(let name, let raw)):
            state.chatHistory.append(ChatMessage(role: .user, content: query))
            var input: [String: Any] = raw
            for (k, v) in raw where v == "true" || v == "false" { input[k] = v == "true" }
            Task {
                let text = await BuddyToolRunner.runShown(name, input, state: state)
                state.chatHistory.append(ChatMessage(role: .assistant, content: text))
            }
        }
        return true
    }

    /// Return or Tab on the list: the selected command's name, and whether it can run as is
    /// (it takes nothing). nil when there is no list, so Return sends what is typed.
    static func complete(_ text: String, selected: Int) -> (text: String, runs: Bool)? {
        let list = BuddySlash.suggestions(for: text)
        guard !text.contains(" "), !list.isEmpty else { return nil }
        let pick = list[min(max(selected, 0), list.count - 1)]
        return pick.takesNothing ? ("/" + pick.name, true) : ("/" + pick.name + " ", false)
    }
}

/// The commands matching what is typed, over the composer; the selected one lit.
struct ChatSlashPalette: View {
    let text: String
    let selected: Int
    let pick: (BuddySlashCommand) -> Void

    var body: some View {
        let list = BuddySlash.suggestions(for: text)
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                Button { pick(c) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: c.symbol)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(Color(hex: "#B0B5BE"))
                            .frame(width: 18)
                        Text("/" + c.name)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(Color(hex: "#F1F2F4"))
                        Text(c.args)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(Color(hex: "#5C6370"))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(c.summary)
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#8E939C"))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(i == selected ? 0.1 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 2)
    }
}

/// Not sure what to ask? A tap sends one.
struct ChatSuggestions: View {
    let send: (String) -> Void

    static let prompts = [
        "What can you do?",
        "/help",
        "Check system status",
        "Summarize activity",
        "Start a 25 minute focus session",
        "Remind me in 10 minutes to stretch",
        "Help me calm down",
    ]

    var body: some View {
        ChipFlowLayout(spacing: 6) {
            ForEach(Self.prompts, id: \.self) { p in
                Button { send(p) } label: {
                    Text(p)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(hex: "#B0B5BE"))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Color.white.opacity(0.06))
                        .overlay(Capsule().stroke(Color.white.opacity(0.09)))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
#endif
