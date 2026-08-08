import Foundation

/// The whole machine's ledger, aggregated: every transcript the CLI has written — and every
/// subagent sidecar working for one — read the same way `/sessions/:id/spend` reads one file.
/// Nothing is stored beyond a per-file cache: the files are the account, so work done in a
/// terminal or before this bridge existed reports exactly as well as work the bridge ran itself.
struct AnalyticsReport: Codable, Sendable {
    struct Totals: Codable, Sendable {
        var costUSD: Double
        var tokens: TokenCounts
        var turns: Int
        var toolCalls: Int
        var sessions: Int
        var activeDays: Int
    }

    struct Day: Codable, Sendable {
        var day: String
        var costUSD: Double
        var tokens: TokenCounts
        var turns: Int
        var toolCalls: Int
        var sessions: Int
    }

    struct Project: Codable, Sendable {
        var directory: String
        var name: String
        var sessions: Int
        var turns: Int
        var costUSD: Double
        var tokens: TokenCounts
    }

    struct Tool: Codable, Sendable {
        var name: String
        var calls: Int
    }

    struct Compactions: Codable, Sendable {
        var count: Int
        var reclaimedTokens: Int
    }

    struct Subagents: Codable, Sendable {
        var runs: Int
        var tokens: TokenCounts
        var costUSD: Double
    }

    struct Records: Codable, Sendable {
        struct BusiestDay: Codable, Sendable {
            var day: String
            var costUSD: Double
            var turns: Int
        }

        struct Session: Codable, Sendable {
            var id: String
            var title: String
            var costUSD: Double
            var turns: Int
        }

        struct Turn: Codable, Sendable {
            var at: Date
            var costUSD: Double
            var seconds: Double?
            var model: String?
            var prompt: String?
            var sessionTitle: String?
        }

        var busiestDay: BusiestDay?
        var priciestSession: Session?
        var priciestTurn: Turn?
        var longestTurn: Turn?
        var streakDays: Int
    }

    var since: Date
    var generatedAt: Date
    var days: Int
    var estimated = true
    var totals: Totals
    var daily: [Day]
    var models: [SpendModel]
    var projects: [Project]
    var tools: [Tool]
    var hourTurns: [Int]
    var hourCostUSD: [Double]
    var cacheSavedUSD: Double
    var compactions: Compactions
    var subagents: Subagents
    var records: Records
}

/// One file reduced to what aggregation needs, cached against the file's identity so a machine
/// with years of history pays the full walk once and then only for files that grew.
///
/// A turn keeps its lines instead of a pre-summed total because the ledger must not pay twice
/// for what the CLI wrote twice: one API message is split across one JSONL line per content
/// block, each repeating the same `usage`, and a fork or resume copies the whole inherited
/// prefix — ids, timestamps and all — into the new file. Money dedups machine-wide by the API
/// message id; tool calls by the line's own uuid, because two tool blocks of one message share
/// the message id and are still two calls.
struct AnalyticsFileStats: Sendable {
    struct Line: Sendable {
        var messageID: String?
        var uuid: String?
        var tokens: TokenCounts
        var costUSD: Double
        var tools: [String: Int]
    }

    struct Turn: Sendable {
        var at: Date
        var seconds: Double?
        var model: String?
        var sidechain: Bool
        var prompt: String?
        var lines: [Line]
    }

    struct Compaction: Sendable {
        var at: Date
        var reclaimed: Int
    }

    var turns: [Turn] = []
    var compactions: [Compaction] = []
}

