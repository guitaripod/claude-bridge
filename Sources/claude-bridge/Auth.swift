import Foundation

/// Whether the Claude CLI on this machine is signed in, and as whom.
///
/// A logged-out CLI answers every turn with "Not logged in · Please run /login" — an assistant
/// message rather than an error — so a client that cannot see this state shows the user a chat
/// that has quietly stopped working.
struct AuthStatus: Codable, Sendable {
    var loggedIn: Bool
    var method: String?
    var email: String?
    var organization: String?
    var subscription: String?
    /// The sign-in in progress, if one is waiting for the code.
    var pending: PendingLogin?

    struct PendingLogin: Codable, Sendable {
        var url: String
        var startedAt: Date
    }

    private enum CLIKeys: String, CodingKey {
        case loggedIn, authMethod, email, orgName, subscriptionType
    }

    init(loggedIn: Bool, method: String? = nil, email: String? = nil, organization: String? = nil,
        subscription: String? = nil, pending: PendingLogin? = nil
    ) {
        self.loggedIn = loggedIn
        self.method = method
        self.email = email
        self.organization = organization
        self.subscription = subscription
        self.pending = pending
    }

    /// `claude auth status --json` — the CLI's own answer, which is the only authority here.
    init?(cliJSON data: Data) {
        guard let container = try? JSONDecoder().decode(CLIStatus.self, from: data) else {
            return nil
        }
        self.init(
            loggedIn: container.loggedIn ?? false,
            method: container.authMethod,
            email: container.email,
            organization: container.orgName,
            subscription: container.subscriptionType)
    }

    private struct CLIStatus: Decodable {
        let loggedIn: Bool?
        let authMethod: String?
        let email: String?
        let orgName: String?
        let subscriptionType: String?
    }
}

/// Signing the machine's Claude CLI in from a phone.
///
/// `claude auth login` is a terminal program: it prints an OAuth URL and then blocks on a prompt
/// for the code the browser hands back. Both halves can be moved off the machine — the bridge runs
/// it on a pseudo-terminal, hands the URL to the client, and types the code the client returns —
/// which is what makes a headless server signable-in from a device that has no shell on it.
actor AuthService {
    private let claudePath: String
    private let workdir: String
    private var session: LoginSession?
    private var cached: (status: AuthStatus, at: Date)?

    init(claudePath: String, workdir: String) {
        self.claudePath = claudePath
        self.workdir = workdir
    }

    /// A sign-in halfway through its two-machine handshake. It is a pseudo-terminal waiting on a
    /// code somebody is reading off a browser, and a restart takes the code they are about to paste
    /// with it — so it counts as work in flight even though no turn is running.
    func isSigningIn() -> Bool {
        session?.isRunning == true
    }

    func status(refreshing: Bool = false) async -> AuthStatus {
        var status = await current(refreshing: refreshing)
        if let session, session.isRunning, let url = session.url {
            status.pending = AuthStatus.PendingLogin(url: url, startedAt: session.startedAt)
        }
        return status
    }

    /// Starts the sign-in and waits for the URL the CLI prints. Returns the status carrying it.
    func beginLogin() async throws -> AuthStatus {
        if let session, session.isRunning, session.url != nil { return await status() }
        session?.cancel()
        let session = LoginSession(claudePath: claudePath, workdir: workdir)
        self.session = session
        try session.start()
        for _ in 0..<60 {
            if let url = session.url, !url.isEmpty { break }
            if !session.isRunning { break }
            try? await Task.sleep(for: .milliseconds(400))
        }
        guard session.url != nil else {
            session.cancel()
            self.session = nil
            throw AuthError.noURL(session.transcriptTail())
        }
        cached = nil
        return await status()
    }

    /// Types the code the browser gave the user, then waits for the CLI to actually be signed in —
    /// the prompt accepting the paste is not the same thing as the token landing.
    func submit(code: String) async throws -> AuthStatus {
        guard let session, session.isRunning else { throw AuthError.noSession }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AuthError.emptyCode }
        session.send(trimmed)
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(750))
            let status = await current(refreshing: true)
            if status.loggedIn {
                session.cancel()
                self.session = nil
                return status
            }
            if !session.isRunning { break }
        }
        let tail = session.transcriptTail()
        session.cancel()
        self.session = nil
        cached = nil
        throw AuthError.rejected(tail)
    }

    func cancel() {
        session?.cancel()
        session = nil
    }

    /// Asking the CLI who is signed in forks a process and waits on it, and `/status` — which
    /// every client polls — used to do that inside this actor: one cold read held every other
    /// auth call for as long as the fork took. The fork now happens off the actor and only once
    /// at a time, and a caller with a fresh enough answer never waits at all.
    private func current(refreshing: Bool) async -> AuthStatus {
        if !refreshing, let cached, Date().timeIntervalSince(cached.at) < Self.freshSeconds {
            return cached.status
        }
        if let probe { return await probe.value }
        let path = claudePath
        let directory = workdir
        let probe = Task.detached(priority: .userInitiated) { () -> AuthStatus in
            let output = Shell.run(
                path, ["auth", "status", "--json"], cwd: directory, timeout: 20)
            return AuthStatus(cliJSON: Data(output.utf8))
                ?? AuthStatus(loggedIn: false, method: "unknown")
        }
        self.probe = probe
        let status = await probe.value
        self.probe = nil
        cached = (status, Date())
        return status
    }

    private static let freshSeconds: TimeInterval = 15
    private var probe: Task<AuthStatus, Never>?
}

