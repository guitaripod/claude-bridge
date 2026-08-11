import Foundation

/// A turn this bridge committed to running, written to disk **before** the process is spawned and
/// erased when the turn settles.
///
/// Everything else about a turn lives in memory, which is correct while the process is alive and
/// worthless the moment it is not: a machine that loses power mid-turn comes back with the user's
/// prompt in the transcript, no reply, nothing that says a reply was ever coming, and a queue of
/// follow-up prompts that simply ceased to exist. The journal is the one record that survives that,
/// and it is deliberately small — what was asked, what it was asked of, and what was waiting behind
/// it — because on the way back up the transcript is the authority on what actually happened.
struct TurnRecord: Codable, Sendable {
    /// This attempt, not the session: a session interrupted twice has two records over its life and
    /// a resume must be able to say which one it is picking up.
    var turnID: String
    var sessionID: String
    /// The transcript the turn was resuming, when it was resuming one. `nil` is a first turn, whose
    /// transcript id the CLI had not yet minted when the record was written.
    var claudeSessionID: String?
    /// What the CLI was handed — attachment references and all. Kept so a recovered turn can be
    /// re-run byte for byte if that is ever the right thing to do.
    var prompt: String
    /// What the person actually typed, which is what a briefing quotes back.
    var displayPrompt: String
    var model: String
    var effort: String
    var fork: Bool
    var directory: String?
    var startedAt: Date
    /// The claude process, once it exists. A pid that is still alive on the way back up means the
    /// child outlived the bridge and may be finishing the work right now.
    var pid: Int32?
    /// Prompts that were waiting behind this turn. They are the part of an interruption most easily
    /// lost and least easily reconstructed — nobody remembers what they queued twenty minutes ago.
    var queued: [QueuedRecord] = []
}

struct QueuedRecord: Codable, Sendable {
    var prompt: String
    var displayPrompt: String
    var model: String?
    var effort: String?
}

/// Every open turn on this machine, keyed by session. One file, rewritten atomically — turns start
/// and end on a human timescale, so the cost is irrelevant and the simplicity is not.
struct TurnJournal: Codable, Sendable {
    var turns: [String: TurnRecord] = [:]

    static func url(besides storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("turns.json")
    }

    static func load(from url: URL) -> TurnJournal {
        guard let data = try? Data(contentsOf: url),
            let journal = try? JSONCoding.decoder.decode(TurnJournal.self, from: data)
        else { return TurnJournal() }
        return journal
    }

    func write(to url: URL) {
        guard let data = try? JSONCoding.encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// What a turn had already done when the machine stopped, read off the CLI's own transcript rather
/// than off anything the bridge remembered — the transcript is the only account that survived.
struct InterruptionProgress: Codable, Sendable {
    var toolCount: Int = 0
    var lastTool: String?
    var filesTouched: [String] = []
    var commands: [String] = []
    /// How far the answer had got. Truncated: this is evidence, not a transcript.
    var partialAnswer: String?

    var isEmpty: Bool {
        toolCount == 0 && filesTouched.isEmpty && commands.isEmpty && partialAnswer == nil
    }
}

/// A turn that was running when the bridge stopped and was not running when it came back.
///
/// This is a first-class state, not an error string: the difference between "the model had nothing
/// to say" and "the machine was pulled out from under it half way through editing your files" is
/// the whole difference, and a session that cannot tell them apart quietly loses work. It stays on
/// the session until it is resumed or dismissed, so a client that was not connected at the time
/// still finds out.
struct Interruption: Codable, Sendable {
    var turnID: String
    var prompt: String
    var startedAt: Date
    var detectedAt: Date
    var claudeSessionID: String?
    var progress: InterruptionProgress
    /// Prompts that were queued behind the interrupted turn and never ran.
    var queued: [String]
    /// Set once a resume has been sent, so the banner stops asking without the record being lost.
    var resumedAt: Date?

    var isResumed: Bool { resumedAt != nil }
}
