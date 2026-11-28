import Foundation

/// Turns one agent's `session/update`s into the stream-json objects Claude Code writes, so an ACP
/// turn is folded by the same ``Assembler`` and settled by the same store a Claude turn is: the
/// journal, the queue, the live mirror, the wait route, the Live Activity and the push need no
/// second road. A tool call is named for what it does (`execute` is Bash with its command, `read`
/// is Read with its path, …) so every client draws it the way it draws Claude's; the agent's plan
/// is a `TodoWrite`, which the clients already fold into the task board, and a question it puts
/// to the person is an `AskUserQuestion` left open, which is how every client knows to draw the
/// card and how the store knows the turn ended waiting on somebody.
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
    /// Questions put to the person this turn and not answered in it, by call id, each with the
    /// words of its first question.
    private var asked: [String: String] = [:]
    /// What the agent said went wrong in place of an answer, when it says so in the answer's own
    /// text rather than as a failure of the request.
    private(set) var failure: String?
    /// Set once the person pressed stop: a call the agent then reports failed was ended, not
    /// refused, and is left for the turn's close to mark stopped.
    var stopping = false

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
        if let failure = failure ?? (stopReason == "cancelled" ? nil : self.failure) {
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

    /// Every call still open when the turn ended, closed rather than left spinning. A question
    /// still waiting on the person is the exception: it stays open, because open is what it is.
    mutating func closeOpenCalls() -> [Output] {
        let open = calls.keys.filter { !closed.contains($0) && asked[$0] == nil }.sorted()
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
        if kind == .text {
            if let words = Self.executorFailure(text) {
                failure = words
                return []
            }
            if restatesQuestion(text) { return [] }
        }
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

    /// Whether a piece of the answer is only the agent writing out a question it has just asked
    /// through its question tool, which an agent does for a client it takes to have no form to
    /// show one in. The card asks it already, so the words are not said twice.
    private func restatesQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return asked.values.contains { !$0.isEmpty && trimmed.hasPrefix($0) }
    }

    /// Antigravity reports a request its model refused as a line of the answer and then ends the
    /// turn as if it had answered: "⚠ agent executor error: generating and executing: Error 429,
    /// Message: …, Status: RESOURCE_EXHAUSTED, Details: []". This reads such a line into the
    /// service's own message and its status, so the turn fails with words a person can act on.
    static func executorFailure(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let marker = "agent executor error:"
        guard trimmed.hasPrefix("⚠"), let found = trimmed.range(of: marker),
            trimmed[..<found.lowerBound].count <= 3
        else { return nil }
        var detail = trimmed[found.upperBound...].trimmingCharacters(in: .whitespaces)
        let lead = "generating and executing:"
        if detail.hasPrefix(lead) {
            detail = detail.dropFirst(lead.count).trimmingCharacters(in: .whitespaces)
        }
        guard !detail.isEmpty else { return "The agent's model did not answer." }
        let whole = NSRange(detail.startIndex..., in: detail)
        guard let match = Self.serviceError?.firstMatch(in: detail, range: whole),
            let code = Range(match.range(at: 1), in: detail),
            let message = Range(match.range(at: 2), in: detail)
        else { return detail }
        let words = detail[message].trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? detail : "\(words) (\(detail[code]))"
    }

    /// "Error 429, Message: …, Status: RESOURCE_EXHAUSTED, Details: […]", as Google's client
    /// library prints a refused request.
    private static let serviceError = try? NSRegularExpression(
        pattern: "^Error (\\d+), Message: (.*?), Status: [A-Z_]+, Details: .*$",
        options: [.dotMatchesLineSeparators])

    private mutating func toolCall(_ update: [String: Any]) -> [Output] {
        guard let id = update["toolCallId"] as? String else { return [] }
        calls[id] = update
        let (name, input) = Self.named(update)
        if name == Self.questionTool {
            asked[id] = ((input["questions"] as? [[String: Any]])?.first?["question"] as? String) ?? ""
        }
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
        out += settle(id, update)
        return out
    }

    /// The call's result, once the agent says it finished or failed. A command that ran and
    /// exited with an error failed, whatever the agent calls it; a call that failed with nothing
    /// to say after stop was pressed is left open for the turn's close to mark stopped.
    private mutating func settle(_ id: String, _ call: [String: Any]) -> [Output] {
        guard let status = call["status"] as? String, status == "completed" || status == "failed",
            !closed.contains(id)
        else { return [] }
        let output = Self.output(call)
        if stopping, status == "failed", output.isEmpty { return [] }
        closed.insert(id)
        asked[id] = nil
        return [
            .object(
                Self.toolResult(
                    id: id, output: output, failed: status == "failed" || Self.exitedWithError(call)))
        ]
    }

    private mutating func toolUpdate(_ update: [String: Any]) -> [Output] {
        guard let id = update["toolCallId"] as? String else { return [] }
        var merged = calls[id] ?? [:]
        for (key, value) in update where !(value is NSNull) { merged[key] = value }
        let known = calls[id] != nil
        if !known, Self.named(merged).0 == Self.questionTool { return [] }
        calls[id] = merged
        var out: [Output] = []
        if !known { out += toolCall(merged.merging(["status": "in_progress"]) { _, new in new }) }
        out += settle(id, merged)
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
        func word(_ keys: String...) -> String? {
            for key in keys {
                if let value = raw[key] as? String { return value }
            }
            return nil
        }
        let path = ((call["locations"] as? [[String: Any]])?.first?["path"] as? String)
            ?? word("path", "file_path", "Path")
        let diff = (call["content"] as? [[String: Any]])?.first { $0["type"] as? String == "diff" }
        if let own = Self.harnessTool(call["name"] as? String, raw: raw) { return own }
        switch kind {
        case "execute":
            let command = word("command", "cmd", "CommandLine") ?? Self.commandFromTitle(title)
            var input: [String: Any] = ["command": command]
            if let summary = word("description", "toolSummary"), !summary.isEmpty {
                input["description"] = summary
            } else if !title.isEmpty, title != command {
                input["description"] = title
            }
            return ("Bash", input)
        case "read":
            return ("Read", ["file_path": path ?? title])
        case "edit":
            let file = (diff?["path"] as? String) ?? path ?? title
            if let diff {
                if diff["oldText"] == nil || diff["oldText"] is NSNull {
                    return ("Write", ["file_path": file, "content": diff["newText"] as? String ?? ""])
                }
                return (
                    "Edit",
                    [
                        "file_path": file, "old_string": diff["oldText"] as? String ?? "",
                        "new_string": diff["newText"] as? String ?? "",
                    ]
                )
            }
            let old = word("old_string", "oldText", "old_str", "Target")
            let new = word("new_string", "newText", "new_str", "Replacement")
            if old == nil, new == nil, let content = word("content", "Content") {
                return ("Write", ["file_path": file, "content": content])
            }
            return ("Edit", ["file_path": file, "old_string": old ?? "", "new_string": new ?? ""])
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
            if let own = call["name"] as? String, !own.isEmpty { return (own, input) }
            let name = title.isEmpty ? kind.capitalized : Self.toolName(title)
            return (name, input)
        }
    }

    static let questionTool = "AskUserQuestion"

    /// A tool an agent's own harness names, where it is one the clients already draw when Claude
    /// Code calls it: Antigravity's checklist of steps is the task board, its question to the
    /// person is the question card, and the agent it starts is a subagent. Each is recognised by
    /// its name and the shape of what it was handed, never by its title.
    private static func harnessTool(_ name: String?, raw: [String: Any]) -> (String, [String: Any])? {
        switch name {
        case "update_steps":
            guard let steps = raw["steps"] as? [[String: Any]], !steps.isEmpty else { return nil }
            let todos: [[String: Any]] = steps.map { step in
                let title = step["title"] as? String ?? ""
                let status = step["status"] as? String ?? "pending"
                let ended = status == "skipped" || status == "failed"
                let content = ended ? "\(title) (\(status))" : title
                let reads: String
                switch status {
                case "done", "skipped": reads = "completed"
                case "in_progress": reads = "in_progress"
                default: reads = "pending"
                }
                return ["content": content, "activeForm": content, "status": reads]
            }
            return ("TodoWrite", ["todos": todos])
        case "ask_question":
            guard let asked = raw["questions"] as? [[String: Any]] else { return nil }
            let questions: [[String: Any]] = asked.compactMap { item in
                guard let question = item["question"] as? String, !question.isEmpty else { return nil }
                let options = (item["options"] as? [String] ?? []).map { option -> [String: Any] in
                    ["label": Self.optionLabel(option), "description": ""]
                }
                return [
                    "question": question, "header": "", "options": options,
                    "multiSelect": item["is_multi_select"] as? Bool ?? false,
                ]
            }
            return questions.isEmpty ? nil : (questionTool, ["questions": questions])
        case "invoke_subagent":
            guard let prompt = raw["Prompt"] as? String else { return nil }
            var input: [String: Any] = ["prompt": prompt]
            if let role = raw["Role"] as? String, !role.isEmpty { input["description"] = role }
            if let type = raw["TypeName"] as? String, !type.isEmpty { input["subagent_type"] = type }
            return ("Agent", input)
        default:
            return nil
        }
    }

    /// An option as a card's button reads it: Antigravity marks the one it would pick by leading
    /// with "(Recommended)", which reads better after the choice than before it.
    private static func optionLabel(_ option: String) -> String {
        let mark = "(Recommended)"
        guard option.hasPrefix(mark) else { return option }
        let rest = option.dropFirst(mark.count).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? option : "\(rest) \(mark)"
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

    /// Whether a command the agent ran ended with an error: it reports the exit code beside the
    /// output, and a nonzero one is a failure even when the call itself completed.
    static func exitedWithError(_ call: [String: Any]) -> Bool {
        guard let raw = call["rawOutput"] as? [String: Any],
            let code = (raw["exit_code"] as? NSNumber)?.intValue
        else { return false }
        return code != 0
    }

    /// What a command printed, without the receipt Antigravity wraps it in ("Created At: …",
    /// "Command exited with code 0.", "Command output:"), which is the agent's bookkeeping and not
    /// anything the command said.
    static func commandOutput(_ raw: [String: Any]) -> String? {
        guard raw["exit_code"] != nil, var text = raw["output"] as? String else { return nil }
        if let marker = text.range(of: "Command output:\n") {
            text = String(text[marker.upperBound...])
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        while text.hasSuffix("\n") { text.removeLast() }
        if text.isEmpty, let code = (raw["exit_code"] as? NSNumber)?.intValue, code != 0 {
            return "Exited with code \(code)."
        }
        return text
    }

    static func output(_ call: [String: Any]) -> String {
        if let raw = call["rawOutput"] as? [String: Any], let printed = commandOutput(raw) {
            return printed
        }
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