enum AuthError: Error {
    case noSession
    case emptyCode
    case noURL(String)
    case rejected(String)

    var message: String {
        switch self {
        case .noSession:
            return "No sign-in is waiting. Start one first."
        case .emptyCode:
            return "That code was empty."
        case .noURL(let tail):
            return "The CLI didn't offer a sign-in link.\(tail.isEmpty ? "" : " It said: \(tail)")"
        case .rejected(let tail):
            return
                "The CLI didn't accept that code.\(tail.isEmpty ? "" : " It said: \(tail)")"
        }
    }
}

/// `claude auth login` running on a pseudo-terminal, because it refuses to print anything useful
/// into a pipe. `script` is what allocates the terminal: it exists on macOS and on any Linux with
/// util-linux, and it forwards our stdin to the program, which is how the code gets typed.
private final class LoginSession: @unchecked Sendable {
    private let claudePath: String
    private let workdir: String
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var transcript = ""

    let startedAt = Date()

    init(claudePath: String, workdir: String) {
        self.claudePath = claudePath
        self.workdir = workdir
    }

    var isRunning: Bool { process.isRunning }

    var url: String? {
        lock.lock()
        defer { lock.unlock() }
        return Self.oauthURL(in: transcript)
    }

    func start() throws {
        #if os(macOS)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            process.arguments = ["-q", "/dev/null", claudePath, "auth", "login"]
        #else
            guard let script = Shell.which("script") else { throw AuthError.noURL("script is not installed on this machine, so the CLI cannot be given a terminal to sign in on.") }
            process.executableURL = script
            process.arguments = ["-qec", "\(claudePath) auth login", "/dev/null"]
        #endif
        process.currentDirectoryURL = URL(fileURLWithPath: workdir)
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        environment["BROWSER"] = "true"
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.append(text)
        }
        try process.run()
    }

    func send(_ code: String) {
        try? input.fileHandleForWriting.write(contentsOf: Data("\(code)\n".utf8))
    }

    func cancel() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    /// The last thing the CLI said, stripped of the escape sequences a terminal program paints
    /// with — what a client shows when the sign-in did not go through.
    func transcriptTail(limit: Int = 240) -> String {
        lock.lock()
        defer { lock.unlock() }
        let lines = Self.plain(transcript)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("://") }
        return String(lines.suffix(2).joined(separator: " ").suffix(limit))
    }

    private func append(_ text: String) {
        lock.lock()
        transcript += text
        if transcript.count > 64_000 { transcript = String(transcript.suffix(32_000)) }
        lock.unlock()
    }

    /// The URL arrives wrapped in a hyperlink escape, so its text is printed twice back to back;
    /// the second copy is cut off at the start of the repeat.
    private static func oauthURL(in transcript: String) -> String? {
        let plain = self.plain(transcript)
        guard let start = plain.range(of: "https://claude.com/") else { return nil }
        let rest = plain[start.lowerBound...]
        let end =
            rest.dropFirst().range(of: "https://")?.lowerBound
            ?? rest.rangeOfCharacter(from: Self.terminators)?.lowerBound
            ?? rest.endIndex
        let url = String(rest[rest.startIndex..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return url.count > 40 ? url : nil
    }

    private static let terminators = CharacterSet(charactersIn: " \n\r\t\"'")
        .union(.controlCharacters)

    private static func plain(_ text: String) -> String {
        var output = ""
        var escaping = false
        var operatingSystemCommand = false
        for character in text {
            if escaping {
                if operatingSystemCommand {
                    if character == "\u{07}" || character == "\\" {
                        escaping = false
                        operatingSystemCommand = false
                    }
                    continue
                }
                if character == "]" {
                    operatingSystemCommand = true
                    continue
                }
                if character.isLetter {
                    escaping = false
                }
                continue
            }
            if character == "\u{1B}" {
                escaping = true
                continue
            }
            output.append(character)
        }
        return output
    }
}