actor AnalyticsLedger {
    private struct Slot {
        var mtime: Date
        var size: Int
        var stats: AnalyticsFileStats
    }

    private struct Job: Sendable {
        var path: String
        var mtime: Date
        var size: Int
        var sidecar: Bool
        var sourceIndex: Int
    }

    private let index: TranscriptIndex
    private var cache: [String: Slot] = [:]
    private static let parseWidth = 8
    /// A gap between a prompt and its last answer past this is a `--resume` days later, not a
    /// turn anyone sat through; it must not win "longest turn".
    static let plausibleTurnSeconds: Double = 7_200

    init(index: TranscriptIndex) {
        self.index = index
    }

    func report(days: Int, now: Date = Date()) async -> AnalyticsReport {
        let window = max(1, min(days, 365))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let today = calendar.startOfDay(for: now)
        let since = calendar.date(byAdding: .day, value: -(window - 1), to: today) ?? today
        let sources = await index.analyticsSources().filter { $0.mtime >= since }

        var jobs: [Job] = []
        for (position, source) in sources.enumerated() {
            jobs.append(
                Job(
                    path: source.path, mtime: source.mtime, size: source.size, sidecar: false,
                    sourceIndex: position))
            for sidecar in Self.sidecarFiles(transcriptPath: source.path, since: since) {
                jobs.append(
                    Job(
                        path: sidecar.path, mtime: sidecar.mtime, size: sidecar.size,
                        sidecar: true, sourceIndex: position))
            }
        }

        let pending = jobs.filter { job in
            guard let slot = cache[job.path] else { return true }
            return slot.mtime != job.mtime || slot.size != job.size
        }
        for (path, slot) in await Self.parse(jobs: pending) {
            cache[path] = slot
        }

        var perSource: [(source: TranscriptIndex.AnalyticsSource, stats: AnalyticsFileStats)] = []
        var subagentRuns: [Int: Int] = [:]
        for source in sources {
            perSource.append((source, AnalyticsFileStats()))
        }
        for job in jobs {
            guard let stats = cache[job.path]?.stats else { continue }
            if job.sidecar, stats.turns.contains(where: { $0.at >= since }) {
                subagentRuns[job.sourceIndex, default: 0] += 1
            }
            perSource[job.sourceIndex].stats.turns.append(contentsOf: stats.turns)
            perSource[job.sourceIndex].stats.compactions.append(contentsOf: stats.compactions)
        }
        let order = perSource.indices.sorted {
            perSource[$0].source.createdAt < perSource[$1].source.createdAt
        }
        return Self.aggregate(
            perSource: order.map { perSource[$0] },
            subagentRuns: Dictionary(
                uniqueKeysWithValues: order.enumerated().compactMap { position, original in
                    subagentRuns[original].map { (position, $0) }
                }),
            since: since, window: window, now: now, calendar: calendar)
    }

    private struct SidecarFile: Sendable {
        var path: String
        var mtime: Date
        var size: Int
    }

    private static func sidecarFiles(transcriptPath: String, since: Date) -> [SidecarFile] {
        var files: [SidecarFile] = []
        for dir in TranscriptIndex.sidecarDirs(transcriptPath: transcriptPath) {
            guard
                let names = try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                    options: .skipsHiddenFiles)
            else { continue }
            for url in names
            where url.lastPathComponent.hasPrefix("agent-") && url.pathExtension == "jsonl" {
                guard
                    let values = try? url.resourceValues(forKeys: [
                        .contentModificationDateKey, .fileSizeKey,
                    ]),
                    let mtime = values.contentModificationDate, mtime >= since
                else { continue }
                files.append(
                    SidecarFile(path: url.path, mtime: mtime, size: values.fileSize ?? 0))
            }
        }
        return files
    }

    private static func parse(jobs: [Job]) async -> [(String, Slot)] {
        await withTaskGroup(of: (String, Slot).self) { group in
            var results: [(String, Slot)] = []
            var iterator = jobs.makeIterator()
            var running = 0
            func enqueue() {
                guard let job = iterator.next() else { return }
                running += 1
                group.addTask {
                    let stats = AnalyticsWalker.read(
                        transcriptPath: job.path, asSidecar: job.sidecar)
                    return (job.path, Slot(mtime: job.mtime, size: job.size, stats: stats))
                }
            }
            for _ in 0..<parseWidth { enqueue() }
            while running > 0 {
                guard let result = await group.next() else { break }
                running -= 1
                results.append(result)
                enqueue()
            }
            return results
        }
    }

    private static func aggregate(
        perSource: [(source: TranscriptIndex.AnalyticsSource, stats: AnalyticsFileStats)],
        subagentRuns: [Int: Int], since: Date, window: Int, now: Date, calendar: Calendar
    ) -> AnalyticsReport {
        let dayFormat = DateFormatter()
        dayFormat.calendar = calendar
        dayFormat.timeZone = calendar.timeZone
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.dateFormat = "yyyy-MM-dd"
        let home = NSHomeDirectory()

        struct DayBucket {
            var costUSD = 0.0
            var tokens = TokenCounts()
            var turns = 0
            var toolCalls = 0
            var sessions: Set<String> = []
        }

        var daily: [String: DayBucket] = [:]
        var models: [String: SpendModel] = [:]
        var projects: [String: AnalyticsReport.Project] = [:]
        var tools: [String: Int] = [:]
        var hourTurns = [Int](repeating: 0, count: 24)
        var hourCost = [Double](repeating: 0, count: 24)
        var totals = AnalyticsReport.Totals(
            costUSD: 0, tokens: TokenCounts(), turns: 0, toolCalls: 0, sessions: 0, activeDays: 0)
        var cacheSaved = 0.0
        var compactionCount = 0
        var reclaimed = 0
        var subagents = AnalyticsReport.Subagents(
            runs: subagentRuns.values.reduce(0, +), tokens: TokenCounts(), costUSD: 0)
        var priciestTurn: AnalyticsReport.Records.Turn?
        var longestTurn: AnalyticsReport.Records.Turn?
        var priciestSession: AnalyticsReport.Records.Session?
        var chargedMessages = Set<String>()
        var chargedLines = Set<String>()

        for (source, stats) in perSource {
            var sessionCost = 0.0
            var sessionTurns = 0
            for turn in stats.turns where turn.at >= since {
                var turnTokens = TokenCounts()
                var turnCost = 0.0
                var turnTools: [String: Int] = [:]
                var owned = turn.lines.isEmpty
                for line in turn.lines {
                    if line.messageID.map({ chargedMessages.insert($0).inserted }) ?? true {
                        turnTokens = turnTokens + line.tokens
                        turnCost += line.costUSD
                    }
                    if line.uuid.map({ chargedLines.insert($0).inserted }) ?? true {
                        owned = true
                        for (name, calls) in line.tools {
                            turnTools[name, default: 0] += calls
                        }
                    }
                }
                guard owned else { continue }
                let key = dayFormat.string(from: turn.at)
                var bucket = daily[key] ?? DayBucket()
                let turnToolCalls = turnTools.values.reduce(0, +)
                bucket.costUSD += turnCost
                bucket.tokens = bucket.tokens + turnTokens
                bucket.toolCalls += turnToolCalls
                bucket.sessions.insert(source.id)
                totals.costUSD += turnCost
                totals.tokens = totals.tokens + turnTokens
                totals.toolCalls += turnToolCalls
                sessionCost += turnCost
                for (name, calls) in turnTools {
                    tools[name, default: 0] += calls
                }
                let rate = Rate.forModel(turn.model ?? "")
                cacheSaved += Double(turnTokens.cacheRead) / 1_000_000 * rate.input
                    * (1 - Rate.cacheRead)
                let modelKey = turn.model ?? "unknown"
                var share = models[modelKey]
                    ?? SpendModel(model: modelKey, turns: 0, tokens: TokenCounts(), costUSD: 0)
                share.tokens = share.tokens + turnTokens
                share.costUSD += turnCost
                var project: AnalyticsReport.Project?
                if let directory = source.directory {
                    var slot = projects[directory]
                        ?? AnalyticsReport.Project(
                            directory: directory,
                            name: directory == home
                                ? "~" : (directory as NSString).lastPathComponent,
                            sessions: 0, turns: 0, costUSD: 0, tokens: TokenCounts())
                    slot.costUSD += turnCost
                    slot.tokens = slot.tokens + turnTokens
                    project = slot
                }
                if turn.sidechain {
                    subagents.tokens = subagents.tokens + turnTokens
                    subagents.costUSD += turnCost
                } else {
                    bucket.turns += 1
                    totals.turns += 1
                    sessionTurns += 1
                    share.turns += 1
                    project?.turns += 1
                    let hour = calendar.component(.hour, from: turn.at)
                    hourTurns[hour] += 1
                    hourCost[hour] += turnCost
                    if turnCost > (priciestTurn?.costUSD ?? 0) {
                        priciestTurn = record(turn: turn, costUSD: turnCost, title: source.title)
                    }
                    if let seconds = turn.seconds, seconds <= plausibleTurnSeconds,
                        seconds > (longestTurn?.seconds ?? 0)
                    {
                        longestTurn = record(turn: turn, costUSD: turnCost, title: source.title)
                    }
                }
                daily[key] = bucket
                models[modelKey] = share
                if let directory = source.directory, let project { projects[directory] = project }
            }
            for compaction in stats.compactions where compaction.at >= since {
                compactionCount += 1
                reclaimed += compaction.reclaimed
            }
            if sessionTurns > 0 {
                totals.sessions += 1
                if let directory = source.directory {
                    projects[directory]?.sessions += 1
                }
                if sessionCost > (priciestSession?.costUSD ?? 0) {
                    priciestSession = AnalyticsReport.Records.Session(
                        id: source.id, title: source.title, costUSD: sessionCost,
                        turns: sessionTurns)
                }
            }
        }

        totals.activeDays = daily.count
        let dayRows = daily.keys.sorted().map { key -> AnalyticsReport.Day in
            let bucket = daily[key] ?? DayBucket()
            return AnalyticsReport.Day(
                day: key, costUSD: bucket.costUSD, tokens: bucket.tokens, turns: bucket.turns,
                toolCalls: bucket.toolCalls, sessions: bucket.sessions.count)
        }
        let busiest = dayRows.max { $0.costUSD < $1.costUSD }.map {
            AnalyticsReport.Records.BusiestDay(day: $0.day, costUSD: $0.costUSD, turns: $0.turns)
        }

        return AnalyticsReport(
            since: since, generatedAt: now, days: window, totals: totals, daily: dayRows,
            models: models.values.sorted { $0.costUSD > $1.costUSD },
            projects: projects.values.sorted { $0.costUSD > $1.costUSD },
            tools: tools.map { AnalyticsReport.Tool(name: $0.key, calls: $0.value) }
                .sorted { $0.calls > $1.calls },
            hourTurns: hourTurns, hourCostUSD: hourCost, cacheSavedUSD: cacheSaved,
            compactions: AnalyticsReport.Compactions(
                count: compactionCount, reclaimedTokens: reclaimed),
            subagents: subagents,
            records: AnalyticsReport.Records(
                busiestDay: busiest, priciestSession: priciestSession,
                priciestTurn: priciestTurn, longestTurn: longestTurn,
                streakDays: streak(
                    days: Set(daily.keys), calendar: calendar, format: dayFormat)))
    }

    private static func record(turn: AnalyticsFileStats.Turn, costUSD: Double, title: String)
        -> AnalyticsReport.Records.Turn
    {
        AnalyticsReport.Records.Turn(
            at: turn.at, costUSD: costUSD, seconds: turn.seconds, model: turn.model,
            prompt: turn.prompt, sessionTitle: title)
    }

    /// Consecutive active days counted back from the most recent active day — a streak that broke
    /// yesterday is still the streak the person is living off today.
    private static func streak(days: Set<String>, calendar: Calendar, format: DateFormatter) -> Int
    {
        guard let latest = days.max(), var cursor = format.date(from: latest) else { return 0 }
        var run = 0
        while days.contains(format.string(from: cursor)) {
            run += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else {
                break
            }
            cursor = previous
        }
        return run
    }
}

