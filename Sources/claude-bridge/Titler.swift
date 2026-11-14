import Foundation

/// Generates a short human title for a session from its first exchange using
/// a one-shot `claude -p` haiku call. Runs in a dedicated working directory
/// whose transcript project dir is deleted afterwards, so title calls never
/// surface as discovered sessions.
enum Titler {
    static func title(
        binary: String, projectsDir: String, user: String, assistant: String
    ) async -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cwd = "\(home)/.claude-bridge/titler"
        try? FileManager.default.createDirectory(
            atPath: cwd, withIntermediateDirectories: true)
        defer { cleanupTranscripts(projectsDir: projectsDir, cwd: cwd) }

        let prompt = """
            Write a title for this coding-agent conversation: 3 to 6 words, plain text, \
            no quotes, no trailing period. Reply with the title only.

            User: \(condense(user, cap: 600))
            Assistant: \(condense(assistant, cap: 400))
            """
        guard let raw = await run(binary: binary, cwd: cwd, prompt: prompt) else { return nil }
        let title = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”."))
        guard !title.isEmpty, title.count <= 70, !title.contains("\n") else { return nil }
        return title
    }

    /// What a look at a conversation's title decided. `moved` names which of the person's messages
    /// it was shown (counted from one, oldest first) the new topic began at; `renamed` is the same
    /// topic under a better name; `failed` is no answer at all — the call failed or the reply was
    /// not one of the three — and is never read as `kept`, so the next turn asks again.
    enum Verdict: Equatable, Sendable {
        case kept
        case renamed(String)
        case moved(title: String, start: Int)
        case failed
    }

    /// Whether a conversation that has been going a while still wears the right name, and if the
    /// topic moved, where. The model is shown the title, the person's messages since the last
    /// look, numbered, and the newest answer, and answers in one of three shapes, so a reworded
    /// title for the same work never reads as new work.
    static func revised(
        binary: String, projectsDir: String, current: String, prompts: [String], assistant: String
    ) async -> Verdict {
        guard !prompts.isEmpty else { return .failed }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cwd = "\(home)/.claude-bridge/titler"
        try? FileManager.default.createDirectory(
            atPath: cwd, withIntermediateDirectories: true)
        defer { cleanupTranscripts(projectsDir: projectsDir, cwd: cwd) }

        let numbered = prompts.enumerated().map { index, text in
            "Message \(index + 1): \(condense(text, cap: 400))"
        }.joined(separator: "\n")
        let prompt = """
            A coding-agent conversation is titled "\(current)". Below are the person's newest \
            messages, numbered, and the agent's latest answer. Reply with exactly one line:
            KEEP — the title still fits what the conversation is focused on now.
            RENAME: <title> — the same focus, but the title could say it better.
            MOVED <n>: <title> — the focus has shifted to a new task, problem or phase of the work, \
            even within the same project, and the shift began at message <n>. A single side \
            question is not a shift.
            A title is 3 to 6 words, plain text, no quotes, no trailing period.

            \(numbered)
            Answer: \(condense(assistant, cap: 400))
            """
        guard let raw = await run(binary: binary, cwd: cwd, prompt: prompt) else { return .failed }
        return verdict(from: raw, current: current, count: prompts.count)
    }

    /// Reads a revision reply: its first non-empty line, with any markdown around it taken off.
    /// `MOVED n: title` with `n` outside the messages shown begins at the newest; a bare title is
    /// read as a rename, never as a move, because only an explicit move may open a chapter; a new
    /// title that only restates the current one is a KEEP.
    static func verdict(from raw: String, current: String, count: Int) -> Verdict {
        guard let line = raw.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t*_`#>")) })
            .first(where: { !$0.isEmpty })
        else { return .failed }
        if line.range(of: #"^keep\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .kept
        }
        if let match = line.firstMatch(of: #/^(?i:moved)\s*(\d{1,3})\s*:\s*(.+)$/#) {
            guard let title = replacement(from: String(match.2), current: current) else {
                return .kept
            }
            let number = Int(match.1) ?? count
            return .moved(title: title, start: (1...max(1, count)).contains(number) ? number : count)
        }
        if let match = line.firstMatch(of: #/^(?i:rename)\s*:\s*(.+)$/#) {
            guard let title = replacement(from: String(match.1), current: current) else {
                return .kept
            }
            return .renamed(title)
        }
        guard line.count <= 70, !line.contains(":") else { return .failed }
        guard let title = replacement(from: line, current: current) else { return .kept }
        return .renamed(title)
    }

    /// One stretch a conversation's history was split into: the message it began at (counted from
    /// one in the list the model was shown), its title, and what it came to.
    struct Segment: Equatable, Sendable {
        var start: Int
        var title: String
        var gist: String?
    }

    /// Splits a conversation that already happened into its chapters, for one that is older than
    /// chapters: the person's messages, numbered, go in, and one line per chapter comes back.
    static func segments(
        binary: String, projectsDir: String, current: String, prompts: [String]
    ) async -> [Segment]? {
        guard !prompts.isEmpty else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cwd = "\(home)/.claude-bridge/titler"
        try? FileManager.default.createDirectory(
            atPath: cwd, withIntermediateDirectories: true)
        defer { cleanupTranscripts(projectsDir: projectsDir, cwd: cwd) }

        let numbered = prompts.enumerated().map { index, text in
            "\(index + 1): \(condense(text, cap: 160))"
        }.joined(separator: "\n")
        let prompt = """
            Below are the person's messages in a coding-agent conversation now titled \
            "\(current)", numbered, oldest first. Split the conversation into its chapters: \
            stretches in which the focus stayed on one task, problem or phase of the work. A single \
            side question is not a chapter. Most conversations have one to six. Reply with one line \
            per chapter, oldest first, and nothing else:
            <number of the message it began at> | <title, 3 to 6 words, plain text> | <one \
            past-tense sentence of at most 16 words saying what that stretch did or decided>
            Leave the last chapter's sentence empty: it is still going. The first chapter begins \
            at message 1.

            \(numbered)
            """
        guard let raw = await run(binary: binary, cwd: cwd, prompt: prompt) else { return nil }
        return segments(from: raw, count: prompts.count)
    }

    /// Reads a segmentation reply: one `n | title | sentence` line per chapter. Lines that are not
    /// that shape are skipped; the first chapter is made to begin at the first message, and a
    /// start that does not move forward is dropped, so what comes back always tiles the messages.
    static func segments(from raw: String, count: Int) -> [Segment]? {
        var result: [Segment] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            let cleaned = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t*_`#>-"))
            let fields = cleaned.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 2, let start = Int(fields[0]), (1...max(1, count)).contains(start),
                let title = replacement(from: fields[1], current: "")
            else { continue }
            let gist = fields.count > 2 ? gistLine(from: fields[2]) : nil
            if result.isEmpty {
                result.append(Segment(start: 1, title: title, gist: gist))
            } else if start > result[result.count - 1].start {
                result.append(Segment(start: start, title: title, gist: gist))
            }
        }
        guard !result.isEmpty else { return nil }
        result[result.count - 1].gist = nil
        return result
    }

    /// One sentence saying what a finished stretch of the conversation came to, written once the
    /// next stretch begins, so a reader can follow a long conversation's arc without rereading it.
    static func gist(
        binary: String, projectsDir: String, title: String, prompts: [String], answer: String
    ) async -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cwd = "\(home)/.claude-bridge/titler"
        try? FileManager.default.createDirectory(
            atPath: cwd, withIntermediateDirectories: true)
        defer { cleanupTranscripts(projectsDir: projectsDir, cwd: cwd) }

        let said = prompts.map { "Person: \(condense($0, cap: 200))" }.joined(separator: "\n")
        let prompt = """
            Here is one stretch of a coding-agent conversation, titled "\(title)": the person's \
            messages in it, oldest first, and the agent's last answer in it. In one plain sentence \
            of at most 16 words, say what this stretch did or decided, in the past tense. Say \
            something was finished, shipped or released only if the last answer says it was; \
            otherwise say what was worked on or proposed. No preamble, no quotes. Reply with the \
            sentence only.

            \(said)
            Answer: \(condense(answer, cap: 600))
            """
        guard let raw = await run(binary: binary, cwd: cwd, prompt: prompt) else { return nil }
        return gistLine(from: raw)
    }

    /// The sentence a gist reply holds: its first non-empty line, unquoted, or nil when it is
    /// empty or runs past what a sentence of sixteen words could be.
    static func gistLine(from raw: String) -> String? {
        guard let line = raw.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }
        let sentence = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”"))
            .trimmingCharacters(in: .whitespaces)
        guard !sentence.isEmpty, sentence.count <= 220 else { return nil }
        return sentence
    }

    /// The new title a revision reply asks for, or nil when it says to keep the current one, says
    /// nothing, or only restates it.
    static func replacement(from raw: String, current: String) -> String? {
        let title = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”."))
        guard !title.isEmpty, title.count <= 70, !title.contains("\n"),
            title.caseInsensitiveCompare("KEEP") != .orderedSame,
            title.caseInsensitiveCompare(current) != .orderedSame
        else { return nil }
        return title
    }

    private static func condense(_ text: String, cap: Int) -> String {
        let flattened = text
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(flattened.prefix(cap))
    }

    /// Ends a title run that outlived its deadline: SIGTERM, then SIGKILL five seconds later for
    /// one still there, since the read waiting on its output ends only when it does and the chat
    /// stays marked as being titled until then.
    private static func end(_ process: Process) {
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private static func run(binary: String, cwd: String, prompt: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = ["-p", "--model", "haiku", "--output-format", "text", prompt]
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)
                var environment = ProcessInfo.processInfo.environment
                environment["CLAUDE_CODE_ENTRYPOINT"] = "claude-bridge-titler"
                process.environment = environment
                process.standardError = FileHandle.nullDevice
                let stdout: Pipe
                do {
                    stdout = try Spawning.serialized {
                        let stdout = Pipe()
                        process.standardOutput = stdout
                        try process.runAllowingBusyExecutable()
                        return stdout
                    }
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let killer = DispatchWorkItem { Self.end(process) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: killer)
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: String(data: data, encoding: .utf8))
            }
        }
    }

    private static func cleanupTranscripts(projectsDir: String, cwd: String) {
        let encoded = cwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let projectDir = "\(projectsDir)/\(encoded)"
        guard projectDir.hasSuffix("titler") else { return }
        try? FileManager.default.removeItem(atPath: projectDir)
    }
}
