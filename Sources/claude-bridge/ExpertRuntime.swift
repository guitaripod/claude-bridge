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
/// command and everything it started are stopped.
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
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let directory, FileManager.default.fileExists(atPath: directory) {
                    process.currentDirectoryURL = URL(fileURLWithPath: directory)
                }
                var merged = ProcessInfo.processInfo.environment
                for (key, value) in environment { merged[key] = value }
                process.environment = merged
                process.standardInput = FileHandle.nullDevice
                let started = Date()
                let output: Pipe
                do {
                    output = try Spawning.serialized {
                        let pipe = Pipe()
                        process.standardOutput = pipe
                        process.standardError = pipe
                        try process.runAllowingBusyExecutable()
                        return pipe
                    }
                } catch {
                    continuation.resume(
                        returning: CommandResult(
                            exitCode: -1, output: error.localizedDescription, seconds: 0, timedOut: false,
                            launched: false))
                    return
                }
                let pid = process.processIdentifier
                let timedOut = TimeoutFlag()
                let killer = DispatchWorkItem {
                    timedOut.set()
                    ProcessTree.stop(pid)
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                continuation.resume(
                    returning: CommandResult(
                        exitCode: process.terminationStatus,
                        output: String(decoding: data, as: UTF8.self),
                        seconds: Date().timeIntervalSince(started), timedOut: timedOut.value, launched: true))
            }
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

/// The machine's process table, read with `ps`: who started whom, so a command that overran is
/// stopped with everything it started, and a lock is traced back to the conversation whose
/// process tree holds it.
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

    static func descendants(of root: Int32, in table: [Int32: Int32]) -> [Int32] {
        var children: [Int32: [Int32]] = [:]
        for (pid, parent) in table { children[parent, default: []].append(pid) }
        var found: [Int32] = []
        var queue = children[root] ?? []
        while let next = queue.popLast(), found.count < 4_000 {
            found.append(next)
            queue.append(contentsOf: children[next] ?? [])
        }
        return found
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

    /// SIGTERM to the process and everything under it, SIGKILL five seconds later for whatever
    /// is still there.
    static func stop(_ pid: Int32) {
        let all = [pid] + descendants(of: pid, in: parents())
        for member in all { kill(member, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            for member in all where kill(member, 0) == 0 { kill(member, SIGKILL) }
        }
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
        item.state = PortProbe.open(host: item.host ?? "127.0.0.1", port: port, timeout: 2) ? "ready" : "absent"
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
                coreDeviceID: nil)
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

    static func pymobiledevice3() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates =
            (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/pymobiledevice3" }
            + ["\(home)/.local/share/pmd-venv/bin/pymobiledevice3", "\(home)/.local/bin/pymobiledevice3"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Whether something is listening on a TCP port, asked with a plain connect and a deadline.
enum PortProbe {
    static func open(host: String, port: Int, timeout: TimeInterval) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if os(macOS)
            hints.ai_socktype = SOCK_STREAM
        #else
            hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let first = info else { return false }
        defer { freeaddrinfo(info) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            let fd = socket(entry.pointee.ai_family, entry.pointee.ai_socktype, entry.pointee.ai_protocol)
            if fd >= 0 {
                let flags = fcntl(fd, F_GETFL, 0)
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
                let result = connect(fd, entry.pointee.ai_addr, entry.pointee.ai_addrlen)
                var reached = result == 0
                if !reached, errno == EINPROGRESS {
                    var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&poller, 1, Int32(timeout * 1000)) == 1 {
                        var error: Int32 = 0
                        var length = socklen_t(MemoryLayout<Int32>.size)
                        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
                        reached = error == 0
                    }
                }
                close(fd)
                if reached { return true }
            }
            cursor = entry.pointee.ai_next
        }
        return false
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
        return Double(output[swiftRange].replacingOccurrences(of: ",", with: "."))
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
