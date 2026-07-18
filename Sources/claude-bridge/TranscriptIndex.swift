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
        var contentDate: Date?
        var turnClosed = false
    }

    struct FoldState: Sendable {
        var fold: TranscriptFold
        var offset: Int
        var includeSidechain: Bool
    }

    private let root: URL
    private let defaultModel: String
    private let defaultEffort: String
    private var cache: [String: CacheSlot] = [:]
    private var pathByID: [String: String] = [:]
    private var folds: [String: FoldState] = [:]
    private var foldOrder: [String] = []
    private var foldTasks: [String: Task<FoldState?, Never>] = [:]
    private static let foldCacheLimit = 24

    init(root: URL, defaultModel: String, defaultEffort: String) {
        self.root = root
        self.defaultModel = defaultModel
        self.defaultEffort = defaultEffort
    }

    func list(excluding claimed: Set<String>, hidden: Set<String>) -> [SessionSummary] {
        scan()
        return cache.values
            .compactMap { slot -> SessionSummary? in
                guard let entry = slot.entry, !claimed.contains(entry.id),
                    !hidden.contains(entry.id)
                else { return nil }
                return summary(for: entry, turnClosed: slot.turnClosed)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
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
            let lastContent = slot.contentDate ?? slot.mtime
            let turnOpen = !slot.turnClosed && lastContent > threshold
            if turnOpen || isSidecarActive(transcriptPath: path, after: threshold) {
                ids.insert(entry.id)
            }
        }
        return ids
    }

    /// Machine-wide "someone is working" signal: any session with an open turn
    /// or subagent sidecar activity within the window.
    func anyActivity(within seconds: TimeInterval) -> Bool {
        !activeIDs(within: seconds).isEmpty
    }

    /// Directories that can hold subagent transcripts: the session's
    /// `subagents/` dir plus one `workflows/<runID>/` level beneath it.
    nonisolated static func sidecarDirs(transcriptPath: String) -> [URL] {
        let root = URL(fileURLWithPath: transcriptPath)
            .deletingPathExtension()
            .appendingPathComponent("subagents")
        var dirs = [root]
        let workflows = root.appendingPathComponent("workflows")
        if let runs = try? FileManager.default.contentsOfDirectory(
            at: workflows, includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles)
        {
            dirs.append(contentsOf: runs)
        }
        return dirs
    }

    /// Subagent sidecars for a session: one summary per `agent-*.jsonl` under
    /// `<sessionID>/subagents/` (including workflow runs), described by the
    /// sibling `.meta.json` the CLI writes alongside.
    func subagents(for id: String) -> [SubagentSummary] {
        guard let transcriptPath = path(for: id) else { return [] }
        let threshold = Date().addingTimeInterval(-Self.subagentActivityWindow)
        let resolved = resolvedTools(transcriptPath: transcriptPath)
        return Self.sidecarDirs(transcriptPath: transcriptPath).flatMap { dir in
            subagents(in: dir, threshold: threshold, resolved: resolved)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    static let subagentActivityWindow: TimeInterval = 90

    private var resolvedCache: [String: (offset: Int, ids: Set<String>)] = [:]

    /// Incremental: only bytes appended since the last call are scanned (with a small
    /// overlap so a marker split across reads isn't missed). A full-file scan of a
    /// growing transcript on every poll starves the actor for minutes.
    private func resolvedTools(transcriptPath: String) -> Set<String> {
        var cached = resolvedCache[transcriptPath] ?? (0, [])
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return cached.ids }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        if size < cached.offset { cached = (0, []) }
        guard size > cached.offset else { return cached.ids }
        let start = max(0, cached.offset - 64)
        try? handle.seek(toOffset: UInt64(start))
        guard let data = try? handle.read(upToCount: size - start) else { return cached.ids }
        cached.ids.formUnion(TranscriptParser.toolUseIDs(in: data))
        cached.offset = size
        resolvedCache[transcriptPath] = cached
        return cached.ids
    }

    /// Agent ids a workflow run's journal records a result for — the
    /// completion signal for workflow agents, which have no spawning Task
    /// tool call in the parent transcript.
    private func journalCompletedAgentIDs(in dir: URL) -> Set<String> {
        let journal = dir.appendingPathComponent("journal.jsonl")
        guard let data = try? Data(contentsOf: journal) else { return [] }
        var ids = Set<String>()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any],
                object["type"] as? String == "result",
                let agentID = object["agentId"] as? String
            else { continue }
            ids.insert(agentID)
        }
        return ids
    }

    private func subagents(in dir: URL, threshold: Date, resolved: Set<String>)
        -> [SubagentSummary]
    {
        let journalCompleted = journalCompletedAgentIDs(in: dir)
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles)
        else { return [] }
        return files
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { file -> SubagentSummary? in
                let name = file.deletingPathExtension().lastPathComponent
                guard name.hasPrefix("agent-") else { return nil }
                let lastContent =
                    TranscriptParser.lastContentDate(atPath: file.path)
                    ?? (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                var title = "Agent"
                var agentType: String?
                var toolUseID: String?
                let metaURL = dir.appendingPathComponent("\(name).meta.json")
                if let data = try? Data(contentsOf: metaURL),
                    let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                {
                    if let description = meta["description"] as? String, !description.isEmpty {
                        title = description
                    }
                    agentType = meta["agentType"] as? String
                    toolUseID = meta["toolUseId"] as? String
                }
                if title == "Agent",
                    let prompt = TranscriptParser.firstUserPromptLine(atPath: file.path)
                {
                    title = prompt
                }
                let agentID = String(name.dropFirst("agent-".count))
                let completed =
                    toolUseID.map(resolved.contains) ?? false
                    || journalCompleted.contains(agentID)
                return SubagentSummary(
                    id: agentID,
                    title: title, agentType: agentType, toolUseID: toolUseID,
                    updatedAt: lastContent,
                    active: !completed && lastContent > threshold,
                    completed: completed)
            }
    }

    func subagentMessages(sessionID: String, agentID: String) async -> [Message]? {
        guard let transcriptPath = path(for: sessionID),
            agentID.allSatisfy({ $0.isLetter || $0.isNumber })
        else { return nil }
        for dir in Self.sidecarDirs(transcriptPath: transcriptPath) {
            let file = dir.appendingPathComponent("agent-\(agentID).jsonl")
            if FileManager.default.fileExists(atPath: file.path) {
                return await foldedMessages(atPath: file.path, includeSidechain: true)
            }
        }
        return nil
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
        if let content = TranscriptParser.lastContentDate(atPath: path), content > threshold {
            return true
        }
        return isSidecarActive(transcriptPath: path, after: threshold)
    }

    private func isSidecarActive(transcriptPath: String, after threshold: Date) -> Bool {
        guard let latest = TranscriptParser.sidecarActivity(transcriptPath: transcriptPath) else {
            return false
        }
        return latest > threshold
    }

    /// Parses the transcript into a `Session` suitable for display or adoption. Incremental:
    /// only bytes appended since the last fetch are read and folded.
    func session(_ id: String) async -> Session? {
        if pathByID[id] == nil { scan() }
        guard let path = pathByID[id], let slot = cache[path], let entry = slot.entry else {
            return nil
        }
        let messages = await foldedMessages(atPath: path)
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

    /// Messages folded from a transcript, served from a per-path incremental cache: the fold
    /// state persists between calls and only appended bytes are read and parsed. The read+parse
    /// runs off the actor, so a large first parse never blocks other index consumers.
    func foldedMessages(atPath path: String, includeSidechain: Bool = false) async -> [Message] {
        await advanceFold(atPath: path, includeSidechain: includeSidechain)?.fold.snapshot ?? []
    }

    /// Fold state advanced to end-of-file, handed to the watcher so tailing continues from the
    /// bytes history parsing already consumed instead of re-reading the whole file.
    func foldHandoff(atPath path: String) async -> FoldState? {
        await advanceFold(atPath: path, includeSidechain: false)
    }

    /// Serialized per path by chaining onto the previous advance — never by
    /// polling a shared slot, which can livelock the actor when a waiter
    /// re-checks faster than the owner's continuation clears it.
    private func advanceFold(atPath path: String, includeSidechain: Bool) async -> FoldState? {
        let previous = foldTasks[path]
        let task = Task<FoldState?, Never> { [weak self] in
            _ = await previous?.value
            return await self?.performAdvance(path: path, includeSidechain: includeSidechain)
        }
        foldTasks[path] = task
        return await task.value
    }

    private func performAdvance(path: String, includeSidechain: Bool) async -> FoldState? {
        let prior = folds[path].flatMap { $0.includeSidechain == includeSidechain ? $0 : nil }
        let parse = Task.detached(priority: .userInitiated) {
            Self.advance(prior, path: path, includeSidechain: includeSidechain)
        }
        let state = await parse.value
        if let state {
            folds[path] = state
            touchFold(path)
        } else {
            folds[path] = nil
            foldOrder.removeAll { $0 == path }
            foldTasks[path] = nil
        }
        return state
    }

    private nonisolated static func advance(
        _ prior: FoldState?, path: String, includeSidechain: Bool
    ) -> FoldState? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        var state =
            prior
            ?? FoldState(
                fold: TranscriptFold(includeSidechain: includeSidechain), offset: 0,
                includeSidechain: includeSidechain)
        if size < state.offset {
            state = FoldState(
                fold: TranscriptFold(includeSidechain: includeSidechain), offset: 0,
                includeSidechain: includeSidechain)
        }
        guard size > state.offset else { return state }
        try? handle.seek(toOffset: UInt64(state.offset))
        guard let data = try? handle.read(upToCount: size - state.offset), !data.isEmpty else {
            return state
        }
        _ = state.fold.consume(data)
        state.offset += data.count
        return state
    }

    private func touchFold(_ path: String) {
        foldOrder.removeAll { $0 == path }
        foldOrder.append(path)
        while foldOrder.count > Self.foldCacheLimit {
            let evicted = foldOrder.removeFirst()
            folds[evicted] = nil
            foldTasks[evicted] = nil
        }
    }

    static let activityWindow: TimeInterval = 180

    /// Discovered transcripts don't record an effort level, so the summary
    /// carries an empty one rather than presenting the server default as if
    /// the session actually ran with it.
    private func summary(for entry: Entry, turnClosed: Bool) -> SessionSummary {
        let threshold = Date().addingTimeInterval(-Self.activityWindow)
        let active =
            (!turnClosed && entry.updatedAt > threshold)
            || isSidecarActive(transcriptPath: entry.path, after: threshold)
        return SessionSummary(
            id: entry.id,
            title: entry.title,
            directory: entry.directory,
            model: entry.model ?? defaultModel,
            effort: "",
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

        let contentDate = TranscriptParser.lastContentDate(atPath: file.path)
        let entry = TranscriptParser.entry(at: file, id: id, updatedAt: contentDate ?? mtime)
        cache[file.path] = CacheSlot(
            mtime: mtime, size: size, entry: entry, contentDate: contentDate,
            turnClosed: TranscriptParser.isTurnClosed(atPath: file.path))
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

    /// Timestamp of the last conversation line in a transcript. An interactive
    /// CLI left open keeps touching the file (trailing `last-prompt` metadata,
    /// no timestamp), so file mtime alone reads attached-but-idle sessions as
    /// active forever.
    static func lastContentDate(atPath path: String) -> Date? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        let window = min(size, 64 * 1024)
        try? handle.seek(toOffset: UInt64(size - window))
        guard let data = try? handle.read(upToCount: window) else { return nil }
        for line in jsonLines(in: data, dropIncompleteTail: false).reversed() {
            if let stamp = (line["timestamp"] as? String).flatMap(parseTimestamp) {
                return stamp
            }
        }
        return nil
    }

    /// First line of the first user prompt in a (sidecar) transcript — the
    /// task description a subagent was spawned with.
    static func firstUserPromptLine(atPath path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 32 * 1024)) ?? Data()
        for line in jsonLines(in: data, dropIncompleteTail: true) {
            guard line["type"] as? String == "user",
                let content = (line["message"] as? [String: Any])?["content"] as? String
            else { continue }
            let first = content.split(separator: "\n").first.map(String.init) ?? content
            let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { continue }
            return String(trimmed.prefix(80))
        }
        return nil
    }

    /// Whether the transcript's last meaningful line closes the turn: the CLI
    /// writes a `system`/`turn_duration` marker when a turn completes, and an
    /// interruption leaves a "[Request interrupted…" user line. Absence of
    /// both means a turn is (or may still be) in flight.
    static func isTurnClosed(atPath path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        let window = min(size, 64 * 1024)
        try? handle.seek(toOffset: UInt64(size - window))
        guard let data = try? handle.read(upToCount: window) else { return false }
        for line in jsonLines(in: data, dropIncompleteTail: false).reversed() {
            switch line["type"] as? String {
            case "system":
                if line["subtype"] as? String == "turn_duration" { return true }
            case "user":
                if let content = (line["message"] as? [String: Any])?["content"] as? String,
                    content.hasPrefix("[Request interrupted")
                {
                    return true
                }
                return false
            case "assistant":
                return false
            default:
                continue
            }
        }
        return false
    }

    /// Tool-use ids that already have a result recorded in the transcript —
    /// a subagent whose spawning Task call is resolved has finished. Byte
    /// scan, never a String walk: grapheme-aware searching of a transcript
    /// this size takes minutes.
    static func toolUseIDs(in data: Data) -> Set<String> {
        let marker = Data("\"tool_use_id\":\"".utf8)
        var ids = Set<String>()
        var search = data.startIndex
        while let range = data.range(of: marker, in: search..<data.endIndex) {
            let tail = data[range.upperBound...]
            guard let close = tail.firstIndex(of: 0x22) else { break }
            ids.insert(String(decoding: data[range.upperBound..<close], as: UTF8.self))
            search = close
        }
        return ids
    }

    /// Latest write across the session's subagent sidecar transcripts,
    /// including workflow-run agents one level deeper.
    static func sidecarActivity(transcriptPath: String) -> Date? {
        TranscriptIndex.sidecarDirs(transcriptPath: transcriptPath)
            .compactMap { dir -> Date? in
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
            .max()
    }

    /// Full parse: folds transcript lines into the bridge's message model.
    static func messages(at file: URL, includeSidechain: Bool = false) -> [Message] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        var fold = TranscriptFold(includeSidechain: includeSidechain)
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

    /// Human-typed prompt text; nil for command wrappers, caveats, and injected
    /// reminders. Background-task notifications condense to a one-line status
    /// instead of their raw XML payload.
    static func typedText(_ content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("<task-notification") {
            return taskNotificationSummary(trimmed)
        }
        for marker in ["<command-", "<local-command", "<system-reminder", "Caveat:"]
        where trimmed.hasPrefix(marker) {
            return nil
        }
        return trimmed
    }

    static func taskNotificationSummary(_ content: String) -> String? {
        var lead = tagValue("summary", in: content)?
            .split(separator: "\n").first.map(String.init)
        if lead == nil, tagValue("status", in: content) != nil || tagValue("usage", in: content) != nil {
            lead = "Background agent finished"
        }
        guard var text = lead else { return nil }
        var stats: [String] = []
        if let ms = tagValue("duration_ms", in: content).flatMap(Double.init) {
            stats.append(compactDuration(ms / 1000))
        }
        if let tools = tagValue("tool_uses", in: content) {
            stats.append("\(tools) tools")
        }
        if let tokens = tagValue("subagent_tokens", in: content).flatMap(Int.init) {
            stats.append(tokens >= 1000 ? "\(tokens / 1000)k tokens" : "\(tokens) tokens")
        }
        if !stats.isEmpty { text += " · " + stats.joined(separator: " · ") }
        return text
    }

    static func compactDuration(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        if seconds < 60 { return "\(max(seconds, 1))s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
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
