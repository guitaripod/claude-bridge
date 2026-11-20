import Foundation

#if canImport(Glibc)
    import Glibc
#endif

/// What a command left behind: how it ended, what it said, and how long it took.
struct CommandResult: Sendable {
    var exitCode: Int32
    var output: String
    var seconds: Double
    var timedOut: Bool
    var launched: Bool
}

/// Runs a command to its end, with stdout and stderr in one stream and a deadline after which the
/// command and everything it started are stopped. The stream goes to a file rather than a pipe,
/// so a background process the command left behind holding its output cannot keep the run from
/// ever ending.
enum CommandRunner {
    /// The person's login shell, so a guard finds the tools their terminal finds.
    static var loginShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/sh"
    }

    static func shell(_ command: String, directory: String?, timeout: TimeInterval) async -> CommandResult {
        await run(loginShell, ["-lc", command], directory: directory, timeout: timeout)
    }

    static func run(
        _ executable: String, _ arguments: [String], directory: String?, timeout: TimeInterval,
        environment: [String: String] = [:]
    ) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: runBlocking(
                        executable, arguments, directory: directory, timeout: timeout, environment: environment))
            }
        }
    }

    /// Spawns the command in a process group of its own, with stdin from `/dev/null`, stdout and
    /// stderr into one file and no other descriptor of the bridge's, and waits on the command
    /// itself. Foundation's `Process` learns of an exit through a descriptor a grandchild inherits
    /// on Linux, so a command that left something running in the background was never seen to end;
    /// a group lets the deadline stop everything the command started, and whatever it left behind
    /// is stopped once it ends, so a guard never leaves processes on the machine.
    private static func runBlocking(
        _ executable: String, _ arguments: [String], directory: String?, timeout: TimeInterval,
        environment: [String: String]
    ) -> CommandResult {
        if let directory, !FileManager.default.fileExists(atPath: directory) {
            return CommandResult(
                exitCode: -1, output: "The folder \(directory) is not on this machine.", seconds: 0, timedOut: false,
                launched: false)
        }
        let capture = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-run-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: capture) }
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in environment { merged[key] = value }
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = merged.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        #if os(macOS)
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
        #else
            var actions = posix_spawn_file_actions_t()
            var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, capture.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        if let directory { posix_spawn_file_actions_addchdir_np(&actions, directory) }
        #if os(macOS)
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        #else
            posix_spawn_file_actions_addclosefrom_np(&actions, 3)
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        #endif
        posix_spawnattr_setpgroup(&attributes, 0)
        var pid: pid_t = 0
        let started = Date()
        let spawned = Spawning.serialized { posix_spawn(&pid, executable, &actions, &attributes, argv, envp) }
        guard spawned == 0 else {
            return CommandResult(
                exitCode: -1, output: String(cString: strerror(spawned)), seconds: 0, timedOut: false, launched: false)
        }
        let timedOut = TimeoutFlag()
        let group = pid
        let killer = DispatchWorkItem {
            timedOut.set()
            stopGroup(group)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        var status: Int32 = 0
        var reaped = waitpid(pid, &status, 0)
        while reaped == -1, errno == EINTR { reaped = waitpid(pid, &status, 0) }
        killer.cancel()
        stopGroup(group)
        let data = (try? Data(contentsOf: capture)) ?? Data()
        return CommandResult(
            exitCode: reaped == pid ? exitCode(status) : -1, output: String(decoding: data, as: UTF8.self),
            seconds: Date().timeIntervalSince(started), timedOut: timedOut.value, launched: true)
    }

    /// The exit status `waitpid` reports, as a shell would: the code a command exited with, or 128
    /// plus the signal that ended it.
    static func exitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    /// SIGTERM to every process in the group, SIGKILL five seconds later for any still there.
    private static func stopGroup(_ group: pid_t) {
        guard kill(-group, 0) == 0 else { return }
        kill(-group, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if kill(-group, 0) == 0 { kill(-group, SIGKILL) }
        }
    }

    /// The last `lines` lines of `text`, for a failure worth reading without its whole log.
    static func tail(_ text: String, lines: Int = 30, bytes: Int = 4_000) -> String {
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
        guard kept.utf8.count > bytes else { return kept.trimmingCharacters(in: .whitespacesAndNewlines) }
        return String(decoding: kept.utf8.suffix(bytes), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }
    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}

