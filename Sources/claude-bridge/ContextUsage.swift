import Foundation

/// `GET /sessions/:id/context`: what fills a conversation's context window, as its own CLI counts
/// it. A client could only estimate the window's contents from the transcript's characters; the CLI
/// knows the system prompt, the tool definitions, the memory files and skills it loaded and what
/// each kind of message weighs, and says so without a turn or a request to the model.
struct ContextUsageReport: Codable, Sendable, Equatable {
    struct Category: Codable, Sendable, Equatable {
        var id: String
        var name: String
        var tokens: Int
        /// `used`, `deferred` (tool definitions loaded only when asked for), `buffer` (held back for
        /// auto-compaction) or `free`.
        var kind: String
    }

    /// How the messages category divides, from the CLI's own breakdown.
    struct Messages: Codable, Sendable, Equatable {
        var user: Int
        var assistant: Int
        var toolCalls: Int
        var toolResults: Int
        var attachments: Int
        var other: Int
    }

    struct MemoryFile: Codable, Sendable, Equatable {
        var path: String
        var tokens: Int
    }

    var model: String?
    var totalTokens: Int
    var maxTokens: Int
    var autoCompactAt: Int?
    var categories: [Category]
    var messages: Messages?
    var memoryFiles: [MemoryFile]
    var measuredAt: Date

    /// The CLI's `get_context_usage` answer, read leniently: a field a newer CLI adds is ignored and
    /// one it drops leaves its slot empty, but an answer with no totals is no answer.
    static func read(_ data: Data, now: Date = Date()) -> ContextUsageReport? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let total = (object["totalTokens"] as? NSNumber)?.intValue,
            let max = ((object["maxTokens"] ?? object["rawMaxTokens"]) as? NSNumber)?.intValue
        else { return nil }
        let categories = (object["categories"] as? [[String: Any]] ?? []).compactMap { raw -> Category? in
            guard let id = raw["id"] as? String, let tokens = (raw["tokens"] as? NSNumber)?.intValue
            else { return nil }
            return Category(
                id: id, name: raw["name"] as? String ?? id, tokens: tokens,
                kind: raw["kind"] as? String ?? "used")
        }
        let breakdown = object["messageBreakdown"] as? [String: Any]
        let messages = breakdown.map { raw in
            func count(_ key: String) -> Int { (raw[key] as? NSNumber)?.intValue ?? 0 }
            return Messages(
                user: count("userMessageTokens"), assistant: count("assistantMessageTokens"),
                toolCalls: count("toolCallTokens"), toolResults: count("toolResultTokens"),
                attachments: count("attachmentTokens"),
                other: count("redirectedContextTokens") + count("unattributedTokens"))
        }
        let files = (object["memoryFiles"] as? [[String: Any]] ?? []).compactMap { raw -> MemoryFile? in
            guard let path = raw["path"] as? String, let tokens = (raw["tokens"] as? NSNumber)?.intValue
            else { return nil }
            return MemoryFile(path: path, tokens: tokens)
        }
        let compacts = object["isAutoCompactEnabled"] as? Bool != false
        return ContextUsageReport(
            model: object["model"] as? String, totalTokens: total, maxTokens: max,
            autoCompactAt: compacts ? (object["autoCompactThreshold"] as? NSNumber)?.intValue : nil,
            categories: categories, messages: messages, memoryFiles: files, measuredAt: now)
    }
}
