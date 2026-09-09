import Foundation

enum Role: String, Codable, Sendable {
    case user
    case assistant
    /// Neither side of the conversation — a boundary the CLI recorded in it, such as a compaction.
    case system
}

enum ToolStatus: String, Codable, Sendable {
    case running
    case completed
    case error
    /// A call ended rather than finished — an interrupted turn's tool whose result never arrived.
    case stopped
}

struct ToolCall: Codable, Sendable {
    var id: String
    var name: String
    var input: String
    var output: String?
    var status: ToolStatus
    /// How the work this call handed to the background ended. A tool that starts a workflow or a
    /// background command answers within milliseconds and the work runs for minutes, so the call's
    /// own `output` is a receipt for a launch and says nothing about an ending. The harness reports
    /// the ending in its own line later, naming the call; this is that report seated back on it.
    var background: BackgroundOutcome?
}

/// The end of work a tool call handed to the background, as the harness reported it.
///
/// The report is a `<task-notification>` line in the transcript, which is condensed to one human
/// sentence before a client ever sees it — the ids and the returned value inside it are the only
/// proof a run ended, and prose is not a place to keep proof. So it travels as this instead.
struct BackgroundOutcome: Codable, Sendable, Equatable {
    enum Status: String, Codable, Sendable {
        case completed
        case failed
        /// Killed rather than finished — a timeout, a teardown, someone pressing stop. Over, with
        /// no answer, which is a different fact from a failure.
        case stopped
    }

    var taskID: String?
    var status: Status
    var summary: String?
    var result: String?
    var reportedAt: Date?
}

/// A file in a conversation: one that travelled with a prompt, or one the agent
/// read and is therefore showing. `url` is relative to the bridge root so a
/// client can fetch the bytes without knowing where on the host they landed.
struct FileRef: Codable, Sendable {
    var path: String
    var mime: String
    var filename: String?
    var url: String?
}

/// The seam left where the CLI replaced the conversation so far with a summary of it. The numbers
/// come straight off the transcript's `compact_boundary` record; ``summary`` is the
/// `isCompactSummary` message that follows it, which is a 16k-word artifact no client should ever
/// render as a chat bubble.
struct Compaction: Codable, Sendable {
    var trigger: String?
    var tokensBefore: Int?
    var tokensAfter: Int?
    var durationMs: Double?
    var preservedMessages: Int?
    var summary: String?
}

enum Part: Codable, Sendable {
    case text(String)
    case reasoning(String)
    case tool(ToolCall)
    case file(FileRef)
    case compaction(Compaction)

    private enum CodingKeys: String, CodingKey { case kind, text, tool, file, compaction }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try c.encode("text", forKey: .kind)
            try c.encode(value, forKey: .text)
        case .reasoning(let value):
            try c.encode("reasoning", forKey: .kind)
            try c.encode(value, forKey: .text)
        case .tool(let call):
            try c.encode("tool", forKey: .kind)
            try c.encode(call, forKey: .tool)
        case .file(let file):
            try c.encode("file", forKey: .kind)
            try c.encode(file, forKey: .file)
        case .compaction(let value):
            try c.encode("compaction", forKey: .kind)
            try c.encode(value, forKey: .compaction)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "tool": self = .tool(try c.decode(ToolCall.self, forKey: .tool))
        case "reasoning": self = .reasoning(try c.decode(String.self, forKey: .text))
        case "file": self = .file(try c.decode(FileRef.self, forKey: .file))
        case "compaction":
            self = .compaction(try c.decode(Compaction.self, forKey: .compaction))
        default: self = .text(try c.decode(String.self, forKey: .text))
        }
    }
}

struct Message: Codable, Sendable {
    var id: String
    var role: Role
    var parts: [Part]
    var createdAt: Date
    /// How long the turn took: from the moment the person pressed return to the last thing the
    /// turn wrote, which is the wait they actually had rather than the model's own share of it.
    /// It grows while the turn does and stops because the turn stopped. Deliberately not a second
    /// timestamp — a message that carries an end stamp reads as finished to everything that has
    /// to tell a live turn from a settled one, and this bridge stamps no completion.
    var seconds: Double?
    /// What answered, as the CLI recorded it on the turn's own API calls — never the session's
    /// configured model, which is what it would run *next* rather than what it just ran.
    var model: String?
    /// Everything the turn's calls consumed, added up with each API message charged exactly once:
    /// the CLI repeats a call's usage on every line it writes for that call, so counting lines
    /// inflates a turn by nearly two.
    var usage: TokenCounts?
    /// What the turn's *last* API call was handed and wrote back, which is the conversation's
    /// footprint in the model's context window right now. `usage` adds every call together — the
    /// right number for a bill, and roughly the call count times too large for a window — so a
    /// client asking how full the window is reads this one and never the sum.
    var context: TokenCounts?
    /// Priced from the same rate table the spend report uses, so a turn's own account and the
    /// conversation's total can never disagree. An estimate, and every surface says so.
    var costUSD: Double?
}

