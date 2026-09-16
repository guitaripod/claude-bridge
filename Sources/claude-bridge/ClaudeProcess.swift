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
    /// Background work the CLI says is still running, by task id — what a reaper must not kill,
    /// a restart must wait for, and a client is told about, because between turns it is the only
    /// sign that the machine is still working for this conversation. Read from the CLI's own level
    /// signal, which replaces the whole set on every change, with the start and end bookends
    /// folded in for the moments between. Ambient monitors — a plugin's watcher that runs for as
    /// long as the process does — are not work anybody is waiting on and are left out.
    private(set) var liveTasks: [String: LiveTask] = [:]

    struct LiveTask: Sendable, Equatable {
        var description: String?
        /// The CLI's own `task_type`. A shell is the one kind whose life the machine can check
        /// for itself; an agent or a workflow runs inside the CLI and leaves no process to find.
        var kind: String?
        /// When this process first heard of the task. A shell that has only just been asked for
        /// may not have forked yet, so its absence from the process table means nothing until it
        /// has had time to appear.
        var seenAt: Date = Date()
        /// The call behind a shell task, when the CLI named it: what was run, how long the model
        /// gave it, and where the harness writes what it says.
        var shell: ShellCall?
        /// The last reading of the shell's work and when that reading last moved.
        var watch: StallWatch?
        /// Set once the machine has found the shell stuck: past its budget with nothing moving
        /// for a whole window. Reported, and — where the policy is on — acted on.
        var stalled = false

        var isShell: Bool { ClaudeProcess.shellKinds.contains(kind ?? "") }

        init(description: String?, kind: String?, seenAt: Date = Date(), shell: ShellCall? = nil) {
            self.description = description
            self.kind = kind
            self.seenAt = seenAt
            self.shell = shell
        }
    }

    /// A background shell as the tool call that started it described it. The CLI's task events
    /// name the call (`tool_use_id`) but not the command, its budget or its output file; those are
    /// on the `assistant` block that made the call and the `tool_result` that answered it, both of
    /// which pass through here, so they are kept by call id until a task claims them.
    struct ShellCall: Sendable, Equatable {
        var toolUseID: String
        var command: String
        /// What the model gave the command to finish in. The harness stops *waiting* there —
        /// it moves the command to the background and tells the model so — but never ends it, so
        /// a command that will never finish outlives its budget by hours.
        var budget: TimeInterval
        /// Whether the model asked for the background itself, or the harness moved a foreground
        /// command there when the budget ran out.
        var explicit: Bool
        var outputFile: String?

        static let defaultBudget: TimeInterval = 120
    }

    /// One reading of a shell's work — CPU its process tree has spent, bytes it has written — and
    /// the moment the reading last changed. Two equal readings a window apart are a shell that is
    /// doing nothing at all, as opposed to one that is quietly busy.
    struct StallWatch: Sendable, Equatable {
        var cpu: Double
        var output: Int64
        var changedAt: Date
    }

    /// A shell the machine has found stuck, with what a person or the model needs to know about it.
    struct StalledShell: Sendable, Equatable {
        var taskID: String
        var description: String?
        var command: String
        var pids: [Int32]
        var outputFile: String?
        var ranFor: TimeInterval
        var budget: TimeInterval
        var silentFor: TimeInterval
    }

    /// How long a shell past its budget must show no CPU time and no output before it is stuck.
    /// A build prints as it goes and a poll loop spends CPU on every pass; only a process that is
    /// blocked — on a stdin nobody will write, a lock nobody holds, a remote that went away —
    /// shows neither for this long.
    static let stallWindow: TimeInterval = 600

    private var shellCalls: [String: ShellCall] = [:]
    private var shellCallOrder: [String] = []
    private static let shellCallsKept = 64

    /// The `task_type` values that run as a child process rather than inside the CLI.
    static let shellKinds: Set<String> = ["local_bash", "bash", "shell"]

    /// How long a task is given to appear in the process table, and how long the process must have
    /// been silent, before an empty process table is taken as the end of its shells.
    static let shellGrace: TimeInterval = 30

    /// Whether the CLI has written a single line since it started.
    ///
    /// A process that has never spoken has not begun the turn it was handed — it is still loading
    /// a transcript, or it is wedged. Separating that from a turn that started and went quiet is
    /// what lets a launch be given seconds while a long tool call is given hours.
    private(set) var hasSpoken = false

    /// The live set as a client hears it: how many, and what the one task is when there is one.
    var backgroundWork: BackgroundWork? {
        guard !liveTasks.isEmpty else { return nil }
        let stalled = liveTasks.values.contains { $0.stalled }
        return BackgroundWork(
            tasks: liveTasks.count,
            task: liveTasks.count == 1 ? liveTasks.values.first?.description : nil,
            since: liveTasks.values.map(\.seenAt).min(),
            stalled: stalled ? true : nil)
    }

    /// Reads every live shell against the machine and says which are stuck.
    ///
    /// The CLI's account of a task is that it is running, and for a shell that is blocked forever
    /// that account is true and useless: the harness ends nothing once the budget the model set
    /// has passed, and the reaper will not retire a process with a task on it, so one command
    /// waiting on a stdin nobody will write keeps a whole CLI resident and a row live for a day.
    /// The machine has a second account — CPU time and bytes written — and a shell past its
    /// budget whose reading has not moved for a full window is stuck by any definition that
    /// matters to the person waiting on it. Each call takes one reading and compares it with the
    /// last; the reading itself is what makes the judgement, so a task stops being stalled the
    /// moment it does anything.
    func assessStalls(now: Date = Date(), window: TimeInterval = stallWindow) -> [StalledShell] {
        guard isRunning else { return [] }
        let shells = liveTasks.filter { $0.value.isShell }
        guard !shells.isEmpty else { return [] }
        let candidates = shellChildren()
        var stalled: [StalledShell] = []
        for (id, task) in shells {
            let budget = task.shell?.budget ?? ShellCall.defaultBudget
            let pids = subtree(for: task, among: candidates, alone: shells.count == 1)
            guard !pids.isEmpty else { continue }
            let reading = StallWatch(
                cpu: pids.reduce(0) { $0 + ProcessProbe.cpuSeconds(of: $1) },
                output: task.shell?.outputFile.map(Self.fileSize) ?? 0,
                changedAt: now)
            var next = task
            if let last = task.watch, last.cpu == reading.cpu, last.output == reading.output {
                next.watch = last
            } else {
                next.watch = reading
            }
            let ranFor = now.timeIntervalSince(task.seenAt)
            let silentFor = now.timeIntervalSince(next.watch?.changedAt ?? now)
            next.stalled = ranFor > budget && silentFor >= window
            liveTasks[id] = next
            if next.stalled {
                stalled.append(
                    StalledShell(
                        taskID: id, description: task.description,
                        command: task.shell?.command ?? task.description ?? "",
                        pids: pids, outputFile: task.shell?.outputFile, ranFor: ranFor,
                        budget: budget, silentFor: silentFor))
            }
        }
        return stalled
    }

    /// Ends the shells named, hard. A shell that has shown nothing for a window will not answer
    /// a polite signal any sooner than it answered its stdin, and the harness starts background
    /// shells with the gentle signals ignored anyway. The reason is written into the task's own
    /// output file first, which is the one place the harness tells the model to look when it
    /// reports the command ended — so the model reads why, and does not simply run it again.
    @discardableResult
    func end(_ shells: [StalledShell], reason: String) -> Int {
        var ended = 0
        for shell in shells {
            if let file = shell.outputFile { Self.append(reason, to: file) }
            let killed = Self.killSubtree(shell.pids)
            if killed > 0 { ended += 1 }
            liveTasks[shell.taskID]?.stalled = true
        }
        return ended
    }

    /// Ends every shell the CLI is carrying, on request. What is found is what is ended; a task
    /// whose process the machine cannot find is left to the CLI's own accounting.
    func endAllShells(reason: String) -> [StalledShell] {
        guard isRunning else { return [] }
        let shells = liveTasks.filter { $0.value.isShell }
        let candidates = shellChildren()
        var ended: [StalledShell] = []
        for (id, task) in shells {
            let pids = subtree(for: task, among: candidates, alone: shells.count == 1)
            guard !pids.isEmpty else { continue }
            let now = Date()
            let shell = StalledShell(
                taskID: id, description: task.description,
                command: task.shell?.command ?? task.description ?? "", pids: pids,
                outputFile: task.shell?.outputFile, ranFor: now.timeIntervalSince(task.seenAt),
                budget: task.shell?.budget ?? ShellCall.defaultBudget,
                silentFor: now.timeIntervalSince(task.watch?.changedAt ?? now))
            if end([shell], reason: reason) > 0 { ended.append(shell) }
        }
        return ended
    }

    /// The CLI's children that are background shells: the harness wraps every `Bash` command in
    /// a `bash -c` that sources its shell snapshot, and that wrapper is what the process table
    /// shows. Language servers and MCP servers are children too and are not shells.
    private func shellChildren() -> [(pid: Int32, commandLine: String)] {
        ProcessProbe.children(of: pid).compactMap { child in
            guard let line = ProcessProbe.commandLine(child) else { return nil }
            return (child, line)
        }
    }

    /// The processes belonging to one task: the wrapper whose command line carries the task's
    /// command, and everything under it. With one shell live every wrapper is its own; with
    /// several, a wrapper that names no command is nobody's, because ending the wrong one is
    /// worse than ending none.
    private func subtree(
        for task: LiveTask, among candidates: [(pid: Int32, commandLine: String)], alone: Bool
    ) -> [Int32] {
        let needle = Self.needle(for: task)
        let wrappers = candidates.filter { candidate in
            if let needle, candidate.commandLine.contains(needle) { return true }
            return alone && needle == nil && Self.isShellWrapper(candidate.commandLine)
        }
        return wrappers.flatMap { [$0.pid] + ProcessProbe.descendants(of: $0.pid) }
    }

    /// The opening of the command as the wrapper's command line will show it: the first line, up
    /// to the first single quote, since the harness re-quotes those. Too short to be telling is
    /// no needle at all.
    static func needle(for task: LiveTask) -> String? {
        guard let command = task.shell?.command ?? task.description else { return nil }
        let head = command.split(separator: "\n", omittingEmptySubsequences: true).first
            .map(String.init) ?? command
        let unquoted = head.split(separator: "'", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? head
        let trimmed = unquoted.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 8 ? trimmed : nil
    }

    static func isShellWrapper(_ commandLine: String) -> Bool {
        commandLine.contains("shell-snapshots") || commandLine.hasPrefix("/bin/bash -c ")
            || commandLine.hasPrefix("bash -c ") || commandLine.hasPrefix("/bin/sh -c ")
            || commandLine.hasPrefix("sh -c ")
    }

    private static func fileSize(_ path: String) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 ?? 0
    }

    private static func append(_ text: String, to path: String) {
        guard let handle = FileHandle(forWritingAtPath: path) else {
            try? Data(text.utf8).write(to: URL(fileURLWithPath: path))
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(("\n" + text + "\n").utf8))
    }

    /// SIGKILL, deepest first, so a parent cannot respawn what its child was doing.
    private static func killSubtree(_ pids: [Int32]) -> Int {
        var killed = 0
        for pid in pids.reversed() where pid > 1 {
            if kill(pid, SIGKILL) == 0 { killed += 1 }
        }
        return killed
    }

    /// Remembers what a `Bash` call asked for, by the call's id, so the task the CLI later says
    /// it started can be read against the command, the budget and the output file it has.
    private func rememberShellCall(_ block: [String: Any]) {
        guard block["type"] as? String == "tool_use",
            let id = block["id"] as? String,
            (block["name"] as? String)?.lowercased() == "bash",
            let input = block["input"] as? [String: Any],
            let command = input["command"] as? String
        else { return }
        let timeout = (input["timeout"] as? Double) ?? (input["timeout"] as? Int).map(Double.init)
        shellCalls[id] = ShellCall(
            toolUseID: id, command: command,
            budget: timeout.map { $0 / 1000 } ?? ShellCall.defaultBudget,
            explicit: input["run_in_background"] as? Bool == true, outputFile: nil)
        shellCallOrder.append(id)
        while shellCallOrder.count > Self.shellCallsKept {
            shellCalls[shellCallOrder.removeFirst()] = nil
        }
    }

    /// The harness answers a backgrounded command with a banner naming the file it writes to;
    /// that file is the only output the shell has, and its size is half of what a stall is
    /// judged on.
    private func rememberShellResult(_ block: [String: Any]) {
        guard block["type"] as? String == "tool_result",
            let id = block["tool_use_id"] as? String, shellCalls[id] != nil
        else { return }
        let text = Self.flattenResult(block["content"])
        guard let file = Self.outputFile(in: text) else { return }
        shellCalls[id]?.outputFile = file
        for (taskID, task) in liveTasks where task.shell?.toolUseID == id {
            liveTasks[taskID]?.shell?.outputFile = file
        }
    }

    static func outputFile(in text: String) -> String? {
        guard let range = text.range(of: "Output is being written to: ") else { return nil }
        let rest = text[range.upperBound...]
        let path = rest.prefix { !$0.isWhitespace }
        let trimmed = path.hasSuffix(".") ? path.dropLast() : path[...]
        return trimmed.isEmpty ? nil : String(trimmed)
    }

    private static func flattenResult(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private func contentBlocks(of object: [String: Any]) -> [[String: Any]] {
        guard let message = object["message"] as? [String: Any] else { return [] }
        return message["content"] as? [[String: Any]] ?? []
    }
    /// Retires background shells the CLI still lists but the machine cannot find.
    ///
    /// The level signal, the end patch and the notification are all the CLI talking, and they
    /// share one blind spot: a shell that dies without the CLI noticing — killed from another
    /// terminal, or reaped by something that never told it — is never spoken about again. The
    /// entry then outlives the work in two places that matter, because a listing reports it as
    /// live and the reaper treats it as a reason to keep a whole CLI resident forever.
    ///
    /// So this is a fourth witness, and the only one that is not the CLI's own account: the
    /// process table. A backgrounded shell is a child of this process for as long as it runs, so
    /// no children at all means no shell is running. It is read only as a negative and only when
    /// every live task is a shell — an agent or a workflow runs inside the CLI and would leave
    /// nothing to find — and only once both the tasks and the process have been quiet long
    /// enough that a fork still on its way cannot be mistaken for one that never happened.
    func retireVanishedShellTasks(now: Date = Date()) -> Bool {
        guard isRunning, !liveTasks.isEmpty else { return false }
        guard liveTasks.values.allSatisfy(\.isShell) else { return false }
        guard liveTasks.values.allSatisfy({ now.timeIntervalSince($0.seenAt) > Self.shellGrace })
        else { return false }
        guard now.timeIntervalSince(lastActivityAt) > Self.shellGrace else { return false }
        guard !ProcessProbe.hasChild(pid) else { return false }
        liveTasks = [:]
        return true
    }

    /// Whether the process has written nothing for `silence`, and whether it ever spoke at all.
    /// Read together by the watchdog: a launch that never produced a line is a different failure
    /// from a turn that started and stopped, and is worth far less patience.
    func quietFor(_ silence: TimeInterval, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastActivityAt) > silence
    }

    /// Whether a `task_updated` patch says the task it names has ended. The CLI stamps an
    /// `end_time` and a settled status on the last patch of every task it stops running, so this
    /// is a second witness beside the level signal and the notification — and the one that still
    /// arrives when a task ends into a turn the process is already busy with. A word this does
    /// not recognise has ended, the way an unrecognised outcome is still an outcome: work that is
    /// going says so in one of the few words that mean going, and counting a stranger as work
    /// pins the process against every reaper and every restart for as long as it lives.
    private static func patchEndsTask(_ patch: [String: Any]) -> Bool {
        if let end = patch["end_time"], !(end is NSNull) { return true }
        guard let status = (patch["status"] as? String)?.lowercased() else { return false }
        return !Self.livingStatuses.contains(status)
    }

    private static let livingStatuses: Set<String> = [
        "running", "started", "starting", "pending", "queued", "in_progress", "active",
    ]

    private(set) var lastActivityAt = Date()
    private(set) var isRunning = false
    private(set) var pid: Int32 = 0

    private let claudePath: String
    private let permissionMode: String
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let exit = ExitLatch()
    private let sink: @Sendable (ClaudeProcess, String) async -> Void
    private let onExit: @Sendable (ClaudeProcess) async -> Void
    private let onTasksChanged: @Sendable (ClaudeProcess, BackgroundWork?) async -> Void
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
        effort: String, sink: @escaping @Sendable (ClaudeProcess, String) async -> Void,
        onExit: @escaping @Sendable (ClaudeProcess) async -> Void,
        onTasksChanged: @escaping @Sendable (ClaudeProcess, BackgroundWork?) async -> Void = {
            _, _ in
        }
    ) {
        self.claudePath = claudePath
        self.permissionMode = permissionMode
        self.launch = launch
        self.model = model
        self.effort = effort
        self.sink = sink
        self.onExit = onExit
        self.onTasksChanged = onTasksChanged
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
        hasSpoken = false
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
        guard await !exited(within: Self.closeGrace) else { return }
        await terminate()
    }

    /// Ends the process now: SIGTERM, and SIGKILL for one that shrugs it off. A child inherits
    /// whatever its parent did with SIGTERM — a signal a service ignores so it can read it off a
    /// dispatch source is ignored by every process it spawns — so a term that is never followed
    /// up is a child that outlives the bridge, holding the transcript and a stdout nobody reads.
    func terminate() async {
        guard process.isRunning else { return }
        process.terminate()
        guard await !exited(within: Self.closeGrace) else { return }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    private func exited(within grace: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [exit] in
                await exit.wait()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: grace)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
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
        hasSpoken = true
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
        if type == "assistant" {
            for block in contentBlocks(of: object) { rememberShellCall(block) }
        }
        if type == "user" {
            for block in contentBlocks(of: object) { rememberShellResult(block) }
        }
        if type == "system" {
            let before = backgroundWork
            switch object["subtype"] as? String {
            case "init":
                if let sid = object["session_id"] as? String { currentSessionID = sid }
            case "background_tasks_changed":
                let tasks = object["tasks"] as? [[String: Any]] ?? []
                let known = liveTasks
                liveTasks = [:]
                for task in tasks where task["ambient"] as? Bool != true {
                    guard let id = task["task_id"] as? String else { continue }
                    var entry = known[id] ?? LiveTask(description: nil, kind: nil)
                    entry.description = task["description"] as? String ?? entry.description
                    entry.kind = task["task_type"] as? String ?? entry.kind
                    liveTasks[id] = entry
                }
            case "task_started":
                if let id = object["task_id"] as? String,
                    object["is_backgrounded"] as? Bool == true,
                    object["ambient"] as? Bool != true
                {
                    var entry = liveTasks[id] ?? LiveTask(description: nil, kind: nil)
                    entry.description = object["description"] as? String ?? entry.description
                    entry.kind = object["task_type"] as? String ?? entry.kind
                    if let toolID = object["tool_use_id"] as? String, let call = shellCalls[toolID] {
                        entry.shell = call
                    }
                    liveTasks[id] = entry
                }
            case "task_updated":
                if let id = object["task_id"] as? String,
                    let patch = object["patch"] as? [String: Any]
                {
                    if Self.patchEndsTask(patch) {
                        liveTasks[id] = nil
                    } else if patch["is_backgrounded"] as? Bool == true, liveTasks[id] == nil {
                        liveTasks[id] = LiveTask(
                            description: patch["description"] as? String,
                            kind: (patch["task_type"] ?? object["task_type"]) as? String)
                    }
                }
            case "task_notification":
                if let id = object["task_id"] as? String { liveTasks[id] = nil }
            default:
                break
            }
            if backgroundWork != before { await onTasksChanged(self, backgroundWork) }
        }
        if swallowing != nil {
            if type == "result" {
                swallowing?.resume(returning: true)
                swallowing = nil
            }
            return
        }
        await sink(self, line)
    }

    private func finished() async {
        isRunning = false
        let carried = backgroundWork
        liveTasks = [:]
        if carried != nil { await onTasksChanged(self, nil) }
        for (_, continuation) in pendingControls { continuation.resume(returning: false) }
        pendingControls = [:]
        expireSwallow()
        try? stdinPipe.fileHandleForWriting.close()
        await onExit(self)
    }
}
