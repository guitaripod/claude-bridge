import Foundation

/// Read-only view over `~/.claude/projects`: every Claude Code CLI transcript on this machine
/// becomes a listable, resumable session. One `.jsonl` file is one session — the CLI keeps a
/// stable session id across `--resume` and appends turns to the same file.
actor TranscriptIndex {
    struct Entry: Sendable {
        var id: String
        var title: String
        var directory: String?
        var model: String?
        var createdAt: Date
        var updatedAt: Date
        var path: String
    }

    private struct CacheSlot {
        var mtime: Date
        var size: Int
        var entry: Entry?
    }

    private let root: URL
    private let defaultModel: String
    private let defaultEffort: String
    private var cache: [String: CacheSlot] = [:]
    private var pathByID: [String: String] = [:]

    init(root: URL, defaultModel: String, defaultEffort: String) {
        self.root = root
        self.defaultModel = defaultModel
        self.defaultEffort = defaultEffort
    }

    func list(excluding claimed: Set<String>, hidden: Set<String>) -> [SessionSummary] {
        scan()
        return cache.values
            .compactMap(\.entry)
            .filter { !claimed.contains($0.id) && !hidden.contains($0.id) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map(summary(for:))
    }

    func contains(_ id: String) -> Bool {
        if pathByID[id] == nil { scan() }
        return pathByID[id] != nil
    }

    /// Fully parses the transcript into a `Session` suitable for display or adoption.
    func session(_ id: String) -> Session? {
        if pathByID[id] == nil { scan() }
        guard let path = pathByID[id], let slot = cache[path], let entry = slot.entry else {
            return nil
        }
        let messages = TranscriptParser.messages(at: URL(fileURLWithPath: path))
        return Session(
            id: entry.id,
            title: entry.title,
            directory: entry.directory,
            claudeSessionID: entry.id,
            model: entry.model ?? defaultModel,
            effort: defaultEffort,
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt,
            messages: messages,
            lastCostUSD: nil,
            lastTokens: nil,
            pendingFork: nil)
    }

    private func summary(for entry: Entry) -> SessionSummary {
        SessionSummary(
            id: entry.id,
            title: entry.title,
            directory: entry.directory,
            model: entry.model ?? defaultModel,
            effort: defaultEffort,
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt)
    }

    private func scan() {
        let fileManager = FileManager.default
        guard
            let projectDirs = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles)
        else { return }

        var seen = Set<String>()
        for dir in projectDirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                let files = try? fileManager.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                    options: .skipsHiddenFiles)
            else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let name = file.deletingPathExtension().lastPathComponent
                guard UUID(uuidString: name) != nil else { continue }
                seen.insert(file.path)
                refresh(file, id: name)
            }
        }

        for stale in cache.keys where !seen.contains(stale) {
            if let id = cache[stale]?.entry?.id { pathByID[id] = nil }
            cache[stale] = nil
        }
    }

    private func refresh(_ file: URL, id: String) {
        guard
            let values = try? file.resourceValues(forKeys: [
                .contentModificationDateKey, .fileSizeKey,
            ]),
            let mtime = values.contentModificationDate,
            let size = values.fileSize
        else { return }
        if let slot = cache[file.path], slot.mtime == mtime, slot.size == size { return }

        let entry = TranscriptParser.entry(at: file, id: id, updatedAt: mtime)
        cache[file.path] = CacheSlot(mtime: mtime, size: size, entry: entry)
        if entry != nil { pathByID[id] = file.path }
    }
}

/// Parses Claude Code CLI transcript files (`.jsonl`, one JSON object per line).
enum TranscriptParser {
    private static let summaryScanLimit = 512 * 1024
    private static let toolOutputLimit = 10_000