/// Reduces one file to analytics turns, with SpendReader's exact reading of tokens, rates and
/// turn boundaries — the two must never disagree about what a turn cost. A subagent sidecar is
/// the same grammar wearing a different meaning, so its lines become sidechain entries: real
/// money and real tool calls that are also not something the person typed.
enum AnalyticsWalker {
    static func read(transcriptPath: String, asSidecar: Bool = false) -> AnalyticsFileStats {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath),
            let data = try? handle.readToEnd()
        else { return AnalyticsFileStats() }
        defer { try? handle.close() }

        var stats = AnalyticsFileStats()
        var open: AnalyticsFileStats.Turn?
        var lastAt: Date?
        var pendingPrompt: String?
        var pendingPromptAt: Date?

        func close() {
            guard var turn = open else { return }
            if let lastAt { turn.seconds = max(0, lastAt.timeIntervalSince(turn.at)) }
            stats.turns.append(turn)
            open = nil
        }

        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard !line.isEmpty,
                let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }
            let type = entry["type"] as? String
            if type == "system", entry["subtype"] as? String == "compact_boundary",
                let metadata = entry["compactMetadata"] as? [String: Any],
                let before = metadata["preTokens"] as? Int
            {
                let after = metadata["postTokens"] as? Int ?? 0
                stats.compactions.append(
                    AnalyticsFileStats.Compaction(
                        at: date(entry["timestamp"]) ?? lastAt ?? Date(),
                        reclaimed: max(0, before - after)))
                continue
            }
            let sidechain = asSidecar || entry["isSidechain"] as? Bool == true
            if type == "user", entry["isMeta"] as? Bool != true, !sidechain {
                if let text = prompt(in: entry) {
                    close()
                    pendingPrompt = text
                    pendingPromptAt = date(entry["timestamp"])
                }
                continue
            }
            guard type == "assistant", let message = entry["message"] as? [String: Any] else {
                continue
            }
            let model = message["model"] as? String
            if model == "<synthetic>" { continue }
            let usage = message["usage"] as? [String: Any] ?? [:]
            let at = date(entry["timestamp"]) ?? lastAt ?? Date()
            let counts = tokens(in: usage)
            let line = AnalyticsFileStats.Line(
                messageID: message["id"] as? String,
                uuid: entry["uuid"] as? String,
                tokens: counts,
                costUSD: Rate.forModel(model ?? "").cost(of: counts),
                tools: toolCalls(in: message))
            if sidechain {
                stats.turns.append(
                    AnalyticsFileStats.Turn(
                        at: at, seconds: nil, model: model, sidechain: true, prompt: nil,
                        lines: [line]))
                continue
            }
            lastAt = at
            if open == nil {
                open = AnalyticsFileStats.Turn(
                    at: pendingPromptAt ?? at, seconds: nil, model: model, sidechain: false,
                    prompt: pendingPrompt, lines: [])
                pendingPrompt = nil
                pendingPromptAt = nil
            }
            guard var turn = open else { continue }
            turn.lines.append(line)
            if turn.model == nil { turn.model = model }
            open = turn
        }
        close()
        return stats
    }

    private static func toolCalls(in message: [String: Any]) -> [String: Int] {
        guard let parts = message["content"] as? [[String: Any]] else { return [:] }
        var calls: [String: Int] = [:]
        for part in parts where part["type"] as? String == "tool_use" {
            guard let name = part["name"] as? String, !name.isEmpty else { continue }
            calls[name, default: 0] += 1
        }
        return calls
    }

    private static func prompt(in entry: [String: Any]) -> String? {
        guard let message = entry["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return trimmed(text) }
        guard let parts = message["content"] as? [[String: Any]] else { return nil }
        for part in parts where part["type"] as? String == "text" {
            if let text = part["text"] as? String, let value = trimmed(text) { return value }
        }
        return nil
    }

    private static func trimmed(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("<") else { return nil }
        return String(value.prefix(160))
    }

    private static func tokens(in usage: [String: Any]) -> TokenCounts {
        var counts = TokenCounts()
        counts.input = usage["input_tokens"] as? Int ?? 0
        counts.output = usage["output_tokens"] as? Int ?? 0
        counts.cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let written = usage["cache_creation_input_tokens"] as? Int ?? 0
        if let split = usage["cache_creation"] as? [String: Any] {
            counts.cacheWrite5m = split["ephemeral_5m_input_tokens"] as? Int ?? 0
            counts.cacheWrite1h = split["ephemeral_1h_input_tokens"] as? Int ?? 0
            let accounted = counts.cacheWrite5m + counts.cacheWrite1h
            if accounted < written { counts.cacheWrite5m += written - accounted }
        } else {
            counts.cacheWrite5m = written
        }
        return counts
    }

    private static func date(_ raw: Any?) -> Date? {
        guard let text = raw as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
