import Foundation

/// A `/goal` — Claude Code's session-scoped stop-hook condition — as recorded in the transcript.
///
/// The CLI appends a `goal_status` attachment when a goal is set (`met: false`), cleared
/// (`met: true`), or achieved (`met: true` plus the judge's reasoning and turn stats). Its own
/// `findGoalToRestore` reads the *last* such record and resumes the condition unless it is met or
/// failed, which is why a goal survives the bridge respawning `claude -p --resume` per message.
/// ``isActive`` reproduces that rule exactly.
struct GoalStatus: Codable, Sendable, Equatable {
    var condition: String
    var met: Bool
    var failed: Bool?
    var reason: String?
    var iterations: Int?
    var durationMs: Double?
    var tokens: Int?
    var updatedAt: Date?

    var isActive: Bool { !met && failed != true }

    init?(attachment: [String: Any], timestamp: Date?) {
        guard attachment["type"] as? String == "goal_status",
            let condition = attachment["condition"] as? String, !condition.isEmpty
        else { return nil }
        self.condition = condition
        met = attachment["met"] as? Bool ?? false
        failed = attachment["failed"] as? Bool
        reason = attachment["reason"] as? String
        iterations = attachment["iterations"] as? Int
        durationMs = attachment["durationMs"] as? Double
        tokens = attachment["tokens"] as? Int
        updatedAt = timestamp
    }
}
