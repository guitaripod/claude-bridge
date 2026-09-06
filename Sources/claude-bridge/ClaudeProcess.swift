import Foundation

/// The shape a process was launched in — what the CLI takes on its command line and cannot be
/// told afterwards. A conversation whose next turn needs a different one gets a new process.
struct ClaudeLaunch: Equatable, Sendable {
    /// The transcript the process resumes; nil starts a fresh conversation.
    var resume: String?
    var fork: Bool
    var directory: String
    var ultracode: Bool
}

/// One long-lived `claude -p --input-format stream-json` for one conversation.
///
/// The bridge used to spawn one `claude -p <prompt>` per turn, which is one *process* per turn:
/// everything a turn left running — a shell in the background, an agent, a workflow — died with
/// it the moment the answer landed, and the next prompt found orphans. The TUI never has this
/// problem because its process lives for the whole conversation. This is that process. Prompts
/// go down its stdin as they arrive, every turn's events come up its stdout under the same
/// session id, background work carries on between turns, and when a task ends while nobody is
/// talking the CLI starts a turn of its own to deal with it — which reaches the store as an
/// unsolicited turn rather than as silence.
///
/// What the CLI cannot be told over stdin is a new process: the working directory, the transcript
/// it resumes, ultracode. A model is changed with a control request and an effort level with the
/// CLI's own slash command, both without losing the process or anything running in it.
actor ClaudeProcess {
    let launch: ClaudeLaunch
    private(set) var model: String
    private(set) var effort: String
    /// The transcript this process is actually on, from the CLI's own `init`. A fresh process
    /// learns it on its first turn; a resumed or forked one may report a different id than it was
    /// handed, and the id it reports is the one the next prompt has to match.
    private(set) var currentSessionID: String?
    /// Background work the CLI says is still running, by task id — what a reaper must not kill
    /// and a restart must wait for.
    private(set) var liveTasks: Set<String> = []
    private(set) var lastActivityAt = Date()
    private(set) var isRunning = false
    private(set) var pid: Int32 = 0

    private let claudePath: String
    private let permissionMode: String
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let exit = ExitLatch()
    private let sink: @Sendable (String) async -> Void
    private let onExit: @Sendable (ClaudeProcess) async -> Void
    private var pendingControls: [String: CheckedContinuation<Bool, Never>] = [:]
    private var swallowing: CheckedContinuation<Bool, Never>?
    private var requestCounter = 0

    /// How long a control request or a slash command is given to answer before the process is
    /// judged unresponsive to it. Both answer in milliseconds when they answer at all.
    static let controlTimeout: Duration = .seconds(3)
    static let slashTimeout: Duration = .seconds(10)
    /// How long a closed stdin is given to end the process before it is terminated.
    static let closeGrace: Duration = .seconds(3)

    init(
        claudePath: String, permissionMode: String, launch: ClaudeLaunch, model: String,
        effort: String, sink: @escaping @Sendable (String) async -> Void,
        onExit: @escaping @Sendable (ClaudeProcess) async -> Void
    ) {
        self.claudePath = claudePath
        self.permissionMode = permissionMode
        self.launch = launch
        self.model = model
        self.effort = effort
        self.sink = sink
        self.onExit = onExit
    }

    /// Whether this process can take a turn that wants `launch`: the same working directory, the
    /// transcript the turn resumes being the one this process is on, and ultracode on when the turn
    /// wants it. A process already in ultracode serves an ordinary turn — the mode is the
    /// session's — and a fork is consumed by its first turn, after which the process is simply on
    /// the transcript it minted.
    func serves(_ wanted: ClaudeLaunch) -> Bool {
        guard isRunning, wanted.directory == launch.directory else { return false }
        guard !wanted.ultracode || launch.ultracode else { return false }
        return wanted.resume == currentSessionID
    }

    /// A prompt written to a CLI that has just exited must come back as a thrown error, never as
    /// a signal that takes the whole bridge down. Process-wide, set once, before the first pipe.
    private static let ignoringBrokenPipes: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    func start() throws {
        _ = Self.ignoringBrokenPipes
        var arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--model", model,
            "--effort", effort,
            "--permission-mode", permissionMode,
            "--add-dir", launch.directory,
        ]
        if permissionMode == "bypassPermissions" {
            arguments.append("--dangerously-skip-permissions")
        }
        if launch.ultracode {
            arguments += ["--settings", #"{"ultracode":true}"#]
        }
        if let resume = launch.resume {
            arguments += ["--resume", resume]
            if launch.fork { arguments.append("--fork-session") }
        }
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: launch.directory)
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CODE_ENTRYPOINT"] = "claude-bridge"
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        let latch = exit
        process.terminationHandler = { _ in latch.signal() }
        try process.run()
        pid = process.processIdentifier
        isRunning = true
        lastActivityAt = Date()
        currentSessionID = launch.resume
        let lines = ClaudeRunner.lineStream(from: stdoutPipe.fileHandleForReading)
        Task { [weak self] in
            for await line in lines {
                guard let self else { return }
                await self.consume(line)
            }
            await self?.finished()
        }
    }

    /// One prompt down the pipe. The CLI treats it as the next user message of the conversation.
    func send(_ prompt: String) throws {
        try write(["type": "user", "message": ["role": "user", "content": prompt]])
        lastActivityAt = Date()
    }

    /// Stops the turn in flight the way the TUI's Escape does, keeping the process and whatever it
    /// has running in the background. False when the process did not answer, which is the cue to
    /// end it the hard way.
    func interrupt() async -> Bool {
        await control("interrupt", fields: [:])
    }

    func setModel(_ wanted: String) async -> Bool {
        guard await control("set_model", fields: ["model": wanted]) else { return false }
        model = wanted
        return true
    }

    /// The CLI has no control request for effort, but its own `/effort` answers over stdin with a
    /// zero-turn result. That result — and the confirmation line before it — is the command's, not
    /// a turn of the conversation, so it is swallowed here rather than handed to the store.
    func setEffort(_ level: String) async -> Bool {
        guard isRunning, swallowing == nil else { return false }
        let accepted: Bool = await withCheckedContinuation { continuation in
            swallowing = continuation
            do {
                try write(["type": "user", "message": ["role": "user", "content": "/effort \(level)"]])
            } catch {
                swallowing = nil
                continuation.resume(returning: false)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: Self.slashTimeout)
                await self?.expireSwallow()
            }
        }
        if accepted { effort = level }
        return accepted
    }

    /// Ends the process gently: stdin closes, the CLI finishes what it is doing and exits, and only
    /// a process that is still there after the grace is terminated.
    func close() async {
        guard isRunning else { return }
        try? stdinPipe.fileHandleForWriting.close()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [exit] in await exit.wait() }
            group.addTask { try? await Task.sleep(for: Self.closeGrace) }
            await group.next()
            group.cancelAll()
        }
        if process.isRunning { process.terminate() }
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    private func control(_ subtype: String, fields: [String: Any]) async -> Bool {
        guard isRunning else { return false }
        requestCounter += 1
        let id = "bridge-\(requestCounter)"
        var request: [String: Any] = ["subtype": subtype]
        for (key, value) in fields { request[key] = value }
        return await withCheckedContinuation { continuation in
            pendingControls[id] = continuation
            do {
                try write(["type": "control_request", "request_id": id, "request": request])
            } catch {
                pendingControls[id] = nil
                continuation.resume(returning: false)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: Self.controlTimeout)
                await self?.expireControl(id)
            }
        }
    }

    private func expireControl(_ id: String) {
        pendingControls.removeValue(forKey: id)?.resume(returning: false)
    }

    private func expireSwallow() {
        swallowing?.resume(returning: false)
        swallowing = nil
    }

    private func write(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    /// Every line the CLI writes. Control answers and the bookkeeping this process keeps for
    /// itself are read here; everything else goes to the store in the order it arrived.
    private func consume(_ line: String) async {
        lastActivityAt = Date()
        guard let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let type = object["type"] as? String
        if type == "control_response" {
            let response = object["response"] as? [String: Any]
            let id = response?["request_id"] as? String ?? ""
            let success = response?["subtype"] as? String == "success"
            pendingControls.removeValue(forKey: id)?.resume(returning: success)
            return
        }
        if type == "system" {
            switch object["subtype"] as? String {
            case "init":
                if let sid = object["session_id"] as? String { currentSessionID = sid }
            case "background_tasks_changed":
                let tasks = object["tasks"] as? [[String: Any]] ?? []
                liveTasks = Set(tasks.compactMap { $0["task_id"] as? String })
            case "task_started":
                if let id = object["task_id"] as? String { liveTasks.insert(id) }
            case "task_notification":
                if let id = object["task_id"] as? String { liveTasks.remove(id) }
            default:
                break
            }
        }
        if swallowing != nil {
            if type == "result" {
                swallowing?.resume(returning: true)
                swallowing = nil
            }
            return
        }
        await sink(line)
    }

    private func finished() async {
        isRunning = false
        liveTasks = []
        for (_, continuation) in pendingControls { continuation.resume(returning: false) }
        pendingControls = [:]
        expireSwallow()
        try? stdinPipe.fileHandleForWriting.close()
        await onExit(self)
    }
}