/// One `<task-notification>` line read whole: which work it reports on, which call started that
/// work, and how it ended. Internal to the fold — a client is handed the ``BackgroundOutcome`` this
/// resolves to, seated on the call, rather than a notification it would have to match up itself.
struct TaskNotification: Sendable, Equatable {
    var taskIDs: [String]
    var toolUseID: String?
    var status: BackgroundOutcome.Status
    var summary: String?
    var result: String?

    func outcome(taskID: String?, at reportedAt: Date) -> BackgroundOutcome {
        BackgroundOutcome(
            taskID: taskID ?? taskIDs.first, status: status, summary: summary, result: result,
            reportedAt: reportedAt)
    }
}

struct Session: Codable, Sendable {
    var id: String
    var title: String
    var directory: String?
    var claudeSessionID: String?
    /// Claude session ids this conversation resumed away from — kept so a
    /// rotated or compacted transcript stays claimed and never resurfaces as a
    /// duplicate "discovered" session alongside the live one.
    var priorClaudeSessionIDs: [String]?
    var model: String
    var effort: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [Message]
    var lastCostUSD: Double?
    var lastTokens: Int?
    var pendingFork: Bool?
    var customTitle: Bool?
    var autoTitled: Bool?
    /// A turn that was running when this bridge stopped and was not running when it came back.
    /// Kept on the session until it is picked up or dismissed, so a client that was not connected
    /// when the machine died still finds out that work was cut off rather than finding silence.
    var interruption: Interruption?
    /// Whether an interrupted turn in this session picks itself back up without being asked.
    /// Off unless someone says otherwise: continuing on its own is right for a long unattended
    /// run and wrong for anything with a person watching, and only the person knows which it is.
    var autoResume: Bool?
    /// Derived from the transcript when a session is served, never stored — the CLI owns goal state.
    var goal: GoalStatus?
    /// Stamped when a session is served, never stored: whether something is moving in this
    /// conversation — its own turn, or agents still working for it — and, narrower, whether its
    /// own turn is open. The transcript alone cannot say when a turn ended, because the CLI never
    /// stamps a message complete, so a client that lost the one frame saying so reads it here.
    var active: Bool?
    var turnOpen: Bool?
    /// Stamped when a session is served, never stored: background work the conversation's own
    /// process is still carrying between turns — a command the model started and stepped back
    /// from, an agent it backgrounded. No turn is open, the prompt is free, and the machine is
    /// still working for this chat; the CLI will speak again on its own when the work ends. A
    /// listing that cannot say this shows a conversation that merely looks finished.
    var backgroundTasks: Int?
    /// What the one task is, when exactly one is running, in the CLI's own words.
    var backgroundTask: String?

    var summary: SessionSummary {
        SessionSummary(
            id: id, title: title, directory: directory, model: model, effort: effort,
            createdAt: createdAt, updatedAt: updatedAt)
    }
}

/// `GET /sessions/:id/revision`: the bridge's record of one session in one small answer, so a
/// client may ask on a clock while its stream is quiet. Served from what the observer computed
/// within the last second rather than recomputed per request.
struct SessionRevision: Codable, Sendable {
    var updatedAt: Date
    var active: Bool
    var turnOpen: Bool
    var backgroundTasks: Int? = nil
    var backgroundTask: String? = nil
}

/// Background work a conversation's process is carrying between turns, as the CLI reports it: how
/// many tasks, and — when there is exactly one — what it is. Absent means none; the CLI's own
/// level signal (`background_tasks_changed`) replaces the whole set on every change, so a missed
/// edge cannot leave a stale count standing.
///
/// It cannot, however, save a task the CLI stops speaking about at all: one killed without a
/// `task_notification` and without a level that prunes it stays in the set for the life of the
/// process. That is why this is reported only *between* turns, which is the whole of what it
/// means — a running turn outranks it, so a stale entry cannot make a session that is plainly
/// thinking also claim to be carrying work nobody can see.
struct BackgroundWork: Codable, Sendable, Equatable {
    var tasks: Int
    var task: String?
}

