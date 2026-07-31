import Foundation

/// Which build of itself the bridge is running.
///
/// The bridge is installed from source — a git checkout plus `swift build` — so the honest answer
/// comes from git rather than a constant baked in at compile time: a tag when the checkout sits on
/// one, otherwise the tag it descends from and the commit. The constant is the fallback for an
/// install that shipped without its `.git` directory.
enum BridgeVersion {
    static let fallback = "1.0.0"

    static func describe(source: String?) -> String {
        guard let source,
            let described = Shell.run("git", ["describe", "--tags", "--always", "--dirty"], cwd: source)
                .trimmedOrNil()
        else { return fallback }
        return described
    }

    static func commit(source: String?) -> String? {
        guard let source else { return nil }
        return Shell.run("git", ["rev-parse", "--short", "HEAD"], cwd: source).trimmedOrNil()
    }

    /// The checkout this binary was built from: what an update has to pull into.
    ///
    /// Set `BRIDGE_SRC` when the binary has been copied away from its checkout. Otherwise it is
    /// derived from the running executable, which lives at `<checkout>/.build/release/claude-bridge`
    /// for every install the script produces.
    static func sourceDirectory() -> String? {
        if let configured = ProcessInfo.processInfo.environment["BRIDGE_SRC"], !configured.isEmpty {
            return isCheckout(configured) ? configured : nil
        }
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            return nil
        }
        var directory = executable.deletingLastPathComponent()
        for _ in 0..<6 {
            if isCheckout(directory.path) { return directory.path }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { break }
            directory = parent
        }
        return nil
    }

    private static func isCheckout(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: "\(path)/Package.swift")
            && FileManager.default.fileExists(atPath: "\(path)/.git")
    }
}

/// Runs a command and collects its output, bounded by a timeout: every caller here talks to the
/// network (`git fetch`) or to a service manager, and a bridge must not wedge on either.
enum Shell {
    private final class Output: @unchecked Sendable {
        var data = Data()
    }

    @discardableResult
    static func run(
        _ executable: String, _ arguments: [String], cwd: String? = nil, timeout: TimeInterval = 30
    ) -> String {
        guard let url = which(executable) else { return "" }
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        guard (try? process.run()) != nil else { return "" }
        let output = Output()
        let handle = pipe.fileHandleForReading
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            output.data = handle.readDataToEndOfFile()
            finished.signal()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 5)
        }
        process.waitUntilExit()
        return String(data: output.data, encoding: .utf8) ?? ""
    }

    static func which(_ executable: String) -> URL? {
        if executable.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: executable)
                ? URL(fileURLWithPath: executable) : nil
        }
        let path =
            ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/local/bin:/usr/bin:/bin"
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/\(executable)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }
}

