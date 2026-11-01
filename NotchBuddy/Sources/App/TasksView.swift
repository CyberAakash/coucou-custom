#if !APPSTORE
import AppKit
import SwiftUI

// MARK: - The Tasks page in the notch (coucou-custom fork, roadmap phase 2)
//
// Your Reminders, open ones only: the lists as chips on top with today's done count, the tasks
// grouped Overdue / Today / Later / No time, and a composer at the bottom, like a chat: type a
// task with a day or time and #list, Return adds it. Ticking, adding and deleting offer Undo.

struct TasksView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var store = TasksStore.shared
    @ObservedObject private var settings = TasksSettings.shared
    @Environment(\.islandViewActive) private var active

    @State private var text = ""
    @FocusState private var composing: Bool
    /// The list chip picked on top; nil shows every shown list.
    @State private var filter: String?
    @State private var undo: UndoNote?

    struct UndoNote: Identifiable {
        let id = UUID()
        let text: String
        let action: (() -> Void)?
    }

    var body: some View {
        ZStack {
            CardBackground(wash: nil)
            Group {
                switch store.access {
                case .granted: page
                case .unknown: permission(denied: false)
                case .denied: permission(denied: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
            if let undo {
                VStack {
                    Spacer()
                    undoToast(undo).padding(.bottom, 62)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: undo?.id)
        .onChange(of: active) { _, on in
            if on {
                store.reload()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { composing = true }
            } else {
                composing = false
            }
        }
        .onAppear {
            #if DEBUG
            if let sample = KeepDebug.tasksComposerText { text = sample }
            #endif
            store.reload()
            if active { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { composing = true } }
        }
    }

    // MARK: Permission

    private func permission(denied: Bool) -> some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Image(systemName: "checklist").font(.system(size: 22, weight: .semibold)).foregroundColor(Color(hex: "#22D3EE"))
            Text(denied ? "Coucou can't read your Reminders" : "Your tasks, from Reminders")
                .font(.system(size: 13, weight: .semibold))
            Text(denied ? "Allow Coucou in System Settings → Privacy & Security → Reminders."
                        : "Tasks you add here appear in Reminders on your iPhone and Watch, and the other way round.")
                .font(.system(size: 11.5)).foregroundColor(Color(hex: "#8E939C"))
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
            Button(denied ? "Open System Settings" : "Allow access to Reminders") {
                if denied { store.openPrivacySettings() } else { Task { await store.requestAccess() } }
            }
            .buttonStyle(HubButtonStyle(primary: true))
            .padding(.top, 2)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Page

    private var visible: [TaskItem] {
        let shown = Set(store.shownLists.map(\.id))
        return store.items.filter { shown.contains($0.listID) && (filter == nil || $0.listID == filter) }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 7) {
            topRow
            if visible.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(TaskGroup.allCases, id: \.self) { group in
                            let rows = visible.filter { TaskGroup.of($0) == group }
                            if !rows.isEmpty {
                                Text(group.label)
                                    .font(.system(size: 8, weight: .heavy)).tracking(1)
                                    .foregroundColor(group == .overdue ? Color(hex: "#F4505E") : Color(hex: "#6B7079"))
                                    .padding(.leading, 2).padding(.top, 3)
                                ForEach(rows) { row($0) }
                            }
                        }
                    }
                    .padding(.bottom, 2)
                }
            }
            composer
        }
    }

    private var topRow: some View {
        HStack(spacing: 6) {
            chip(title: "All", color: nil, on: filter == nil) { filter = nil }
            ForEach(store.shownLists) { list in
                chip(title: list.title, color: list.color, on: filter == list.id) { filter = filter == list.id ? nil : list.id }
            }
            Spacer(minLength: 6)
            if store.doneToday > 0 {
                Text("Done today · \(store.doneToday)").font(.system(size: 10)).foregroundColor(Color(hex: "#6B7079")).fixedSize()
            }
            Button("Show all in Reminders") { store.openReminders() }
                .buttonStyle(.plain).pointer()
                .font(.system(size: 10, weight: .semibold)).foregroundColor(Color(hex: "#3B9EFF")).fixedSize()
        }
    }

    private func chip(title: String, color: Color?, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let color { Circle().fill(color).frame(width: 7, height: 7) }
                Text(title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
            }
            .foregroundColor(on ? Color(hex: "#0B0C0E") : Color(hex: "#C5C8CD"))
            .padding(.horizontal, 9).frame(height: 22)
            .background(Capsule().fill(on ? Color(hex: "#F5F6F8") : Color.white.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).pointer()
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Spacer(minLength: 0)
            Text(store.items.isEmpty ? "Nothing to do" : "Nothing in this list")
                .font(.system(size: 13, weight: .semibold))
            Text("Type a task below; a day or time and #list are picked up.")
                .font(.system(size: 11.5)).foregroundColor(Color(hex: "#8E939C"))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: A task

    private func row(_ item: TaskItem) -> some View {
        let list = store.list(item.listID)
        let group = TaskGroup.of(item)
        return HStack(spacing: 9) {
            Rectangle().fill(list?.color ?? Color.gray).frame(width: 3)
            Button { complete(item) } label: {
                Circle().strokeBorder(group == .overdue ? Color(hex: "#F4505E") : Color(hex: "#6B7079"), lineWidth: 1.5)
                    .frame(width: 14, height: 14)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain).pointer().help("Done")
            Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            Text(timeLine(item, group: group, list: list))
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(group == .overdue ? Color(hex: "#F4505E") : Color(hex: "#8E939C"))
                .lineLimit(1).fixedSize()
                .padding(.trailing, 10)
        }
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contextMenu { menu(item) }
    }

    private func timeLine(_ item: TaskItem, group: TaskGroup, list: TaskList?) -> String {
        guard let due = item.due else { return filter == nil ? (list?.title ?? "No time") : "No time" }
        if group == .overdue {
            return "Missed " + (item.hasTime && Calendar.current.isDateInToday(due)
                ? due.formatted(date: .omitted, time: .shortened)
                : TaskComposer.label(due, hasTime: item.hasTime))
        }
        if group == .today { return item.hasTime ? due.formatted(date: .omitted, time: .shortened) : "Today" }
        return TaskComposer.label(due, hasTime: item.hasTime)
    }

    @ViewBuilder private func menu(_ item: TaskItem) -> some View {
        Menu("Move to list") {
            ForEach(store.lists) { list in
                Button { store.move(item.id, to: list.id) } label: {
                    if list.id == item.listID { Label(list.title, systemImage: "checkmark") } else { Text(list.title) }
                }
            }
        }
        Menu("Time") {
            Button("In an hour") { store.setDue(item.id, Date().addingTimeInterval(3600), hasTime: true) }
            Button("Tomorrow morning") {
                let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now)) ?? .now
                store.setDue(item.id, Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow), hasTime: true)
            }
            Button("Today") { store.setDue(item.id, Calendar.current.startOfDay(for: .now), hasTime: false) }
            Button("No time") { store.setDue(item.id, nil, hasTime: false) }
        }
        Divider()
        Button("Open in Reminders") { store.openReminders() }
        Button("Delete", role: .destructive) { delete(item) }
    }

    // MARK: Actions with Undo

    private func complete(_ item: TaskItem) {
        store.setDone(item.id, true)
        say("Done · \(item.title)") { store.setDone(item.id, false) }
    }

    private func delete(_ item: TaskItem) {
        store.delete(item.id)
        // Undo puts it back as a new reminder with the same text, time and list.
        say("Deleted · \(item.title)") { store.add(title: item.title, due: item.due, hasTime: item.hasTime, listID: item.listID) }
    }

    private func say(_ text: String, undo action: (() -> Void)?) {
        let note = UndoNote(text: text, action: action)
        undo = note
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if undo?.id == note.id { undo = nil } }
    }

    private func undoToast(_ note: UndoNote) -> some View {
        HStack(spacing: 10) {
            Text(note.text).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
            if let action = note.action {
                Button("Undo") { action(); undo = nil }
                    .buttonStyle(.plain).pointer()
                    .font(.system(size: 11.5, weight: .bold)).foregroundColor(Color(hex: "#22D3EE"))
            }
        }
        .padding(.horizontal, 14).frame(height: 30)
        .background(Capsule().fill(Color(hex: "#24262B")))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
    }

    // MARK: Composer

    private var parsed: ParsedTask {
        TaskComposer.parse(text, lists: store.lists.map { (id: $0.id, title: $0.title) })
    }

    /// Where a task typed now goes: its #list, else the list picked on top, else the default.
    private func targetList(_ p: ParsedTask) -> TaskList? {
        p.listID.flatMap(store.list) ?? filter.flatMap(store.list) ?? store.newTaskList
    }

    private var composer: some View {
        let p = parsed
        let target = targetList(p)
        return VStack(alignment: .leading, spacing: 5) {
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                HStack(spacing: 6) {
                    Text("Will add").font(.system(size: 9.5)).foregroundColor(Color(hex: "#6B7079"))
                    if let due = p.due {
                        Text(TaskComposer.label(due, hasTime: p.hasTime))
                            .font(.system(size: 10.5, weight: .semibold)).foregroundColor(Color(hex: "#67E8F9"))
                            .padding(.horizontal, 9).frame(height: 20)
                            .background(Capsule().fill(Color(hex: "#22D3EE").opacity(0.14)))
                    } else {
                        Text("No time").font(.system(size: 10.5, weight: .semibold)).foregroundColor(Color(hex: "#8E939C"))
                            .padding(.horizontal, 9).frame(height: 20)
                            .background(Capsule().fill(Color.white.opacity(0.06)))
                    }
                    if let target {
                        HStack(spacing: 5) {
                            Circle().fill(target.color).frame(width: 7, height: 7)
                            Text(target.title).font(.system(size: 10.5, weight: .semibold)).foregroundColor(Color(hex: "#C5C8CD"))
                        }
                        .padding(.horizontal, 9).frame(height: 20)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                    }
                }
                .padding(.leading, 2)
                .transition(.opacity)
            }
            HStack(spacing: 8) {
                TextField("Add a task to \(target?.title ?? "Reminders")…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focusEffectDisabled()   // the capsule's border already shows focus
                    .focused($composing)
                    .onSubmit(add)
                Button(action: add) {
                    Text("Return").font(.system(size: 10.5, weight: .heavy))
                        .foregroundColor(Color(hex: "#04161A"))
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(Capsule().fill(Color(hex: "#22D3EE").opacity(p.title.isEmpty ? 0.35 : 1)))
                }
                .buttonStyle(.plain).pointer(!p.title.isEmpty)
                .disabled(p.title.isEmpty)
            }
            .padding(.leading, 14).padding(.trailing, 6)
            .frame(height: 34)
            .background(Capsule().fill(Color(hex: "#1F2024")))
            .overlay(Capsule().strokeBorder(Color(hex: "#22D3EE").opacity(composing ? 0.45 : 0.12)))
            Text("Type a task; a day or time and #list are picked up. Return adds it. Right-click a task for its list and time.")
                .font(.system(size: 9.5)).foregroundColor(Color(hex: "#6B7079"))
                .lineLimit(1).padding(.horizontal, 4)
        }
        .animation(.easeOut(duration: 0.15), value: text.isEmpty)
    }

    private func add() {
        let p = parsed
        guard !p.title.isEmpty else { return }
        let target = targetList(p)
        if let id = store.add(title: p.title, due: p.due, hasTime: p.hasTime, listID: target?.id) {
            text = ""
            let when = p.due.map { " · " + TaskComposer.label($0, hasTime: p.hasTime) } ?? ""
            say("Added to \(target?.title ?? "Reminders")\(when)") { store.delete(id) }
        } else {
            say("Reminders didn't take it; try again", undo: nil)
        }
    }
}
#endif
