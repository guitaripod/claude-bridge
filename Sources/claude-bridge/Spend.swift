import Foundation

/// USD per million tokens for one model tier, with the cache multipliers the API bills against the
/// base input rate. A Max/Pro subscription is a flat fee, so none of this is what the person pays —
/// it is what the same tokens would have cost on the metered API, which is the only number that
/// makes one conversation comparable to another. Every surface that shows it says "estimate".
struct Rate: Sendable {
    var input: Double
    var output: Double

    static let cacheWrite5m = 1.25
    static let cacheWrite1h = 2.0
    static let cacheRead = 0.1

    func cost(of tokens: TokenCounts) -> Double {
        func per(_ count: Int, _ rate: Double) -> Double { Double(count) / 1_000_000 * rate }
        return per(tokens.input, input)
            + per(tokens.output, output)
            + per(tokens.cacheWrite5m, input * Self.cacheWrite5m)
            + per(tokens.cacheWrite1h, input * Self.cacheWrite1h)
            + per(tokens.cacheRead, input * Self.cacheRead)
    }

    /// Loose matching on the model id so a point release keeps its price, and an unrecognised
    /// Claude model is priced as the flagship rather than dropped — a turn missing from a total
    /// is a worse lie than a turn priced one tier too high.
    static func forModel(_ model: String) -> Rate {
        let id = model.lowercased()
        if id.contains("fable") || id.contains("mythos") { return Rate(input: 10, output: 50) }
        if id.contains("haiku") { return Rate(input: 1, output: 5) }
        if id.contains("sonnet") { return Rate(input: 3, output: 15) }
        return Rate(input: 5, output: 25)
    }
}

/// The token tiers that price differently. `cacheWrite5m` / `cacheWrite1h` split the single
/// `cache_creation_input_tokens` field when the finer `cache_creation.ephemeral_*` breakdown is
/// present; without it every cache write falls into the cheaper five-minute tier.
struct TokenCounts: Codable, Sendable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0

    var cacheWrite: Int { cacheWrite5m + cacheWrite1h }
    var total: Int { input + output + cacheRead + cacheWrite }

    static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: lhs.input + rhs.input, output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite5m: lhs.cacheWrite5m + rhs.cacheWrite5m,
            cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h)
    }
}

/// One prompt and everything the agent did to answer it: every API call the CLI made between one
/// thing the person said and the next, added together. A turn is the unit a person recognises —
/// "that question cost me eleven cents" — where an API call is an implementation detail of it.
///
/// It starts when the person pressed return, not when the first call came back, because the wait
/// is part of what a turn was.
struct SpendTurn: Codable, Sendable {
    var at: Date
    var seconds: Double?
    var model: String?
    var calls: Int
    var tokens: TokenCounts
    var costUSD: Double
    /// What the person actually asked, trimmed — a bar in a chart is unreadable without it.
    var prompt: String?
}

struct SpendModel: Codable, Sendable {
    var model: String
    var turns: Int
    var tokens: TokenCounts
    var costUSD: Double
}

/// What a whole conversation has cost, turn by turn, read from the CLI's own transcript.
struct SpendReport: Codable, Sendable {
    var costUSD: Double
    var tokens: TokenCounts
    var turns: [SpendTurn]
    var byModel: [SpendModel]
    var startedAt: Date?
    var endedAt: Date?
    /// True when every number here was priced from a rate table rather than reported by the
    /// provider. The clients must say so; a made-up exact figure is worse than an honest estimate.
    var estimated = true
}

/// Reads a session's spend out of the transcript the CLI writes anyway.
///
/// Nothing is stored and nothing is accumulated in memory: the file *is* the ledger, so a session
/// that ran in a terminal, on another client, or before this bridge was installed reports exactly
/// as well as one this bridge ran itself.
enum SpendReader {
    /// A hard ceiling on turns returned, newest kept. A months-old session can hold thousands and
    /// no chart can draw them; the totals are still computed over everything.
    static let maxTurns = 400

    static func read(transcriptPath: String) -> SpendReport? {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.readToEnd() else { return nil }

        var turns: [SpendTurn] = []
        var open: SpendTurn?
        var lastAt: Date?
        var pendingPrompt: String?
        var pendingPromptAt: Date?
        var chargedMessages = Set<String>()

        func close() {
            guard var turn = open else { return }
            if let lastAt { turn.seconds = max(0, lastAt.timeIntervalSince(turn.at)) }
            turns.append(turn)
            open = nil
        }

        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard !line.isEmpty,
                let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }
            let type = entry["type"] as? String
            if type == "user", entry["isMeta"] as? Bool != true,
                entry["isSidechain"] as? Bool != true
            {
                if let text = prompt(in: entry) {
                    close()
                    pendingPrompt = text
                    pendingPromptAt = date(entry["timestamp"])
                }
                continue
            }
            guard type == "assistant", let message = entry["message"] as? [String: Any],
                let usage = message["usage"] as? [String: Any]
            else { continue }
            let at = date(entry["timestamp"]) ?? lastAt ?? Date()
            lastAt = at
            let model = message["model"] as? String
            if open == nil {
                open = SpendTurn(
                    at: pendingPromptAt ?? at, model: model, calls: 0, tokens: TokenCounts(),
                    costUSD: 0, prompt: pendingPrompt)
                pendingPrompt = nil
                pendingPromptAt = nil
            }
            var turn = open ?? SpendTurn(
                at: at, model: model, calls: 0, tokens: TokenCounts(), costUSD: 0, prompt: nil)
            if (message["id"] as? String).map({ chargedMessages.insert($0).inserted }) ?? true {
                let counts = tokens(in: usage)
                turn.calls += 1
                turn.tokens = turn.tokens + counts
                turn.costUSD += Rate.forModel(model ?? "").cost(of: counts)
            }
            if turn.model == nil { turn.model = model }
            open = turn
        }
        close()
        guard !turns.isEmpty else { return nil }

        var byModel: [String: SpendModel] = [:]
        var total = TokenCounts()
        var cost = 0.0
        for turn in turns {
            total = total + turn.tokens
            cost += turn.costUSD
            let key = turn.model ?? "unknown"
            var slot = byModel[key] ?? SpendModel(
                model: key, turns: 0, tokens: TokenCounts(), costUSD: 0)
            slot.turns += 1
            slot.tokens = slot.tokens + turn.tokens
            slot.costUSD += turn.costUSD
            byModel[key] = slot
        }

        return SpendReport(
            costUSD: cost, tokens: total,
            turns: Array(turns.suffix(maxTurns)),
            byModel: byModel.values.sorted { $0.costUSD > $1.costUSD },
            startedAt: turns.first?.at, endedAt: turns.last?.at)
    }

    /// The words the person typed, not a tool result the CLI writes back as a user entry.
    private static func prompt(in entry: [String: Any]) -> String? {
        guard let message = entry["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String {
            return trimmed(text)
        }
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

    /// The CLI stamps every line with fractional seconds; a formatter is cheap next to the JSON
    /// parse this walk already does, and a shared one would need locking for no gain.
    private static func date(_ raw: Any?) -> Date? {
        guard let text = raw as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
