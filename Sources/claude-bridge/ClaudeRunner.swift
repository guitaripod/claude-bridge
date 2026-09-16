import Foundation

/// Where the CLI is and how it is allowed to act, plus what one turn of it comes back as. The
/// process itself is ``ClaudeProcess`` — one per conversation, alive across turns — and the
/// folding of its events into a message is ``Assembler``, one per turn.
struct ClaudeRunner: Sendable {
    let claudePath: String
    let workdir: String
    let permissionMode: String

    struct Outcome: Sendable {
        /// What the turn produced, in order: the assistant's chunks and, between them, every
        /// compaction seam as a message of its own — the shape the transcript fold reads back.
        var messages: [Message]
        var claudeSessionID: String?
        var costUSD: Double?
        var tokens: Int?
        /// The turn compacted. A seam message carries the numbers the CLI streamed; only the
        /// transcript knows the summary — see `SessionStore.fillCompaction`.
        var didCompact = false
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[runner] \(message)\n".utf8))
    }

    /// Reads a file handle on a background thread, yielding complete newline-delimited lines.
    static func lineStream(from handle: FileHandle) -> AsyncStream<String> {
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
                try? handle.close()
                continuation.finish()
            }
        }
    }
}

/// One-shot exit signal: resumes whoever is awaiting the child, whether the
/// termination handler fires before or after the wait begins, and lets a
/// cancelled wait fall through instead of stranding the task.
final class ExitLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var signalled = false

    func signal() {
        lock.lock()
        signalled = true
        let waiter = continuation
        continuation = nil
        lock.unlock()
        waiter?.resume()
    }

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if signalled {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        } onCancel: {
            signal()
        }
    }
}

/// Folds Claude's stream-json events into the turn's messages, emitting incremental events.
/// Parts keep stream order — narration text stays interleaved with the tool calls it describes
/// instead of collapsing into one trailing blob.
///
/// A compaction splits the turn the way the transcript records it: the seam is a `system`
/// message of its own, and what the model says after it is a fresh assistant message. The two
/// records of a conversation — this stream and the CLI's own file — then hold the same messages
/// in the same shape, which is what lets the sweep name the file's copy after the streamed one
/// instead of handing a client a second card for the seam it has just watched arrive.
struct Assembler {
    /// The assistant message currently being written. Starts as the id the store announced with
    /// the turn and moves on at every seam.
    private(set) var messageID: String
    var sessionID: String?
    var costUSD: Double?
    var tokens: Int?
    private(set) var didCompact = false
    /// The numbers the CLI reports for a compaction it just did, from its own boundary record.
    /// The transcript's copy carries the summary as well and replaces this once it lands.
    private var compactionMetadata: Compaction?
    private enum Segment {
        case text(String)
        case thinking(String)
        case tool(String)
        case file(FileRef)
        case compaction(seamID: String)
    }
    private var segments: [Segment] = []
    /// One id per assistant chunk, in order; the first is the id the store announced.
    private var chunkIDs: [String]
    /// Whether the client has been told the current chunk exists. The first chunk is announced by
    /// the store when the turn opens; a chunk begun at a seam is announced by the first event
    /// that lands in it, so a seam nothing follows leaves no empty bubble behind.
    private var chunkAnnounced = true
    private var tools: [String: ToolCall] = [:]
    /// Task id to the id of the call that launched it, read out of launch banners. The fold keeps
    /// the same book for the same reason — see ``rememberLaunchedTask(in:of:)``.
    private var taskLaunches: [String: String] = [:]
    private var currentBlock: (index: Int, toolID: String?)?
    private var blockBoundary = true

    init(messageID: String) {
        self.messageID = messageID
        chunkIDs = [messageID]
    }

