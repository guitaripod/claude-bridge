import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// When this machine last came up. A pid is only evidence that a process is alive if nothing has
/// rebooted since it was written down — after a reboot the number is somebody else's, and adopting
/// a stranger's process because its pid matches is the worst outcome available here.
enum MachineUptime {
    static func bootedAt() -> Date? {
        #if canImport(Darwin)
            var boot = timeval()
            var size = MemoryLayout<timeval>.stride
            var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
            guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0, boot.tv_sec != 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec))
        #else
            guard let stat = try? String(contentsOfFile: "/proc/stat", encoding: .utf8) else {
                return nil
            }
            for line in stat.split(separator: "\n") where line.hasPrefix("btime ") {
                guard let seconds = TimeInterval(line.dropFirst("btime ".count)) else { return nil }
                return Date(timeIntervalSince1970: seconds)
            }
            return nil
        #endif
    }
}

/// Whether a pid is still a live `claude` — both halves matter. `kill(pid, 0)` says a process
/// exists; only its command line says it is the one we spawned rather than whatever the kernel
/// handed that number to next.
enum ProcessProbe {
    static func isLiveClaude(_ pid: Int32) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 else { return false }
        return commandLine(pid)?.contains("claude") == true
    }

    /// Whether the process has a child process of its own.
    ///
    /// A backgrounded `Bash` is a direct child `bash -c` of the CLI for the whole of its life, so
    /// the absence of any child is the machine's own word that no shell the CLI still lists is
    /// running. It cannot say which child belongs to which task, and a foreground tool is a child
    /// too — which is why this is only ever read as a negative, and only when every live task is a
    /// shell.
    static func hasChild(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        #if canImport(Darwin)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-P", String(pid)]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return true }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return !String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        #else
            // The kernel keeps the list already; a full walk of /proc is the fallback for a build
            // without CONFIG_PROC_CHILDREN. Either way an unreadable answer counts as "has a
            // child", because a probe that cannot see is not evidence that nothing is there.
            let children = "/proc/\(pid)/task/\(pid)/children"
            if let data = readProcFile(children) {
                return !String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else {
                return true
            }
            for entry in entries where Int32(entry) != nil {
                guard let stat = try? String(contentsOfFile: "/proc/\(entry)/stat", encoding: .utf8),
                    let close = stat.lastIndex(of: ")")
                else { continue }
                let fields = stat[stat.index(close, offsetBy: 1)...]
                    .split(separator: " ", omittingEmptySubsequences: true)
                guard fields.count > 1, Int32(fields[1]) == pid else { continue }
                return true
            }
            return false
        #endif
    }

    /// The direct children of a process. Empty when there are none or the table cannot be read.
    static func children(of pid: Int32) -> [Int32] {
        guard pid > 0 else { return [] }
        #if canImport(Darwin)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-P", String(pid)]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
                .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        #else
            // The kernel files a child under the *thread* that spawned it, so every thread's list
            // is read: a child spawned off the main thread is still a child.
            if let threads = try? FileManager.default.contentsOfDirectory(atPath: "/proc/\(pid)/task") {
                var found: [Int32] = []
                var listed = false
                for thread in threads {
                    guard let data = readProcFile("/proc/\(pid)/task/\(thread)/children")
                    else { continue }
                    listed = true
                    found += String(decoding: data, as: UTF8.self)
                        .split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
                }
                if listed { return found }
            }
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else {
                return []
            }
            return entries.compactMap { entry -> Int32? in
                guard let child = Int32(entry), let fields = statFields(child), fields.count > 1,
                    Int32(fields[1]) == pid
                else { return nil }
                return child
            }
        #endif
    }

    /// Every process under one, breadth first, so a parent comes before what it spawned.
    static func descendants(of pid: Int32) -> [Int32] {
        var found: [Int32] = []
        var queue = children(of: pid)
        var seen: Set<Int32> = [pid]
        while !queue.isEmpty {
            let next = queue.removeFirst()
            guard seen.insert(next).inserted else { continue }
            found.append(next)
            queue.append(contentsOf: children(of: next))
        }
        return found
    }

    /// CPU time the process itself has spent, in seconds. A reading that does not move between
    /// two looks is a process that is blocked rather than busy.
    static func cpuSeconds(of pid: Int32) -> Double {
        #if canImport(Darwin)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-o", "cputime=", "-p", String(pid)]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return 0 }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return parseClock(String(decoding: data, as: UTF8.self))
        #else
            guard let fields = statFields(pid), fields.count > 13,
                let user = Double(fields[11]), let system = Double(fields[12])
            else { return 0 }
            let ticks = Double(sysconf(Int32(_SC_CLK_TCK)))
            return ticks > 0 ? (user + system) / ticks : 0
        #endif
    }

    /// `ps` prints CPU time as `[[days-]hours:]minutes:seconds.hundredths`.
    static func parseClock(_ text: String) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        var days = 0.0
        var clock = trimmed
        if let dash = clock.firstIndex(of: "-") {
            days = Double(clock[..<dash]) ?? 0
            clock = String(clock[clock.index(after: dash)...])
        }
        let parts = clock.split(separator: ":").compactMap { Double($0) }
        let seconds = parts.reversed().enumerated().reduce(0.0) { total, part in
            total + part.element * pow(60, Double(part.offset))
        }
        return days * 86400 + seconds
    }

    /// A `/proc` file read whole, empty when it is empty, nil when it cannot be opened or read.
    ///
    /// Read through a handle rather than `FileManager.contents(atPath:)`, `Data(contentsOf:)`
    /// or `String(contentsOfFile:)`: Foundation's whole-file readers leak the 4 KB buffer they
    /// allocate for a file whose size reads as zero whenever the read comes back empty, and
    /// procfs reports every file's size as zero while a kernel thread's `cmdline` and most
    /// `children` lists really are empty. The owners probe walks every process on the machine
    /// every two seconds and the stall probe every thread of every live CLI, so the bridge
    /// leaked about a megabyte a second on a busy machine until the kernel killed it.
    static func readProcFile(_ path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            return try handle.readToEnd() ?? Data()
        } catch {
            return nil
        }
    }

    #if !canImport(Darwin)
        /// The fields of `/proc/<pid>/stat` after the bracketed command name, so a name with
        /// spaces or parentheses in it cannot shift every column that follows.
        private static func statFields(_ pid: Int32) -> [Substring]? {
            guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
                let close = stat.lastIndex(of: ")")
            else { return nil }
            return stat[stat.index(close, offsetBy: 1)...]
                .split(separator: " ", omittingEmptySubsequences: true)
        }
    #endif

    /// The sessions a live Claude Code process is serving, read off the machine: a CLI that has
    /// launched background work keeps a handle on that session's `<tmp>/claude-<uid>/<project>/
    /// <session>/tasks` directory for the rest of its life, so the session ids behind those
    /// handles are exactly the conversations whose background agents and runs can still be alive.
    ///
    /// The handle is the CLI's own implementation, not a promise, so the answer is only given when
    /// the machine demonstrably speaks it: empty when no CLI is running at all, the set when at
    /// least one CLI is seen holding a tasks directory, and nil — cannot say — when the process
    /// table cannot be read, a CLI's handles cannot be, or CLIs are running and none holds one.
    static func sessionsServedByLiveCLIs() -> Set<String>? {
        #if canImport(Darwin)
            return nil
        #else
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else {
                return nil
            }
            var served = Set<String>()
            var sawCLI = false
            for entry in entries {
                guard let pid = Int32(entry), isClaudeCLI(pid) else { continue }
                sawCLI = true
                guard
                    let fds = try? FileManager.default.contentsOfDirectory(
                        atPath: "/proc/\(pid)/fd")
                else { return nil }
                for fd in fds {
                    guard
                        let target = try? FileManager.default.destinationOfSymbolicLink(
                            atPath: "/proc/\(pid)/fd/\(fd)"),
                        let session = taskSession(in: target)
                    else { continue }
                    served.insert(session)
                }
            }
            guard sawCLI else { return [] }
            return served.isEmpty ? nil : served
        #endif
    }

    /// The session a path under a CLI's task directory belongs to: the component before `tasks`,
    /// under a `claude-<uid>` root.
    static func taskSession(in path: String) -> String? {
        let parts = path.split(separator: "/")
        guard let tasks = parts.lastIndex(of: "tasks"), tasks >= 2,
            parts[..<tasks].contains(where: { $0.hasPrefix("claude-") })
        else { return nil }
        return String(parts[tasks - 1])
    }

    /// A Claude Code process, however it was installed: the native binary names itself `claude`,
    /// a package install runs under node with the package on its command line. The bridge itself
    /// is `claude-bridge` and never matches.
    private static func isClaudeCLI(_ pid: Int32) -> Bool {
        if let comm = try? String(contentsOfFile: "/proc/\(pid)/comm", encoding: .utf8),
            comm.trimmingCharacters(in: .whitespacesAndNewlines) == "claude"
        {
            return true
        }
        guard let data = readProcFile("/proc/\(pid)/cmdline"),
            !data.isEmpty
        else { return false }
        let arguments = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        if let first = arguments.first, (first as NSString).lastPathComponent == "claude" {
            return true
        }
        return arguments.prefix(3).contains { $0.contains("@anthropic-ai/claude-code") }
    }

    static func commandLine(_ pid: Int32) -> String? {
        #if canImport(Darwin)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-o", "command=", "-p", String(pid)]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        #else
            guard let data = readProcFile("/proc/\(pid)/cmdline") else {
                return nil
            }
            return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\0", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        #endif
    }
}