    /// Cheap prefix scan: enough to produce a list row without reading the whole file.
    static func entry(at file: URL, id: String, updatedAt: Date) -> TranscriptIndex.Entry? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: summaryScanLimit)) ?? Data()

        var directory: String?
        var model: String?
        var createdAt: Date?
        var title: String?
        var commandTitle: String?

        for line in jsonLines(in: data, dropIncompleteTail: data.count == summaryScanLimit) {
            if directory == nil, let cwd = line["cwd"] as? String { directory = cwd }
            if createdAt == nil, let stamp = line["timestamp"] as? String {
                createdAt = parseTimestamp(stamp)
            }
            let message = line["message"] as? [String: Any]
            if model == nil, let value = message?["model"] as? String { model = value }
            guard title == nil, isRealLine(line), line["type"] as? String == "user",
                let content = message?["content"] as? String
            else { continue }
            if let typed = typedText(content) {
                title = deriveTitle(typed)
            } else if commandTitle == nil, let command = commandText(content) {
                commandTitle = deriveTitle(command)
            }
            if title != nil, directory != nil, model != nil { break }
        }

        guard let heading = title ?? commandTitle else { return nil }
        return TranscriptIndex.Entry(
            id: id, title: heading, directory: directory, model: model,
            createdAt: createdAt ?? updatedAt, updatedAt: updatedAt, path: file.path)
    }

    /// Full parse: folds transcript lines into the bridge's message model. Consecutive assistant
    /// API messages (interleaved with tool results) merge into one turn, mirroring how the
    /// bridge's own runner assembles a turn.
    static func messages(at file: URL) -> [Message] {
        guard let data = try? Data(contentsOf: file) else { return [] }

        var messages: [Message] = []
        var turn: Message?
        var toolLocation: [String: (messageIndex: Int?, partIndex: Int)] = [:]

        func flushTurn() {
            guard let done = turn else { return }
            messages.append(done)
            for (toolID, location) in toolLocation where location.messageIndex == nil {
                toolLocation[toolID] = (messages.count - 1, location.partIndex)
            }
            turn = nil
        }
        func resolveTool(_ toolID: String, output: String, isError: Bool) {
            guard let location = toolLocation[toolID] else { return }
            let update: (inout Message) -> Void = { message in
                guard case .tool(var call) = message.parts[location.partIndex] else { return }
                call.output = String(output.prefix(toolOutputLimit))
                call.status = isError ? .error : .completed
                message.parts[location.partIndex] = .tool(call)
            }
            if let index = location.messageIndex {
                update(&messages[index])
            } else if turn != nil {
                update(&turn!)
            }
        }

        for line in jsonLines(in: data, dropIncompleteTail: false) {
            guard isRealLine(line), let type = line["type"] as? String,
                let message = line["message"] as? [String: Any]
            else { continue }
            let uuid = line["uuid"] as? String ?? UUID().uuidString
            let stamp = (line["timestamp"] as? String).flatMap(parseTimestamp) ?? Date()

            switch type {
            case "user":
                if let content = message["content"] as? String {
                    guard let text = typedText(content) ?? commandText(content) else { continue }
                    flushTurn()
                    messages.append(
                        Message(id: uuid, role: .user, parts: [.text(text)], createdAt: stamp))
                } else if let blocks = message["content"] as? [[String: Any]] {
                    var texts: [String] = []
                    for block in blocks {
                        switch block["type"] as? String {
                        case "tool_result":
                            guard let toolID = block["tool_use_id"] as? String else { continue }
                            resolveTool(
                                toolID, output: flatten(block["content"]),
                                isError: block["is_error"] as? Bool == true)
                        case "text":
                            if let text = (block["text"] as? String).flatMap(typedText) {
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
                    }
                }
            case "assistant":
                guard let blocks = message["content"] as? [[String: Any]] else { continue }
                if turn == nil {
                    turn = Message(id: uuid, role: .assistant, parts: [], createdAt: stamp)
                }
                for block in blocks {
                    switch block["type"] as? String {
                    case "thinking":
                        if let thinking = block["thinking"] as? String, !thinking.isEmpty {
                            turn?.parts.append(.reasoning(thinking))
                        }
                    case "text":
                        if let text = block["text"] as? String, !text.isEmpty {
                            turn?.parts.append(.text(text))
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
                            input: input, status: .completed)
                        turn?.parts.append(.tool(call))
                        toolLocation[toolID] = (nil, (turn?.parts.count ?? 1) - 1)
                    default:
                        break
                    }
                }
            default:
                continue
            }
        }
        flushTurn()
        return messages.filter { !$0.parts.isEmpty }
    }

    private static func jsonLines(in data: Data, dropIncompleteTail: Bool) -> [[String: Any]] {
        var lines: [[String: Any]] = []
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            if end == data.endIndex, dropIncompleteTail { break }
            if end > start,
                let object = try? JSONSerialization.jsonObject(with: data[start..<end])
                    as? [String: Any]
            {
                lines.append(object)
            }
            start = end < data.endIndex ? data.index(after: end) : data.endIndex
        }
        return lines
    }

    private static func isRealLine(_ line: [String: Any]) -> Bool {
        line["isMeta"] as? Bool != true && line["isSidechain"] as? Bool != true
    }

    /// Human-typed prompt text; nil for command wrappers, caveats, and injected reminders.
    private static func typedText(_ content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for marker in ["<command-", "<local-command", "<system-reminder", "Caveat:"]
        where trimmed.hasPrefix(marker) {
            return nil
        }
        return trimmed
    }

    /// Renders a slash-command invocation (`<command-name>/foo</command-name>…`) as `/foo args`.
    private static func commandText(_ content: String) -> String? {
        guard let name = tagValue("command-name", in: content) else { return nil }
        let args = tagValue("command-args", in: content) ?? ""
        return args.isEmpty ? name : "\(name) \(args)"
    }

    private static func tagValue(_ tag: String, in content: String) -> String? {
        guard let open = content.range(of: "<\(tag)>"),
            let close = content.range(of: "</\(tag)>", range: open.upperBound..<content.endIndex)
        else { return nil }
        let value = content[open.upperBound..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func deriveTitle(_ text: String) -> String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        return String(firstLine.prefix(60))
    }

    private static func flatten(_ content: Any?) -> String {
        if let string = content as? String { return string }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    private static let fractionalTimestamp = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true)

    private static func parseTimestamp(_ raw: String) -> Date? {
        (try? Date(raw, strategy: fractionalTimestamp)) ?? (try? Date(raw, strategy: .iso8601))
    }
}
