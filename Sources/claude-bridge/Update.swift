import Foundation

/// Which build of itself the bridge is running.
///
/// The bridge is installed from source — a git checkout plus `swift build` — so the honest answer
/// comes from git rather than a constant baked in at compile time: a tag when the checkout sits on
/// one, otherwise the tag it descends from and the commit. The constant is the fallback for an
/// install that shipped without its `.git` directory.
enum BridgeVersion {
    static let fallback = "1.4.0"

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

    /// What this *process* is, as opposed to what the directory it came from currently says.
    ///
    /// The installer writes the stamp immediately after the build that produced this binary, and
    /// it is read exactly once, at startup — which is what makes it true by construction. A client
    /// comparing this against ``describe(source:)`` learns the one thing the old contract could
    /// never tell it: that a build has landed and nothing has restarted onto it yet, which under a
    /// `manual` service manager is a permanent state rather than a passing one.
    struct Stamp: Decodable {
        let version: String
        let commit: String?
        let builtAt: Date?
        let source: String?
    }

    static let running: Stamp? = {
        let environment = ProcessInfo.processInfo.environment
        let directory =
            environment["BRIDGE_STATE_DIR"]
            ?? environment["BRIDGE_STORE"].map {
                URL(fileURLWithPath: $0).deletingLastPathComponent().path
            }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude-bridge").path
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: "\(directory)/build.json"))
        else { return nil }
        return try? JSONCoding.decoder.decode(Stamp.self, from: data)
    }()
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
        String(
            data: data(executable, arguments, cwd: cwd, timeout: timeout), encoding: .utf8) ?? ""
    }

    /// What the command complained about. A `git fetch` that cannot reach its remote writes the
    /// reason to stderr and nowhere else, and a client told only "no update available" would read
    /// a dead network as good news.
    static func runCapturingErrors(
        _ executable: String, _ arguments: [String], cwd: String? = nil, timeout: TimeInterval = 30
    ) -> String {
        guard let url = which(executable) else { return "\(executable) is not on the PATH" }
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let pipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = pipe
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        guard (try? process.run()) != nil else { return "could not run \(executable)" }
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
            return "timed out after \(Int(timeout))s"
        }
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return "" }
        return String(data: output.data, encoding: .utf8) ?? ""
    }

    /// The bytes as the command wrote them. A path is bytes, and git's `-z` formats separate
    /// records with a NUL — both survive a `Data` and neither survives a lossy decode.
    static func data(
        _ executable: String, _ arguments: [String], cwd: String? = nil, timeout: TimeInterval = 30
    ) -> Data {
        guard let url = which(executable) else { return Data() }
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
        guard (try? process.run()) != nil else { return Data() }
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
        return output.data
    }

    /// Starts a command and walks away: no pipe to read, no exit to wait for. Backgrounding
    /// through a shell instead leaves this process holding the child's output, which turns a
    /// hand-off into a wait for the whole job.
    static func spawn(_ executable: String, _ arguments: [String], environment: [String: String]) {
        guard let url = which(executable) else { return }
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in environment { merged[key] = value }
        process.environment = merged
        try? process.run()
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

/// What the bridge actually did about looking for a newer build.
///
/// `updateAvailable: false` used to cover four situations a client could not tell apart —
/// genuinely current, asked not to check, nothing to check with, and a fetch that failed silently.
/// Saying which one it was is the difference between "up to date" and "I could not find out", and
/// only this end knows.
struct RemoteCheck: Codable, Sendable {
    var checked: Bool
    var ok: Bool
    var at: Date?
    var error: String?
    var ref: String?
}

/// What a client needs to decide whether to offer an update, and to follow one it started.
struct UpdateStatus: Codable, Sendable {
    /// What the checkout says. A fact about a directory, which moves under a `git checkout` and
    /// runs ahead of this process between a build and a restart.
    var version: String
    /// What this process is, stamped when it was built. The honest answer to "what are you
    /// running".
    var running: String?
    /// A build has landed that this process is not running. Permanent under `manual`.
    var restartRequired = false
    var builtAt: Date?
    var remote: RemoteCheck?
    /// Commits the checkout has that its upstream does not: an update is a fast-forward, so any of
    /// these means no press can take it.
    var ahead: Int?
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
        let ahead: Int
        let ref: String?
        let at: Date
        /// Why the refs these counts came from may be stale. The counts are still worth reporting —
        /// a machine that was three commits behind an hour ago still is — but a client told the
        /// check succeeded would print "up to date" off week-old refs, which is the one sentence
        /// this whole contract exists to prevent.
        let fetchFailed: String?
    }

    /// Why the last attempt to consult the remote did not produce one, kept so the answer can say
    /// so rather than looking like "nothing newer".
    private var lastRemoteError: String?

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
        let phase = Self.settled(state)
        let checkout = BridgeVersion.describe(source: source)
        let manager = Self.serviceManager()
        var status = UpdateStatus(
            version: checkout,
            running: BridgeVersion.running?.version,
            restartRequired: restartRequired(source: source),
            builtAt: BridgeVersion.running?.builtAt,
            remote: RemoteCheck(checked: false, ok: false),
            commit: BridgeVersion.commit(source: source),
            manager: manager,
            source: source,
            phase: phase,
            startedAt: state?.startedAt,
            finishedAt: state?.finishedAt,
            log: phase == "idle" ? nil : logTail())
        guard let source else {
            status.reason =
                "This bridge was not installed from a git checkout, so it cannot update itself."
            status.remote = RemoteCheck(
                checked: false, ok: false,
                error: "There is no checkout here to compare against the project.")
            return status
        }
        guard Shell.which("git") != nil else {
            status.reason = "git is needed to update, and it is not on this machine's PATH."
            status.remote = RemoteCheck(
                checked: false, ok: false, error: "git is not on this machine's PATH.")
            return status
        }
        guard Shell.which("swift") != nil else {
            status.reason = "A Swift toolchain is needed to rebuild, and swift is not on the PATH."
            status.remote = RemoteCheck(
                checked: false, ok: false, error: "No Swift toolchain, so nothing here can rebuild.")
            return status
        }
        if isDirty(source) {
            status.reason = "The checkout at \(source) has uncommitted changes."
        } else {
            status.canUpdate = true
            if manager == "manual" {
                status.reason =
                    "No service supervises this bridge, so it will rebuild but you will have to "
                    + "start it again yourself."
            }
        }
        guard refreshing else {
            status.remote = RemoteCheck(
                checked: false, ok: false, error: "This answer did not consult the project.")
            return status
        }
        guard let remote = remoteState() else {
            status.remote = RemoteCheck(
                checked: true, ok: false, at: Date(),
                error: lastRemoteError ?? "The project could not be reached.")
            return status
        }
        status.latestCommit = remote.commit
        status.latestVersion = remote.describe
        status.changes = remote.changes
        status.behind = remote.behind
        status.ahead = remote.ahead
        status.updateAvailable = remote.behind > 0
        status.remote = RemoteCheck(
            checked: true, ok: remote.fetchFailed == nil, at: remote.at,
            error: remote.fetchFailed, ref: remote.ref)
        if remote.ahead > 0 {
            status.canUpdate = false
            status.reason =
                "This checkout has \(remote.ahead) commits of its own, so it cannot be "
                + "fast-forwarded onto the project."
        }
        return status
    }

    /// A build that landed while this process kept running. Under a service manager it lasts
    /// seconds; under `manual` it lasts until somebody starts the bridge again, and for that whole
    /// time the checkout is not what is answering the request.
    ///
    /// Commits, never `describe` strings: a describe carries `-dirty`, so comparing the one stamped
    /// at build time against one taken now would announce a build nobody made the moment anybody
    /// edits a file in that checkout. A dirty tree cannot have produced this binary either way, so
    /// it answers no rather than guessing.
    private func restartRequired(source: String?) -> Bool {
        guard let source, !isDirty(source) else { return false }
        guard let built = BridgeVersion.running?.commit, !built.isEmpty,
            let head = BridgeVersion.commit(source: source)
        else { return false }
        return !built.hasPrefix(head) && !head.hasPrefix(built)
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
        try? Data().write(to: logURL, options: .atomic)
        write(UpdateState(phase: "running", startedAt: Date(), finishedAt: nil))
        detach(script: script, source: source)
        watch()
        lastFetch = nil
        return (true, status(refreshing: false))
    }

    /// Hands the work to a process that keeps running after this one answers, and stops caring
    /// about it: the script builds, and the restart is this process's own job — see ``watch()``.
    private func detach(script: String, source: String) {
        var environment = [
            "BRIDGE_SRC": source,
            "BRIDGE_STATE_DIR": stateDirectory.path,
        ]
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        Shell.spawn("/bin/bash", [script, "--update", "--managed"], environment: environment)
    }

    /// Reconciles a process that just started with the update that may have been running when it
    /// did: a phase of `restarting` means this process *is* that restart, and a build still in
    /// flight has to be watched again, because the binary it produces still needs loading.
    func resume() {
        guard let state = readState() else { return }
        switch state.phase {
        case "restarting":
            write(
                UpdateState(phase: "succeeded", startedAt: state.startedAt, finishedAt: Date()))
        case "running", "building":
            watch()
        default:
            break
        }
    }

    /// Restarting is the bridge's own move, not the script's.
    ///
    /// Every way of asking a supervisor to restart a service kills the process group the asking
    /// script lives in — and a launchd job that keeps being respawned will happily rebuild and
    /// restart forever. So the script stops at `restarting`, and the bridge exits: `Restart=always`
    /// and `KeepAlive` bring it straight back, now running the binary that was just built.
    private func watch() {
        Task { [weak self] in
            guard let self else { return }
            for _ in 0..<600 {
                try? await Task.sleep(for: .seconds(2))
                guard let phase = await self.phaseOnDisk() else { continue }
                if phase == "restarting" {
                    await self.finishAndExit()
                    return
                }
                if phase == "failed" || phase == "succeeded" { return }
            }
        }
    }

    private func phaseOnDisk() -> String? { readState()?.phase }

    /// An update whose process was killed — a machine that slept, a service stopped mid-build —
    /// leaves its phase behind forever. After half an hour it is not running, it failed.
    private static func settled(_ state: UpdateState?) -> String {
        guard let state else { return "idle" }
        let unfinished = ["running", "building", "restarting"].contains(state.phase)
        guard unfinished, let started = state.startedAt,
            Date().timeIntervalSince(started) > 30 * 60
        else { return state.phase }
        return "failed"
    }

    private func finishAndExit() async {
        write(UpdateState(phase: "succeeded", startedAt: readState()?.startedAt, finishedAt: Date()))
        guard Self.serviceManager() != "manual" else { return }
        try? await Task.sleep(for: .milliseconds(600))
        exit(0)
    }

    private func exports(_ environment: [String: String]) -> String {
        environment.map { "export \($0.key)=\"\($0.value)\";" }.joined(separator: " ")
    }

    /// The script is copied out of the checkout before it runs: bash reads a script as it executes,
    /// and the update rewrites that file underneath it.
    ///
    /// A checkout old enough to predate the installer has no script to copy, which is exactly the
    /// checkout most in need of an update — so it is taken from the commit being updated to
    /// instead, straight out of the object database the fetch already filled.
    private func stagedScript(source: String) -> String? {
        let staged = NSTemporaryDirectory() + "claude-bridge-update.sh"
        try? FileManager.default.removeItem(atPath: staged)
        let local = "\(source)/install.sh"
        if FileManager.default.fileExists(atPath: local),
            (try? FileManager.default.copyItem(atPath: local, toPath: staged)) != nil
        {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged)
            return staged
        }
        guard let head = remoteHead(source) else { return nil }
        let script = Shell.run("git", ["show", "\(head):install.sh"], cwd: source)
        guard script.contains("#!"),
            (try? script.write(toFile: staged, atomically: true, encoding: .utf8)) != nil
        else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged)
        return staged
    }

    /// Only the fetch is rate-limited — it is the part that costs a network round trip. How far
    /// behind this checkout is gets recomputed every time: it is a local question, and the answer
    /// changes the moment the checkout moves.
    private func remoteState() -> RemoteState? {
        guard let source else {
            lastRemoteError = "There is no checkout here to compare against the project."
            return nil
        }
        if lastFetch.map({ Date().timeIntervalSince($0) >= 300 }) ?? true {
            let complaint = Shell.runCapturingErrors(
                "git", ["fetch", "--quiet", "--tags", "origin"], cwd: source, timeout: 25)
            lastFetch = Date()
            lastRemoteError = complaint.trimmedOrNil().map {
                "Could not reach the project: \(String($0.prefix(200)))"
            }
        }
        guard let upstream = remoteRef(source), let head = remoteHead(source) else {
            lastRemoteError =
                lastRemoteError ?? "This checkout tracks nothing that could be compared against."
            return nil
        }
        let behind =
            Int(
                Shell.run("git", ["rev-list", "--count", "HEAD..\(head)"], cwd: source)
                    .trimmedOrNil() ?? "")
        let ahead =
            Int(
                Shell.run("git", ["rev-list", "--count", "\(head)..HEAD"], cwd: source)
                    .trimmedOrNil() ?? "")
        guard let behind, let ahead else {
            lastRemoteError = "git could not count how far this checkout is from the project."
            return nil
        }
        let changes = Shell.run(
            "git", ["log", "--pretty=format:%s", "-20", "HEAD..\(head)"], cwd: source
        ).split(separator: "\n").map(String.init)
        let describe = Shell.run("git", ["describe", "--tags", "--always", head], cwd: source)
            .trimmedOrNil()
        let state = RemoteState(
            commit: String(head.prefix(7)), describe: describe, changes: changes, behind: behind,
            ahead: ahead, ref: upstream, at: Date(), fetchFailed: lastRemoteError)
        cachedRemote = state
        return state
    }

    /// The name of the line this checkout is measured against, so a machine deliberately on a
    /// feature branch is not silently counted as behind everyone else's master.
    private func remoteRef(_ source: String) -> String? {
        if let upstream = Shell.run(
            "git", ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], cwd: source
        ).trimmedOrNil() {
            return upstream
        }
        for candidate in ["origin/HEAD", "origin/master", "origin/main"]
        where Shell.run("git", ["rev-parse", candidate], cwd: source).trimmedOrNil() != nil {
            return candidate
        }
        return nil
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

    /// A tail, not a transcript: a Swift build prints thousands of lines of warnings, and this
    /// rides in every poll a client makes while the update runs.
    private func logTail(lines: Int = 12, characters: Int = 2000) -> String? {
        guard let contents = try? String(contentsOf: logURL, encoding: .utf8) else { return nil }
        let tail = contents.split(separator: "\n").suffix(lines).joined(separator: "\n")
        return String(tail.suffix(characters)).trimmedOrNil()
    }

    /// Whether something will start this process again if it exits — the whole restart strategy
    /// rests on it, so the question is asked of the supervisor this process actually runs under,
    /// not of a unit name someone hoped for. On Linux that is our own cgroup and its `Restart=`;
    /// on macOS, the launch agent the installer writes, whose `KeepAlive` we know.
    ///
    /// Asked every time rather than once: a service installed after this process started would
    /// otherwise be reported as `manual` for the life of the process, and `manual` is exactly what
    /// changes what the button on the other end promises.
    static func serviceManager() -> String {
        #if os(macOS)
            return Shell.run("launchctl", ["list"], timeout: 10)
                .contains("com.guitaripod.claude-bridge") ? "launchd" : "manual"
        #else
            guard let unit = systemdUnit() else { return "manual" }
            let restart = Shell.run(
                "systemctl", ["--user", "show", unit, "-p", "Restart", "--value"], timeout: 10
            ).trimmedOrNil()
            return restart == "always" || restart == "on-success" ? "systemd" : "manual"
        #endif
    }

    /// The systemd unit this process belongs to, read off its own cgroup: the last path component
    /// that names a service, since the user manager itself (`user@1000.service`) is one too.
    private static func systemdUnit() -> String? {
        guard let cgroup = try? String(contentsOfFile: "/proc/self/cgroup", encoding: .utf8) else {
            return nil
        }
        for line in cgroup.split(separator: "\n") {
            let units = line.split(separator: "/").filter { $0.hasSuffix(".service") }
            if let unit = units.last, !unit.hasPrefix("user@") { return String(unit) }
        }
        return nil
    }
}
