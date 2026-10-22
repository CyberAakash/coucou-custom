// BotState for standalone test compilation; scripts/test-buddy.sh checks it matches
// Sources/CoucouKit/IslandTypes.swift.
import Foundation

enum BotState: String, CaseIterable {
    case idle, working, thinking, searching
    case approval, question, error, finished
    case ratelimit, sleeping, dizzy
}
