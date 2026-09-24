import Foundation

/// What the operating system lets this bridge — and so every agent it starts — touch.
///
/// macOS asks a person before a process reads their Documents, Desktop, Downloads, other apps'
/// data or a network volume, and it asks on the Mac's own screen. A bridge is a daemon that
/// nobody is watching, so without a standing grant an agent's turn stalls behind a dialog on a
/// machine across the room, or fails the read outright. Full Disk Access is the one grant that
/// covers all of them, and it is kept against the binary's signature (see `install.sh`), so it is
/// given once rather than once per update.
///
/// Nothing here may cause a prompt: the state is read from whether the privacy database itself can
/// be opened, which only Full Disk Access allows and which is never asked for.
struct MachinePermissions: Codable, Sendable {
    struct Grant: Codable, Sendable {
        var id: String
        var state: String
    }

    var platform: String
    var host: String?
    var executable: String?
    var grants: [Grant]
    var requestedAt: Date?

    static let fullDiskAccess = "fullDiskAccess"
}

struct PermissionRequest: Decodable {
    let id: String
}

actor MachinePermissionService {
    private let home: String
    private var requestedAt: Date?
    private var lastProbe: [String] = []

    init(home: String) {
        self.home = home
    }

    func status() -> MachinePermissions {
        #if os(macOS)
            MachinePermissions(
                platform: "macos", host: Self.hostName(), executable: Self.executable()?.path,
                grants: [
                    .init(
                        id: MachinePermissions.fullDiskAccess,
                        state: hasFullDiskAccess() ? "granted" : "missing")
                ],
                requestedAt: requestedAt)
        #else
            MachinePermissions(
                platform: "linux", host: Self.hostName(), executable: nil, grants: [],
                requestedAt: nil)
        #endif
    }

    /// Opens the Full Disk Access list in System Settings on this Mac and shows the bridge's binary
    /// in Finder beside it, so the one step left for the person at the machine is to drag it in
    /// (or switch it on, when a previous build already put it there).
    func request(_ id: String) throws -> MachinePermissions {
        #if os(macOS)
            guard id == MachinePermissions.fullDiskAccess else {
                throw MachinePermissionError.unknown(id)
            }
            Self.open([
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
            ])
            if let executable = Self.executable() {
                Self.open(["-R", executable.path])
            }
            requestedAt = Date()
            return status()
        #else
            throw MachinePermissionError.notApplicable
        #endif
    }

    /// Asked of a fresh child rather than of this process: a child is what an agent is, it answers
    /// to the bridge's grant the same way, and it reads a grant switched on since the bridge started
    /// instead of whatever this long-lived process was told the first time it looked. Two places
    /// only Full Disk Access opens and none ever prompts for: Safari's folder, which every Mac has,
    /// and the privacy database itself.
    private func hasFullDiskAccess() -> Bool {
        let library = URL(fileURLWithPath: home).appendingPathComponent("Library")
        let probes: [(String, [String])] = [
            ("/bin/ls", [library.appendingPathComponent("Safari").path]),
            ("/usr/bin/head", ["-c", "1", library.appendingPathComponent("Application Support/com.apple.TCC/TCC.db").path]),
        ]
        var answers: [String] = []
        var granted = false
        for (tool, arguments) in probes {
            let opened = Self.succeeds(tool, arguments)
            answers.append("\(arguments.last ?? tool)=\(opened)")
            granted = granted || opened
        }
        if lastProbe != answers {
            lastProbe = answers
            print("[permissions] full disk access probe: \(answers.joined(separator: ", "))")
        }
        return granted
    }

    private static func succeeds(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func executable() -> URL? {
        Bundle.main.executableURL?.resolvingSymlinksInPath()
    }

    private static func hostName() -> String? {
        let name = ProcessInfo.processInfo.hostName
        return name.isEmpty ? nil : name.replacingOccurrences(of: ".local", with: "")
    }

    private static func open(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

enum MachinePermissionError: Error {
    case unknown(String)
    case notApplicable

    var message: String {
        switch self {
        case .unknown(let id): return "no permission called \(id)"
        case .notApplicable: return "this machine does not ask for permissions"
        }
    }
}
