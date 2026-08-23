import Foundation

/// Spawns `claude -p` in streaming-JSON mode for one turn, maps its events to ``BridgeEvent``s,
/// and returns the assembled assistant message plus the (new or resumed) Claude session id.
struct ClaudeRunner: Sendable {
    let claudePath: String
    let workdir: String
    let permissionMode: String

    struct Outcome: Sendable {
        var message: Message
        var claudeSessionID: String?
        var costUSD: Double?
        var tokens: Int?
        /// The turn compacted. The message carries a placeholder ``Part/compaction(_:)`` in stream
        /// order whose numbers only the transcript knows — see `SessionStore.fillCompaction`.
        var didCompact = false
    }

    func run(
        prompt: String,
        resume claudeSessionID: String?,
        model: String,
        effort: String,
        ultracode: Bool = false,
        fork: Bool = false,
        directory: String? = nil,
        onStart: (@Sendable (Int32) -> Void)? = nil,
        onSessionID: (@Sendable (String) -> Void)? = nil,
        onBackground: (@Sendable (String, BackgroundOutcome) -> Void)? = nil,
        emit: @Sendable @escaping (BridgeEvent) -> Void
    ) async -> Outcome {
        let cwd = directory ?? workdir
        let messageID = UUID().uuidString
        var arguments = [
            "-p", prompt,
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--model", model,
            "--effort", effort,
            "--permission-mode", permissionMode,
            "--add-dir", cwd,
        ]
        if permissionMode == "bypassPermissions" {
            arguments.append("--dangerously-skip-permissions")
        }
        if ultracode {
            arguments += ["--settings", #"{"ultracode":true}"#]
        }
        if let claudeSessionID {
            arguments += ["--resume", claudeSessionID]
            if fork { arguments.append("--fork-session") }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CODE_ENTRYPOINT"] = "claude-bridge"
        process.environment = environment

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let exit = ExitLatch()
        process.terminationHandler = { _ in exit.signal() }

        emit(.status("running"))
        emit(
            .messageUpserted(
                Message(id: messageID, role: .assistant, parts: [.text("")], createdAt: Date())))

        var assembler = Assembler(messageID: messageID)
        let lines = Self.lineStream(from: stdout.fileHandleForReading)
        do {
            try process.run()
        } catch {
            emit(.error("Failed to launch Claude: \(error.localizedDescription)"))
            return Outcome(
                message: Message(
                    id: messageID, role: .assistant,
                    parts: [.text("⚠️ Could not start Claude.")], createdAt: Date()),
                claudeSessionID: claudeSessionID)
        }

        onStart?(process.processIdentifier)
        var reportedSessionID: String?
        for await line in lines {
            guard let data = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            assembler.ingest(
                object, emit: emit,
                report: { toolID, outcome in onBackground?(toolID, outcome) })
            if let sid = assembler.sessionID, sid != reportedSessionID {
                reportedSessionID = sid
                onSessionID?(sid)
            }
        }
        await Self.awaitExit(of: process, latch: exit)

        let message = assembler.finalMessage()
        emit(.messageUpserted(message))
        return Outcome(
            message: message, claudeSessionID: assembler.sessionID ?? claudeSessionID,
            costUSD: assembler.costUSD, tokens: assembler.tokens,
            didCompact: assembler.didCompact)
    }

    /// Waits for the child to die without ever calling `waitUntilExit()`.
    /// That call spins the *calling* thread's run loop, but a Swift-concurrency
    /// task resumes on whatever cooperative thread is free after an await — not
    /// necessarily the one that launched the process — and the death
    /// notification is then delivered to a run loop nobody is spinning. The
    /// wait never returns: the turn never finishes, the session never leaves
    /// "running", and the blocked cooperative thread is gone for good. The
    /// termination handler fires on a Foundation-owned queue instead, with a
    /// bounded fallback in case it is never called at all — stdout is already
    /// at EOF by the time we get here, so the child is done in every normal case.
    private static func awaitExit(of process: Process, latch: ExitLatch) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await latch.wait() }
            group.addTask {
                try? await Task.sleep(for: .seconds(15))
            }
            await group.next()
            group.cancelAll()
        }
        guard process.isRunning else { return }
        log("child \(process.processIdentifier) outlived its output; terminating")
        process.terminate()
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[runner] \(message)\n".utf8))
    }

    /// Reads a file handle on a background thread, yielding complete newline-delimited lines.
    private static func lineStream(from handle: FileHandle) -> AsyncStream<String> {
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
private final class ExitLatch: @unchecked Sendable {
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

/// Folds Claude's stream-json events into a single assistant message, emitting incremental events.
/// Parts keep stream order — narration text stays interleaved with the tool calls it describes
/// instead of collapsing into one trailing blob.
private struct Assembler {
    let messageID: String
    var sessionID: String?
    var costUSD: Double?
    var tokens: Int?
    private(set) var didCompact = false
    private enum Segment {
        case text(String)
        case thinking(String)
        case tool(String)
        case file(FileRef)
        case compaction
    }
    private var segments: [Segment] = []
    private var tools: [String: ToolCall] = [:]
    /// Task id to the id of the call that launched it, read out of launch banners. The fold keeps
    /// the same book for the same reason — see ``rememberLaunchedTask(in:of:)``.
    private var taskLaunches: [String: String] = [:]
    private var currentBlock: (index: Int, toolID: String?)?
    private var blockBoundary = true

    init(messageID: String) { self.messageID = messageID }

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
        if !hasContent { segments.append(.text(text)) }
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
            segments.append(.compaction)
            blockBoundary = true
            emit(.compaction(phase: "finished", error: nil))
        } else if object["status"] as? String == "compacting" {
            emit(.compaction(phase: "started", error: nil))
        }
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
            emit(.toolUpserted(messageID: messageID, call))
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
            emit(.toolUpserted(messageID: messageID, call))
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

    func finalMessage() -> Message {
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
                if let call = tools[id] { parts.append(.tool(call)) }
            case .file(let file):
                parts.append(.file(file))
            case .compaction:
                parts.append(.compaction(Compaction()))
            }
        }
        if parts.isEmpty { parts.append(.text("")) }
        return Message(id: messageID, role: .assistant, parts: parts, createdAt: Date())
    }

    private static func flatten(_ content: Any?) -> String {
        if let string = content as? String { return string }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }
}
