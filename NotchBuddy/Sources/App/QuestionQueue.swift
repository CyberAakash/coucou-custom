import Foundation
import Combine

// MARK: - Question queue (coucou-custom fork)
//
// Upstream shows one question at a time and a new one displaces the one on the card (sent back
// to its terminal, never offered again). Here a question that arrives while another is shown
// waits in line; it comes up when the shown one ends (answered in the notch or the terminal,
// Reply in terminal, timeout). Its hook connection is held meanwhile; the terminal keeps its own
// dialog (questions go through PermissionRequest), so it can be answered there at any time.

struct QueuedQuestion {
    let id = UUID()
    let fd: Int32
    let parsed: AskQuestion
    let payload: [String: Any]
    let sessionId: String
    let projectName: String
    let receivedAt: Date
}

struct QuestionLine {
    static let maxWaiting = 5
    /// The relay waits 118 s and Claude Code's hook timeout is 120 s: an older entry is dead.
    static let maxAge: TimeInterval = 110

    private(set) var entries: [QueuedQuestion] = []
    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    /// false when full: the caller sends the question back to its terminal.
    mutating func enqueue(_ q: QueuedQuestion) -> Bool {
        guard entries.count < Self.maxWaiting else { return false }
        entries.append(q)
        return true
    }

    /// The next one still alive, and the expired ones it skipped (to release).
    mutating func next(now: Date = Date()) -> (next: QueuedQuestion?, expired: [QueuedQuestion]) {
        var expired: [QueuedQuestion] = []
        while let first = entries.first {
            entries.removeFirst()
            if now.timeIntervalSince(first.receivedAt) < Self.maxAge { return (first, expired) }
            expired.append(first)
        }
        return (nil, expired)
    }

    /// Questions of `sessionId` (answered in that terminal, or its turn ended).
    mutating func remove(session sessionId: String) -> [QueuedQuestion] {
        let gone = entries.filter { $0.sessionId == sessionId }
        entries.removeAll { $0.sessionId == sessionId }
        return gone
    }

    mutating func remove(id: UUID) -> QueuedQuestion? {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return nil }
        return entries.remove(at: i)
    }

    func position(of sessionId: String) -> Int? {
        entries.firstIndex { $0.sessionId == sessionId }.map { $0 + 1 }
    }
}

/// What the question card and the Sessions view show about the line.
@MainActor
final class QuestionQueueModel: ObservableObject {
    static let shared = QuestionQueueModel()
    @Published var shownProject = ""
    @Published var shownSessionId = ""
    @Published var waitingSessions: [String] = []

    var waiting: Int { waitingSessions.count }
}