struct SessionSummary: Codable, Sendable, Equatable {
    var id: String
    var title: String
    var directory: String?
    var model: String
    var effort: String
    var createdAt: Date
    var updatedAt: Date
    var active: Bool?
    /// Whether the session's own turn is open — the transcript is being written and its last turn
    /// has not closed. `active` is wider: it also counts a sidecar or a fan-out agent still moving,
    /// which keeps the row live in a list but is not a turn a client should show as running once
    /// the conversation itself has settled. Nil where the bridge cannot tell them apart.
    var turnOpen: Bool?
    /// A turn in this session was cut off by the machine and has not been picked back up. A list
    /// that cannot say this shows a conversation that merely looks finished.
    var interrupted: Bool?
    /// How many agents are working for this session right now, and — when a
    /// single one is — what it was sent to do. A session deep in fan-out is
    /// live without a word appearing in its own transcript, so this is the only
    /// thing a list can say about it.
    var agents: Int?
    var agentTask: String?
    /// The conversation is bookmarked. The mark belongs to the machine that holds the transcript
    /// rather than to the phone that made it: a bookmark is a fact about a conversation, and a
    /// person who saved a chat from the couch is looking for it at the desk an hour later.
    var saved: Bool?
    /// This turn is one the bridge started by itself to finish background work the previous turn
    /// was killed in the middle of. A row that cannot say this shows a conversation apparently
    /// talking to itself.
    var resuming: Bool?
    /// Background work the conversation's process is carrying with no turn open — see
    /// ``Session/backgroundTasks``. Nil when there is none.
    var backgroundTasks: Int?
    var backgroundTask: String?
}

/// The agents working for one session, as a list row can describe them.
struct AgentActivity: Sendable {
    var count: Int
    var task: String?
}

struct SubagentSummary: Codable, Sendable, Equatable {
    var id: String
    var title: String
    var agentType: String?
    var toolUseID: String?
    var updatedAt: Date
    var active: Bool
    var completed: Bool
    /// What a live agent is doing right now, from its sidecar transcript: when it keeps a todo
    /// list, how far through it is; always, how many tools it has run and which one is current.
    var startedAt: Date?
    var toolCount: Int?
    var currentTool: String?
    var todosDone: Int?
    var todosTotal: Int?
    var currentTodo: String?
}

struct SubagentTranscript: Codable, Sendable {
    var id: String
    var messages: [Message]
}

struct RenameRequest: Codable, Sendable {
    var title: String
}

/// What a client wants changed about a session record. Both fields are optional and a patch that
/// names neither is refused, so a client that sends only a bookmark cannot silently blank a title.
struct SessionPatch: Codable, Sendable {
    var title: String?
    var saved: Bool?

    var cleanTitle: String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else { return nil }
        return title
    }

    var isEmpty: Bool { cleanTitle == nil && saved == nil }
}

struct UsageSummary: Codable, Sendable {
    var costUSD: Double?
    var tokens: Int?
}

struct SendRequest: Codable, Sendable {
    var text: String
    var model: String?
    var effort: String?
    var attachments: [SendAttachment]?
}

/// An uploaded file accompanying a prompt. The bridge writes it to disk and
/// references its path in the prompt so headless Claude can `Read` it — the
/// Read tool renders images natively, which gives true vision input.
struct SendAttachment: Codable, Sendable {
    var mime: String
    var filename: String?
    var dataBase64: String
}

struct AutoResumeRequest: Codable, Sendable {
    var enabled: Bool
}

struct CreateRequest: Codable, Sendable {
    var title: String?
    var directory: String?
    var model: String?
    var effort: String?
}

/// Events streamed to a subscribed client over SSE. Mirrors the Kit's BackendEvent shape.
enum BridgeEvent: Codable, Sendable {
    case messageUpserted(Message)
    case partTextDelta(messageID: String, delta: String)
    case toolUpserted(messageID: String, ToolCall)
    case status(String)
    case error(String)
    /// The session's `/goal` changed; `nil` once nothing is being pursued.
    case goal(GoalStatus?)
    /// A compaction started, finished, or failed. Separate from ``status`` because the turn is
    /// still running throughout — it just spends minutes re-reading the conversation instead of
    /// answering, and a client that can't say so looks hung.
    case compaction(phase: String, error: String?)
    /// A turn was cut off by the machine rather than by the model, and here is what it had got
    /// done. `nil` clears the state — the turn was picked back up, or dismissed. Separate from
    /// ``error`` because an error is something the turn said and this is something that happened
    /// to it, and only one of the two is worth offering to continue.
    case interrupted(Interruption?)
    /// The background work the conversation's process is carrying changed — a task the model
    /// started and stepped back from began or ended. `nil` once nothing is running. Separate from
    /// ``status`` because no turn is open either way: the prompt is free, and the machine is
    /// still working for the chat, which a client that can only say running or idle has to call
    /// idle.
    case background(BackgroundWork?)