/// What became of a turn the bridge had open when it stopped.
enum TurnVerdict: Sendable, Equatable {
    /// The transcript closes the turn: it finished, whether or not this bridge was alive to see it.
    /// The answer is on disk and has only to be taken back into the session.
    case completed
    /// The child outlived the bridge and is still working. Nothing is broken — the turn is watched
    /// to its end instead of being declared lost.
    case stillRunning(pid: Int32)
    /// Nothing is running and the turn never closed.
    case interrupted
}

enum TurnRecovery {
    /// The verdict on one journaled turn.
    ///
    /// The order is deliberate: a closed transcript wins over everything, because a turn that
    /// finished is finished no matter what the process table says. Only then does liveness matter,
    /// and only when the pid can be trusted — the record has to predate the current boot, and the
    /// process at that number has to still be a `claude`.
    static func verdict(
        for record: TurnRecord, transcriptPath: String?, bootedAt: Date?, now: Date = Date()
    ) -> TurnVerdict {
        if let transcriptPath, TranscriptParser.isTurnClosed(atPath: transcriptPath) {
            return .completed
        }
        if let pid = record.pid, trustsPID(record: record, bootedAt: bootedAt),
            ProcessProbe.isLiveClaude(pid)
        {
            return .stillRunning(pid: pid)
        }
        return .interrupted
    }

