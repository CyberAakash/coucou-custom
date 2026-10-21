import SwiftUI

// MARK: - Sessions view (coucou-custom fork)
//
// One tab per live agent session, and below it what the selected session is doing. The body
// is built from the session's state: what needs you comes first, then what it is doing
// (subagents, todos) or what it answered, then the activity log. Empty sections never show.

struct SessionsView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var live = LiveSessions.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: 10) {
                SessionTabs(live: live)
                if let s = live.selected {
                    SessionDetail(session: s, state: state)
                } else {
                    Text(String(localized: "sessions.none", defaultValue: "No agent session right now."))
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(12)
        }
        .onAppear { live.refresh() }
    }
}

// MARK: Tabs

private struct SessionTabs: View {
    @ObservedObject var live: LiveSessions

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(live.sessions) { s in
                    let on = s.id == live.selected?.id
                    Button { live.select(s.id) } label: {
                        HStack(spacing: 6) {
                            SessionStatusIcon(status: s.status)
                            Text(s.projectName)
                                .font(.system(size: 12, weight: on ? .semibold : .regular))
                                .lineLimit(1)
                            Text(agentName(s.pill))
                                .font(.system(size: 11))
                                .foregroundColor(Color(hex: "#8E939C"))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(on ? 0.14 : 0.05)))
                        .overlay(Capsule().stroke(Color(hex: pillColor(s.pill)).opacity(on ? 0.8 : 0), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(height: 28)
    }
}

struct SessionStatusIcon: View {
    let status: SessionTracker.Status

    var body: some View {
        switch status {
        case .working:    ProgressView().controlSize(.mini).frame(width: 12, height: 12)
        case .background: icon("hourglass", "#8EC5FF")
        case .waiting:    icon("hand.raised.fill", "#F5A623")
        case .finished:   icon("checkmark.circle.fill", "#4ADE80")
        case .failed:     icon("exclamationmark.triangle.fill", "#F87171")
        case .idle:       icon("circle", "#6B7079")
        }
    }

    private func icon(_ name: String, _ hex: String) -> some View {
        Image(systemName: name).font(.system(size: 10, weight: .semibold)).foregroundColor(Color(hex: hex))
            .frame(width: 12, height: 12)
    }
}

// MARK: Detail

private struct SessionDetail: View {
    let session: SessionTracker.Session
    @ObservedObject var state: AppState
    @State private var promptExpanded = false
    @State private var agentsExpanded = false

    private var s: SessionTracker.Session { session }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    if s.status == .waiting { waitingBanner }
                    if s.status == .failed, let error = s.errorDetail {
                        section(String(localized: "sessions.error", defaultValue: "Stopped on an error")) {
                            Text(error).font(.system(size: 12)).foregroundColor(Color(hex: "#FCA5A5"))
                                .textSelection(.enabled)
                        }
                    }
                    if s.status == .finished || s.status == .background, let message = s.finalMessage {
                        section(String(localized: "sessions.answer", defaultValue: "Answer")) {
                            ChatMarkdownView(markdown: message).textSelection(.enabled)
                        }
                    }
                    if !s.subagents.isEmpty { agents }
                    if !s.todos.isEmpty { todos }
                    if let prompt = s.prompt, !prompt.isEmpty { promptSection(prompt) }
                    if s.steps.contains(where: { $0.agentId == nil }) { activity }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 6)
            }
        }
    }

    // MARK: Header: agent · status · elapsed · Open terminal

    private var header: some View {
        HStack(spacing: 8) {
            SessionStatusIcon(status: s.status)
            Text(statusLine)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1).truncationMode(.tail)
            if s.status == .working || s.status == .background, let start = s.turnStartedAt {
                Text(start, style: .timer)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(Color(hex: "#8E939C"))
            }
            Spacer(minLength: 4)
            #if !APPSTORE
            Button(String(localized: "sessions.open-terminal", defaultValue: "Open terminal")) {
                LiveSessions.shared.openTerminal(s)
                NotificationCenter.default.post(name: .islandCollapse, object: nil)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            #endif
        }
    }

    private var statusLine: String {
        let agent = agentName(s.pill)
        switch s.status {
        case .working:
            return s.currentStep.map { "\(agent) · \($0)" } ?? "\(agent) · working"
        case .background:
            return "\(agent) · \(s.runningSubagents) agent\(s.runningSubagents == 1 ? "" : "s") still running"
        case .waiting:  return "\(agent) · waiting for you"
        case .finished: return "\(agent) · finished"
        case .failed:   return "\(agent) · stopped on an error"
        case .idle:     return "\(agent) · ready"
        }
    }

    // MARK: Sections

    @ViewBuilder private var waitingBanner: some View {
        let approval = state.pendingApproval.flatMap { $0.sessionId == s.id ? $0 : nil }
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill").foregroundColor(Color(hex: "#F5A623"))
            Text(approval.map { "Needs permission: \($0.command ?? $0.tool)" }
                 ?? (state.pendingQuestion != nil ? "Has a question for you" : "Waiting for you in the terminal"))
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2)
            Spacer(minLength: 4)
            if approval != nil || state.pendingQuestion != nil {
                Button(String(localized: "sessions.review", defaultValue: "Review")) {
                    state.view = approval != nil ? .approval : .question
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: "#F5A623").opacity(0.12)))
    }

    /// A session's subagents as one row: "Agents · 2 running". Tap to see each one and its
    /// last steps; their steps stay out of the session's Activity.
    private var agents: some View {
        let running = s.runningSubagents
        let started = s.subagents.map(\.startedAt).min() ?? Date()
        let ended = running > 0 ? nil : s.subagents.compactMap(\.endedAt).max()
        return VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { agentsExpanded.toggle() } } label: {
                HStack(spacing: 8) {
                    if running > 0 {
                        ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 10))
                            .foregroundColor(Color(hex: "#4ADE80")).frame(width: 12)
                    }
                    Text(running > 0
                         ? "Agents · \(running) running" + (s.subagents.count > running ? ", \(s.subagents.count - running) done" : "")
                         : "Agents · \(s.subagents.count) done")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 4)
                    Text(duration(from: started, to: ended))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(Color(hex: "#6B7079"))
                    Image(systemName: agentsExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color(hex: "#8E939C"))
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if agentsExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(s.subagents, id: \.id) { a in agentRow(a) }
                }
                .padding(.leading, 10)
            }
        }
    }

    private func agentRow(_ a: SessionTracker.Subagent) -> some View {
        let steps = s.steps.filter { $0.agentId == a.id }.suffix(5)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if a.running {
                    ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                } else {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color(hex: "#4ADE80")).frame(width: 12)
                }
                Text(a.description).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(a.type).font(.system(size: 10)).foregroundColor(Color(hex: "#8E939C")).lineLimit(1)
                Spacer(minLength: 4)
                Text(duration(from: a.startedAt, to: a.endedAt))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(Color(hex: "#6B7079"))
            }
            ForEach(Array(steps.reversed().enumerated()), id: \.offset) { _, step in
                Text(step.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(hex: step.failed ? "#F87171" : "#A1A6AE"))
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.leading, 20)
            }
        }
    }

    private var todos: some View {
        let done = s.todos.filter { $0.status == "completed" }.count
        return section("Tasks · \(done)/\(s.todos.count)") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(s.todos, id: \.id) { t in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: t.status == "completed" ? "checkmark.square.fill"
                              : t.status == "in_progress" ? "arrow.right.square.fill" : "square")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: t.status == "completed" ? "#4ADE80"
                                                   : t.status == "in_progress" ? "#8EC5FF" : "#6B7079"))
                        Text(t.status == "in_progress" ? (t.activeForm ?? t.content) : t.content)
                            .font(.system(size: 12, weight: t.status == "in_progress" ? .semibold : .regular))
                            .foregroundColor(Color(hex: t.status == "completed" ? "#8E939C" : "#F5F6F8"))
                            .strikethrough(t.status == "completed")
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private func promptSection(_ prompt: String) -> some View {
        section(String(localized: "sessions.prompt", defaultValue: "You asked")) {
            Text(prompt)
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "#C7CAD0"))
                .lineLimit(promptExpanded ? nil : 2)
                .textSelection(.enabled)
                .onTapGesture { promptExpanded.toggle() }
        }
    }

    private var activity: some View {
        section(String(localized: "sessions.activity", defaultValue: "Activity")) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(s.steps.filter { $0.agentId == nil }.suffix(40).reversed().enumerated()), id: \.offset) { _, step in
                    HStack(spacing: 6) {
                        if step.failed {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                                .foregroundColor(Color(hex: "#F87171"))
                        }
                        Text(step.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color(hex: "#A1A6AE"))
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text(step.date, style: .time)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(Color(hex: "#6B7079"))
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundColor(Color(hex: "#6B7079"))
            content()
        }
    }

    private func duration(from start: Date, to end: Date?) -> String {
        let seconds = Int((end ?? Date()).timeIntervalSince(start))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

// MARK: - Home-card controls

/// Next to a pill's title on the home card: "‹ 2/3 ›" when the pill has several sessions (the
/// card then follows the selected one), the upstream step counter otherwise. The card itself
/// (title and step row) opens the Sessions view.
struct SessionControls: View {
    let task: AgentTask
    @ObservedObject private var live = LiveSessions.shared

    var body: some View {
        let list = live.sessions(for: task.id)
        HStack(spacing: 4) {
            if list.count > 1 {
                let index = list.firstIndex { $0.id == live.shown(for: task.id)?.id } ?? 0
                arrow("chevron.left") { live.cycle(pill: task.id, by: -1) }
                Text("\(index + 1)/\(list.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(Color(hex: "#A1A6AE"))
                    .fixedSize()
                arrow("chevron.right") { live.cycle(pill: task.id, by: 1) }
            } else if task.steps.count > 1 {
                Text("\(min(task.stepIndex + 1, task.steps.count))/\(task.steps.count)")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .fixedSize()
            }
        }
    }

    private func arrow(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Color(hex: "#A1A6AE"))
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}

extension LiveSessions {
    /// Title of a pill on the home card: the shown session's project when the pill has several.
    func title(for task: AgentTask) -> String {
        sessions(for: task.id).count > 1 ? (shown(for: task.id)?.projectName ?? task.name) : task.name
    }

    /// The pill's ticker, grouped by session. Upstream mixes every session's and every
    /// subagent's steps into one ticker; here it shows the shown session's own steps and its
    /// agents as one line ("▸ 2 agents running"). With one session and no agents the upstream
    /// ticker stays, so its diff rows keep opening the diff.
    func tickerTask(for task: AgentTask) -> AgentTask {
        guard let s = shown(for: task.id), usesSessionTicker(task) else { return task }
        var t = task
        t.name = s.projectName
        t.steps = s.steps.filter { $0.agentId == nil }.suffix(20).map(\.text)
        if t.steps.isEmpty, let message = s.finalMessage { t.steps = [message] }
        let running = s.runningSubagents
        if running > 0 {
            t.steps.append("▸ \(running) agent\(running == 1 ? "" : "s") running")
        } else if !s.subagents.isEmpty, s.isBusy {
            t.steps.append("▸ \(s.subagents.count) agent\(s.subagents.count == 1 ? "" : "s") done")
        }
        t.stepIndex = max(0, t.steps.count - 1)
        return t
    }

    func hasSeveralSessions(_ task: AgentTask) -> Bool { sessions(for: task.id).count > 1 }

    /// The session ticker replaces upstream's when the pill has several sessions or the shown
    /// one has agents; then the upstream diff indices no longer match the rows.
    func usesSessionTicker(_ task: AgentTask) -> Bool {
        hasSeveralSessions(task) || !(shown(for: task.id)?.subagents.isEmpty ?? true)
    }

    /// What a tap on the home card's step row does: open the Sessions view on the session the
    /// card shows. Nil when the pill has no listed session (upstream behaviour: nothing).
    func openAction(pill: String) -> (() -> Void)? {
        guard let id = shown(for: pill)?.id else { return nil }
        return { [weak self] in
            self?.select(id)
            AppState.shared.view = .sessions
        }
    }
}

// MARK: - Helpers

private func agentName(_ pill: String) -> String {
    PillCatalog.definition(for: pill)?.sessionSubtitle ?? "Agent"
}

@MainActor private func pillColor(_ pill: String) -> String {
    AppState.shared.tasks.first { $0.id == pill }?.color ?? PillCatalog.definition(for: pill)?.color ?? "#E07950"
}