    mutating func ingest(
        _ object: [String: Any], emit: (BridgeEvent) -> Void,
        report: (String, BackgroundOutcome) -> Void = { _, _ in }
    ) {
        switch object["type"] as? String {
        case "system":
            switch object["subtype"] as? String {
            case "init":
                if let sid = object["session_id"] as? String { sessionID = sid }
            case "status":
                ingestCompactionStatus(object, emit: emit)
            case "compact_boundary":
                ingestCompactionBoundary(object, emit: emit)
            case "task_notification":
                ingestTaskNotificationEvent(object, emit: emit, report: report)
            default:
                break
            }
        case "stream_event":
            ingestStreamEvent(object["event"] as? [String: Any] ?? [:], emit: emit)
        case "user":
            ingestUser(object, emit: emit, report: report)
        case "result":
            if let cost = object["total_cost_usd"] as? Double { costUSD = cost }
            if let usage = object["usage"] as? [String: Any] {
                let input = usage["input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                tokens = input + output
            }
            ingestFailure(object, emit: emit)
        default:
            break
        }
    }

    /// A turn the CLI refused rather than answered.
    ///
    /// The clearest case is a signed-out machine: the CLI reports "Not logged in · Please run
    /// /login" as a result, and the assistant message it streams alongside is empty — so without
    /// this the client shows a blank turn and no reason for it. The text becomes both a failure
    /// event, which a client can act on, and the turn's own words, so the transcript says what
    /// happened.
    private mutating func ingestFailure(_ object: [String: Any], emit: (BridgeEvent) -> Void) {
        guard object["is_error"] as? Bool == true,
            let text = (object["result"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return }
        emit(.error(text))
        let hasContent = segments.contains { segment in
            switch segment {
            case .text(let value): return !value.trimmingCharacters(in: .whitespaces).isEmpty
            case .thinking, .tool, .file, .compaction: return true
            }
        }
        if !hasContent {
            announceChunk(emit: emit)
            segments.append(.text(text))
        }
    }

    /// Compaction is a turn that spends minutes reading instead of answering, and the CLI is the
    /// only thing that knows it started. Forwarding those markers is what lets a client say
    /// "compacting" instead of showing a stalled response.
    private mutating func ingestCompactionStatus(
        _ object: [String: Any], emit: (BridgeEvent) -> Void
    ) {
        if let error = object["compact_error"] as? String {
            emit(.compaction(phase: "failed", error: error))
        } else if object["compact_result"] as? String != nil {
            didCompact = true
            openSeam(emit: emit)
            emit(.compaction(phase: "finished", error: nil))
        } else if object["status"] as? String == "compacting" {
            emit(.compaction(phase: "started", error: nil))
        }
    }

    /// The CLI's own record of a compaction it just did — trigger, tokens before and after, how
    /// long it took. The seam is opened here if the status markers did not already put it in
    /// stream order, so an auto-compaction reported only by its boundary still renders; either
    /// way the seam on the wire is updated with the numbers the moment they are known.
    private mutating func ingestCompactionBoundary(
        _ object: [String: Any], emit: (BridgeEvent) -> Void
    ) {
        guard let meta = object["compact_metadata"] as? [String: Any] else { return }
        var compaction = Compaction()
        compaction.trigger = meta["trigger"] as? String
        compaction.tokensBefore = (meta["pre_tokens"] as? NSNumber)?.intValue
        compaction.tokensAfter = (meta["post_tokens"] as? NSNumber)?.intValue
        compaction.durationMs = (meta["duration_ms"] as? NSNumber)?.doubleValue
        compactionMetadata = compaction
        if !didCompact {
            didCompact = true
            openSeam(emit: emit)
            return
        }
        for segment in segments.reversed() {
            guard case .compaction(let seamID) = segment else { continue }
            emit(.messageUpserted(seamMessage(seamID)))
            return
        }
    }

    /// Cuts the turn at a compaction. A chunk with words or calls in it keeps its id and the seam
    /// takes a fresh one; a chunk nothing has landed in yet gives its id to the seam instead, so
    /// the bubble the store announced becomes the seam rather than standing empty beside it — which
    /// is a manual `/compact`, and an auto-compaction that fired before the model's first word.
    /// Either way what follows goes to a new chunk, announced only once something lands in it.
    private mutating func openSeam(emit: (BridgeEvent) -> Void) {
        let seamID = Self.hasContent(currentChunk) ? UUID().uuidString : messageID
        segments.append(.compaction(seamID: seamID))
        blockBoundary = true
        currentBlock = nil
        messageID = UUID().uuidString
        chunkIDs.append(messageID)
        chunkAnnounced = false
        emit(.messageUpserted(seamMessage(seamID)))
    }

    private func seamMessage(_ seamID: String) -> Message {
        Message(
            id: seamID, role: .system, parts: [.compaction(compactionMetadata ?? Compaction())],
            createdAt: Date())
    }

    /// The segments since the last seam.
    private var currentChunk: ArraySlice<Segment> {
        let start = segments.lastIndex { segment in
            if case .compaction = segment { return true }
            return false
        }
        return segments[(start.map { $0 + 1 } ?? 0)...]
    }

    /// Puts the current chunk on the wire before the first event that addresses it, since a delta
    /// for a message the client does not hold is dropped there.
    private mutating func announceChunk(emit: (BridgeEvent) -> Void) {
        guard !chunkAnnounced else { return }
        chunkAnnounced = true
        emit(
            .messageUpserted(
                Message(id: messageID, role: .assistant, parts: [.text("")], createdAt: Date())))
    }

    /// The harness's report that background work ended, as the long-lived CLI delivers it: a
    /// structured line rather than a user message, naming the task and — for work this bridge
    /// launched — the call that started it. Seated the same way the text form is.
    private mutating func ingestTaskNotificationEvent(
        _ object: [String: Any], emit: (BridgeEvent) -> Void,
        report: (String, BackgroundOutcome) -> Void
    ) {
        let status: BackgroundOutcome.Status
        switch (object["status"] as? String)?.lowercased() {
        case "completed", "success", "succeeded": status = .completed
        case "stopped", "killed", "cancelled", "canceled", "aborted": status = .stopped
        default: status = .failed
        }
        let outcome = BackgroundOutcome(
            taskID: object["task_id"] as? String, status: status,
            summary: object["summary"] as? String, result: nil, reportedAt: Date())
        if let toolID = object["tool_use_id"] as? String {
            seat(toolID, outcome, emit: emit, report: report)
            return
        }
        guard let taskID = object["task_id"] as? String, let toolID = taskLaunches[taskID] else {
            return
        }
        seat(toolID, outcome, emit: emit, report: report)
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
                segments.append(.tool(id))
                currentBlock = (index, id)
                blockBoundary = true
                announceChunk(emit: emit)
                emit(.toolUpserted(messageID: messageID, call))
            } else {
                currentBlock = (index, nil)
                blockBoundary = true
            }
        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any] else { return }
            if let chunk = delta["text"] as? String {
                if !blockBoundary, case .text(let existing) = segments.last {
                    segments[segments.count - 1] = .text(existing + chunk)
                } else {
                    segments.append(.text(chunk))
                    blockBoundary = false
                }
                announceChunk(emit: emit)
                emit(.partTextDelta(messageID: messageID, delta: chunk))
            } else if let chunk = delta["thinking"] as? String {
                if !blockBoundary, case .thinking(let existing) = segments.last {
                    segments[segments.count - 1] = .thinking(existing + chunk)
                } else {
                    segments.append(.thinking(chunk))
                    blockBoundary = false
                }
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

    /// The CLI writes two different things as a `user` object, told apart by the shape of
    /// `message.content`: an array of blocks is the tool results of the turn being assembled, and a
    /// bare string is one of the harness's own lines — among them the `<task-notification>` that
    /// reports background work ending. Reading only the array shape is what left every live turn's
    /// launching call with no ending on it, while the same turn read back off disk had one.
    private mutating func ingestUser(
        _ object: [String: Any], emit: (BridgeEvent) -> Void,
        report: (String, BackgroundOutcome) -> Void
    ) {
        guard let message = object["message"] as? [String: Any] else { return }
        if let blocks = message["content"] as? [[String: Any]] {
            ingestToolResults(blocks, from: object, emit: emit)
        } else if let text = message["content"] as? String {
            ingestTaskNotification(
                text,
                at: (object["timestamp"] as? String).flatMap(TranscriptParser.parseTimestamp)
                    ?? Date(),
                emit: emit, report: report)
        }
    }

    /// The harness's report that background work ended, seated back on the call that started it.
    ///
    /// Matching is the fold's, not a second rule of this path's own: a report naming a call names
    /// it outright, and a report naming only tasks is bound through the launch banners this has
    /// been reading all along. A report for a call this bridge never saw names nothing here and
    /// nothing in the store, and is simply dropped.
    private mutating func ingestTaskNotification(
        _ content: String, at stamp: Date, emit: (BridgeEvent) -> Void,
        report: (String, BackgroundOutcome) -> Void
    ) {
        guard TranscriptParser.isTaskNotification(content),
            let notification = TranscriptParser.taskNotification(content)
        else { return }
        if let toolID = notification.toolUseID {
            seat(toolID, notification.outcome(taskID: nil, at: stamp), emit: emit, report: report)
            return
        }
        for taskID in notification.taskIDs {
            guard let toolID = taskLaunches[taskID] else { continue }
            seat(toolID, notification.outcome(taskID: taskID, at: stamp), emit: emit, report: report)
        }
    }

    /// The call a report belongs to is usually in an earlier turn, already persisted, and this
    /// assembler holds only the turn it is building — so the outcome goes both ways. Locally it
    /// lands on the call if this turn made it; either way it is reported to the store, which is the
    /// only thing that holds every stored message. Seating it twice writes the same value twice.
    private mutating func seat(
        _ toolID: String, _ outcome: BackgroundOutcome, emit: (BridgeEvent) -> Void,
        report: (String, BackgroundOutcome) -> Void
    ) {
        if var call = tools[toolID] {
            call.background = outcome
            tools[toolID] = call
            emit(.toolUpserted(messageID: chunkID(holding: toolID), call))
        }
        report(toolID, outcome)
    }

    /// A tool that hands its work to the background answers with a banner naming the task it just
    /// started. Reading that one line is what lets a report arriving minutes later — naming no call
    /// at all — find the call it belongs to.
    private mutating func rememberLaunchedTask(in output: String, of toolID: String) {
        let banner = output.prefix(Self.launchBannerLimit)
        guard let range = banner.range(of: "Task ID:") else { return }
        let id = banner[range.upperBound...].prefix { $0 != "\n" }
            .trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        taskLaunches[id] = toolID
    }

    /// How far into a tool's output a launch banner is looked for. Every tool result of every turn
    /// is offered to this, and a banner announces itself in its first line or two — so the bound is
    /// what keeps a megabyte of `Read` output from being scanned for a phrase that only ever
    /// appears at the top of something else.
    private static let launchBannerLimit = 2_048

    private mutating func ingestToolResults(
        _ content: [[String: Any]], from object: [String: Any], emit: (BridgeEvent) -> Void
    ) {
        for block in content where block["type"] as? String == "tool_result" {
            guard let toolID = block["tool_use_id"] as? String else { continue }
            let flattened = Self.flatten(block["content"])
            rememberLaunchedTask(in: flattened, of: toolID)
            guard var call = tools[toolID] else { continue }
            // The same ceiling the transcript reader applies, so a `cat` of something enormous
            // does not lodge megabytes in the session store for the life of the process — and so
            // a turn read live and the same turn read back off disk say the same thing.
            call.output = String(flattened.prefix(TranscriptParser.toolOutputLimit))
            call.status = (block["is_error"] as? Bool == true) ? .error : .completed
            tools[toolID] = call
            emit(.toolUpserted(messageID: chunkID(holding: toolID), call))
            appendImage(
                from: block, result: object["toolUseResult"], toolID: toolID, call: call)
        }
    }

    /// A picture the agent just looked at joins the turn where it looked, so the
    /// answer that follows arrives with the thing it is talking about.
    private mutating func appendImage(
        from block: [String: Any], result: Any?, toolID: String, call: ToolCall
    ) {
        guard let mime = ImageResult.mime(block: block, result: result),
            let path = ImageResult.path(toolInput: call.input)
        else { return }
        segments.append(
            .file(
                FileRef(
                    path: path, mime: mime, filename: (path as NSString).lastPathComponent,
                    url: ImageResult.url(path: path, toolID: toolID, session: sessionID))))
        blockBoundary = true
    }

    /// The message a call was made in: the chunk before the seam that follows it, or the current
    /// one when no seam does. A result for a call made before a compaction lands on the chunk
    /// that holds the call, not on whatever the model is writing now.
    private func chunkID(holding toolID: String) -> String {
        var chunk = 0
        for segment in segments {
            switch segment {
            case .tool(let id) where id == toolID: return chunkIDs[chunk]
            case .compaction: chunk += 1
            default: break
            }
        }
        return messageID
    }

    /// Everything the turn produced, as the messages the transcript will hold: each assistant
    /// chunk under its own id, each seam between them as a system message. A turn that said
    /// nothing at all is one empty assistant message, so the bubble the store announced settles.
    func finalMessages() -> [Message] {
        var messages: [Message] = []
        var chunk = 0
        var current: ArraySlice<Segment> = []
        let now = Date()
        func flushChunk() {
            let parts = Self.parts(of: current, tools: tools)
            if !parts.isEmpty {
                messages.append(
                    Message(id: chunkIDs[chunk], role: .assistant, parts: parts, createdAt: now))
            }
            current = []
        }
        for segment in segments {
            guard case .compaction(let seamID) = segment else {
                current.append(segment)
                continue
            }
            flushChunk()
            messages.append(seamMessage(seamID))
            chunk += 1
        }
        flushChunk()
        if messages.isEmpty {
            messages.append(
                Message(id: chunkIDs[0], role: .assistant, parts: [.text("")], createdAt: now))
        }
        return messages
    }

    private static func parts(of segments: ArraySlice<Segment>, tools: [String: ToolCall]) -> [Part] {
        var parts: [Part] = []
        for segment in segments {
            switch segment {
            case .text(let value):
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                parts.append(.text(value))
            case .thinking(let value):
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                parts.append(.reasoning(value))
            case .tool(let id):
                if var call = tools[id] {
                    if call.status == .running { call.status = .stopped }
                    parts.append(.tool(call))
                }
            case .file(let file):
                parts.append(.file(file))
            case .compaction:
                break
            }
        }
        return parts
    }

    private static func hasContent(_ segments: ArraySlice<Segment>) -> Bool {
        segments.contains { segment in
            switch segment {
            case .text(let value), .thinking(let value):
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .tool, .file: return true
            case .compaction: return false
            }
        }
    }

    private static func flatten(_ content: Any?) -> String {
        if let string = content as? String { return string }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }
}