    static func trustsPID(record: TurnRecord, bootedAt: Date?) -> Bool {
        guard let bootedAt else { return false }
        return record.startedAt > bootedAt
    }

    /// What the interrupted turn had already done, read from its own transcript: everything the CLI
    /// recorded after the prompt that started it. A model's own account of what it did is the least
    /// reliable line in a transcript, so this counts tool calls rather than reading prose about them.
    static func progress(transcriptPath: String?, since startedAt: Date) -> InterruptionProgress {
        guard let transcriptPath else { return InterruptionProgress() }
        let messages = TranscriptParser.messages(at: URL(fileURLWithPath: transcriptPath))
        guard let lastUser = messages.lastIndex(where: { $0.role == .user }) else {
            return InterruptionProgress()
        }
        var progress = InterruptionProgress()
        var files: [String] = []
        var commands: [String] = []
        var answer = ""
        for message in messages[(lastUser + 1)...] where message.role == .assistant {
            for part in message.parts {
                switch part {
                case .tool(let call):
                    progress.toolCount += 1
                    progress.lastTool = call.name
                    if let path = pathArgument(in: call.input), !files.contains(path) {
                        files.append(path)
                    }
                    if isShell(call.name), let command = commandArgument(in: call.input),
                        !commands.contains(command)
                    {
                        commands.append(command)
                    }
                case .text(let value):
                    answer += value
                default:
                    continue
                }
            }
        }
        progress.filesTouched = Array(files.prefix(20))
        progress.commands = Array(commands.prefix(10))
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { progress.partialAnswer = String(trimmed.suffix(1_200)) }
        return progress
    }

