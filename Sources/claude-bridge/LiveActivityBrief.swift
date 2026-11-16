import Foundation

/// What a card says beyond its line, the way the Agents wall's tile does: the turn's latest steps,
/// the agent's plan, what it said last, the files it changed, the last minute of its pulse, the
/// model answering and the question it stopped on.
///
/// This is Tailscode's `LiveActivityBrief`, built by hand so the card a push leaves on a sleeping
/// phone draws the same tile the app draws while it runs. Facts only — a step is the tool's name and
/// the few input fields its plain reading needs, never a sentence — because the phone writes the
/// words in its own language. Every key is a wire contract with every installed app: added, never
/// renamed.
struct CardBrief: Codable, Sendable, Equatable {
    struct Step: Codable, Sendable, Equatable {
        var id: String
        var tool: String
        var input: [String: String]?
        /// `running`, `done`, `failed` or `stopped`.
        var state: String
    }

    struct Plan: Codable, Sendable, Equatable {
        var done: Int
        var total: Int
        var current: String?
        var next: String?
    }

    var steps: [Step] = []
    var plan: Plan?
    var said: String?
    var files: [String] = []
    var added = 0
    var removed = 0
    /// When this bridge saw the turn move, pruned to the pulse's minute and a quarter second apart.
    var stamps: [Date] = []
    var model: String?
    var ask: String?

    static let stepLimit = 4
    static let idLimit = 12
    static let inputLimit = 160
    /// The fields that name a file, kept from their end when cut, where the file's own name is.
    static let pathKeys: Set<String> = ["file_path", "path", "notebook_path"]
    static let saidLimit = 160
    static let askLimit = 280
    static let itemLimit = 90
    static let beatBuckets = 24
    static let beatSpan: TimeInterval = 60
    static let beatCeiling = 4
    static let stampSpacing: TimeInterval = 0.25
    /// The input fields a step's plain reading reads, the app's `LiveActivityStep.inputKeys`.
    static let inputKeys: [String] = [
        "command", "description", "file_path", "path", "notebook_path", "pattern", "query", "url",
        "subject", "status", "subagent_type", "name", "skill", "question",
    ]

    var moved: Date? { stamps.last }

    /// The turn moved: a step, a word, a tool coming back.
    mutating func note(_ now: Date) {
        if let last = stamps.last, now >= last, now.timeIntervalSince(last) < Self.stampSpacing { return }
        stamps.append(now)
        stamps = stamps.filter { now.timeIntervalSince($0) < Self.beatSpan }
    }

    /// A tool call was seen: it joins or updates the steps, and the calls the card says more about
    /// — a plan, an edit, a question — say it.
    mutating func absorb(_ tool: ToolCall) {
        let input = Self.object(tool.input)
        let id = String(tool.id.suffix(Self.idLimit))
        let step = Step(
            id: id, tool: tool.name, input: Self.fields(input), state: Self.state(tool.status))
        if let index = steps.firstIndex(where: { $0.id == id }) {
            steps[index] = step
        } else {
            steps.append(step)
            if steps.count > Self.stepLimit { steps.removeFirst(steps.count - Self.stepLimit) }
        }
        let name = tool.name.lowercased()
        if name == "todowrite" { plan = Self.plan(input) }
        if name == "askuserquestion" { ask = tool.status == .running ? Self.question(input) : nil }
        if tool.status == .completed { countEdit(name: name, input: input) }
    }

    /// What a push tells apart from the last one: a step landing or coming back, the plan moving,
    /// a question asked, a file changed. The pulse and the words are left out; they ride along.
    var shape: String {
        let marks = steps.map { "\($0.id):\($0.state)" }.joined(separator: ",")
        return "\(marks)|\(plan?.done ?? -1)/\(plan?.total ?? -1)|\(ask ?? "")|\(files.count)"
    }

    /// An answer was written or rewritten: who wrote it, and its last words.
    mutating func absorb(_ message: Message) {
        guard message.role == .assistant else { return }
        if let model = message.model, !model.isEmpty { self.model = model }
        for part in message.parts.reversed() {
            guard case .text(let text) = part else { continue }
            let plain = Self.plain(text)
            if !plain.isEmpty {
                said = Self.cut(plain, to: Self.saidLimit)
                return
            }
        }
    }

