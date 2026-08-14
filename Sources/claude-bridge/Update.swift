import Foundation

/// Which build of itself the bridge is running.
///
/// The bridge is installed from source — a git checkout plus `swift build` — so the honest answer
/// comes from git rather than a constant baked in at compile time: a tag when the checkout sits on
/// one, otherwise the tag it descends from and the commit. The constant is the fallback for an
/// install that shipped without its `.git` directory.
enum BridgeVersion {
    static let fallback = "1.6.0"

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
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: "\(directory)/build.json")),
            let stamp = try? JSONCoding.decoder.decode(Stamp.self, from: data)
        else { return nil }
        return describesThisBinary(stamp) ? stamp : nil
    }()

    /// Whether the stamp is about the binary that is actually running.
    ///
    /// The installer writes it immediately after the build it describes, so a binary newer than
    /// its own stamp was produced by some other hand — a plain `swift build` in the checkout — and
    /// the stamp is now describing a build nobody is running. That is not a cosmetic wrong number:
    /// the stamp is read once, at startup, and a commit in it that will never match HEAD makes
    /// `restartRequired` permanently true, so every restart taken to clear it re-reads the same
    /// lie and lands in the same state. A machine that keeps itself current then restarts on a
    /// loop, forever, over work no restart can do.
    ///
    /// Disowning it costs only the one thing the stamp was for — noticing a build that has landed
    /// and not started — and leaves the checkout's own `describe` answering for the version, which
    /// is what the contract said before the stamp existed.
    private static func describesThisBinary(_ stamp: Stamp) -> Bool {
        let executable = Bundle.main.executableURL?.resolvingSymlinksInPath()
        let modified = executable.flatMap {
            try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date
        }
        return stampDescribes(builtAt: stamp.builtAt, executableModified: modified ?? nil)
    }

    /// The comparison itself, where it can be read and tested.
    ///
    /// The slack is not fuzziness about which build this is: the installer stamps seconds after
    /// the link, and it writes whole seconds, so a binary modified at 11:49:15.8 against a stamp
    /// reading 11:49:15 would fail a strict comparison on every correct install there has ever
    /// been. What it is separating is builds seconds apart from builds days apart, and a stamp
    /// left behind by a hand-built binary is never within a minute of it.
    ///
    /// A stamp with nothing to compare against is believed: a bridge too old to date itself, or a
    /// filesystem that will not answer, is not evidence of a lie.
    static let stampSlack: TimeInterval = 60

    static func stampDescribes(builtAt: Date?, executableModified: Date?) -> Bool {
        guard let builtAt, let executableModified else { return true }
        return executableModified <= builtAt.addingTimeInterval(stampSlack)
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

/// Where a Swift toolchain lives when it is not on the PATH.
///
/// The bridge answers "can this machine rebuild me" and the installer then has to actually do it,
/// so the two have to look in the same places. Rather than keep two lists in step, the bridge
/// resolves it once and hands the answer to the script as `BRIDGE_SWIFT` — a promise the build
/// cannot fail on a technicality the status never saw. A bridge started outside its own runner has
/// a bare PATH, which is how a machine with a perfectly good toolchain came to report it had none.
enum BridgeToolchain {
    static let candidates = [
        "\(NSHomeDirectory())/.local/share/swiftly/bin",
        "/usr/local/swift/usr/bin",
        "/opt/swift/usr/bin",
    ]

    static func resolve() -> String? {
        if let onPath = Shell.which("swift") { return onPath.path }
        for directory in candidates {
            let candidate = "\(directory)/swift"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// What that toolchain says it is, in one line. Two toolchains on one machine is how a module
    /// format error becomes unreadable, so the answer names which one would do the building.
    static func describe(_ path: String) -> String? {
        guard
            let first = Shell.run(path, ["--version"], timeout: 20)
                .split(separator: "\n").first.map(String.init)?.trimmedOrNil()
        else { return path }
        return "\(first) · \(path)"
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

/// What stands between this machine and a one-press update, in a shape a client can render.
///
/// The sentence alone was never enough: "the checkout has uncommitted changes" is not actionable
/// without knowing which, and a raw `git status` is thousands of lines going into a field three
/// clients persist. So the obstacle is a stable kind, one sentence, and a capped list of the things
/// themselves — the sentence is what a person acknowledges, the list is what they act on.
struct UpdateObstacle: Codable, Sendable {
    var kind: String
    var summary: String
    var items: [String]
    /// How many more there are than the list carries.
    var more: Int

    static let itemLimit = 8

    init(kind: String, summary: String, items: [String] = []) {
        self.kind = kind
        self.summary = summary
        self.items = Array(items.prefix(Self.itemLimit))
        more = max(0, items.count - Self.itemLimit)
    }
}

/// What this machine does about updates when nobody is asking.
///
/// Off until somebody turns it on, and reported rather than assumed: a client draws its switch from
/// what the machine last answered, never from what that client last sent.
struct UpdateAutomation: Codable, Sendable {
    var enabled: Bool
    var lastTakenAt: Date?
    var lastTarget: String?
    var nextLookAt: Date?
    /// Why nothing is being taken right now, when something could otherwise have been.
    var holdingOff: String?
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
    /// What stands in the way, in a shape that can be listed rather than only read.
    var obstacle: UpdateObstacle?
    /// Whether anything a restart would destroy is happening right now.
    var busy: MachineQuiet?
    /// A build has landed and this process is waiting for the machine to go quiet before it takes
    /// it. The wait is a state, not a silence.
    var waitingSince: Date?
    /// Whether one press can put this process onto a build already sitting on disk. False without a
    /// supervisor: a bridge that exits with nothing to start it again is a bridge nobody can reach.
    var canRestart = false
    var automation: UpdateAutomation?
    /// Which Swift would do the building, named so a module-format failure is readable.
    var toolchain: String?
}

struct UpdateState: Codable, Sendable {
    var phase: String
    var startedAt: Date?
    var finishedAt: Date?
    /// The installer's own process, so a second one is refused on liveness rather than on a wall
    /// clock — a cold build on a small machine outlives any timeout worth setting.
    var pid: Int32?
}

/// What this machine has decided about updating itself, and what it has learned from trying.
///
/// Persisted beside the state file. The failure memory is the whole difference between an
/// unattended updater and a machine that rebuilds a commit that cannot build, at full load, on the
/// desk somebody is working at, forever.
struct UpdatePolicy: Codable, Sendable {
    var enabled = false
    var lastTakenAt: Date?
    var lastTarget: String?
    /// The commit that refused to land, and how many times it has been tried.
    var failedTarget: String?
    var failures = 0
    /// When the next unattended attempt is allowed. Cleared by a target that is not the failed one.
    var retryAfter: Date?

    static let firstBackoff: TimeInterval = 3600
    static let maximumBackoff: TimeInterval = 24 * 3600

    /// One spelling of a commit. `git rev-parse` answers forty characters and the status reports
    /// seven, and a memory keyed to one of those while every question arrives in the other is a
    /// memory that never recognises anything.
    static func key(_ commit: String) -> String { String(commit.prefix(7)) }

    mutating func noteFailure(target: String, now: Date = Date()) {
        let target = Self.key(target)
        failures = failedTarget == target ? failures + 1 : 1
        failedTarget = target
        let delay = min(
            Self.maximumBackoff, Self.firstBackoff * pow(2, Double(min(failures - 1, 8))))
        retryAfter = now.addingTimeInterval(delay)
    }

    mutating func noteSuccess(target: String?, now: Date = Date()) {
        lastTakenAt = now
        lastTarget = target.map(Self.key)
        failedTarget = nil
        failures = 0
        retryAfter = nil
    }

    /// Whether an unattended attempt at this commit is allowed yet. A commit that is not the one
    /// that failed is always allowed: the fix for a broken build is usually the next commit.
    func allows(target: String, now: Date = Date()) -> Bool {
        guard failedTarget == Self.key(target), let retryAfter else { return true }
        return now >= retryAfter
    }
}

/// The bridge updating itself: fetch, rebuild, restart.
///
/// A phone cannot ssh into the machine it is talking to, so a bridge that can only be updated from
/// a terminal is a bridge that never gets updated. The work runs in a detached process and reports
/// through a state file that survives the restart, so a client can follow a job whose server went
/// away mid-answer.
///
/// The restart is this process exiting, and that is the dangerous half: on Linux the supervisor
/// tears down the whole control group, so every `claude` the bridge started dies with it. A check
/// taken when the build *starts* says nothing about the machine minutes later when the build ends,
/// so the quiet test is a barrier at the exit rather than a gate at the door — and while it waits it
/// says so, because a restart that has not happened yet is a state and not a silence.
actor UpdateService {
    private let source: String?
    private let stateDirectory: URL
    private let stateURL: URL
    private let logURL: URL
    private let policyURL: URL
    private var policy: UpdatePolicy
    private var lastFetch: Date?
    private var cachedRemote: RemoteState?
    private var waitingSince: Date?
    private var barrier: Task<Void, Never>?
    private var ticker: Task<Void, Never>?

    /// What the machine is doing, asked of the parts that know. Absent until wired, which reads as
    /// not quiet — the safe answer for a question nobody can answer yet.
    private var quiet: (@Sendable () async -> MachineQuiet)?
    /// Everything that has to reach disk before this process ends. `exit(0)` runs no deferred work,
    /// and a restart taken right after a conversation is exactly when the store's debounce is armed.
    private var settle: (@Sendable () async -> Void)?

    private struct RemoteState {
        let commit: String
        let describe: String?
        let changes: [String]
        let behind: Int
        let ahead: Int
        let aheadSubjects: [String]
        let ref: String?
        let at: Date
        /// Why the refs these counts came from may be stale. The counts are still worth reporting —
        /// a machine that was three commits behind an hour ago still is — but a client told the
        /// check succeeded would print "up to date" off week-old refs, which is the one sentence
        /// this whole contract exists to prevent. Nothing unattended may act on them.
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
        policyURL = stateDirectory.appendingPathComponent("update.policy.json")
        try? FileManager.default.createDirectory(
            at: stateDirectory, withIntermediateDirectories: true)
        policy =
            (try? Data(contentsOf: policyURL)).flatMap {
                try? JSONCoding.decoder.decode(UpdatePolicy.self, from: $0)
            } ?? UpdatePolicy()
    }

    /// Wires the two things this actor cannot know about itself: whether the machine is busy, and
    /// what has to be written before it may stop.
    func attach(
        quiet: @escaping @Sendable () async -> MachineQuiet,
        settle: @escaping @Sendable () async -> Void
    ) {
        self.quiet = quiet
        self.settle = settle
    }

    /// The whole answer, with the machine's own account of its update policy written last — what
    /// it is holding off for is decided by the same facts that decide whether it could act, so it
    /// cannot be composed before those are known.
    func status(refreshing: Bool = true) async -> UpdateStatus {
        var status = await read(refreshing: refreshing)
        status.automation = automation(
            manager: status.manager, blocked: status.canUpdate ? nil : status.reason,
            owed: status.restartRequired && !status.canRestart)
        return status
    }

    private func read(refreshing: Bool) async -> UpdateStatus {
        let state = readState()
        let phase = settled(state)
        let checkout = BridgeVersion.describe(source: source)
        let manager = Self.serviceManager()
        let busy = await quiet?() ?? .unknown
        let owed = restartRequired(source: source)
        var status = UpdateStatus(
            version: checkout,
            running: BridgeVersion.running?.version,
            restartRequired: owed,
            builtAt: BridgeVersion.running?.builtAt,
            remote: RemoteCheck(checked: false, ok: false),
            commit: BridgeVersion.commit(source: source),
            manager: manager,
            source: source,
            phase: phase,
            startedAt: state?.startedAt,
            finishedAt: state?.finishedAt,
            log: phase == "idle" ? nil : logTail(),
            busy: busy,
            waitingSince: waitingSince,
            canRestart: owed && manager != "manual")
        guard let source else {
            status.reason =
                "This bridge was not installed from a git checkout, so it cannot update itself."
            status.obstacle = UpdateObstacle(
                kind: "noCheckout", summary: "There is no checkout on that machine to update from.")
            status.remote = RemoteCheck(
                checked: false, ok: false,
                error: "There is no checkout here to compare against the project.")
            return status
        }
        guard Shell.which("git") != nil else {
            status.reason = "git is needed to update, and it is not on this machine's PATH."
            status.obstacle = UpdateObstacle(
                kind: "noGit", summary: "git is not on that machine's PATH.")
            status.remote = RemoteCheck(
                checked: false, ok: false, error: "git is not on this machine's PATH.")
            return status
        }
        // Whether this machine can rebuild and whether it can find out that it is behind are two
        // separate facts, and answering the second with the first is how a machine twenty commits
        // out of date went missing from the surface entirely.
        if let toolchain = BridgeToolchain.resolve() {
            status.toolchain = BridgeToolchain.describe(toolchain)
            if let obstacle = dirt(source) {
                status.reason = obstacle.summary
                status.obstacle = obstacle
            } else {
                status.canUpdate = true
                if manager == "manual" {
                    status.reason =
                        "No service supervises this bridge, so it will rebuild but you will have "
                        + "to start it again yourself."
                }
            }
        } else {
            status.reason =
                "A Swift toolchain is needed to rebuild, and none was found on that machine."
            status.obstacle = UpdateObstacle(
                kind: "noToolchain",
                summary: "No Swift toolchain on that machine, so nothing there can rebuild.",
                items: BridgeToolchain.candidates)
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
            let summary =
                "That checkout has \(remote.ahead) commits of its own, so it cannot be "
                + "fast-forwarded onto the project."
            status.reason = summary
            status.obstacle = UpdateObstacle(
                kind: "ahead", summary: summary, items: remote.aheadSubjects)
        }
        return status
    }

    /// What the machine will do about updates on its own, and what it has learned from trying.
    private func automation(manager: String, blocked: String?, owed: Bool) -> UpdateAutomation {
        UpdateAutomation(
            enabled: policy.enabled, lastTakenAt: policy.lastTakenAt,
            lastTarget: policy.lastTarget,
            nextLookAt: policy.enabled ? Date().addingTimeInterval(Self.lookEvery) : nil,
            holdingOff: policy.enabled
                ? holdingOff(manager: manager, blocked: blocked, owed: owed) : nil)
    }

    /// The one sentence an unattended machine owes: not that it is idle, but what it is waiting for.
    ///
    /// Every reason a client would be wrong to stop asking a person belongs here, because the
    /// absence of this sentence is exactly what tells the surface nobody has to act.
    private func holdingOff(manager: String, blocked: String?, owed: Bool) -> String? {
        if manager == "manual" {
            return "Nothing supervises this bridge, so it will not replace itself unattended."
        }
        if owed {
            return "A build is waiting on that machine and nothing there would start it again."
        }
        if let blocked { return blocked }
        guard let failed = policy.failedTarget, let retry = policy.retryAfter, retry > Date() else {
            return nil
        }
        return
            "Held off after \(policy.failures) failed attempts at \(failed). A newer commit, or an "
            + "update taken by hand, clears it."
    }

    /// Whether an update is in flight, decided on the installer being alive rather than on a clock.
    ///
    /// The wall clock was the only guard, and a cold `swift build -c release` on a small machine —
    /// or a laptop that sleeps mid-build — outlives any timeout worth setting. A second installer in
    /// the same checkout is two `git merge`s and two builds against one `.build`, which ends as a
    /// truncated binary the supervisor restarts into.
    /// A pid is only evidence while the job it belongs to is one an installer could still be doing.
    /// Terminal phases clear it outright, and the phase is checked as well as the liveness, because
    /// a number the operating system handed to somebody else months later would otherwise refuse
    /// every future update on this machine, silently and forever.
    private func installerAlive() -> Bool {
        guard let state = readState(), Self.installing.contains(state.phase),
            let pid = state.pid, pid > 0
        else { return false }
        return kill(pid, 0) == 0
    }

    private static let installing: Set<String> = ["running", "building"]

    /// The phase to show. A job whose installer is gone is not running, whatever the file says.
    private func settled(_ state: UpdateState?) -> String {
        guard let state else { return "idle" }
        let unfinished = ["running", "building", "restarting", "waiting"].contains(state.phase)
        guard unfinished else { return terminal(state) }
        if state.phase == "waiting" { return waitingSince == nil ? "failed" : "waiting" }
        // A build that got as far as writing `restarting` succeeded; only the loading of it is
        // owed, and `restartRequired` is what reports that. Left alone it would be an installation
        // that never finishes, which is the one thing no state here may become.
        if state.phase == "restarting" { return aged(state) ? "succeeded" : state.phase }
        if installerAlive() { return state.phase }
        // The window between accepting the job and the script stamping its own pid: nothing here is
        // dead, it simply has not started saying so yet.
        guard state.pid != nil || aged(state, over: 120) else { return state.phase }
        return "failed"
    }

    /// Long enough that no build, however cold, is still honestly in it.
    private func aged(_ state: UpdateState, over: TimeInterval = 6 * 3600) -> Bool {
        guard let started = state.startedAt else { return true }
        return Date().timeIntervalSince(started) > over
    }

    /// A failure older than the binary answering the request is not news about that binary.
    ///
    /// Recovering by hand — re-running the installer, fixing a toolchain, freeing a disk — leaves
    /// the old `failed` behind, and a phase read straight off disk would keep a machine that is
    /// genuinely current wearing a corpse from three weeks ago, forever, because nothing but another
    /// in-app update ever clears it.
    private func terminal(_ state: UpdateState) -> String {
        guard state.phase == "failed", let built = BridgeVersion.running?.builtAt,
            let finished = state.finishedAt, finished < built
        else { return state.phase }
        return "idle"
    }

    /// Starts an update unless one is already running, and answers with the status a client should
    /// show while it waits.
    func start() async -> (accepted: Bool, status: UpdateStatus) {
        var current = await status(refreshing: false)
        guard current.canUpdate else { return (false, current) }
        guard !installerAlive(), current.phase != "restarting", current.phase != "waiting" else {
            return (false, current)
        }
        guard let source, let script = stagedScript(source: source) else {
            current.reason = "install.sh is missing from the checkout, so there is nothing to run."
            return (false, current)
        }
        try? Data().write(to: logURL, options: .atomic)
        write(UpdateState(phase: "running", startedAt: Date(), finishedAt: nil, pid: nil))
        detach(script: script, source: source)
        watch()
        lastFetch = nil
        return (true, await status(refreshing: false))
    }

    /// Puts this process onto a build that is already on disk, without rebuilding anything.
    ///
    /// A machine that built and never restarted used to be a dead end wearing the words "restart the
    /// bridge there" — a terminal instruction for the one thing the bridge can do to itself. It
    /// refuses without a supervisor, because a bridge that exits with nothing to start it again is a
    /// machine no phone can reach.
    func restart() async -> (accepted: Bool, status: UpdateStatus) {
        var current = await status(refreshing: false)
        guard Self.serviceManager() != "manual" else {
            current.reason =
                "Nothing supervises this bridge, so it would not come back. Start it on that "
                + "machine instead."
            return (false, current)
        }
        guard current.restartRequired || current.phase == "restarting" else {
            current.reason = "This bridge is already running the build in its checkout."
            return (false, current)
        }
        guard barrier == nil else { return (true, current) }
        beginRestart()
        return (true, await status(refreshing: false))
    }

    /// Turns unattended updating on or off. It is the machine's setting rather than a device's, so
    /// two clients can never disagree about it and a phone nobody opens again does not stop it.
    /// The answer consults the project like any other check. A client renders the whole row from
    /// what comes back, so answering without it would turn a machine that was up to date into one
    /// that "cannot say" the instant somebody touched the switch — a verdict change with nothing
    /// behind it but the asking.
    func setAutomation(enabled: Bool) async -> UpdateStatus {
        policy.enabled = enabled
        writePolicy()
        return await status(refreshing: true)
    }

    /// Hands the work to a process that keeps running after this one answers, and stops caring
    /// about it: the script builds, and the restart is this process's own job — see ``watch()``.
    private func detach(script: String, source: String) {
        var environment = [
            "BRIDGE_SRC": source,
            "BRIDGE_STATE_DIR": stateDirectory.path,
        ]
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        // The toolchain the status promised, so the build cannot fail on a PATH the client never saw.
        if let toolchain = BridgeToolchain.resolve() { environment["BRIDGE_SWIFT"] = toolchain }
        Shell.spawn("/bin/bash", [script, "--update", "--managed"], environment: environment)
    }

    /// Reconciles a process that just started with the update that may have been running when it
    /// did: a phase of `restarting` means this process *is* that restart, and a build still in
    /// flight has to be watched again, because the binary it produces still needs loading.
    func resume() {
        guard let state = readState() else { return }
        switch state.phase {
        case "restarting", "waiting":
            policy.noteSuccess(target: BridgeVersion.running?.commit)
            writePolicy()
            write(
                UpdateState(
                    phase: "succeeded", startedAt: state.startedAt, finishedAt: Date(), pid: nil))
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
    ///
    /// The poll is bounded by the installer's life rather than by a count of iterations: a build
    /// that outlived a twenty-minute cap used to land on disk with nothing left watching for it,
    /// and the machine then stopped taking updates forever while reporting a failure that never
    /// happened.
    private func watch() {
        Task { [weak self] in
            guard let self else { return }
            while true {
                try? await Task.sleep(for: .seconds(2))
                let phase = await self.phaseOnDisk()
                if phase == "restarting" {
                    await self.beginRestart()
                    return
                }
                if phase == "failed" {
                    await self.noteFailedAttempt()
                    return
                }
                if phase == "succeeded" || phase == nil { return }
                if await self.installerAlive() == false {
                    // A dead installer that got as far as writing the build is a restart owed, not a
                    // failure: the binary is on disk and only the loading of it is missing.
                    if await self.restartOwed() {
                        await self.beginRestart()
                    } else {
                        await self.markFailed()
                    }
                    return
                }
            }
        }
    }

    private func phaseOnDisk() -> String? { readState()?.phase }

    private func restartOwed() -> Bool { restartRequired(source: source) }

    private func markFailed() {
        write(
            UpdateState(
                phase: "failed", startedAt: readState()?.startedAt, finishedAt: Date(), pid: nil))
        noteFailedAttempt()
    }

    /// A failure is recorded against a name the next attempt will ask about. The two ends read the
    /// commit from different places — one abbreviates, one does not — and a backoff keyed to a
    /// string nothing ever matches is a backoff that never holds anything off.
    private func noteFailedAttempt() {
        let target = cachedRemote?.commit ?? remoteHead(source ?? "") ?? "unknown"
        policy.noteFailure(target: UpdatePolicy.key(target))
        writePolicy()
    }

    /// The restart, held behind the one question that matters: is anything running that this would
    /// destroy. The wait is reported rather than silent, and it is abandoned rather than held
    /// forever — a machine that never goes quiet keeps its build on disk and its offer to load it.
    private func beginRestart() {
        guard barrier == nil else { return }
        guard Self.serviceManager() != "manual" else {
            // Nothing here would start the bridge again, so the job is over with the build on disk:
            // `restartRequired` is what says the loading is still owed. Leaving the phase at
            // `restarting` would wear an installation that never ends and refuse every future
            // press, on the one kind of machine nobody can reach to clear it.
            write(
                UpdateState(
                    phase: "succeeded", startedAt: readState()?.startedAt, finishedAt: Date(),
                    pid: nil))
            return
        }
        waitingSince = Date()
        write(
            UpdateState(
                phase: "waiting", startedAt: readState()?.startedAt, finishedAt: nil, pid: nil))
        barrier = Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(Self.quietDeadline)
            while Date() < deadline {
                if await self.machineIsQuiet() {
                    await self.finishAndExit()
                    return
                }
                try? await Task.sleep(for: .seconds(5))
            }
            await self.abandonRestart()
        }
    }

    /// Asked twice, a second apart. The gap between deciding to stop and stopping is the whole
    /// window in which a turn can start, and asking once leaves it as wide as the code between.
    private func machineIsQuiet() async -> Bool {
        guard let quiet else { return false }
        guard await quiet().quiet else { return false }
        try? await Task.sleep(for: .seconds(1))
        return await quiet().quiet
    }

    private func abandonRestart() {
        barrier = nil
        waitingSince = nil
        write(
            UpdateState(
                phase: "succeeded", startedAt: readState()?.startedAt, finishedAt: Date(), pid: nil))
    }

    private func finishAndExit() async {
        write(
            UpdateState(
                phase: "restarting", startedAt: readState()?.startedAt, finishedAt: Date(),
                pid: nil))
        policy.noteSuccess(target: BridgeVersion.commit(source: source))
        writePolicy()
        await settle?()
        try? await Task.sleep(for: .milliseconds(300))
        exit(0)
    }

    /// The machine looking for its own updates, on its own, and taking them when it can finish the
    /// job. Every gate here is a refusal to act on something a person would want to be asked about:
    /// counts read off refs a failed fetch left behind, a commit that has already refused to build,
    /// an installer still running, and a machine with nothing to bring it back.
    func startAutomation() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            while !Task.isCancelled {
                await self?.considerUpdating()
                try? await Task.sleep(for: .seconds(Self.lookEvery))
            }
        }
    }

    private func considerUpdating() async {
        guard policy.enabled, Self.serviceManager() != "manual", !installerAlive(),
            barrier == nil
        else { return }
        let current = await status(refreshing: true)
        // A build this machine already made and never loaded is the job it is furthest through, and
        // the checkout is level with the project by then — so the offer that would have driven this
        // is gone and only the loading is left. Missing it means running the old binary until
        // somebody opens the app, which is the thing automation exists to stop needing.
        if current.restartRequired, current.canRestart {
            beginRestart()
            return
        }
        guard current.canUpdate, current.updateAvailable, current.remote?.ok == true,
            let target = current.latestCommit, policy.allows(target: target)
        else { return }
        _ = await start()
    }

    /// The script is copied out of the checkout before it runs: bash reads a script as it executes,
    /// and the update rewrites that file underneath it.
    ///
    /// The project's own copy wins over the local one wherever the fetch reached it. An installer
    /// bug can only be fixed by the installer that replaces it, and the machines carrying a broken
    /// one are exactly the machines nobody opens a terminal on. The staging directory is this user's
    /// alone: a fixed path in a shared `/tmp` is a script somebody else can write between the copy
    /// and the run, and an unattended loop turns that window from "when somebody presses" into
    /// "every half hour, forever".
    private func stagedScript(source: String) -> String? {
        let directory = stateDirectory.appendingPathComponent("staging")
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let staged = directory.appendingPathComponent("install.sh").path
        if let head = remoteHead(source) {
            let script = Shell.run("git", ["show", "\(head):install.sh"], cwd: source)
            if script.contains("#!"), write(script, to: staged) { return staged }
        }
        let local = "\(source)/install.sh"
        guard let script = try? String(contentsOfFile: local, encoding: .utf8),
            write(script, to: staged)
        else { return nil }
        return staged
    }

    private func write(_ script: String, to path: String) -> Bool {
        guard (try? script.write(toFile: path, atomically: true, encoding: .utf8)) != nil else {
            return false
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return true
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
        let mine =
            ahead > 0
            ? Shell.run(
                "git", ["log", "--pretty=format:%s", "-20", "\(head)..HEAD"], cwd: source
            ).split(separator: "\n").map(String.init) : []
        let describe = Shell.run("git", ["describe", "--tags", "--always", head], cwd: source)
            .trimmedOrNil()
        let state = RemoteState(
            commit: String(head.prefix(7)), describe: describe, changes: changes, behind: behind,
            ahead: ahead, aheadSubjects: mine, ref: upstream, at: Date(),
            fetchFailed: lastRemoteError)
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
        guard !source.isEmpty else { return nil }
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

    /// What the checkout is carrying that a fast-forward would have to survive, named rather than
    /// merely counted: "it has uncommitted changes" is not something anybody can act on.
    private func dirt(_ source: String) -> UpdateObstacle? {
        let porcelain = Shell.run("git", ["status", "--porcelain"], cwd: source)
            .split(separator: "\n").map(String.init)
        guard !porcelain.isEmpty else { return nil }
        let untracked = porcelain.filter { $0.hasPrefix("??") }
        let changed = porcelain.filter { !$0.hasPrefix("??") }
        let summary =
            changed.isEmpty
            ? "The checkout at \(source) has \(untracked.count) untracked files, and the installer "
                + "refuses to build a tree it did not expect."
            : "The checkout at \(source) has \(changed.count) uncommitted changes"
                + (untracked.isEmpty ? "." : " and \(untracked.count) untracked files.")
        return UpdateObstacle(
            kind: "dirty", summary: summary,
            items: (changed + untracked).map { String($0.dropFirst(3)) })
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
        guard let source, dirt(source) == nil else { return false }
        guard let built = BridgeVersion.running?.commit, !built.isEmpty,
            let head = BridgeVersion.commit(source: source)
        else { return false }
        return !built.hasPrefix(head) && !head.hasPrefix(built)
    }

    private func readState() -> UpdateState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONCoding.decoder.decode(UpdateState.self, from: data)
    }

    /// The installer writes its own pid over this the moment it starts, so a phase written from
    /// here carries the one already on disk rather than erasing the liveness fact — but only while
    /// the phase is one an installer could still be inside. A pid outliving its job is a number the
    /// operating system will hand to somebody else.
    private func write(_ state: UpdateState) {
        var state = state
        if state.pid == nil, Self.installing.contains(state.phase) {
            state.pid = readState()?.pid
        }
        guard let data = try? JSONCoding.encoder.encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    private func writePolicy() {
        guard let data = try? JSONCoding.encoder.encode(policy) else { return }
        try? data.write(to: policyURL, options: .atomic)
    }

    /// A tail, not a transcript: a Swift build prints thousands of lines of warnings, and this
    /// rides in every poll a client makes while the update runs.
    private func logTail(lines: Int = 12, characters: Int = 2000) -> String? {
        guard let contents = try? String(contentsOf: logURL, encoding: .utf8) else { return nil }
        let tail = contents.split(separator: "\n").suffix(lines).joined(separator: "\n")
        return String(tail.suffix(characters)).trimmedOrNil()
    }

    /// How often an unattended machine looks, and how long a restart may wait for the machine to go
    /// quiet before it gives the build back to the person.
    private static let lookEvery: TimeInterval = 30 * 60
    private static let quietDeadline: TimeInterval = 12 * 3600

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