/// The machine's process table, read with `ps`: who started whom, so a lock is traced back to the
/// conversation whose process tree holds it.
enum ProcessTree {
    static func parents() -> [Int32: Int32] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-A", "-o", "pid=,ppid="]
        ps.standardError = FileHandle.nullDevice
        let pipe: Pipe
        do {
            pipe = try Spawning.serialized {
                let pipe = Pipe()
                ps.standardOutput = pipe
                try ps.runAllowingBusyExecutable()
                return pipe
            }
        } catch {
            return [:]
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        var table: [Int32: Int32] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]), let parent = Int32(parts[1]) else { continue }
            table[pid] = parent
        }
        return table
    }

    /// `pid` and every process above it, nearest first.
    static func ancestors(of pid: Int32, in table: [Int32: Int32]) -> [Int32] {
        var chain: [Int32] = [pid]
        var cursor = pid
        while let parent = table[cursor], parent > 1, chain.count < 64, !chain.contains(parent) {
            chain.append(parent)
            cursor = parent
        }
        return chain
    }

    /// The processes that have `path` open — on macOS through `lsof`, on Linux by reading every
    /// process's descriptors.
    static func holders(of path: String) -> [Int32] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        #if os(macOS)
            let lsof = Process()
            lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            lsof.arguments = ["-t", "--", path]
            lsof.standardError = FileHandle.nullDevice
            guard
                let pipe = try? Spawning.serialized({ () throws -> Pipe in
                    let pipe = Pipe()
                    lsof.standardOutput = pipe
                    try lsof.runAllowingBusyExecutable()
                    return pipe
                })
            else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            lsof.waitUntilExit()
            return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { Int32($0) }
        #else
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            var found: [Int32] = []
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? [] {
                guard let pid = Int32(entry) else { continue }
                let fds = "/proc/\(entry)/fd"
                for fd in (try? FileManager.default.contentsOfDirectory(atPath: fds)) ?? [] {
                    if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "\(fds)/\(fd)"),
                        target == resolved
                    {
                        found.append(pid)
                        break
                    }
                }
            }
            return found
        #endif
    }
}

/// Proves an expert's bench: asks the machine about each device, probe and port, and who holds
/// each lock. A proof says what it found as keys and values; the words are the client's.
enum BenchProver {
    struct AppleDevice: Sendable {
        var identifiers: Set<String>
        var name: String
        var model: String?
        var platform: String?
        var osVersion: String?
        var state: String
        var transport: String?
        var coreDeviceID: String?
        var udid: String? = nil
    }

    static func prove(
        _ items: [BenchItem], now: Date = Date(),
        holder: @escaping @Sendable ([Int32]) async -> BenchHolder?
    ) async -> [BenchItem] {
        let devices = items.contains { $0.kind == "appleDevice" } ? await appleDevices() : nil
        var proven: [BenchItem] = []
        for item in items {
            var result = item.described
            result.checkedAt = now
            switch item.kind {
            case "appleDevice":
                await proveDevice(&result, devices: devices)
            case "command":
                await proveCommand(&result)
            case "port":
                proveP(&result)
            default:
                result.state = "unknown"
            }
            if let lock = item.lock?.trimmingCharacters(in: .whitespaces), !lock.isEmpty,
                result.state == "ready" || result.state == "unknown"
            {
                let pids = ProcessTree.holders(of: (lock as NSString).expandingTildeInPath)
                if !pids.isEmpty {
                    result.state = "held"
                    result.holder = await holder(pids) ?? BenchHolder(pid: pids.first)
                }
            }
            proven.append(result)
        }
        return proven
    }

