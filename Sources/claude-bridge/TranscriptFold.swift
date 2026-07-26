import Foundation

/// Incrementally folds transcript bytes into bridge messages, reporting which message ids each
/// chunk changed so a live watcher can emit precise upserts. Consecutive assistant API messages
/// (interleaved with tool results) merge into one turn, mirroring the bridge's own runner; the
/// open turn is part of ``snapshot`` so an in-flight response is visible mid-turn.
struct TranscriptFold: Sendable {
    private var messages: [Message] = []
    private var turn: Message?
    private var toolLocation: [String: (messageIndex: Int?, partIndex: Int)] = [:]
    private var pending = Data()
    private let includeSidechain: Bool
    /// Latest `/goal` record seen. Folded here rather than scanned separately because these bytes
    /// are already being read and parsed — goal tracking costs nothing on top of it.
    private(set) var goal: GoalStatus?

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

    /// Scans with a cursor and trims the consumed prefix once at the end —
    /// removing each line from the front of a whole-file feed is quadratic.
    mutating func consume(_ data: Data) -> Set<String> {
        pending.append(data)
        var changed = Set<String>()
        var start = pending.startIndex
        while let newline = pending[start...].firstIndex(of: 0x0A) {
            let lineData = pending[start..<newline]
            start = pending.index(after: newline)
            guard lineData.count > 1,
                let line = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            ingest(line, changed: &changed)
        }
        pending = Data(pending[start...])
        return changed
    }

    private mutating func ingest(_ line: [String: Any], changed: inout Set<String>) {
        if line["type"] as? String == "attachment" {
            guard let attachment = line["attachment"] as? [String: Any],
                let status = GoalStatus(
                    attachment: attachment,
                    timestamp: (line["timestamp"] as? String).flatMap(
                        TranscriptParser.parseTimestamp))
            else { return }
            goal = status
            return
        }
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
                    Message(
                        id: uuid, role: .user, parts: Self.userParts(text), createdAt: stamp))
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
                            parts: Self.userParts(texts.joined(separator: "\n\n")),
                            createdAt: stamp))
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

    /// Splits the attachment markers the bridge appends to a prompt back out of
    /// the text they were glued onto. The transcript is the only record a
    /// reloaded (or CLI-started) session has, so parsing them here is what makes
    /// an image the user sent still render as an image tomorrow — and keeps the
    /// machine-facing "use the Read tool" line out of the chat bubble.
    static func userParts(_ text: String) -> [Part] {
        guard text.contains(Self.attachmentMarker) else { return [.text(text)] }
        var prose: [String] = []
        var files: [FileRef] = []
        for line in text.components(separatedBy: "\n") {
            guard let path = Self.attachmentPath(in: line) else {
                prose.append(line)
                continue
            }
            files.append(
                FileRef(
                    path: path, mime: Self.mime(forPath: path),
                    filename: (path as NSString).lastPathComponent,
                    url: Self.attachmentURL(forPath: path)))
        }
        guard !files.isEmpty else { return [.text(text)] }
        let remainder = prose.joined(separator: "\n").trimmingCharacters(
            in: .whitespacesAndNewlines)
        return files.map { Part.file($0) } + (remainder.isEmpty ? [] : [.text(remainder)])
    }

    private static let attachmentMarker = "(use the Read tool to view it): "

    private static func attachmentPath(in line: String) -> String? {
        guard line.hasPrefix("Attached "), let range = line.range(of: Self.attachmentMarker)
        else { return nil }
        let path = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return path.hasPrefix("/") ? path : nil
    }

    /// Only files the bridge itself stored are fetchable; anything else the CLI
    /// was pointed at stays a path with no bytes behind it.
    private static func attachmentURL(forPath path: String) -> String? {
        let parts = path.components(separatedBy: "/")
        guard let root = parts.firstIndex(of: "attachments"), parts.count == root + 3 else {
            return nil
        }
        return "/attachments/\(parts[root + 1])/\(parts[root + 2])"
    }

    private static func mime(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "webp": return "image/webp"
        case "pdf": return "application/pdf"
        default: return "application/octet-stream"
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