    /// The brief's wire form for a card at `now`. A settled card keeps its steps, its words, its
    /// files, who answered and the question it stopped on, and leaves out the pulse and the plan,
    /// which belong to a turn still going; a live one leaves out its words, which only an ending
    /// shows.
    func payload(now: Date, settled: Bool) -> [String: Any] {
        var brief: [String: Any] = [:]
        if !steps.isEmpty {
            brief["steps"] = steps.map { step -> [String: Any] in
                var object: [String: Any] = ["id": step.id, "tool": step.tool, "state": step.state]
                if let input = step.input, !input.isEmpty { object["input"] = input }
                return object
            }
        }
        if let plan, !settled {
            var object: [String: Any] = ["done": plan.done, "total": plan.total]
            if let current = plan.current { object["current"] = current }
            if let next = plan.next { object["next"] = next }
            brief["plan"] = object
        }
        if settled, let said { brief["said"] = said }
        if !files.isEmpty { brief["files"] = files.count }
        if added > 0 { brief["added"] = added }
        if removed > 0 { brief["removed"] = removed }
        if !settled, !stamps.isEmpty {
            brief["beat"] = beat(now: now)
            if let moved { brief["moved"] = moved.timeIntervalSinceReferenceDate }
        }
        if let model { brief["model"] = model }
        if let ask { brief["ask"] = ask }
        return brief
    }

    /// The most the brief may take once encoded: the app's `LiveActivityBrief.byteBudget`, so a
    /// card this bridge pushes and one the app writes give up the same parts in the same order and
    /// never draw two different cards for the same turn.
    static let byteBudget = 2_400

    /// The brief's wire form under `byteBudget`, giving up what the app's `fitted()` gives up and
    /// in its order: the words cut short, then the words, the oldest steps, each step's input, the
    /// plan's next item, the ask cut short, and the steps and plan; `bare` keeps only the pulse and
    /// the model, for a push that would not fit otherwise.
    static func fitted(
        _ brief: CardBrief, settled: Bool, now: Date, parts: LiveActivityPusher.BriefParts
    ) -> [String: Any] {
        var trimmed = brief
        if parts == .bare { trimmed = CardBrief(stamps: brief.stamps, model: brief.model) }
        let shrinks: [(inout CardBrief) -> Bool] = [
            { brief in
                guard let said = brief.said, said.count > 60 else { return false }
                brief.said = cut(said, to: 60)
                return true
            },
            { brief in
                guard brief.said != nil else { return false }
                brief.said = nil
                return true
            },
            { brief in
                guard brief.steps.count > 2 else { return false }
                brief.steps = Array(brief.steps.suffix(2))
                return true
            },
            { brief in
                guard brief.steps.contains(where: { $0.input != nil }) else { return false }
                brief.steps = brief.steps.map { Step(id: $0.id, tool: $0.tool, input: nil, state: $0.state) }
                return true
            },
            { brief in
                guard brief.plan?.next != nil else { return false }
                brief.plan?.next = nil
                return true
            },
            { brief in
                guard let ask = brief.ask, ask.count > 80 else { return false }
                brief.ask = cut(ask, to: 80)
                return true
            },
            { brief in
                guard !brief.steps.isEmpty || brief.plan != nil else { return false }
                brief.steps = []
                brief.plan = nil
                return true
            },
        ]
        func size(_ brief: CardBrief) -> Int {
            (try? JSONSerialization.data(withJSONObject: brief.payload(now: now, settled: settled)).count) ?? .max
        }
        for shrink in shrinks {
            guard size(trimmed) > byteBudget else { break }
            _ = shrink(&trimmed)
        }
        if size(trimmed) > byteBudget { trimmed = CardBrief(stamps: brief.stamps) }
        return trimmed.payload(now: now, settled: settled)
    }

    /// The pulse as digits, oldest first: how many times the turn moved in each slice of the last
    /// minute, at most `beatCeiling`.
    func beat(now: Date) -> String {
        var counts = [Int](repeating: 0, count: Self.beatBuckets)
        let width = Self.beatSpan / Double(Self.beatBuckets)
        for stamp in stamps {
            let age = now.timeIntervalSince(stamp)
            guard age >= 0, age < Self.beatSpan else { continue }
            let index = Self.beatBuckets - 1 - Int(age / width)
            if counts.indices.contains(index) { counts[index] += 1 }
        }
        return counts.map { String(min($0, Self.beatCeiling)) }.joined()
    }