    private static func proveDevice(_ item: inout BenchItem, devices: [AppleDevice]?) async {
        guard let devices else {
            item.state = "unknown"
            return
        }
        let wanted = (item.identifier ?? item.name).lowercased()
        guard let device = devices.first(where: { $0.identifiers.contains(wanted) }) else {
            item.state = "absent"
            return
        }
        var facts: [String: String] = [:]
        facts["name"] = device.name
        if let model = device.model { facts["model"] = model }
        if let platform = device.platform { facts["os"] = platform }
        if let version = device.osVersion { facts["osVersion"] = version }
        if let transport = device.transport { facts["transport"] = transport }
        item.facts = facts
        item.state = device.state
        #if os(macOS)
            if device.state == "ready", let id = device.coreDeviceID, await isLocked(id) == true {
                item.state = "locked"
            }
        #else
            if device.state == "ready", let udid = device.udid, let locked = await isLocked(udid: udid) {
                if locked { item.state = "locked" }
            } else if device.state == "ready" {
                item.state = "unknown"
            }
        #endif
    }

    private static func proveCommand(_ item: inout BenchItem) async {
        guard let command = item.command, !command.isEmpty else {
            item.state = "unknown"
            return
        }
        let result = await CommandRunner.shell(command, directory: nil, timeout: 20)
        let first = result.output.split(separator: "\n").first.map { String($0.prefix(200)) }
        item.state = result.exitCode == 0 && !result.timedOut ? "ready" : "absent"
        if let first { item.facts = ["output": first] }
    }

    private static func proveP(_ item: inout BenchItem) {
        guard let port = item.port else {
            item.state = "unknown"
            return
        }
        switch PortProbe.open(host: item.host ?? "127.0.0.1", port: port, timeout: 2) {
        case true?: item.state = "ready"
        case false?: item.state = "absent"
        case nil: item.state = "unknown"
        }
    }

