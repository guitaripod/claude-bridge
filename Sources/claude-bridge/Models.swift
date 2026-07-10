import Foundation

enum Role: String, Codable, Sendable {
    case user
    case assistant
}

enum ToolStatus: String, Codable, Sendable {
    case running
    case completed
    case error
}

struct ToolCall: Codable, Sendable {
    var id: String
    var name: String
    var input: String
    var output: String?
    var status: ToolStatus
}

enum Part: Codable, Sendable {
    case text(String)
    case reasoning(String)
    case tool(ToolCall)

    private enum CodingKeys: String, CodingKey { case kind, text, tool }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try c.encode("text", forKey: .kind)
            try c.encode(value, forKey: .text)
        case .reasoning(let value):
            try c.encode("reasoning", forKey: .kind)
            try c.encode(value, forKey: .text)
        case .tool(let call):
            try c.encode("tool", forKey: .kind)
            try c.encode(call, forKey: .tool)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "tool": self = .tool(try c.decode(ToolCall.self, forKey: .tool))
        case "reasoning": self = .reasoning(try c.decode(String.self, forKey: .text))
        default: self = .text(try c.decode(String.self, forKey: .text))
        }
    }
}

struct Message: Codable, Sendable {
    var id: String
    var role: Role
    var parts: [Part]
    var createdAt: Date
}

struct Session: Codable, Sendable {
    var id: String
    var title: String
    var directory: String?
    var claudeSessionID: String?
    var model: String
    var effort: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [Message]
    var lastCostUSD: Double?
    var lastTokens: Int?
    var pendingFork: Bool?

    var summary: SessionSummary {
        SessionSummary(
            id: id, title: title, directory: directory, model: model, effort: effort,
            createdAt: createdAt, updatedAt: updatedAt)
    }
}

struct SessionSummary: Codable, Sendable {
    var id: String
    var title: String
    var directory: String?
    var model: String
    var effort: String
    var createdAt: Date
    var updatedAt: Date
    var active: Bool?
}

struct SendRequest: Codable, Sendable {
    var text: String
    var model: String?
    var effort: String?
}

struct CreateRequest: Codable, Sendable {
    var title: String?
    var directory: String?
    var model: String?
    var effort: String?
}

/// Events streamed to a subscribed client over SSE. Mirrors the Kit's BackendEvent shape.
enum BridgeEvent: Codable, Sendable {
    case messageUpserted(Message)
    case partTextDelta(messageID: String, delta: String)
    case toolUpserted(messageID: String, ToolCall)
    case status(String)
    case error(String)

    private enum CodingKeys: String, CodingKey {
        case type, message, messageID, delta, tool, status, error
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .messageUpserted(let message):
            try c.encode("message", forKey: .type)
            try c.encode(message, forKey: .message)
        case .partTextDelta(let messageID, let delta):
            try c.encode("delta", forKey: .type)
            try c.encode(messageID, forKey: .messageID)
            try c.encode(delta, forKey: .delta)
        case .toolUpserted(let messageID, let tool):
            try c.encode("tool", forKey: .type)
            try c.encode(messageID, forKey: .messageID)
            try c.encode(tool, forKey: .tool)
        case .status(let value):
            try c.encode("status", forKey: .type)
            try c.encode(value, forKey: .status)
        case .error(let value):
            try c.encode("error", forKey: .type)
            try c.encode(value, forKey: .error)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "message": self = .messageUpserted(try c.decode(Message.self, forKey: .message))
        case "delta":
            self = .partTextDelta(
                messageID: try c.decode(String.self, forKey: .messageID),
                delta: try c.decode(String.self, forKey: .delta))
        case "tool":
            self = .toolUpserted(
                messageID: try c.decode(String.self, forKey: .messageID),
                try c.decode(ToolCall.self, forKey: .tool))
        case "status": self = .status(try c.decode(String.self, forKey: .status))
        default: self = .error(try c.decode(String.self, forKey: .error))
        }
    }
}