    private enum CodingKeys: String, CodingKey {
        case type, message, messageID, delta, tool, status, error, goal, phase, interruption
        case tasks, task
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .messageUpserted(let message):
            try c.encode("message", forKey: .type)
            try c.encode(message, forKey: .message)
        case .partTextDelta(let messageID, let delta):
            try c.encode("delta", forKey: .type)
            try c.encode(messageID, forKey: .messageID)
            try c.encode(delta, forKey: .delta)
        case .toolUpserted(let messageID, let tool):
            try c.encode("tool", forKey: .type)
            try c.encode(messageID, forKey: .messageID)
            try c.encode(tool, forKey: .tool)
        case .status(let value):
            try c.encode("status", forKey: .type)
            try c.encode(value, forKey: .status)
        case .error(let value):
            try c.encode("error", forKey: .type)
            try c.encode(value, forKey: .error)
        case .goal(let status):
            try c.encode("goal", forKey: .type)
            try c.encodeIfPresent(status, forKey: .goal)
        case .compaction(let phase, let error):
            try c.encode("compaction", forKey: .type)
            try c.encode(phase, forKey: .phase)
            try c.encodeIfPresent(error, forKey: .error)
        case .interrupted(let interruption):
            try c.encode("interrupted", forKey: .type)
            try c.encodeIfPresent(interruption, forKey: .interruption)
        case .background(let work):
            try c.encode("background", forKey: .type)
            try c.encode(work?.tasks ?? 0, forKey: .tasks)
            try c.encodeIfPresent(work?.task, forKey: .task)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "message": self = .messageUpserted(try c.decode(Message.self, forKey: .message))
        case "delta":
            self = .partTextDelta(
                messageID: try c.decode(String.self, forKey: .messageID),
                delta: try c.decode(String.self, forKey: .delta))
        case "tool":
            self = .toolUpserted(
                messageID: try c.decode(String.self, forKey: .messageID),
                try c.decode(ToolCall.self, forKey: .tool))
        case "status": self = .status(try c.decode(String.self, forKey: .status))
        case "goal": self = .goal(try c.decodeIfPresent(GoalStatus.self, forKey: .goal))
        case "compaction":
            self = .compaction(
                phase: try c.decode(String.self, forKey: .phase),
                error: try c.decodeIfPresent(String.self, forKey: .error))
        case "interrupted":
            self = .interrupted(try c.decodeIfPresent(Interruption.self, forKey: .interruption))
        case "background":
            let tasks = try c.decodeIfPresent(Int.self, forKey: .tasks) ?? 0
            self = .background(
                tasks > 0
                    ? BackgroundWork(
                        tasks: tasks, task: try c.decodeIfPresent(String.self, forKey: .task))
                    : nil)
        default: self = .error(try c.decode(String.self, forKey: .error))
        }
    }
}

struct FileEntry: Codable, Sendable {
    var path: String
    var name: String
    var isDirectory: Bool
}

struct FileContent: Codable, Sendable {
    var path: String
    var content: String
}

/// Directory listing for the app's file browser — rooted at the server
/// user's home, `.` and `~` resolving there.
enum FileBrowsing {
    static func resolve(_ raw: String, home: String) -> String {
        if raw.isEmpty || raw == "." { return home }
        if raw == "~" { return home }
        if raw.hasPrefix("~/") { return home + raw.dropFirst(1) }
        if !raw.hasPrefix("/") { return "\(home)/\(raw)" }
        return raw
    }

    static func list(_ path: String) -> [FileEntry]? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue,
            let names = try? FileManager.default.contentsOfDirectory(atPath: path)
        else { return nil }
        return names
            .filter { !$0.hasPrefix(".") }
            .map { name in
                let full = path.hasSuffix("/") ? "\(path)\(name)" : "\(path)/\(name)"
                var childIsDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: full, isDirectory: &childIsDirectory)
                return FileEntry(path: full, name: name, isDirectory: childIsDirectory.boolValue)
            }
    }

    static func content(_ path: String, cap: Int = 262_144) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path),
            let data = try? handle.read(upToCount: cap)
        else { return nil }
        try? handle.close()
        return String(data: data, encoding: .utf8)
    }

    /// Raw bytes of a regular file, refusing directories and anything past the
    /// cap — this feeds an inline image in a phone client, not a file transfer.
    static func bytes(_ path: String, cap: Int = 40 * 1024 * 1024) -> Data? {
        guard readableSize(path, cap: cap) != nil else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// How big a file is, when it is a regular file this bridge will serve at all — the same
    /// question `bytes` asks, answered without reading it, so a route can stream instead.
    static func readableSize(_ path: String, cap: Int = 40 * 1024 * 1024) -> Int? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            !isDirectory.boolValue,
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int,
            size <= cap
        else { return nil }
        return size
    }
}