    private static let pathKeys = ["file_path", "filePath", "path", "notebook_path"]

    private static func pathArgument(in input: String) -> String? {
        guard let data = input.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for key in pathKeys {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func commandArgument(in input: String) -> String? {
        guard let data = input.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let command = object["command"] as? String, !command.isEmpty
        else { return nil }
        return String(
            command.replacingOccurrences(of: "\n", with: " ").prefix(160))
    }

    private static func isShell(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered == "bash" || lowered == "shell" || lowered == "run"
    }
}

/// The prompt that picks an interrupted turn back up.
///
/// Re-sending the original prompt is the obvious thing and the wrong one: the agent may have
/// already written half a file, run a migration, or pushed a branch before the machine went down,
/// and a blind retry does all of it again. What actually resumes work is telling the model where it
/// was cut off, what its own transcript says it had already done, and that the state on disk is now
/// unknown to it. The turn's context is still there — the CLI resumes the same transcript — so this
/// is a continuation, not a re-briefing.
enum ResumeBrief {
    static func compose(_ interruption: Interruption, now: Date = Date()) -> String {
        var lines: [String] = []
        lines.append(
            "You were interrupted. The machine running you stopped \(elapsed(from: interruption.startedAt, to: interruption.detectedAt)) into this turn, before you finished answering. This is the same conversation — everything above is yours."
        )
        lines.append("The turn you were part-way through was:\n\n\(quote(interruption.prompt))")

        let progress = interruption.progress
        if progress.isEmpty {
            lines.append(
                "Your transcript shows nothing recorded after that prompt, so you had most likely not started. Begin it properly."
            )
        } else {
            var evidence: [String] = []
            if progress.toolCount > 0 {
                let last = progress.lastTool.map { ", the last of them \($0)" } ?? ""
                evidence.append("- \(progress.toolCount) tool calls\(last)")
            }
            if !progress.filesTouched.isEmpty {
                evidence.append(
                    "- touched: " + progress.filesTouched.map { "`\($0)`" }.joined(separator: ", "))
            }
            if !progress.commands.isEmpty {
                evidence.append(
                    "- ran: " + progress.commands.map { "`\($0)`" }.joined(separator: ", "))
            }
            if let answer = progress.partialAnswer {
                evidence.append("- your answer had got as far as:\n\n\(quote(answer))")
            }
            lines.append(
                "What your own transcript says you had already done:\n"
                    + evidence.joined(separator: "\n"))
        }

        if !interruption.queued.isEmpty {
            lines.append(
                "These were waiting behind that turn and never ran — deal with them after it:\n"
                    + interruption.queued.map { "- \(firstLine($0))" }.joined(separator: "\n"))
        }

        lines.append(
            "Do not start the whole task again, and do not re-do work the list above says is done. A half-written file or a command that ran twice is the failure mode here, so check the state of anything you had in progress before you touch it — read the files back, look at the working tree — then carry on from where you actually are. Say in one line what you are picking up, then do it."
        )
        return lines.joined(separator: "\n\n")
    }

    private static func quote(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(40)
            .map { "> \($0)" }
            .joined(separator: "\n")
    }

    private static func firstLine(_ text: String) -> String {
        String(
            (text.split(separator: "\n").first.map(String.init) ?? text)
                .trimmingCharacters(in: .whitespaces)
                .prefix(120))
    }

    static func elapsed(from: Date, to: Date) -> String {
        let seconds = max(0, to.timeIntervalSince(from))
        if seconds < 90 { return "seconds" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) minutes" }
        return "\(Int(seconds / 3_600)) hours"
    }
}
