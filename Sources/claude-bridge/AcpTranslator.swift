import Foundation

/// Turns one agent's `session/update`s into the stream-json objects Claude Code writes, so an ACP
/// turn is folded by the same ``Assembler`` and settled by the same store a Claude turn is: the
/// journal, the queue, the live mirror, the wait route, the Live Activity and the push need no
/// second road. A tool call is named for what it does (`execute` is Bash with its command, `read`
/// is Read with its path, …) so every client draws it the way it draws Claude's; the agent's plan
/// is a `TodoWrite`, which the clients already fold into the task board.
struct AcpTranslator {
    enum Output {
        case object([String: Any])
        case title(String)
        case context(used: Int, size: Int)
    }

    private enum Block { case none, text, thinking }
    private var block: Block = .none
    private var index = 0
    private var planCount = 0
    private var calls: [String: [String: Any]] = [:]
    private var closed: Set<String> = []

    mutating func translate(_ params: [String: Any]) -> [Output] {
        guard let update = params["update"] as? [String: Any],
            let kind = update["sessionUpdate"] as? String
        else { return [] }
        switch kind {
        case "agent_message_chunk":
            return chunk(update, as: .text)
        case "agent_thought_chunk":
            return chunk(update, as: .thinking)
        case "tool_call":
            return toolCall(update)
        case "tool_call_update":
            return toolUpdate(update)
        case "plan":
            return plan(update)
        case "session_info_update":
            guard let title = (update["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
            else { return [] }
            return [.title(title)]
        case "usage_update":
            guard let used = update["used"] as? Int, let size = update["size"] as? Int else {
                return []
            }
            return [.context(used: used, size: size)]
        default:
            return []
        }
    }

    /// How the turn ended, as the CLI would have said it. A refusal is the agent declining in so
    /// many words, which the assembler turns into the turn's own text and a failure event.
    func result(stopReason: String, failure: String? = nil) -> [String: Any] {
        if let failure {
            return ["type": "result", "is_error": true, "result": failure]
        }
        switch stopReason {
        case "refusal":
            return ["type": "result", "is_error": true, "result": "The agent declined to answer."]
        case "max_tokens":
            return [
                "type": "result", "is_error": true,
                "result": "The agent stopped at its output limit.",
            ]
        case "max_turn_requests":
            return [
                "type": "result", "is_error": true,
                "result": "The agent stopped at its limit of steps for one turn.",
            ]
        default:
            return ["type": "result", "is_error": false]
        }
    }

    /// Every call still open when the turn ended, closed as stopped rather than left spinning.
    mutating func closeOpenCalls() -> [Output] {
        let open = calls.keys.filter { !closed.contains($0) }.sorted()
        return open.flatMap { id in
            closed.insert(id)
            return [Output.object(Self.toolResult(id: id, output: "", failed: true))]
        }
    }

    private mutating func chunk(_ update: [String: Any], as kind: Block) -> [Output] {
        guard let content = update["content"] as? [String: Any],
            content["type"] as? String == "text",
            var text = content["text"] as? String, !text.isEmpty
        else { return [] }
        if block != kind {
            text = String(text.drop { $0.isNewline })
            guard !text.isEmpty else { return [] }
        }
        var out: [Output] = []
        if block != kind {
            index += 1
            out.append(
                .object(
                    Self.stream([
                        "type": "content_block_start", "index": index,
                        "content_block": ["type": kind == .text ? "text" : "thinking"],
                    ])))
            block = kind
        }
        let delta: [String: Any] =
            kind == .text ? ["type": "text_delta", "text": text] : ["type": "thinking_delta", "thinking": text]
        out.append(
            .object(Self.stream(["type": "content_block_delta", "index": index, "delta": delta])))
        return out
    }

    private mutating func toolCall(_ update: [String: Any]) -> [Output] {
        guard let id = update["toolCallId"] as? String else { return [] }
        calls[id] = update
        let (name, input) = Self.named(update)
        let inputJSON =
            (try? JSONSerialization.data(withJSONObject: input)).map {
                String(decoding: $0, as: UTF8.self)
            } ?? "{}"
        index += 1
        block = .none
        var out: [Output] = [
            .object(
                Self.stream([
                    "type": "content_block_start", "index": index,
                    "content_block": ["type": "tool_use", "id": id, "name": name],
                ])),
            .object(
                Self.stream([
                    "type": "content_block_delta", "index": index,
                    "delta": ["type": "input_json_delta", "partial_json": inputJSON],
                ])),
            .object(Self.stream(["type": "content_block_stop", "index": index])),
        ]
        if let status = update["status"] as? String, status == "completed" || status == "failed" {
            closed.insert(id)
            out.append(
                .object(
                    Self.toolResult(
                        id: id, output: Self.output(update), failed: status == "failed")))
        }
        return out
    }

    private mutating func toolUpdate(_ update: [String: Any]) -> [Output] {
        guard let id = update["toolCallId"] as? String else { return [] }
        var merged = calls[id] ?? [:]
        for (key, value) in update where !(value is NSNull) { merged[key] = value }
        let known = calls[id] != nil
        calls[id] = merged
        var out: [Output] = []
        if !known { out += toolCall(merged.merging(["status": "in_progress"]) { _, new in new }) }
        guard let status = merged["status"] as? String, status == "completed" || status == "failed",
            !closed.contains(id)
        else { return out }
        closed.insert(id)
        out.append(
            .object(Self.toolResult(id: id, output: Self.output(merged), failed: status == "failed")))
        return out
    }

    private mutating func plan(_ update: [String: Any]) -> [Output] {
        let entries = update["entries"] as? [[String: Any]] ?? []
        guard !entries.isEmpty else { return [] }
        planCount += 1
        let todos: [[String: Any]] = entries.map { entry in
            let content = entry["content"] as? String ?? ""
            return [
                "content": content, "activeForm": content,
                "status": entry["status"] as? String ?? "pending",
            ]
        }
        let id = "acp-plan-\(planCount)-\(UUID().uuidString.prefix(8))"
        index += 1
        block = .none
        let inputJSON =
            (try? JSONSerialization.data(withJSONObject: ["todos": todos])).map {
                String(decoding: $0, as: UTF8.self)
            } ?? "{}"
        closed.insert(id)
        return [
            .object(
                Self.stream([
                    "type": "content_block_start", "index": index,
                    "content_block": ["type": "tool_use", "id": id, "name": "TodoWrite"],
                ])),
            .object(
                Self.stream([
                    "type": "content_block_delta", "index": index,
                    "delta": ["type": "input_json_delta", "partial_json": inputJSON],
                ])),
            .object(Self.stream(["type": "content_block_stop", "index": index])),
            .object(Self.toolResult(id: id, output: "Plan updated", failed: false)),
        ]
    }

    /// A tool call named the way a Claude Code transcript would name the same act, with the input
    /// fields the clients read for it.
    static func named(_ call: [String: Any]) -> (String, [String: Any]) {
        let kind = call["kind"] as? String ?? "other"
        let title = (call["title"] as? String) ?? ""
        let raw = call["rawInput"] as? [String: Any] ?? [:]
        let path = ((call["locations"] as? [[String: Any]])?.first?["path"] as? String)
            ?? (raw["path"] as? String) ?? (raw["file_path"] as? String)
        let diff = (call["content"] as? [[String: Any]])?.first { $0["type"] as? String == "diff" }
        switch kind {
        case "execute":
            let command =
                (raw["command"] as? String)
                ?? (raw["cmd"] as? String)
                ?? Self.commandFromTitle(title)
            var input: [String: Any] = ["command": command]
            if !title.isEmpty, title != command { input["description"] = title }
            return ("Bash", input)
        case "read":
            return ("Read", ["file_path": path ?? title])
        case "edit":
            let file = (diff?["path"] as? String) ?? path ?? title
            if let diff, diff["oldText"] == nil || diff["oldText"] is NSNull {
                return ("Write", ["file_path": file, "content": diff["newText"] as? String ?? ""])
            }
            return (
                "Edit",
                [
                    "file_path": file, "old_string": diff?["oldText"] as? String ?? "",
                    "new_string": diff?["newText"] as? String ?? "",
                ]
            )
        case "search":
            let pattern = (raw["pattern"] as? String) ?? (raw["query"] as? String) ?? title
            if title.lowercased().contains("web") {
                return ("WebSearch", ["query": pattern])
            }
            var input: [String: Any] = ["pattern": pattern]
            if let path { input["path"] = path }
            return ("Grep", input)
        case "fetch":
            if let url = raw["url"] as? String { return ("WebFetch", ["url": url]) }
            if let query = raw["query"] as? String { return ("WebSearch", ["query": query]) }
            return ("WebFetch", ["url": title])
        default:
            if let known = Self.claudeTool(title, raw: raw, path: path) { return known }
            var input = raw
            if input.isEmpty, !title.isEmpty { input["description"] = title }
            if let path, input["file_path"] == nil { input["file_path"] = path }
            let name = title.isEmpty ? kind.capitalized : Self.toolName(title)
            return (name, input)
        }
    }

    /// Claude Code's tool names, keyed the way agents spell them in a title (`bash`, `Read`,
    /// `web_fetch`, `todo_write`). DeepSeek Harness reports every call as kind `other`, titled with
    /// such a name and carrying Claude-shaped arguments.
    private static let claudeTools: [String: String] = [
        "bash": "Bash", "read": "Read", "write": "Write", "edit": "Edit", "glob": "Glob",
        "grep": "Grep", "webfetch": "WebFetch", "websearch": "WebSearch", "todowrite": "TodoWrite",
    ]

    /// A call of no particular kind whose title is one of Claude Code's tool names is that tool,
    /// its input kept as the agent sent it except where Claude's shape differs: a file tool's path
    /// is its `file_path`, a search's first query its `query`, and each task its `activeForm`.
    private static func claudeTool(
        _ title: String, raw: [String: Any], path: String?
    ) -> (String, [String: Any])? {
        let key = toolName(title).lowercased().replacingOccurrences(of: "_", with: "")
        guard let name = claudeTools[key] else { return nil }
        var input = raw
        switch name {
        case "Read", "Write", "Edit":
            if input["file_path"] == nil, let path { input["file_path"] = path }
        case "WebSearch":
            if input["query"] == nil, let first = (raw["queries"] as? [String])?.first {
                input["query"] = first
            }
        case "TodoWrite":
            if let todos = raw["todos"] as? [[String: Any]] {
                input["todos"] = todos.map { todo in
                    todo.merging(["activeForm": todo["content"] as? String ?? ""]) { old, _ in old }
                }
            }
        default:
            break
        }
        return (name, input)
    }

    /// "terminal: uname -s" → "uname -s"; a title with no such prefix is the command itself.
    private static func commandFromTitle(_ title: String) -> String {
        guard let colon = title.firstIndex(of: ":") else { return title }
        let head = title[..<colon].lowercased()
        guard head.count <= 16, !head.contains(" ") else { return title }
        return String(title[title.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }

    /// A tool's own word from its title: the part before a colon or the first word, so a row reads
    /// "skill_view" rather than a sentence.
    private static func toolName(_ title: String) -> String {
        if let colon = title.firstIndex(of: ":") {
            let head = title[..<colon].trimmingCharacters(in: .whitespaces)
            if !head.isEmpty, head.count <= 32 { return head }
        }
        return String(title.prefix(48))
    }

    static func output(_ call: [String: Any]) -> String {
        var pieces: [String] = []
        for item in call["content"] as? [[String: Any]] ?? [] {
            switch item["type"] as? String {
            case "content":
                if let inner = item["content"] as? [String: Any], let text = inner["text"] as? String {
                    pieces.append(text)
                }
            case "diff":
                let path = item["path"] as? String ?? ""
                let old = (item["oldText"] as? String)?.split(whereSeparator: \.isNewline).count ?? 0
                let new = (item["newText"] as? String)?.split(whereSeparator: \.isNewline).count ?? 0
                pieces.append("\(path): +\(new) −\(old)")
            default:
                break
            }
        }
        if pieces.isEmpty {
            if let raw = call["rawOutput"] as? String {
                pieces.append(raw)
            } else if let raw = call["rawOutput"],
                !(raw is NSNull),
                let data = try? JSONSerialization.data(withJSONObject: raw, options: .fragmentsAllowed)
            {
                pieces.append(String(decoding: data, as: UTF8.self))
            }
        }
        return pieces.joined(separator: "\n")
    }

    private static func stream(_ event: [String: Any]) -> [String: Any] {
        ["type": "stream_event", "event": event]
    }

    static func toolResult(id: String, output: String, failed: Bool) -> [String: Any] {
        [
            "type": "user",
            "message": [
                "role": "user",
                "content": [
                    ["type": "tool_result", "tool_use_id": id, "content": output, "is_error": failed]
                ],
            ],
        ]
    }
}
