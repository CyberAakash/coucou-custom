import Foundation

// The recap's records, as RecapStore.swift has them (scripts/test-daily-brief.sh checks they match).

struct RecapTurn: Codable {
    var pillId: String
    var project: String
    var start: Date
    var end: Date
    var filesChanged: Int
    var linesAdded: Int
    var linesRemoved: Int
    var commandsRun: Int
    var questions: Int
}
struct RecapDecision: Codable {
    var pillId: String
    var date: Date
    var decision: String     // "allow", "always", "deny", "ask"
}
