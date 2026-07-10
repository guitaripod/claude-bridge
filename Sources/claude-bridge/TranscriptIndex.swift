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

    func path(for id: String) -> String? {
        if pathByID[id] == nil { scan() }
        return pathByID[id]
    }

    func updatedAt(for id: String) -> Date? {
        guard let path = path(for: id) else { return nil }
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [
            .contentModificationDateKey
        ])
        return values?.contentModificationDate ?? cache[path]?.mtime
    }

    /// Session ids whose transcript (or subagent sidecar files) were written to
    /// within the window — "someone (this bridge or an interactive CLI) is
    /// working in this session right now". Subagent activity matters: while a
    /// session fans work out to agents, its main transcript can stay quiet for
    /// minutes even though it is very much live.
    func activeIDs(within seconds: TimeInterval) -> Set<String> {
        scan()
        let threshold = Date().addingTimeInterval(-seconds)
        var ids = Set<String>()
        for (path, slot) in cache {
            guard let entry = slot.entry else { continue }
            if slot.mtime > threshold || isSidecarActive(transcriptPath: path, after: threshold) {
                ids.insert(entry.id)
            }
        }
        return ids
    }

    /// Latest transcript mtime per session id, for freshening stored sessions
    /// whose conversation has since continued elsewhere.
    func transcriptDates() -> [String: Date] {
        scan()
        var dates: [String: Date] = [:]
        for slot in cache.values {
            guard let entry = slot.entry else { continue }
            dates[entry.id] = slot.mtime
        }
        return dates
    }

    /// True when the transcript (or its subagent sidecars) was written within
    /// the window — someone's process is actively working in the session.
    func isWriting(_ id: String, within seconds: TimeInterval) -> Bool {
        guard let path = path(for: id) else { return false }
        let threshold = Date().addingTimeInterval(-seconds)
        if let mtime = updatedAt(for: id), mtime > threshold { return true }
        return isSidecarActive(transcriptPath: path, after: threshold)
    }

    private func isSidecarActive(transcriptPath: String, after threshold: Date) -> Bool {
        guard let latest = TranscriptParser.sidecarActivity(transcriptPath: transcriptPath) else {
            return false
        }
        return latest > threshold
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

    static let activityWindow: TimeInterval = 180

    private func summary(for entry: Entry) -> SessionSummary {
        let threshold = Date().addingTimeInterval(-Self.activityWindow)
        let active =
            entry.updatedAt > threshold
            || isSidecarActive(transcriptPath: entry.path, after: threshold)
        return SessionSummary(
            id: entry.id,
            title: entry.title,
            directory: entry.directory,
            model: entry.model ?? defaultModel,
            effort: defaultEffort,
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt,
            active: active)
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
    static let toolOutputLimit = 10_000

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

    /// Latest write across the session's subagent sidecar transcripts
    /// (`<projectDir>/<sessionID>/subagents/*.jsonl`), if any exist.
    static func sidecarActivity(transcriptPath: String) -> Date? {
        let dir = URL(fileURLWithPath: transcriptPath)
            .deletingPathExtension()
            .appendingPathComponent("subagents")
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles)
        else { return nil }
        return files
            .filter { $0.pathExtension == "jsonl" }
            .compactMap {
                (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
            }
            .max()
    }

    /// Full parse: folds transcript lines into the bridge's message model.
    static func messages(at file: URL) -> [Message] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        var fold = TranscriptFold()
        _ = fold.consume(data)
        return fold.snapshot
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

    static func isRealLine(_ line: [String: Any]) -> Bool {
        line["isMeta"] as? Bool != true && line["isSidechain"] as? Bool != true
    }

    /// Human-typed prompt text; nil for command wrappers, caveats, and injected reminders.
    static func typedText(_ content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for marker in ["<command-", "<local-command", "<system-reminder", "Caveat:"]
        where trimmed.hasPrefix(marker) {
            return nil
        }
        return trimmed
    }

    /// Renders a slash-command invocation (`<command-name>/foo</command-name>…`) as `/foo args`.
    static func commandText(_ content: String) -> String? {
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

    static func flatten(_ content: Any?) -> String {
        if let string = content as? String { return string }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    static let fractionalTimestamp = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true)

    static func parseTimestamp(_ raw: String) -> Date? {
        (try? Date(raw, strategy: fractionalTimestamp)) ?? (try? Date(raw, strategy: .iso8601))
    }
}