    /// The Apple devices this machine can reach: devicectl on a Mac, pymobiledevice3 elsewhere.
    static func appleDevices() async -> [AppleDevice]? {
        #if os(macOS)
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("bridge-devices-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: file) }
            let result = await CommandRunner.run(
                "/usr/bin/xcrun", ["devicectl", "list", "devices", "--quiet", "--json-output", file.path],
                directory: nil, timeout: 30)
            guard result.launched, let data = try? Data(contentsOf: file) else { return nil }
            return parseDevicectl(data)
        #else
            guard let tool = pymobiledevice3() else { return nil }
            let result = await CommandRunner.run(tool, ["usbmux", "list"], directory: nil, timeout: 20)
            guard result.exitCode == 0 else { return nil }
            return parseUsbmux(Data(result.output.utf8))
        #endif
    }

    static func parseDevicectl(_ data: Data) -> [AppleDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = root["result"] as? [String: Any],
            let devices = result["devices"] as? [[String: Any]]
        else { return [] }
        return devices.compactMap { device in
            let hardware = device["hardwareProperties"] as? [String: Any] ?? [:]
            guard hardware["reality"] as? String != "virtual" else { return nil }
            let connection = device["connectionProperties"] as? [String: Any] ?? [:]
            let properties = device["deviceProperties"] as? [String: Any] ?? [:]
            let id = device["identifier"] as? String
            let udid = hardware["udid"] as? String
            let name = properties["name"] as? String ?? hardware["marketingName"] as? String ?? "Device"
            let tunnel = connection["tunnelState"] as? String
            let paired = connection["pairingState"] as? String == "paired"
            let state: String
            switch tunnel {
            case "connected": state = "ready"
            case "disconnected" where paired: state = "ready"
            default: state = "absent"
            }
            let transport: String?
            switch connection["transportType"] as? String {
            case "wired": transport = "wired"
            case "localNetwork": transport = "network"
            default: transport = nil
            }
            let identifiers = Set([id, udid, name].compactMap { $0?.lowercased() })
            return AppleDevice(
                identifiers: identifiers, name: name, model: hardware["marketingName"] as? String,
                platform: hardware["platform"] as? String, osVersion: properties["osVersionNumber"] as? String,
                state: state, transport: transport, coreDeviceID: id)
        }
    }

    static func parseUsbmux(_ data: Data) -> [AppleDevice] {
        guard let devices = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return devices.map { device in
            let udid = device["UniqueDeviceID"] as? String ?? device["Identifier"] as? String
            let name = device["DeviceName"] as? String ?? "Device"
            let connection = device["ConnectionType"] as? String
            return AppleDevice(
                identifiers: Set([udid, name].compactMap { $0?.lowercased() }), name: name,
                model: device["ProductType"] as? String, platform: nil,
                osVersion: device["ProductVersion"] as? String, state: "ready",
                transport: connection == "USB" ? "usb" : connection == "Network" ? "network" : nil,
                coreDeviceID: nil, udid: udid)
        }
    }

    #if os(macOS)
        private static func isLocked(_ coreDeviceID: String) async -> Bool? {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("bridge-lock-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: file) }
            _ = await CommandRunner.run(
                "/usr/bin/xcrun",
                ["devicectl", "device", "info", "lockState", "--device", coreDeviceID, "--quiet", "--json-output", file.path],
                directory: nil, timeout: 12)
            guard let data = try? Data(contentsOf: file),
                let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let result = root["result"] as? [String: Any]
            else { return nil }
            return result["passcodeRequired"] as? Bool
        }
    #endif

    #if !os(macOS)
        /// Whether a device on USB is locked right now, from its lockdown record; nil when it did
        /// not answer, so an unproven lock is never read as unlocked.
        private static func isLocked(udid: String) async -> Bool? {
            guard let tool = pymobiledevice3() else { return nil }
            let result = await CommandRunner.run(tool, ["lockdown", "info", "--udid", udid], directory: nil, timeout: 12)
            guard result.exitCode == 0,
                let start = result.output.firstIndex(of: "{"),
                let object = try? JSONSerialization.jsonObject(with: Data(result.output[start...].utf8)) as? [String: Any]
            else { return nil }
            return object["PasswordProtected"] as? Bool
        }
    #endif

    static func pymobiledevice3() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates =
            (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/pymobiledevice3" }
            + ["\(home)/.local/share/pmd-venv/bin/pymobiledevice3", "\(home)/.local/bin/pymobiledevice3"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Whether something is listening on a TCP port, asked with a plain connect, the name resolved
/// and every address tried inside one deadline. Nil when the name could not be resolved in time,
/// which is not knowing rather than nothing listening.
enum PortProbe {
    static func open(host: String, port: Int, timeout: TimeInterval) -> Bool? {
        let deadline = Date().addingTimeInterval(timeout)
        guard let addresses = resolve(host: host, port: port, timeout: timeout) else { return nil }
        for address in addresses {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return false }
            if connects(address, timeout: left) { return true }
        }
        return false
    }

    private struct Address {
        var family: Int32
        var type: Int32
        var proto: Int32
        var bytes: [UInt8]
    }

    private final class Resolution: @unchecked Sendable {
        let lock = NSLock()
        var addresses: [Address]?
    }

    private static func resolve(host: String, port: Int, timeout: TimeInterval) -> [Address]? {
        if let literal = lookup(host: host, port: port, numericOnly: true), !literal.isEmpty { return literal }
        let box = Resolution()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let found = lookup(host: host, port: port, numericOnly: false) ?? []
            box.lock.lock()
            box.addresses = found
            box.lock.unlock()
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        box.lock.lock()
        defer { box.lock.unlock() }
        return box.addresses
    }

    /// The addresses `host` names. With `numericOnly` only an address written out answers, at once
    /// and without asking a resolver.
    private static func lookup(host: String, port: Int, numericOnly: Bool) -> [Address]? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_flags = numericOnly ? AI_NUMERICHOST : 0
        #if os(macOS)
            hints.ai_socktype = SOCK_STREAM
        #else
            hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0 else { return nil }
        defer { freeaddrinfo(info) }
        var found: [Address] = []
        var cursor = info
        while let entry = cursor {
            if let raw = entry.pointee.ai_addr {
                let bytes = Array(UnsafeRawBufferPointer(start: raw, count: Int(entry.pointee.ai_addrlen)))
                found.append(
                    Address(
                        family: entry.pointee.ai_family, type: entry.pointee.ai_socktype,
                        proto: entry.pointee.ai_protocol, bytes: bytes))
            }
            cursor = entry.pointee.ai_next
        }
        return found
    }

    private static func connects(_ address: Address, timeout: TimeInterval) -> Bool {
        let fd = socket(address.family, address.type, address.proto)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let result = address.bytes.withUnsafeBytes { raw in
            connect(fd, raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(address.bytes.count))
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&poller, 1, Int32(max(1, timeout * 1000))) == 1 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
        return error == 0
    }
}

/// Runs one guard and reads its verdict: the command's exit, then the number it printed against
/// its line when the guard measures one.
enum GuardRunner {
    static let defaultTimeout = 30 * 60

    static func run(_ item: GuardItem, fallbackDirectory: String?) async -> GuardRun {
        let started = Date()
        let result = await CommandRunner.shell(
            item.command, directory: (item.directory ?? fallbackDirectory).map { ($0 as NSString).expandingTildeInPath },
            timeout: TimeInterval(item.timeout ?? defaultTimeout))
        return verdict(item, result, at: started)
    }

    static func verdict(_ item: GuardItem, _ result: CommandResult, at: Date) -> GuardRun {
        var run = GuardRun(
            at: at, passed: false, seconds: (result.seconds * 10).rounded() / 10, exitCode: result.exitCode,
            value: nil, output: nil, failure: nil)
        if result.timedOut {
            run.failure = "timeout"
        } else if !result.launched || result.exitCode != 0 {
            run.failure = "exit"
        } else if let metric = item.metric {
            guard let value = value(of: metric, in: result.output) else {
                run.failure = "missing"
                run.output = CommandRunner.tail(result.output)
                return run
            }
            run.value = value
            let under = metric.atMost.map { value <= $0 } ?? true
            let over = metric.atLeast.map { value >= $0 } ?? true
            run.passed = under && over
            if !run.passed { run.failure = "metric" }
        } else {
            run.passed = true
        }
        if !run.passed, run.output == nil { run.output = CommandRunner.tail(result.output) }
        return run
    }

    /// The last match of the metric's pattern, its first group read as a number.
    static func value(of metric: GuardMetric, in output: String) -> Double? {
        guard let expression = try? NSRegularExpression(pattern: metric.pattern) else { return nil }
        let range = NSRange(output.startIndex..., in: output)
        guard let match = expression.matches(in: output, range: range).last else { return nil }
        let group = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
        guard let swiftRange = Range(group, in: output) else { return nil }
        guard let number = Double(output[swiftRange]), number.isFinite else { return nil }
        return number
    }
}

/// One question put to Claude outside any conversation the person sees: a fork of a task that is
/// never saved, or a fresh call, with an answer bound to a JSON schema. Read-only tools, no MCP
/// servers and no hooks, so the question can neither change the machine nor be held up by
/// anything the person's own settings run at the end of a turn.
enum ExpertAsk {
    struct Request: Sendable {
        var directory: String
        var resume: String?
        var model: String
        var prompt: String
        var schema: String
        var timeout: TimeInterval = 300
    }

    static func arguments(_ request: Request) -> [String] {
        var arguments = ["-p", "--no-session-persistence"]
        if let resume = request.resume { arguments += ["--resume", resume, "--fork-session"] }
        arguments += [
            "--model", request.model, "--output-format", "json", "--json-schema", request.schema,
            "--tools", "Read,Grep,Glob", "--strict-mcp-config", "--settings", #"{"disableAllHooks":true}"#,
            request.prompt,
        ]
        return arguments
    }

    static func ask(claudePath: String, _ request: Request) async -> (answer: [String: Any]?, failure: String?) {
        let result = await CommandRunner.run(
            claudePath, arguments(request), directory: request.directory, timeout: request.timeout,
            environment: ["CLAUDE_CODE_ENTRYPOINT": "claude-bridge-expert"])
        if result.timedOut { return (nil, "Claude took too long to answer.") }
        return read(result.output)
    }

    /// The structured answer out of `--output-format json`, or why there is none.
    static func read(_ output: String) -> (answer: [String: Any]?, failure: String?) {
        let line = output.split(separator: "\n").last { $0.hasPrefix("{") }.map(String.init) ?? output
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return (nil, CommandRunner.tail(output, lines: 3, bytes: 400).nilIfEmpty ?? "Claude gave no answer.")
        }
        if let structured = object["structured_output"] as? [String: Any] { return (structured, nil) }
        if let text = object["result"] as? String,
            let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        {
            return (parsed, nil)
        }
        if object["is_error"] as? Bool == true {
            return (nil, (object["result"] as? String).map { String($0.prefix(400)) } ?? "Claude could not answer.")
        }
        return (nil, "Claude's answer was not in the expected shape.")
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
