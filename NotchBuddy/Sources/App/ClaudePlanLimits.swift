#if !APPSTORE
import Foundation

// coucou-custom fork: the Claude plan's limits as claude.ai's usage page lists them — the current
// session, then each weekly limit (all models, and each model with its own, such as Fable) — read
// from Claude Code's `get_usage` control request (ClaudePlanLimitsFetcher). Kept free of AppKit for
// tests/DailyBriefTests.swift.

struct ClaudePlanLimits: Equatable, Codable {
    struct Limit: Equatable, Codable, Identifiable {
        enum Kind: String, Codable { case session, weeklyAll, weeklyModel }
        let kind: Kind
        /// "Current session", "All models", "Fable".
        let label: String
        let percent: Double
        let resetsAt: Date?
        var id: String { "\(kind.rawValue)·\(label)" }
        var isWeekly: Bool { kind != .session }
    }

    var plan: String?          // "team", "max", "pro"
    var limits: [Limit]
    var updatedAt: Date

    var session: Limit? { limits.first { $0.kind == .session } }
    var weekly: [Limit] { limits.filter(\.isWeekly) }

    /// The `response` of a `get_usage` control_response. Nil when the plan has no limits to show
    /// (an API key, a third-party provider) or the shape is not understood.
    static func parse(_ response: [String: Any], now: Date = Date()) -> ClaudePlanLimits? {
        guard let rate = response["rate_limits"] as? [String: Any] else { return nil }
        let plan = response["subscription_type"] as? String
        var limits: [Limit] = []
        if let rows = rate["limits"] as? [[String: Any]] {
            for row in rows {
                guard let kind = row["kind"] as? String, let pct = number(row["percent"]) else { continue }
                let resets = (row["resets_at"] as? String).flatMap(date)
                switch kind {
                case "session":
                    limits.append(Limit(kind: .session, label: "Current session", percent: pct, resetsAt: resets))
                case "weekly_all":
                    limits.append(Limit(kind: .weeklyAll, label: "All models", percent: pct, resetsAt: resets))
                case "weekly_scoped":
                    let scope = row["scope"] as? [String: Any]
                    let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
                    limits.append(Limit(kind: .weeklyModel, label: model ?? "Model", percent: pct, resetsAt: resets))
                default:
                    continue
                }
            }
        }
        // Older answers without `limits`: the named windows.
        if limits.isEmpty {
            func window(_ key: String) -> (Double, Date?)? {
                guard let w = rate[key] as? [String: Any], let pct = number(w["utilization"]) else { return nil }
                return (pct, (w["resets_at"] as? String).flatMap(date))
            }
            if let s = window("five_hour") { limits.append(Limit(kind: .session, label: "Current session", percent: s.0, resetsAt: s.1)) }
            if let w = window("seven_day") { limits.append(Limit(kind: .weeklyAll, label: "All models", percent: w.0, resetsAt: w.1)) }
            for (key, name) in [("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet")] {
                if let w = window(key) { limits.append(Limit(kind: .weeklyModel, label: name, percent: w.0, resetsAt: w.1)) }
            }
            for m in rate["model_scoped"] as? [[String: Any]] ?? [] {
                guard let name = m["display_name"] as? String, let pct = number(m["utilization"]) else { continue }
                limits.append(Limit(kind: .weeklyModel, label: name, percent: pct, resetsAt: (m["resets_at"] as? String).flatMap(date)))
            }
        }
        guard !limits.isEmpty else { return nil }
        return ClaudePlanLimits(plan: plan, limits: limits, updatedAt: now)
    }

    /// From the status line's windows, when the CLI cannot be asked: the session and the weekly.
    static func from(_ usage: PlanUsageWindows) -> ClaudePlanLimits? {
        var limits: [Limit] = []
        if let f = usage.fiveHour { limits.append(Limit(kind: .session, label: "Current session", percent: f.pct, resetsAt: f.resetsAt)) }
        if let s = usage.sevenDay { limits.append(Limit(kind: .weeklyAll, label: "All models", percent: s.pct, resetsAt: s.resetsAt)) }
        return limits.isEmpty ? nil : ClaudePlanLimits(plan: nil, limits: limits, updatedAt: usage.updatedAt)
    }

    private static func number(_ v: Any?) -> Double? { (v as? Double) ?? (v as? Int).map(Double.init) }

    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// "Resets in 2 hr 50 min", "Resets Mon 20:30".
    static func resetText(_ date: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let date else { return "" }
        let s = Int(date.timeIntervalSince(now))
        guard s > 0 else { return "Resets now" }
        if s < 3600 { return "Resets in \(max(1, s / 60)) min" }
        if s < 12 * 3600 { return "Resets in \(s / 3600) hr \((s % 3600) / 60) min" }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "EEE HH:mm"
        return "Resets \(f.string(from: date))"
    }
}

/// The status line's two windows, as the app keeps them (PlanUsage) — mirrored here so this file
/// stays free of the app's types.
struct PlanUsageWindows {
    var fiveHour: (pct: Double, resetsAt: Date)?
    var sevenDay: (pct: Double, resetsAt: Date)?
    var updatedAt: Date
}
#endif