    private mutating func countEdit(name: String, input: [String: Any]) {
        guard let kind = Self.fileKind(name),
            let path = (input["file_path"] ?? input["path"] ?? input["notebook_path"]) as? String,
            !path.isEmpty
        else { return }
        if !files.contains(path) { files.append(path) }
        if kind == .edit, let old = input["old_string"] as? String { removed += Self.lines(old) }
        if let new = input["new_string"] as? String {
            added += Self.lines(new)
        } else if let content = input["content"] as? String {
            added += Self.lines(content)
        }
    }

    private enum FileKind { case edit, write }

    /// Whether a tool writes a file, by the same reading of its name the app's summaries use: a
    /// to-do list or a task is never a file, whatever its name says.
    private static func fileKind(_ name: String) -> FileKind? {
        func has(_ words: String...) -> Bool { words.contains { name.contains($0) } }
        if has("todo", "taskcreate", "taskupdate", "tasklist", "taskget") { return nil }
        if name == "askuserquestion" || name == "task" || name == "agent" || name == "skill" { return nil }
        if has("workflow", "websearch", "webfetch", "fetch", "http", "bash", "shell", "terminal", "exec") {
            return nil
        }
        if has("edit", "patch", "str_replace", "apply") { return .edit }
        if has("write", "create") { return .write }
        return nil
    }

    private static func lines(_ text: String) -> Int {
        text.isEmpty ? 0 : text.reduce(into: 1) { count, character in if character == "\n" { count += 1 } }
    }

    private static func state(_ status: ToolStatus) -> String {
        switch status {
        case .running: return "running"
        case .completed: return "done"
        case .error: return "failed"
        case .stopped: return "stopped"
        }
    }

    private static func object(_ input: String) -> [String: Any] {
        guard let data = input.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func fields(_ input: [String: Any]) -> [String: String]? {
        var fields: [String: String] = [:]
        for key in inputKeys {
            guard let value = input[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            fields[key] = pathKeys.contains(key)
                ? String(trimmed.suffix(inputLimit)) : String(trimmed.prefix(inputLimit))
        }
        return fields.isEmpty ? nil : fields
    }

    /// A to-do list as a card says it: how far through, the item in hand and the one after; none
    /// once every item is done, which is a plan no longer being worked through.
    private static func plan(_ input: [String: Any]) -> Plan? {
        guard let todos = input["todos"] as? [[String: Any]], !todos.isEmpty else { return nil }
        let statuses = todos.map { $0["status"] as? String ?? "pending" }
        let done = statuses.filter { $0 == "completed" }.count
        guard done < todos.count else { return nil }
        let current = todos.first { $0["status"] as? String == "in_progress" }
        let next = todos.first { $0["status"] as? String ?? "pending" == "pending" }
        let currentWords = (current?["activeForm"] as? String) ?? (current?["content"] as? String)
        return Plan(
            done: done, total: todos.count,
            current: currentWords.map { cut($0, to: itemLimit) },
            next: (next?["content"] as? String).map { cut($0, to: itemLimit) })
    }

    private static func question(_ input: [String: Any]) -> String? {
        let first = (input["questions"] as? [[String: Any]])?.first
        guard let text = (first?["question"] as? String) ?? (input["question"] as? String) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : cut(trimmed, to: askLimit)
    }

    /// Markdown taken off the words, so a card quotes what the agent said rather than how it was
    /// typeset: emphasis, code ticks, headings and links read as the words inside them.
    static func plain(_ text: String) -> String {
        var words = text
        for mark in ["**", "__", "`"] { words = words.replacingOccurrences(of: mark, with: "") }
        words = words.replacingOccurrences(
            of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        words = words.replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s*"#, with: "", options: .regularExpression)
        words = words.replacingOccurrences(of: #"(?m)^\s*[-*+]\s+"#, with: "", options: .regularExpression)
        words = words.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return words.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cut(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(max(limit - 1, 1))).trimmingCharacters(in: .whitespaces) + "…"
    }
}
