import Foundation

// MARK: - QuestionLine tests (coucou-custom fork)

@main
enum QuestionQueueTests {
    static var failures = 0
    static func check(_ label: String, _ ok: Bool) {
        print(ok ? "✓ \(label)" : "✗ \(label)")
        if !ok { failures += 1 }
    }

    static func q(_ session: String, age: TimeInterval = 0, fd: Int32 = 3) -> QueuedQuestion {
        let item = AskQuestionItem(question: "Pick?", header: "", options: [AskQuestionOption(label: "A", description: ""),
                                                                             AskQuestionOption(label: "B", description: "")],
                                   multiSelect: false)
        return QueuedQuestion(fd: fd, parsed: AskQuestion(questions: [item]), payload: [:], sessionId: session,
                              projectName: session, receivedAt: Date().addingTimeInterval(-age))
    }

    static func main() {
        var line = QuestionLine()
        check("first in", line.enqueue(q("A")))
        _ = line.enqueue(q("B")); _ = line.enqueue(q("C"))
        check("order kept", line.entries.map(\.sessionId) == ["A", "B", "C"])
        check("position of B is 2", line.position(of: "B") == 2)
        let n = line.next()
        check("next is the oldest", n.next?.sessionId == "A" && n.expired.isEmpty && line.count == 2)

        // Cap
        var full = QuestionLine()
        for i in 0..<QuestionLine.maxWaiting { _ = full.enqueue(q("s\(i)")) }
        check("over the cap: refused", !full.enqueue(q("extra")) && full.count == QuestionLine.maxWaiting)

        // Expired entries are skipped and handed back for release
        var old = QuestionLine()
        _ = old.enqueue(q("stale", age: QuestionLine.maxAge + 5)); _ = old.enqueue(q("fresh"))
        let r = old.next()
        check("expired skipped", r.next?.sessionId == "fresh" && r.expired.map(\.sessionId) == ["stale"])
        var allOld = QuestionLine()
        _ = allOld.enqueue(q("x", age: 500))
        let r2 = allOld.next()
        check("only expired: none shown, one released", r2.next == nil && r2.expired.count == 1 && allOld.isEmpty)

        // Answered in the terminal: by session
        var bySession = QuestionLine()
        _ = bySession.enqueue(q("A")); _ = bySession.enqueue(q("B")); _ = bySession.enqueue(q("A"))
        let gone = bySession.remove(session: "A")
        check("remove(session:) takes all of that session", gone.count == 2 && bySession.entries.map(\.sessionId) == ["B"])
        let id = bySession.entries[0].id
        check("remove(id:)", bySession.remove(id: id)?.sessionId == "B" && bySession.isEmpty)

        print(failures == 0 ? "\nQuestionQueueTests: all passed" : "\n\(failures) failed")
        if failures > 0 { exit(1) }
    }
}
