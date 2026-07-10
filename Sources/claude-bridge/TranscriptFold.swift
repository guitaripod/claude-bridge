import Foundation

/// Incrementally folds transcript bytes into bridge messages, reporting which message ids each
/// chunk changed so a live watcher can emit precise upserts. Consecutive assistant API messages
/// (interleaved with tool results) merge into one turn, mirroring the bridge's own runner; the
/// open turn is part of ``snapshot`` so an in-flight response is visible mid-turn.
struct TranscriptFold {
    private var messages: [Message] = []
    private var turn: Message?
    private var toolLocation: [String: (messageIndex: Int?, partIndex: Int)] = [:]
    private var pending = Data()
    private let includeSidechain: Bool

    init(includeSidechain: Bool = false) {
        self.includeSidechain = includeSidechain
    }

    var snapshot: [Message] {
        var all = messages
        if let turn { all.append(turn) }
        return all.filter { !$0.parts.isEmpty }
    }

    mutating func reset() {
        self = TranscriptFold()
    }

    mutating func consume(_ data: Data) -> Set<String> {
        pending.append(data)
        var changed = Set<String>()
        while let newline = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            guard lineData.count > 1,
                let line = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            ingest(line, changed: &changed)
        }
        return changed
    }

    private mutating func ingest(_ line: [String: Any], changed: inout Set<String>) {
        guard line["isMeta"] as? Bool != true,
            includeSidechain || line["isSidechain"] as? Bool != true,
            let type = line["type"] as? String,
            let message = line["message"] as? [String: Any]
        else { return }
        let uuid = line["uuid"] as? String ?? UUID().uuidString
        let stamp =
            (line["timestamp"] as? String).flatMap(TranscriptParser.parseTimestamp) ?? Date()

        switch type {
        case "user":
            if let content = message["content"] as? String {
                guard let text = TranscriptParser.typedText(content)
                        ?? TranscriptParser.commandText(content)
                else { return }
                flushTurn()
                messages.append(
                    Message(id: uuid, role: .user, parts: [.text(text)], createdAt: stamp))
                changed.insert(uuid)
            } else if let blocks = message["content"] as? [[String: Any]] {
                var texts: [String] = []
                for block in blocks {
                    switch block["type"] as? String {
                    case "tool_result":
                        guard let toolID = block["tool_use_id"] as? String else { continue }
                        resolveTool(
                            toolID, output: TranscriptParser.flatten(block["content"]),
                            isError: block["is_error"] as? Bool == true, changed: &changed)
                    case "text":
                        if let text = (block["text"] as? String)
                            .flatMap(TranscriptParser.typedText)
                        {
                            texts.append(text)
                        }
                    default:
                        break
                    }
                }
                if !texts.isEmpty {
                    flushTurn()
                    messages.append(
                        Message(
                            id: uuid, role: .user,
                            parts: [.text(texts.joined(separator: "\n\n"))], createdAt: stamp))
                    changed.insert(uuid)
                }
            }
        case "assistant":
            guard let blocks = message["content"] as? [[String: Any]] else { return }
            if turn == nil {
                turn = Message(id: uuid, role: .assistant, parts: [], createdAt: stamp)
            }
            for block in blocks {
                switch block["type"] as? String {
                case "thinking":
                    if let thinking = block["thinking"] as? String, !thinking.isEmpty {
                        turn?.parts.append(.reasoning(thinking))
                        markTurnChanged(&changed)
                    }
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty {
                        turn?.parts.append(.text(text))
                        markTurnChanged(&changed)
                    }
                case "tool_use":
                    guard let toolID = block["id"] as? String else { continue }
                    let input =
                        (block["input"] as? [String: Any]).flatMap { object in
                            (try? JSONSerialization.data(withJSONObject: object))
                                .flatMap { String(data: $0, encoding: .utf8) }
                        } ?? ""
                    let call = ToolCall(
                        id: toolID, name: block["name"] as? String ?? "tool",
                        input: input, status: .running)
                    turn?.parts.append(.tool(call))
                    toolLocation[toolID] = (nil, (turn?.parts.count ?? 1) - 1)
                    markTurnChanged(&changed)
                default:
                    break
                }
            }
        default:
            return
        }
    }

    private mutating func markTurnChanged(_ changed: inout Set<String>) {
        if let id = turn?.id { changed.insert(id) }
    }

    private mutating func flushTurn() {
        guard let done = turn else { return }
        messages.append(done)
        for (toolID, location) in toolLocation where location.messageIndex == nil {
            toolLocation[toolID] = (messages.count - 1, location.partIndex)
        }
        turn = nil
    }

    private mutating func resolveTool(
        _ toolID: String, output: String, isError: Bool, changed: inout Set<String>
    ) {
        guard let location = toolLocation[toolID] else { return }
        let update: (inout Message) -> Void = { message in
            guard case .tool(var call) = message.parts[location.partIndex] else { return }
            call.output = String(output.prefix(TranscriptParser.toolOutputLimit))
            call.status = isError ? .error : .completed
            message.parts[location.partIndex] = .tool(call)
        }
        if let index = location.messageIndex {
            update(&messages[index])
            changed.insert(messages[index].id)
        } else if turn != nil {
            update(&turn!)
            markTurnChanged(&changed)
        }
    }
}
