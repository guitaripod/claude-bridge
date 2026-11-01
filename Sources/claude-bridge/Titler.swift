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

    /// Whether a conversation that has been going a while still wears the right name. The model
    /// is shown the title and the newest exchange and answers `KEEP` or a replacement, so a topic
    /// that has moved on is renamed and one that merely continued is left alone.
    static func revised(
        binary: String, projectsDir: String, current: String, user: String, assistant: String
    ) async -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cwd = "\(home)/.claude-bridge/titler"
        try? FileManager.default.createDirectory(
            atPath: cwd, withIntermediateDirectories: true)
        defer { cleanupTranscripts(projectsDir: projectsDir, cwd: cwd) }

        let prompt = """
            A coding-agent conversation is titled "\(current)". Here is its latest exchange. \
            If the title still describes what the conversation is about now, reply KEEP. \
            If the topic has moved on, reply with a new title instead: 3 to 6 words, plain \
            text, no quotes, no trailing period. Reply with KEEP or the title only.

            User: \(condense(user, cap: 600))
            Assistant: \(condense(assistant, cap: 400))
            """
        guard let raw = await run(binary: binary, cwd: cwd, prompt: prompt) else { return nil }
        return replacement(from: raw, current: current)
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
                let stdout = Pipe()
                process.standardOutput = stdout
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let killer = DispatchWorkItem { process.terminate() }
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
