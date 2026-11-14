import Foundation

/// What a sign-in on the machine looks like from the other screen: what it printed, the links and
/// codes in it, whether it is waiting for an answer, and how it ended.
struct AgentSignInState: Codable, Sendable, Equatable {
    var agent: String
    var method: String
    /// `running`, `succeeded`, `failed` or `cancelled`.
    var state: String
    var lines: [String]
    var links: [String]
    var codes: [String]
    var exitCode: Int32?
    var startedAt: Date
}

/// An agent's own sign-in, run on a pseudo-terminal so it behaves as it would for a person at the
/// machine, with what it prints relayed to whoever asked and what they type relayed back. The
/// Claude sign-in the bridge already does, made general: the machine runs the command, the device
/// opens the link and returns the code.
final class AgentSignIn: @unchecked Sendable {
    let agent: String
    let method: String
    private let process = Process()
    private let input = Spawning.pipe()
    private let output = Spawning.pipe()
    private let lock = NSLock()
    private var transcript = ""
    private var ended: (state: String, code: Int32?)?
    private let startedAt = Date()
    private let onExit: @Sendable (AgentSignIn) -> Void

    init(agent: String, method: String, onExit: @escaping @Sendable (AgentSignIn) -> Void = { _ in }) {
        self.agent = agent
        self.method = method
        self.onExit = onExit
    }

    func start(executable: String, arguments: [String], environment: [String: String], directory: String)
        throws
    {
        let line = ([executable] + arguments).map(Self.quoted).joined(separator: " ")
        #if os(macOS)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            process.arguments = ["-q", "/dev/null", executable] + arguments
        #else
            guard let script = CommandLocator.find("script", home: NSHomeDirectory()) else {
                throw AcpFailure.rpc(
                    code: -32603,
                    message: "script is not installed on this machine, so the sign-in cannot be given a terminal.",
                    detail: nil)
            }
            process.executableURL = URL(fileURLWithPath: script)
            process.arguments = ["-qec", line, "/dev/null"]
        #endif
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in environment { merged[key] = value }
        merged["TERM"] = "dumb"
        merged["BROWSER"] = "true"
        merged["NO_BROWSER"] = "1"
        process.environment = merged
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.append(String(decoding: data, as: UTF8.self))
        }
        process.terminationHandler = { [weak self] finished in
            finished.releaseFinished()
            guard let self else { return }
            self.lock.lock()
            if self.ended == nil {
                let code = finished.terminationStatus
                self.ended = (code == 0 ? "succeeded" : "failed", code)
            }
            self.lock.unlock()
            self.onExit(self)
        }
        try process.runAllowingBusyExecutable()
    }

    func send(_ text: String) {
        try? input.fileHandleForWriting.write(contentsOf: Data("\(text)\n".utf8))
    }

    /// For a sign-in the agent runs itself over ACP rather than in a terminal: what it has printed
    /// so far replaces the transcript, and its end is said from outside.
    func record(_ text: String) {
        lock.lock()
        transcript = text
        lock.unlock()
    }

    func finish(succeeded: Bool) {
        lock.lock()
        if ended == nil { ended = (succeeded ? "succeeded" : "failed", succeeded ? 0 : 1) }
        lock.unlock()
        onExit(self)
    }

    func cancel() {
        lock.lock()
        if ended == nil { ended = ("cancelled", nil) }
        lock.unlock()
        if process.isRunning { process.terminate() }
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ended == nil
    }

    var succeeded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ended?.state == "succeeded"
    }

    func snapshot() -> AgentSignInState {
        lock.lock()
        let text = transcript
        let end = ended
        lock.unlock()
        let lines = Self.lines(text)
        return AgentSignInState(
            agent: agent, method: method, state: end?.state ?? "running",
            lines: Array(lines.suffix(40)), links: Self.links(in: lines), codes: Self.codes(in: lines),
            exitCode: end?.code, startedAt: startedAt)
    }

    /// The lines of what was printed, as a person reads them: escape sequences gone, carriage
    /// returns resolved to the text they left standing, blank lines dropped.
    static func lines(_ text: String) -> [String] {
        TerminalText.plain(text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                String(line.split(separator: "\r").last ?? "").trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
    }

    static func links(in lines: [String]) -> [String] {
        var found: [String] = []
        for line in lines {
            var rest = Substring(line)
            while let start = rest.range(of: "https://") ?? rest.range(of: "http://") {
                let tail = rest[start.lowerBound...]
                let end = tail.firstIndex { $0 == " " || $0 == "\"" || $0 == "'" || $0 == ">" || $0 == ")" }
                    ?? tail.endIndex
                let link = String(tail[..<end]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
                if link.count > 10, !found.contains(link) { found.append(link) }
                rest = tail[end...]
            }
        }
        return found
    }

    /// A one-time code a device flow asks the person to type somewhere else: letters and digits
    /// in two groups of four or more, joined by a dash.
    static func codes(in lines: [String]) -> [String] {
        var found: [String] = []
        for line in lines where !line.contains("://") {
            for word in line.split(whereSeparator: { $0 == " " || $0 == ":" }) {
                let parts = word.split(separator: "-")
                guard parts.count == 2,
                    parts.allSatisfy({ $0.count >= 4 && $0.count <= 8 && $0.allSatisfy { $0.isLetter || $0.isNumber } }),
                    word.contains(where: \.isUppercase) || word.contains(where: \.isNumber)
                else { continue }
                let code = String(word)
                if !found.contains(code) { found.append(code) }
            }
        }
        return found
    }

    private func append(_ text: String) {
        lock.lock()
        transcript += text
        if transcript.count > 64_000 { transcript = String(transcript.suffix(32_000)) }
        lock.unlock()
    }

    private static func quoted(_ word: String) -> String {
        guard word.contains(where: { " \"'$`\\;&|<>()*?".contains($0) }) else { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
