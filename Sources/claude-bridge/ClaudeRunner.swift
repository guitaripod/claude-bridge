import Foundation

/// Spawns `claude -p` in streaming-JSON mode for one turn, maps its events to ``BridgeEvent``s,
/// and returns the assembled assistant message plus the (new or resumed) Claude session id.
struct ClaudeRunner: Sendable {
    let claudePath: String
    let workdir: String
    let permissionMode: String

    struct Outcome: Sendable {
        var message: Message
        var claudeSessionID: String?
        var costUSD: Double?
        var tokens: Int?
    }

    func run(
        prompt: String,
        resume claudeSessionID: String?,
        model: String,
        effort: String,
        fork: Bool = false,
        directory: String? = nil,
        emit: @Sendable @escaping (BridgeEvent) -> Void
    ) async -> Outcome {
        let cwd = directory ?? workdir
        let messageID = UUID().uuidString
        var arguments = [
            "-p", prompt,
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--model", model,
            "--effort", effort,
            "--permission-mode", permissionMode,
            "--add-dir", cwd,
        ]
        if permissionMode == "bypassPermissions" {
            arguments.append("--dangerously-skip-permissions")
        }
        if let claudeSessionID {
            arguments += ["--resume", claudeSessionID]
            if fork { arguments.append("--fork-session") }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CODE_ENTRYPOINT"] = "claude-bridge"
        process.environment = environment

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        emit(.status("running"))
        emit(
            .messageUpserted(
                Message(id: messageID, role: .assistant, parts: [.text("")], createdAt: Date())))

        var assembler = Assembler(messageID: messageID)
        let lines = Self.lineStream(from: stdout.fileHandleForReading)
        do {
            try process.run()
        } catch {
            emit(.error("Failed to launch Claude: \(error.localizedDescription)"))
            return Outcome(
                message: Message(
                    id: messageID, role: .assistant,
                    parts: [.text("⚠️ Could not start Claude.")], createdAt: Date()),
                claudeSessionID: claudeSessionID)
        }

        for await line in lines {
            guard let data = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            assembler.ingest(object, emit: emit)
        }
        process.waitUntilExit()

        let message = assembler.finalMessage()
        emit(.messageUpserted(message))
        emit(.status("idle"))
        return Outcome(
            message: message, claudeSessionID: assembler.sessionID ?? claudeSessionID,
            costUSD: assembler.costUSD, tokens: assembler.tokens)
    }

    /// Reads a file handle on a background thread, yielding complete newline-delimited lines.
    private static func lineStream(from handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            Thread.detachNewThread {
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer[buffer.startIndex..<newline]
                        buffer.removeSubrange(buffer.startIndex...newline)
                        if let line = String(data: lineData, encoding: .utf8) {
                            continuation.yield(line)
                        }
                    }
                }
                continuation.finish()
            }
        }
    }
}

/// Folds Claude's stream-json events into a single assistant message, emitting incremental events.
private struct Assembler {
    let messageID: String
    var sessionID: String?
    var costUSD: Double?
    var tokens: Int?
    private var text = ""
    private var thinking = ""
    private var tools: [String: ToolCall] = [:]
    private var toolOrder: [String] = []
    private var currentBlock: (index: Int, toolID: String?)?

    init(messageID: String) { self.messageID = messageID }

    mutating func ingest(_ object: [String: Any], emit: (BridgeEvent) -> Void) {
        switch object["type"] as? String {
        case "system":
            if object["subtype"] as? String == "init", let sid = object["session_id"] as? String {
                sessionID = sid
            }
        case "stream_event":
            ingestStreamEvent(object["event"] as? [String: Any] ?? [:], emit: emit)
        case "user":
            ingestToolResults(from: object, emit: emit)
        case "result":
            if let cost = object["total_cost_usd"] as? Double { costUSD = cost }
            if let usage = object["usage"] as? [String: Any] {
                let input = usage["input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                tokens = input + output
            }
        default:
            break
        }
    }

    private mutating func ingestStreamEvent(_ event: [String: Any], emit: (BridgeEvent) -> Void) {
        switch event["type"] as? String {
        case "content_block_start":
            let index = event["index"] as? Int ?? 0
            if let block = event["content_block"] as? [String: Any],
                block["type"] as? String == "tool_use",
                let id = block["id"] as? String
            {
                let call = ToolCall(
                    id: id, name: block["name"] as? String ?? "tool", input: "", status: .running)
                tools[id] = call
                toolOrder.append(id)
                currentBlock = (index, id)
                emit(.toolUpserted(messageID: messageID, call))
            } else {
                currentBlock = (index, nil)
            }
        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any] else { return }
            if let chunk = delta["text"] as? String {
                text += chunk
                emit(.partTextDelta(messageID: messageID, delta: chunk))
            } else if let chunk = delta["thinking"] as? String {
                thinking += chunk
            } else if let partial = delta["partial_json"] as? String,
                let toolID = currentBlock?.toolID
            {
                tools[toolID]?.input += partial
            }
        case "content_block_stop":
            currentBlock = nil
        default:
            break
        }
    }

    private mutating func ingestToolResults(from object: [String: Any], emit: (BridgeEvent) -> Void) {
        guard let message = object["message"] as? [String: Any],
            let content = message["content"] as? [[String: Any]]
        else { return }
        for block in content where block["type"] as? String == "tool_result" {
            guard let toolID = block["tool_use_id"] as? String, var call = tools[toolID] else {
                continue
            }
            call.output = Self.flatten(block["content"])
            call.status = (block["is_error"] as? Bool == true) ? .error : .completed
            tools[toolID] = call
            emit(.toolUpserted(messageID: messageID, call))
        }
    }

    func finalMessage() -> Message {
        var parts: [Part] = []
        if !thinking.isEmpty { parts.append(.reasoning(thinking)) }
        for id in toolOrder {
            if let call = tools[id] { parts.append(.tool(call)) }
        }
        if !text.isEmpty { parts.append(.text(text)) }
        if parts.isEmpty { parts.append(.text("")) }
        return Message(id: messageID, role: .assistant, parts: parts, createdAt: Date())
    }

    private static func flatten(_ content: Any?) -> String {
        if let string = content as? String { return string }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }
}