extension String {
    func trimmedOrNil() -> String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// What a client needs to decide whether to offer an update, and to follow one it started.
struct UpdateStatus: Codable, Sendable {
    var version: String
    var commit: String?
    var latestVersion: String?
    var latestCommit: String?
    var updateAvailable = false
    var behind: Int?
    var changes: [String] = []
    /// False when this install cannot update itself — no checkout, a dirty one, no toolchain. The
    /// `reason` says which, in words a person can act on.
    var canUpdate = false
    var reason: String?
    var manager: String
    var source: String?
    var phase: String
    var startedAt: Date?
    var finishedAt: Date?
    var log: String?
}

struct UpdateState: Codable, Sendable {
    var phase: String
    var startedAt: Date?
    var finishedAt: Date?
}

/// The bridge updating itself: fetch, rebuild, restart.
///
/// A phone cannot ssh into the machine it is talking to, so a bridge that can only be updated from
/// a terminal is a bridge that never gets updated. The work runs in a detached process — the last
/// thing it does is restart the service, which kills this one — and reports through a state file
/// that survives the restart, so a client can follow a job whose server went away mid-answer.
actor UpdateService {
    private let source: String?
    private let stateDirectory: URL
    private let stateURL: URL
    private let logURL: URL
    private var lastFetch: Date?
    private var cachedRemote: RemoteState?

    private struct RemoteState {
        let commit: String
        let describe: String?
        let changes: [String]
        let behind: Int
    }

    init(stateDirectory: URL) {
        source = BridgeVersion.sourceDirectory()
        self.stateDirectory = stateDirectory
        stateURL = stateDirectory.appendingPathComponent("update.state.json")
        logURL = stateDirectory.appendingPathComponent("update.log")
        try? FileManager.default.createDirectory(
            at: stateDirectory, withIntermediateDirectories: true)
    }

    func status(refreshing: Bool = true) -> UpdateStatus {
        let state = readState()
        let phase = state?.phase ?? "idle"
        var status = UpdateStatus(
            version: BridgeVersion.describe(source: source),
            commit: BridgeVersion.commit(source: source),
            manager: Self.serviceManager,
            source: source,
            phase: phase,
            startedAt: state?.startedAt,
            finishedAt: state?.finishedAt,
            log: phase == "idle" ? nil : logTail())
        guard let source else {
            status.reason =
                "This bridge was not installed from a git checkout, so it cannot update itself."
            return status
        }
        guard Shell.which("git") != nil else {
            status.reason = "git is needed to update, and it is not on this machine's PATH."
            return status
        }
        guard Shell.which("swift") != nil else {
            status.reason = "A Swift toolchain is needed to rebuild, and swift is not on the PATH."
            return status
        }
        if isDirty(source) {
            status.reason = "The checkout at \(source) has uncommitted changes."
        } else {
            status.canUpdate = true
            if Self.serviceManager == "manual" {
                status.reason =
                    "No service supervises this bridge, so it will rebuild but you will have to "
                    + "start it again yourself."
            }
        }
        if refreshing, let remote = remoteState() {
            status.latestCommit = remote.commit
            status.latestVersion = remote.describe
            status.changes = remote.changes
            status.behind = remote.behind
            status.updateAvailable = remote.behind > 0
        }
        return status
    }

    /// Starts an update unless one is already running, and answers with the status a client should
    /// show while it waits.
    func start() -> (accepted: Bool, status: UpdateStatus) {
        var current = status(refreshing: false)
        guard current.canUpdate else { return (false, current) }
        guard current.phase != "running" else { return (false, current) }
        guard let source, let script = stagedScript(source: source) else {
            current.reason = "install.sh is missing from the checkout, so there is nothing to run."
            return (false, current)
        }
        let now = Date()
        write(UpdateState(phase: "running", startedAt: now, finishedAt: nil))
        try? Data().write(to: logURL, options: .atomic)
        detach(script: script, source: source)
        lastFetch = nil
        current.phase = "running"
        current.startedAt = now
        current.finishedAt = nil
        return (true, current)
    }

    /// The updater has to outlive the process that starts it: its last step restarts the service,
    /// and a child of that service dies with it. systemd gives us a transient unit outside our own
    /// cgroup, launchd takes a submitted job, and anything else gets a plain detached process —
    /// enough when nothing is going to signal a process group.
    private func detach(script: String, source: String) {
        var environment = [
            "BRIDGE_SRC": source,
            "BRIDGE_STATE_DIR": stateDirectory.path,
        ]
        environment["PATH"] = ProcessInfo.processInfo.environment["PATH"]
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        let command = "\(exports(environment)) exec /bin/bash \(script) --update"
        switch Self.serviceManager {
        case "systemd":
            var arguments = ["--user", "--collect", "--quiet", "--unit=claude-bridge-update"]
            arguments += environment.map { "--setenv=\($0.key)=\($0.value)" }
            arguments += ["/bin/bash", script, "--update"]
            Shell.run("systemd-run", arguments, timeout: 15)
        case "launchd":
            Shell.run(
                "launchctl",
                [
                    "submit", "-l", "com.guitaripod.claude-bridge.update", "--", "/bin/bash", "-c",
                    command,
                ],
                timeout: 15)
        default:
            Shell.run(
                "/bin/sh",
                ["-c", "\(exports(environment)) nohup /bin/bash \(script) --update >/dev/null 2>&1 &"],
                timeout: 15)
        }
    }

    private func exports(_ environment: [String: String]) -> String {
        environment.map { "export \($0.key)=\"\($0.value)\";" }.joined(separator: " ")
    }

    /// The script is copied out of the checkout before it runs: bash reads a script as it executes,
    /// and the update rewrites that file underneath it.
    private func stagedScript(source: String) -> String? {
        let origin = "\(source)/install.sh"
        guard FileManager.default.fileExists(atPath: origin) else { return nil }
        let staged = NSTemporaryDirectory() + "claude-bridge-update.sh"
        try? FileManager.default.removeItem(atPath: staged)
        guard (try? FileManager.default.copyItem(atPath: origin, toPath: staged)) != nil else {
            return nil
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged)
        return staged
    }

    private func remoteState() -> RemoteState? {
        guard let source else { return nil }
        if let lastFetch, Date().timeIntervalSince(lastFetch) < 300 { return cachedRemote }
        Shell.run("git", ["fetch", "--quiet", "--tags", "origin"], cwd: source, timeout: 25)
        lastFetch = Date()
        guard let head = remoteHead(source) else {
            cachedRemote = nil
            return nil
        }
        let range = "HEAD..\(head)"
        let behind =
            Int(Shell.run("git", ["rev-list", "--count", range], cwd: source).trimmedOrNil() ?? "")
            ?? 0
        let changes = Shell.run("git", ["log", "--pretty=format:%s", "-20", range], cwd: source)
            .split(separator: "\n").map(String.init)
        let describe = Shell.run("git", ["describe", "--tags", "--always", head], cwd: source)
            .trimmedOrNil()
        cachedRemote = RemoteState(
            commit: String(head.prefix(9)), describe: describe, changes: changes, behind: behind)
        return cachedRemote
    }

    /// The branch this checkout tracks, falling back to the remote's default branch: an install
    /// that was cloned normally tracks one, but a checkout moved between machines may not.
    private func remoteHead(_ source: String) -> String? {
        if let upstream = Shell.run(
            "git", ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], cwd: source
        ).trimmedOrNil() {
            return Shell.run("git", ["rev-parse", upstream], cwd: source).trimmedOrNil()
        }
        for candidate in ["origin/HEAD", "origin/master", "origin/main"] {
            if let resolved = Shell.run("git", ["rev-parse", candidate], cwd: source).trimmedOrNil()
            {
                return resolved
            }
        }
        return nil
    }

    private func isDirty(_ source: String) -> Bool {
        Shell.run("git", ["status", "--porcelain"], cwd: source).trimmedOrNil() != nil
    }

    private func readState() -> UpdateState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONCoding.decoder.decode(UpdateState.self, from: data)
    }

    private func write(_ state: UpdateState) {
        guard let data = try? JSONCoding.encoder.encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    private func logTail(lines: Int = 40) -> String? {
        guard let contents = try? String(contentsOf: logURL, encoding: .utf8) else { return nil }
        return contents.split(separator: "\n").suffix(lines).joined(separator: "\n").trimmedOrNil()
    }

    static let serviceManager: String = {
        #if os(macOS)
            return Shell.run("launchctl", ["list"], timeout: 10)
                .contains("com.guitaripod.claude-bridge") ? "launchd" : "manual"
        #else
            let unit = Shell.run(
                "systemctl", ["--user", "is-enabled", "claude-bridge.service"], timeout: 10)
            return unit.contains("enabled") || unit.contains("static") ? "systemd" : "manual"
        #endif
    }()
}
