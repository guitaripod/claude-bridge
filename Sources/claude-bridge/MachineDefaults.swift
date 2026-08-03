import Foundation

/// The model and effort the machine's own Claude would run with — read from
/// `~/.claude/settings.json`, where the CLI saves every `/model` and effort
/// pick, so a chat that names nothing runs what the terminal would run instead
/// of a bridge-invented constant. `BRIDGE_MODEL`/`BRIDGE_EFFORT` still win when
/// set; the hardcoded pair is only the last resort for a machine whose settings
/// file names neither. The file is re-read whenever its mtime moves, so a
/// `/model` pick in a terminal changes what the next new chat runs without a
/// bridge restart.
final class MachineDefaults: @unchecked Sendable {
    private let modelOverride: String?
    private let effortOverride: String?
    private let settingsURL: URL
    private let lock = NSLock()
    private var cached: (model: String?, effort: String?) = (nil, nil)
    private var cachedMtime: Date?

    init(modelOverride: String?, effortOverride: String?, home: String) {
        self.modelOverride = modelOverride
        self.effortOverride = effortOverride
        self.settingsURL = URL(fileURLWithPath: home)
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    func model() -> String { modelOverride ?? settings().model ?? "sonnet" }
    func effort() -> String { effortOverride ?? settings().effort ?? "medium" }

    private func settings() -> (model: String?, effort: String?) {
        lock.lock()
        defer { lock.unlock() }
        let resolved = settingsURL.resolvingSymlinksInPath()
        let mtime = (try? FileManager.default.attributesOfItem(atPath: resolved.path))?[
            .modificationDate] as? Date
        if let cachedMtime, cachedMtime == mtime { return cached }
        cachedMtime = mtime
        cached = Self.read(resolved)
        return cached
    }

    private static func read(_ url: URL) -> (model: String?, effort: String?) {
        guard let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (nil, nil) }
        return (
            model: nonEmpty(object["model"] as? String),
            effort: nonEmpty(object["effortLevel"] as? String))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
